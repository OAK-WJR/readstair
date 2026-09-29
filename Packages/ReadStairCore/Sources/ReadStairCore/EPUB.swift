import Foundation

/// DRM-free EPUB 2 and 3: the title, the author, the cover image, and the text of the spine's XHTML documents in reading order, in
/// page-break units.
/// Each document starts a unit, and so does each entry of the book's own table of contents that points into the text, which gives
/// that unit its label. Copy-protected books, and books whose `dc:language` is clearly not English, are refused.
enum EPUB {
    /// Font obfuscation (IDPF's and Adobe's) is the one use of encryption.xml that leaves the text readable.
    private static let fontObfuscation: Set<String> = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
    /// A table of contents with more entries is ignored, a bound on the page breaks a crafted book can ask for.
    static let maxContentsEntries = 5_000

    static func read(_ data: Data) throws(EBookError) -> EBook {
        let archive = try ZipArchive(data)
        // Copy protection: a rights file (Adobe's, Apple's), or encryption.xml encrypting more than fonts
        if archive.paths.contains("META-INF/rights.xml") || archive.paths.contains("META-INF/sinf.xml") { throw .drm }
        let encryption = try archive.data(at: "META-INF/encryption.xml")
        if let encryption {
            guard let methods = XMLElements.parse(encryption)?.filter({ $0.name == "EncryptionMethod" }),
                  methods.allSatisfy({ fontObfuscation.contains($0.attributes["Algorithm"] ?? "") }) else { throw .drm }
        }

        // The package document's path is resolved like an href, so a leading "/" or "./" finds it too
        guard let container = try archive.data(at: "META-INF/container.xml").flatMap(XMLElements.parse),
              let fullPath = container.first(where: { $0.name == "rootfile" })?.attributes["full-path"],
              case let packagePath = path(of: fullPath, from: ""),
              let package = try archive.data(at: packagePath).flatMap(XMLElements.parse) else { throw .unreadable }
        // Refused only when every language named is known and not English: "und" (undetermined) and "mul" (several) pass. The
        // primary subtag is compared whole, so "en-GB", "eng" and the full name "English" are English and "enq" is not.
        let languages = package.filter { $0.name == "language" && !$0.text.isEmpty }
            .map { $0.text.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "" }
        if !languages.isEmpty, !languages.contains(where: { ["en", "eng", "english", "und", "mul"].contains($0) }) { throw .notEnglish }

        let items = Dictionary(package.filter { $0.name == "item" }.map { ($0.attributes["id"] ?? "", $0.attributes) },
                               uniquingKeysWith: { first, _ in first })
        // The spine's text as one run of blocks, and each file read: where its blocks are in the run, and its anchors
        var blocks: [TextBlock] = []
        var files: [String: (blocks: Range<Int>, anchors: [String: Int])] = [:]
        var readPaths: Set<String> = []
        var characters = 0
        for itemref in package where itemref.name == "itemref" && itemref.attributes["linear"] != "no" {
            // Only XHTML, not the navigation document (a table of contents), and each file once
            guard let item = items[itemref.attributes["idref"] ?? ""], mediaType(item) == "application/xhtml+xml",
                  !isNavigation(item), let href = item["href"], case let file = path(of: href, from: packagePath),
                  readPaths.insert(file).inserted, let text = try archive.data(at: file).flatMap(XHTMLText.read),
                  !text.blocks.isEmpty else { continue }
            // Counted as it is read: a crafted book could otherwise inflate gigabytes of text before EBookReader checks the total
            characters += text.blocks.reduce(0) { $0 + $1.text.count }
            guard characters <= EBookReader.maxCharacters else { throw .tooLarge }
            files[file] = (blocks.count..<blocks.count + text.blocks.count, text.anchors)
            blocks += text.blocks
        }
        // With encryption.xml, no readable text at all means the text itself is encrypted
        guard !blocks.isEmpty else { throw encryption == nil ? .empty : .drm }

        // The entries kept, in the table's order: each where it starts in the run, with its label. An entry is dropped if its file
        // was not read, its anchor is unknown or has no text after it in its file, or its label is blank; also if it starts before
        // the last entry kept. One that starts where the last entry kept does replaces it.
        var entries: [(start: Int, label: String)] = []
        if let contents = tableOfContents(package, items: items, packagePath: packagePath, archive: archive),
           contents.links.count <= maxContentsEntries {
            for link in contents.links {
                let fragment = link.href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first ?? ""
                guard let file = files[path(of: link.href, from: contents.path)], let label = label(link.label) else { continue }
                var start = file.blocks.lowerBound
                if !fragment.isEmpty {
                    guard let anchor = file.anchors[fragment.removingPercentEncoding ?? String(fragment)],
                          anchor < file.blocks.count else { continue }
                    start += anchor
                }
                if let last = entries.last {
                    guard start >= last.start else { continue }
                    if start == last.start { entries.removeLast() }
                }
                entries.append((start, label))
            }
        }

        // Units break at every file's start and at every entry kept, and an entry's unit takes its label. Without entries, each
        // file is one unit.
        let labels = Dictionary(uniqueKeysWithValues: entries.map { ($0.start, $0.label) })
        let starts = Set(files.values.map { $0.blocks.lowerBound }).union(labels.keys).sorted()
        let chapters = zip(starts, starts.dropFirst() + [blocks.count]).map { start, end in
            EBook.Chapter(title: labels[start], blocks: Array(blocks[start..<end]))
        }
        let title = package.first { $0.name == "title" && !$0.text.isEmpty }?.text
        let author = package.first { $0.name == "creator" && !$0.text.isEmpty }?.text
        return EBook(title: title, chapters: chapters, author: author, cover: cover(package, items: items, packagePath: packagePath,
                                                                                  archive: archive))
    }

