import Foundation
import Testing
@testable import ReadStairCore

/// U-EPUB-008–012: an EPUB's own table of contents (the navigation document, else the NCX) splits its text into page-break units
/// and labels them, and `<br>` is a line break. Synthetic books built in memory with ZipWriter, through EPUBTests' builder.
extension EPUBTests {
    private static func item(_ id: String, _ href: String, _ extra: String = "") -> String {
        #"<item id="\#(id)" href="\#(href)" media-type="application/xhtml+xml"\#(extra)/>"#
    }

    private static func spine(_ ids: String...) -> String {
        ids.map { #"<itemref idref="\#($0)"/>"# }.joined()
    }

    /// A `toc` nav listing `entries` (href, label) in one flat list.
    private static func tocNav(_ entries: [(String, String)]) -> String {
        #"<nav epub:type="toc"><ol>"# + entries.map { #"<li><a href="\#($0.0)">\#($0.1)</a></li>"# }.joined() + "</ol></nav>"
    }

    /// An NCX whose navMap is `points`.
    private static func ncx(_ points: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>Test Book</text></docTitle>
        <navMap>\(points)</navMap>
        <pageList><pageTarget type="normal" value="2"><navLabel><text>2</text></navLabel><content src="text/one.xhtml#p2"/></pageTarget>
        </pageList></ncx>
        """
    }

    private static func point(_ label: String, _ src: String, _ nested: String = "") -> String {
        "<navPoint><navLabel><text>\(label)</text></navLabel><content src=\"\(src)\"/>\(nested)</navPoint>"
    }

    /// Two files: one.xhtml (a heading and two paragraphs, then a second heading at `middle` and a paragraph) and, in a file whose
    /// name needs %20, a paragraph before a section `two`.
    private static let twoFiles = [
        ("OEBPS/text/one.xhtml", xhtml(#"<h1>One</h1><p>First.</p><p id="p2">Page two.</p><h2 id="middle">Half</h2><p>Middle.</p>"#)),
        ("OEBPS/text/Chapter Two.xhtml", xhtml(#"<p>Before.</p><section id="two"><h1>Two</h1><p>Second.</p></section>"#)),
    ]
    private static let twoFilesManifest = item("one", "text/one.xhtml") + item("two", "text/Chapter%20Two.xhtml")
    private static let twoFilesBlocks: [[TextBlock]] = [
        [.heading("One"), .paragraph("First."), .paragraph("Page two.")], [.heading("Half"), .paragraph("Middle.")],
        [.paragraph("Before.")], [.heading("Two"), .paragraph("Second.")],
    ]

    @Test("U-EPUB-008 Nav: entries in document order, nested ones flattened; hrefs relative to the nav (a subfolder, ../, ./, %20, #fragment); labels are all the link's text, <br> as a space, collapsed, capped at 100 and trimmed; the toc nav beats a landmarks and a page-list nav before it, else the first nav counts; the nav is never a unit")
    func navigationDocument() throws {
        // Its 100th character is a space, which the cap must not leave at the end
        let long = String(repeating: "Long text ", count: 15)
        let nav = Self.xhtml("""
            <nav epub:type="page-list"><ol><li><a href="../text/one.xhtml#p2">2</a></li></ol></nav>
            <nav epub:type="landmarks"><ol><li><a href="../text/Chapter%20Two.xhtml">Start</a></li></ol></nav>
            <nav epub:type="toc" id="toc"><h2>Contents</h2><ol>
              <li><a href="../text/one.xhtml"> One:<br/>The   <em>First</em>
                  </a><ol><li><a href="../text/./one.xhtml#middle">One and a Half</a></li></ol></li>
              <li><span>Part Two</span><ol><li><a href="../nav/../text/Chapter%20Two.xhtml#two">\(long)</a></li></ol></li>
            </ol></nav>
            """)
        // The nav is also in the spine: it is still never read as text
        let book = try EBookReader.read(epub(manifest: Self.item("nav", "nav/toc.xhtml", #" properties="nav""#) + Self.twoFilesManifest,
                                             spine: Self.spine("nav", "one", "two"),
                                             files: [("OEBPS/nav/toc.xhtml", nav)] + Self.twoFiles))
        #expect(book.chapters.map(\.title) == ["One: The First", "One and a Half", nil, String(long.prefix(99))])
        #expect(book.chapters.map(\.blocks) == Self.twoFilesBlocks)

        // Without a toc nav, the first nav is the table of contents
        let untyped = Self.xhtml(#"<nav><ol><li><a href="text/one.xhtml#middle">Half</a></li></ol></nav>"#
                                      + #"<nav epub:type="landmarks"><ol><li><a href="text/one.xhtml">Start</a></li></ol></nav>"#)
        let first = try EBookReader.read(epub(manifest: Self.item("nav", "nav.xhtml", #" properties="nav""#) + Self.twoFilesManifest,
                                              spine: Self.spine("one", "two"), files: [("OEBPS/nav.xhtml", untyped)] + Self.twoFiles))
        #expect(first.chapters.map(\.title) == [nil, "Half", nil])
        #expect(first.chapters.flatMap(\.blocks) == Self.twoFilesBlocks.flatMap(\.self))
    }

    @Test("U-EPUB-009 NCX: found through the spine's toc, else by its media type; nested navPoints flattened, hrefs relative to the NCX, in a folder of its own too; its pageList is not the table of contents; a nav beats the NCX, unless it has no link")
    func ncx() throws {
        func points(_ folder: String) -> String {
            Self.point("One", folder + "text/one.xhtml", Self.point("Half", folder + "text/one.xhtml#middle"))
                + Self.point(" Two\n ", folder + "text/Chapter%20Two.xhtml#two")
        }
        let files = [("OEBPS/toc.ncx", Self.ncx(points("")))] + Self.twoFiles
        // Named by the spine: its media type does not matter
        let named = try EBookReader.read(epub(manifest: #"<item id="ncx" href="toc.ncx" media-type="text/xml"/>"# + Self.twoFilesManifest,
                                              spine: Self.spine("one", "two"), spineTOC: "ncx", files: files))
        #expect(named.chapters.map(\.title) == ["One", "Half", nil, "Two"])
        #expect(named.chapters.map(\.blocks) == Self.twoFilesBlocks)
        // Found by its media type, in a folder beside the text's: its srcs go through ../
        let listed = try EBookReader.read(epub(manifest: #"<item id="ncx" href="toc/toc.ncx" media-type="application/x-dtbncx+xml"/>"#
                                               + Self.twoFilesManifest, spine: Self.spine("one", "two"),
                                               files: [("OEBPS/toc/toc.ncx", Self.ncx(points("../")))] + Self.twoFiles))
        #expect(listed.chapters.map(\.title) == ["One", "Half", nil, "Two"])

        // With both, the nav's labels count; a toc nav with no link does not, and the NCX's do
        let ncxItem = #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#
        func withNav(_ nav: String) throws -> EBook {
            try EBookReader.read(epub(manifest: ncxItem + Self.item("nav", "nav.xhtml", #" properties="nav""#) + Self.twoFilesManifest,
                                      spine: Self.spine("one", "two"), spineTOC: "ncx", files: files + [("OEBPS/nav.xhtml", nav)]))
        }
        let nav = Self.xhtml(Self.tocNav([("text/one.xhtml", "Nav One"), ("text/Chapter%20Two.xhtml#two", "Nav Two")]))
        #expect(try withNav(nav).chapters.map(\.title) == ["Nav One", nil, "Nav Two"])
        #expect(try withNav(Self.xhtml(Self.tocNav([]))).chapters.map(\.title) == ["One", "Half", nil, "Two"])
    }

    @Test("U-EPUB-010 Entries dropped: into pg-footer, an unknown fragment, one after its file's text, a non-linear, unlisted or image-only file, a blank label, one before the last kept; at an equal position the later label wins; one entry gives one titled unit; over 5,000 entries, nav or NCX, the table is ignored")
    func dropAndMerge() throws {
        let manifest = Self.item("a", "a.xhtml") + Self.item("b", "b.xhtml") + Self.item("c", "c.xhtml") + Self.item("d", "d.xhtml")
            + Self.item("e", "e.xhtml") + Self.item("nav", "nav.xhtml", #" properties="nav""#)
        let files = [
            ("OEBPS/a.xhtml", Self.xhtml(#"<p>A one.</p><p id="a2"><a id="a2b"/>A two.</p><p>A three.</p>"#)),
            ("OEBPS/b.xhtml", Self.xhtml(#"<p>End.</p><a id="tail"/><section id="pg-footer"><h2 id="license">LICENSE</h2></section>"#)),
            ("OEBPS/c.xhtml", Self.xhtml("<p>Non-linear.</p>")), ("OEBPS/d.xhtml", Self.xhtml("<p>Unlisted.</p>")),
            ("OEBPS/e.xhtml", Self.xhtml(#"<figure><img src="art.png" alt="Art"/></figure>"#)),
        ]
        let spine = Self.spine("a", "b") + #"<itemref idref="c" linear="no"/>"# + Self.spine("e")
        let entries = [("a.xhtml", "A"), ("a.xhtml#nowhere", "Unknown"), ("b.xhtml#license", "License"), ("b.xhtml#tail", "Tail"),
                       ("c.xhtml", "Non-linear"), ("d.xhtml", "Unlisted"), ("e.xhtml", "Image"), ("a.xhtml#a2", " <br/> "),
                       ("a.xhtml#a2", "Earlier"), ("a.xhtml#a2b", "Later"), ("a.xhtml", "Back"), ("b.xhtml", "B")]
        func read(_ entries: [(String, String)]) throws -> EBook {
            let nav = ("OEBPS/nav.xhtml", Self.xhtml(Self.tocNav(entries)))
            return try EBookReader.read(epub(manifest: manifest, spine: spine, files: files + [nav]))
        }
        let book = try read(entries)
        #expect(book.chapters.map(\.title) == ["A", "Later", "B"])
        #expect(book.chapters.map(\.blocks)
                == [[.paragraph("A one.")], [.paragraph("A two."), .paragraph("A three.")], [.paragraph("End.")]])

        let single = try read([("a.xhtml#a2", "Only")])
        #expect(single.chapters.map(\.title) == [nil, "Only", nil])
        // A blank label alone: nothing replaces it, so a kept one would split a2 off
        #expect(try read([("a.xhtml#a2", " <br/> ")]).chapters.map(\.title) == [nil, nil])

        // 5,000 entries at one position leave the last label; one more and the table is ignored
        let many = (0..<5_001).map { ("a.xhtml", "Entry \($0)") }
        #expect(try read(Array(many.dropLast())).chapters.map(\.title) == ["Entry 4999", nil])
        #expect(try read(many).chapters.map(\.title) == [nil, nil])
        let points = many.map { Self.point($0.1, $0.0) }
        func readNCX(_ points: [String]) throws -> EBook {
            try EBookReader.read(epub(manifest: #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#
                                      + Self.item("a", "a.xhtml") + Self.item("b", "b.xhtml"),
                                      spine: Self.spine("a", "b"), files: files + [("OEBPS/toc.ncx", Self.ncx(points.joined()))]))
        }
        #expect(try readNCX(Array(points.dropLast())).chapters.map(\.title) == ["Entry 4999", nil])
        #expect(try readNCX(points).chapters.map(\.title) == [nil, nil])
    }

    @Test("U-EPUB-011 Units break at every file start and every kept entry, titles only at entries: text before the first entry is untitled, an inline anchor starts its paragraph, file#bodyid is the file start; the words equal a read without the table; anchors map to blocks")
    func splitting() throws {
        let files = [
            ("OEBPS/f1.xhtml", Self.xhtml(#"<p>Intro one.</p><p>Intro two.</p><h2 id="c1">Chapter 1</h2>"#
                                          + #"<p>Text <a id="mid"/>with an anchor.</p><p>More.</p>"#)),
            ("OEBPS/f2.xhtml", Self.xhtml("<p>Second file.</p>").replacing("<body>", with: #"<body id="f2body">"#)),
            ("OEBPS/f3.xhtml", Self.xhtml(#"<p>Third file.</p><div id="c3"><p>Three.</p></div>"#)),
        ]
        let manifest = Self.item("f1", "f1.xhtml") + Self.item("f2", "f2.xhtml") + Self.item("f3", "f3.xhtml")
        let nav = ("OEBPS/nav.xhtml", Self.xhtml(Self.tocNav([("f1.xhtml#c1", "Chapter 1"), ("f1.xhtml#mid", "Mid"),
                                                                   ("f2.xhtml#f2body", "Second"), ("f3.xhtml#c3", "Three")])))
        let book = try EBookReader.read(epub(manifest: manifest + Self.item("nav", "nav.xhtml", #" properties="nav""#),
                                             spine: Self.spine("f1", "f2", "f3"), files: files + [nav]))
        #expect(book.chapters == [
            EBook.Chapter(blocks: [.paragraph("Intro one."), .paragraph("Intro two.")]),
            EBook.Chapter(title: "Chapter 1", blocks: [.heading("Chapter 1")]),
            EBook.Chapter(title: "Mid", blocks: [.paragraph("Text with an anchor."), .paragraph("More.")]),
            EBook.Chapter(title: "Second", blocks: [.paragraph("Second file.")]),
            EBook.Chapter(blocks: [.paragraph("Third file.")]), EBook.Chapter(title: "Three", blocks: [.paragraph("Three.")]),
        ])
        // Without the table: one untitled unit per file, and the same blocks in the same order
        let plain = try EBookReader.read(epub(manifest: manifest, spine: Self.spine("f1", "f2", "f3"), files: files))
        #expect(plain.chapters.map(\.title) == [nil, nil, nil])
        #expect(plain.chapters.flatMap(\.blocks) == book.chapters.flatMap(\.blocks))

        // Anchors: <body> is 0; a block element after its flush; an inline one, <a name> too, in the block that holds it; after
        // the last block, the count; the first of a repeated id; none in <head> or in skipped content
        let document = #"""
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head id="head"><title id="title">T</title></head>
            <body id="body">Loose <b id="loose">text</b><p id="p1">One <span id="inline">inline</span></p><div id="empty"></div>
            <p>Two <a name="named"/><span id="p1">again</span><span epub:type="pagebreak" id="page3">3</span></p>
            <section id="pg-footer"><p id="license">License.</p></section><a id="after"/></body></html>
            """#
        let read = try #require(XHTMLText.read(Data(document.utf8)))
        #expect(read.blocks == [.paragraph("Loose text"), .paragraph("One inline"), .paragraph("Two again")])
        #expect(read.anchors == ["body": 0, "loose": 0, "p1": 1, "inline": 1, "empty": 2, "named": 2, "after": 3])
    }

    @Test("U-EPUB-012 <br/> is one U+2028 with the whitespace around it collapsed, <br/><br/> too; at a block's start or end it is trimmed; td and th still give a space; U+2028 survives EBookReader beside a soft hyphen")
    func lineBreaks() throws {
        let body = """
            <p><span>How doth</span>  <br/>
               <span>the little</span></p>
            <p>One<br/><br/>two <br/> <br/>three</p><p><br/> Trimmed <br/></p><h2>CHAPTER I.<br/>Down the Rabbit-Hole</h2>
            <table><tr><th>Name</th><td>Alice</td></tr></table><p>Twin\u{AD}kle, twin\u{AD} <br/> kle</p>
            """
        let blocks: [TextBlock] = [.paragraph("How doth\u{2028}the little"), .paragraph("One\u{2028}two\u{2028}three"),
                                   .paragraph("Trimmed"), .heading("CHAPTER I.\u{2028}Down the Rabbit-Hole"), .paragraph("Name Alice")]
        #expect(XHTMLText.read(Data(Self.xhtml(body).utf8))?.blocks == blocks + [.paragraph("Twin\u{AD}kle, twin\u{AD}\u{2028}kle")])
        let book = try EBookReader.read(epub(files: [("OEBPS/text/c1.xhtml", Self.xhtml(body))]))
        #expect(book.chapters.map(\.blocks) == [blocks + [.paragraph("Twinkle, twin\u{2028}kle")]])

        #expect(EBookReader.collapsingWhitespace(" \t a \n b \u{2028}\u{2028} c\u{2028} ") == "a b\u{2028}c")
        #expect(EBookReader.collapsingWhitespace(" \n ").isEmpty)
    }
}
