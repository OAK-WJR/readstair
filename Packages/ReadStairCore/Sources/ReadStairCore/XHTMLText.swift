import Foundation

/// The text of one XHTML document as headings and paragraphs, in reading order, and where its anchors are. Only `<body>` is read;
/// page-break markers, notes and note references, inline SVG and MathML, Project Gutenberg's header and footer (its license) and
/// Standard Ebooks' boilerplate are left out. `<br>` is a line break inside the block: U+2028 LINE SEPARATOR. Ported from the
/// paragraph collector of tools/make-fixtures.swift.
enum XHTMLText {
    /// The blocks, and each anchor (an `id`, or a `name` on `<a>`, of `<body>` or of an element in it that is read) with the index
    /// of the block it starts: the block that holds an inline element, 0 for `<body>`, the blocks' count for one after the last
    /// block. The first of a repeated anchor counts. Nil if the document is not well-formed XML, even with its HTML entities made
    /// numeric.
    static func read(_ data: Data) -> (blocks: [TextBlock], anchors: [String: Int])? {
        parsed(data, into: BlockCollector()).map { (blocks: $0.blocks, anchors: $0.anchors) }
    }

    /// `delegate` after it has been given `data`, with its HTML entities made numeric and namespaces processed; nil if `data` is not
    /// well-formed XML.
    static func parsed<Delegate: XMLParserDelegate>(_ data: Data, into delegate: Delegate) -> Delegate? {
        let parser = XMLParser(data: numericEntities(data))
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        return parser.parse() ? delegate : nil
    }

    /// XMLParser knows only XML's own five named entities: it fails on HTML's (`&nbsp;`, `&mdash;`), or drops them without a word
    /// when the document names a DTD. So each becomes a numeric reference; a name not in the table becomes a space. An `&` that
    /// starts no reference at all (AT&T) fails the parse too, so it becomes `&amp;`. The bytes are scanned as ASCII, which leaves
    /// UTF-8 intact and a UTF-16 document untouched. Also run on the package document.
    static func numericEntities(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "&"), let end = bytes[(index + 1)...].prefix(33).firstIndex(of: UInt8(ascii: ";")),
               let name = String(bytes: bytes[(index + 1)..<end], encoding: .ascii),
               name.first?.isLetter == true, name.allSatisfy({ $0.isLetter || $0.isNumber }) {
                let xml = ["amp", "lt", "gt", "quot", "apos"].contains(name)
                output += (xml ? "&\(name);" : entities[name].map { "&#\($0);" } ?? " ").utf8
                index = end + 1
            } else if bytes[index] == UInt8(ascii: "&"), !startsCharacterReference(bytes[(index + 1)...]) {
                output += "&amp;".utf8
                index += 1
            } else if bytes[index] == UInt8(ascii: "<"), bytes[index...].starts(with: "<![CDATA[".utf8),
                      let close = bytes[index...].firstRange(of: "]]>".utf8) {
                // A CDATA section's text stands as written: nothing in it is a reference
                output += bytes[index..<close.upperBound]
                index = close.upperBound
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return Data(output)
    }

    /// Whether `rest`, the bytes after an `&`, start an XML character reference: `#` and decimal digits or `#x` and hex digits,
    /// then `;`.
    private static func startsCharacterReference(_ rest: ArraySlice<UInt8>) -> Bool {
        guard let end = rest.prefix(12).firstIndex(of: UInt8(ascii: ";")),
              let reference = String(bytes: rest[..<end], encoding: .ascii), reference.hasPrefix("#") else { return false }
        let hex = reference.hasPrefix("#x"), digits = reference.dropFirst(hex ? 2 : 1)
        return !digits.isEmpty && digits.allSatisfy { hex ? $0.isHexDigit : ("0"..."9").contains($0) }
    }