    /// The cover image's bytes: the manifest item whose `properties` hold `cover-image` (EPUB 3), else the one a `<meta name="cover">`
    /// names by its id, or by its href as some books have it (EPUB 2). Nil if there is none or it cannot be read (an entry over the
    /// size limit too). Whether it is an image the app can use is the typesetter's call (`TypesetBook.usableCover`).
    private static func cover(_ package: [XMLElements.Element], items: [String: [String: String]], packagePath: String,
                              archive: ZipArchive) -> Data? {
        let declared = package.first { element in
            element.name == "item" && (element.attributes["properties"] ?? "").split(separator: " ").contains("cover-image")
        }?.attributes["href"]
        let named = package.first { $0.name == "meta" && $0.attributes["name"] == "cover" }?.attributes["content"]
        guard let href = declared ?? named.flatMap({ items[$0]?["href"] ?? $0 }) else { return nil }
        return try? archive.data(at: path(of: href, from: packagePath))
    }

    /// The archive path of an href in the package document: relative to the package document's folder, without its fragment,
    /// percent-decoded, with `.` and `..` resolved.
    static func path(of href: String, from packagePath: String) -> String {
        let file = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        var parts = packagePath.split(separator: "/").dropLast()
        for part in (file.removingPercentEncoding ?? String(file)).split(separator: "/") {
            if part == ".." {
                _ = parts.popLast()
            } else if part != "." {
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    /// The book's table of contents: the path of its file, and its links in document order. The navigation document's `<nav>`
    /// whose `epub:type` has `toc`, else its first `<nav>`; without one, or when that has no link, the NCX the spine names, else the
    /// one the manifest lists. Nil if there is none, or it cannot be read: the book is read without it.
    private static func tableOfContents(_ package: [XMLElements.Element], items: [String: [String: String]], packagePath: String,
                                        archive: ZipArchive) -> (path: String, links: [ContentsLink])? {
        func document(_ item: [String: String]?) -> (path: String, data: Data)? {
            guard let href = item?["href"], case let file = path(of: href, from: packagePath),
                  let data = try? archive.data(at: file) else { return nil }
            return (file, data)
        }
        let manifest = package.filter { $0.name == "item" }.map(\.attributes)
        if let navigation = document(manifest.first(where: isNavigation)),
           let navs = XHTMLText.parsed(navigation.data, into: NavLinks())?.navs,
           let nav = navs.first(where: { $0.types.contains("toc") }) ?? navs.first, !nav.links.isEmpty {
            return (navigation.path, nav.links)
        }
        let named = package.first { $0.name == "spine" }?.attributes["toc"].flatMap { items[$0] }
        guard let ncx = document(named ?? manifest.first { mediaType($0) == "application/x-dtbncx+xml" }),
              let points = XHTMLText.parsed(ncx.data, into: NCXPoints()) else { return nil }
        return (ncx.path, points.links)
    }

    /// A manifest item's media type, lowercased, without parameters.
    private static func mediaType(_ item: [String: String]) -> String? {
        item["media-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Whether a manifest item is the navigation document.
    private static func isNavigation(_ item: [String: String]) -> Bool {
        (item["properties"] ?? "").split(separator: " ").contains("nav")
    }

    /// A table of contents label: `text` with its whitespace collapsed to single spaces, capped at `TypesetBook.maxTitleLength` and
    /// trimmed (a cap that falls on a space leaves none at the end); nil if it is blank.
    private static func label(_ text: String) -> String? {
        let label = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(TypesetBook.maxTitleLength)
            .trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }
}

/// A table of contents entry as its file has it: the href it points to, and its label's text.
private typealias ContentsLink = (href: String, label: String)

/// The elements of a small XML document in document order, by local name (namespaces ignored), with their attributes and their
/// own text, whitespace collapsed. Enough for container.xml, encryption.xml and the package document.
private final class XMLElements: NSObject, XMLParserDelegate {
    struct Element {
        var name: String
        var attributes: [String: String]
        var text = ""
    }

    private var elements: [Element] = []
    private var open: [Int] = []

    /// Nil if the document is not well-formed XML, even with its HTML entities made numeric (a `dc:description` may use them).
    static func parse(_ data: Data) -> [Element]? {
        XHTMLText.parsed(data, into: XMLElements())?.elements.map { element in
            var element = element
            element.text = element.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return element
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        open.append(elements.count)
        elements.append(Element(name: name, attributes: attributes))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let index = open.last { elements[index].text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let index = open.last { elements[index].text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        open.removeLast()
    }
}

/// A navigation document's `<nav>` elements, each with the words of its `epub:type` and its links in document order: every `<a
/// href>` inside it, a nested list's too, labelled with all the text inside the `<a>`, a `<br>` read as a space. Past
/// `EPUB.maxContentsEntries` a nav's links are no longer kept, only one more to show there are too many.
private final class NavLinks: NSObject, XMLParserDelegate {
    struct Nav {
        var types: [Substring]
        var links: [ContentsLink] = []
    }

    private(set) var navs: [Nav] = []
    /// The `<nav>` elements open: one inside another is part of it.
    private var navDepth = 0
    /// Inside a link, the elements open in it, the `<a>` counted.
    private var linkDepth = 0
    private var link: ContentsLink = ("", "")

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if linkDepth > 0 {
            linkDepth += 1
            if name == "br" { link.label += " " }
        } else if name == "nav" {
            if navDepth == 0 { navs.append(Nav(types: (attributes["epub:type"] ?? "").split(whereSeparator: \.isWhitespace))) }
            navDepth += 1
        } else if navDepth > 0, name == "a", let href = attributes["href"] {
            linkDepth = 1
            link = (href, "")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if linkDepth > 0 { link.label += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if linkDepth > 0 { link.label += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if linkDepth > 0 {
            linkDepth -= 1
            if linkDepth == 0, navs[navs.count - 1].links.count <= EPUB.maxContentsEntries { navs[navs.count - 1].links.append(link) }
        } else if name == "nav" {
            navDepth -= 1
        }
    }
}

/// An NCX's table of contents: the `navPoint`s of its `navMap` in document order, each before those nested in it, as links: its
/// `content`'s `src`, labelled with the text of its first `navLabel` that has any. Past `EPUB.maxContentsEntries` the parse is
/// abandoned, and the table with it.
private final class NCXPoints: NSObject, XMLParserDelegate {
    private(set) var links: [ContentsLink] = []
    /// The elements open, by name.
    private var open: [String] = []
    /// The navPoints open, as indices into `links`.
    private var points: [Int] = []
    private var inLabel = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let parent = open.last
        open.append(name)
        if name == "navPoint", open.contains("navMap") {
            guard links.count < EPUB.maxContentsEntries else { return parser.abortParsing() }
            points.append(links.count)
            links.append(("", ""))
        } else if let point = points.last {
            if name == "content", parent == "navPoint", links[point].href.isEmpty { links[point].href = attributes["src"] ?? "" }
            // A navLabel of the innermost navPoint open: one of a nested navPoint's would have opened that navPoint first
            if name == "text", parent == "navLabel", open.dropLast(2).last == "navPoint", links[point].label.isEmpty { inLabel = true }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inLabel, let point = points.last { links[point].label += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inLabel, let point = points.last { links[point].label += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        open.removeLast()
        if name == "navPoint", open.contains("navMap") { points.removeLast() }
        if name == "text" { inLabel = false }
    }
}