    /// HTML's Latin-1 entities (U+00A0 to U+00FF, in order) and the punctuation books use.
    private static let entities: [String: Int] = {
        var table = ["OElig": 338, "oelig": 339, "ensp": 8194, "emsp": 8195, "thinsp": 8201, "ndash": 8211, "mdash": 8212,
                     "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "dagger": 8224,
                     "Dagger": 8225, "bull": 8226, "hellip": 8230, "prime": 8242, "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250,
                     "euro": 8364, "trade": 8482]
        let latin1 = """
            nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 acute micro para \
            middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute \
            Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute \
            THORN szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde \
            ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml
            """
        for (offset, name) in latin1.split(separator: " ").enumerated() { table[String(name)] = 0xA0 + offset }
        return table
    }()
}

/// Collects blocks: each block element flushes the text so far at its start and at its end, as a heading inside h1–h6 or hgroup
/// and as a paragraph elsewhere. Inline elements (em, a, span) only add their text. Anchors are noted where their element starts,
/// after a block element's flush.
private final class BlockCollector: NSObject, XMLParserDelegate {
    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "hgroup"]
    private static let blockElements = headings.union(["p", "div", "li", "blockquote", "dd", "dt", "pre", "tr", "section"])
    /// SVG and MathML inside a chapter hold a picture's labels or a formula, not the book's prose.
    private static let skippedElements: Set<String> = ["head", "script", "style", "svg", "math"]
    private static let skippedIDs: Set<String> = ["pg-header", "pg-footer"]
    /// Page breaks, notes, and a publisher's boilerplate (Standard Ebooks' imprint, colophon, copyright page and list of
    /// illustrations: several pages a book), and the title and half-title pages, which only repeat the cover's title and author.
    /// Compared with each word of `epub:type` and `role`, less a vocabulary prefix (`z3998:`) or ARIA's `doc-`, so `doc-pagebreak`
    /// counts too. Not `title`: chapter headings carry it.
    private static let skippedTypes: Set<String> = ["pagebreak", "footnote", "footnotes", "endnote", "endnotes", "noteref",
                                                    "imprint", "colophon", "copyright-page", "loi", "titlepage", "halftitlepage"]

    private(set) var blocks: [TextBlock] = []
    private(set) var anchors: [String: Int] = [:]
    private var text = ""
    private var inBody = false
    /// Above zero inside a skipped element: counts the elements open inside it.
    private var skipDepth = 0
    private var headingDepth = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let words = (attributes["epub:type"] ?? "") + " " + (attributes["role"] ?? "")
        let types = words.split(whereSeparator: \.isWhitespace).map { word in
            let type = word.split(separator: ":").last ?? word
            return type.hasPrefix("doc-") ? String(type.dropFirst(4)) : String(type)
        }
        if skipDepth > 0 || Self.skippedElements.contains(name) || Self.skippedIDs.contains(attributes["id"] ?? "")
            || types.contains(where: Self.skippedTypes.contains) {
            skipDepth += 1
            return
        }
        if name == "body" {
            inBody = true
        } else if Self.blockElements.contains(name) {
            flush()
            if Self.headings.contains(name) { headingDepth += 1 }
        } else if name == "br" {
            text += "\u{2028}"
        } else if ["td", "th"].contains(name) {
            text += " "
        }
        guard inBody else { return }
        for anchor in [attributes["id"], name == "a" ? attributes["name"] : nil].compactMap(\.self) where anchors[anchor] == nil {
            anchors[anchor] = blocks.count
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inBody, skipDepth == 0 { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inBody, skipDepth == 0 { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skipDepth > 0 {
            skipDepth -= 1
        } else if name == "body" {
            flush()
            inBody = false
        } else if Self.blockElements.contains(name) {
            flush()
            if Self.headings.contains(name) { headingDepth -= 1 }
        }
    }

    /// Ends the block collected so far, if it has any text, with its whitespace collapsed.
    private func flush() {
        let block = EBookReader.collapsingWhitespace(text)
        text = ""
        if !block.isEmpty { blocks.append(headingDepth > 0 ? .heading(block) : .paragraph(block)) }
    }
}
