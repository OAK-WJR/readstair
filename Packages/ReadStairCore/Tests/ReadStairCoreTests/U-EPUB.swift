import Foundation
import Testing
@testable import ReadStairCore

/// U-EPUB-001–013: reading EPUB files: the committed fixture, copy protection, language, the package document and its spine, the
/// text of XHTML documents, the limit on text and the author; U-TOC.swift has the table of contents and line breaks (008–012).
/// All but the fixture are built in memory with ZipWriter.
@Suite("U-EPUB EPUB and XHTMLText")
struct EPUBTests {
    private static let chapter = #"<item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>"#

    /// An XHTML document with `body` as its body.
    static func xhtml(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>Chapter</title><style>p { margin: 0 }</style></head>
        <body>\(body)</body>
        </html>
        """
    }

    /// A minimal EPUB: mimetype, container.xml naming the package document at `packagePath` (none if nil; spelled `fullPath` if
    /// given), the package document from `metadata`, `manifest` and `spine` (with `spineTOC` as its `toc`), and `files` (archive
    /// path, contents), by default one chapter the manifest names c1, and `images` (archive path, bytes).
    func epub(metadata: String = "<dc:title>Test Book</dc:title><dc:language>en</dc:language>",
              manifest: String = EPUBTests.chapter, spine: String = #"<itemref idref="c1"/>"#, spineTOC: String? = nil,
              packagePath: String? = "OEBPS/content.opf", fullPath: String? = nil,
              files: [(String, String)] = [("OEBPS/text/c1.xhtml", EPUBTests.xhtml("<p>Alice was beginning.</p>"))],
              images: [(String, Data)] = []) -> Data {
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip")
        if let packagePath {
            zip.add("META-INF/container.xml", """
                <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
                <rootfiles><rootfile full-path="\(fullPath ?? packagePath)" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """)
            zip.add(packagePath, """
                <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\(metadata)</metadata>
                <manifest>\(manifest)</manifest><spine\(spineTOC.map { #" toc="\#($0)""# } ?? "")>\(spine)</spine></package>
                """)
        }
        for (path, text) in files { zip.add(path, text) }
        for (path, data) in images { zip.add(path, data: data) }
        return zip.archive
    }

    private static func encryption(_ algorithms: [String]) -> (String, String) {
        let methods = algorithms.map {
            #"<enc:EncryptedData><enc:EncryptionMethod Algorithm="\#($0)"/></enc:EncryptedData>"#
        }
        return ("META-INF/encryption.xml", #"""
            <?xml version="1.0"?><encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">\#(methods.joined())</encryption>
            """#)
    }

    private static func paragraphs(_ blocks: [TextBlock]) -> [String] {
        blocks.compactMap { block in
            guard case .paragraph(let text) = block else { return nil }
            return text
        }
    }

    @Test("U-EPUB-001 Fixture (Info-ZIP, DEFLATE): the title, no author, one untitled chapter (no table of contents) opening with its headings, and the paragraphs' words equal the replay reader's for the same XHTML")
    func fixture() throws {
        let book = try EBookReader.read(Data(contentsOf: fixtureURL("Fixtures/alice-chapter-1.epub")))
        #expect(book.title == "Alice’s Adventures in Wonderland" && book.author == nil)
        #expect(book.chapters.map(\.title) == [nil])
        let blocks = try #require(book.chapters.first).blocks
        #expect(blocks.prefix(2) == [.heading("I"), .heading("Down the Rabbit-Hole")])
        let paragraphs = Self.paragraphs(blocks)
        #expect(paragraphs.count == blocks.count - 2)
        #expect(paragraphs.count == 24)
        #expect(paragraphs.first?.hasPrefix("Alice was beginning to get very tired of sitting by her sister on the bank,") == true)
        #expect(paragraphs.last == "So she set to work, and very soon finished off the cake.")
        let reference = try #require(ReplayBook.all().first { $0.name == "alice-chapter-1" })
        #expect(paragraphs.flatMap { $0.split(separator: " ").map(String.init) } == reference.words)
    }

    @Test("U-EPUB-002 Copy protection → drm: rights.xml, sinf.xml, an encrypted ZIP entry, encryption.xml with AES; font obfuscation alone reads")
    func copyProtection() throws {
        for extra in [("META-INF/rights.xml", "<rights/>"), ("META-INF/sinf.xml", "<sinf/>"),
                      Self.encryption(["http://www.w3.org/2001/04/xmlenc#aes128-cbc"]),
                      Self.encryption(["http://www.idpf.org/2008/embedding", "http://www.w3.org/2001/04/xmlenc#aes256-cbc"])] {
            #expect(throws: EBookError.drm, "\(extra.0)") {
                try EPUB.read(epub(files: [("OEBPS/text/c1.xhtml", Self.xhtml("<p>Text.</p>")), extra]))
            }
        }
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip")
        zip.entries.append(.init(path: "META-INF/container.xml", data: Data("<container/>".utf8), flags: 1))
        #expect(throws: EBookError.drm) { try EPUB.read(zip.archive) }

        let obfuscated = Self.encryption(["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"])
        let read = try EPUB.read(epub(files: [("OEBPS/text/c1.xhtml", Self.xhtml("<p>Text.</p>")), obfuscated]))
        #expect(read.chapters.map(\.blocks) == [[.paragraph("Text.")]])
        // With encryption.xml and no readable text, the text itself is taken to be encrypted
        #expect(throws: EBookError.drm) { try EPUB.read(epub(files: [obfuscated])) }
    }

    @Test("U-EPUB-003 dc:language: fr, de or enq → notEnglish; en, en-GB, en_US, eng, English, und, mul, fr with en, or none → read")
    func language() throws {
        func languages(_ codes: [String]) -> String {
            "<dc:title>T</dc:title>" + codes.map { "<dc:language>\($0)</dc:language>" }.joined()
        }
        for codes in [["fr"], ["de-DE"], ["enq"]] {
            #expect(throws: EBookError.notEnglish, "\(codes)") { try EPUB.read(epub(metadata: languages(codes))) }
        }
        for codes in [["en"], ["en-GB"], ["EN-us"], ["en_US"], ["eng"], ["English"], ["und"], ["mul"], ["fr", "en"], [""], []] {
            #expect(try EPUB.read(epub(metadata: languages(codes))).chapters.count == 1, "\(codes)")
        }
    }

    @Test("U-EPUB-004 The spine: linear=\"no\", the nav document, images and unparseable or empty chapters are skipped, in spine order, a media type's case and parameters ignored; no container.xml or package → unreadable; nothing left → empty")
    func spine() throws {
        let manifest = """
            <item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="toc" href="toc.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="art" href="images/art.svg" media-type="image/svg+xml"/>
            <item id="broken" href="text/broken.xhtml" media-type="application/xhtml+xml"/>
            <item id="picture" href="text/picture.xhtml" media-type="application/xhtml+xml"/>
            <item id="one" href="text/one.xhtml" media-type="application/xhtml+xml"/>
            <item id="two" href="text/two.xhtml" media-type="Application/XHTML+xml; charset=utf-8"/>
            <item id="gone" href="text/gone.xhtml" media-type="application/xhtml+xml"/>
            """
        let spine = """
            <itemref idref="cover" linear="no"/><itemref idref="toc"/><itemref idref="art"/><itemref idref="broken"/>
            <itemref idref="picture"/><itemref idref="two"/><itemref idref="one"/><itemref idref="gone"/><itemref idref="unknown"/>
            """
        let files = [("OEBPS/text/cover.xhtml", Self.xhtml("<p>Cover</p>")),
                     ("OEBPS/toc.xhtml", Self.xhtml("<nav><ol><li>One</li></ol></nav>")),
                     ("OEBPS/images/art.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>Art</text></svg>"),
                     ("OEBPS/text/broken.xhtml", "<html><body><p>Unclosed</body></html>"),
                     ("OEBPS/text/picture.xhtml", Self.xhtml(#"<figure><img src="../images/art.svg" alt="Art"/></figure>"#)),
                     ("OEBPS/text/one.xhtml", Self.xhtml("<p>One.</p>")), ("OEBPS/text/two.xhtml", Self.xhtml("<p>Two.</p>"))]
        let book = try EPUB.read(epub(manifest: manifest, spine: spine, files: files))
        #expect(book.title == "Test Book")
        #expect(book.chapters.map(\.blocks) == [[.paragraph("Two.")], [.paragraph("One.")]])

        #expect(throws: EBookError.unreadable) { try EPUB.read(epub(packagePath: nil)) }
        var zip = ZipWriter()
        zip.add("META-INF/container.xml", #"<container><rootfiles><rootfile full-path="missing.opf"/></rootfiles></container>"#)
        #expect(throws: EBookError.unreadable) { try EPUB.read(zip.archive) }
        #expect(throws: EBookError.empty) { try EPUB.read(epub(spine: "")) }
        #expect(throws: EBookError.empty) { try EPUB.read(epub(manifest: manifest, spine: spine, files: Array(files.prefix(5)))) }
    }

    @Test("U-EPUB-005 The package document: container.xml's full-path and an href resolve alike (a leading / or ./, ../, %20 decoded, the #fragment dropped); an undeclared prefix, HTML entities, a bare & and CDATA in its metadata read")
    func hrefs() throws {
        #expect(EPUB.path(of: "../Text/./Chapter%20One.xhtml#start", from: "OEBPS/Package/content.opf") == "OEBPS/Text/Chapter One.xhtml")
        #expect(EPUB.path(of: "chapter.xhtml", from: "content.opf") == "chapter.xhtml")
        let manifest = #"<item id="c1" href="../Text/Chapter%20One.xhtml#start" media-type="application/xhtml+xml"/>"#
        let book = try EPUB.read(epub(manifest: manifest, packagePath: "OEBPS/Package/content.opf",
                                      files: [("OEBPS/Text/Chapter One.xhtml", Self.xhtml("<p>Found.</p>"))]))
        #expect(book.chapters.map(\.blocks) == [[.paragraph("Found.")]])
        for fullPath in ["/OEBPS/content.opf", "./OEBPS/content.opf"] {
            #expect(try EPUB.read(epub(fullPath: fullPath)).chapters.count == 1, "\(fullPath)")
        }

        // The opf: prefix is not declared
        let metadata = #"""
            <dc:title opf:file-as="Q&A">Q&A&nbsp;&mdash; AT&amp;T</dc:title><dc:language><![CDATA[en]]></dc:language>
            <dc:description>&lt;p&gt;Caf&eacute; &amp; more&lt;/p&gt;</dc:description>
            """#
        #expect(try EPUB.read(epub(metadata: metadata)).title == "Q&A — AT&T")
        #expect(throws: EBookError.notEnglish) {
            try EPUB.read(epub(metadata: "<dc:title>T</dc:title><dc:language><![CDATA[fr]]></dc:language>"))
        }
    }

    @Test("U-EPUB-006 XHTML text: body only; headings and hgroup → heading, other blocks → paragraph; <br> a line break; HTML entities, a bare & and CDATA; page breaks, notes, inline SVG and MathML, Gutenberg's header and footer, Standard Ebooks' boilerplate and the title and half-title pages skipped (not a chapter's title), also with epub: undeclared; invisible characters removed by EBookReader")
    func xhtmlText() throws {
        let body = """
            <header id="pg-header"><h2>The Project Gutenberg eBook of Alice</h2><p>This eBook is for the use of anyone.</p></header>
            <section epub:type="titlepage"><h1 epub:type="title">Alice’s Adventures in Wonderland</h1><p>By Lewis Carroll.</p></section>
            <section epub:type="imprint"><p>This ebook is the product of many hours of hard work.</p></section>
            <section epub:type="halftitlepage"><h2 epub:type="fulltitle">Alice’s Adventures in Wonderland</h2></section>
            <section epub:type="chapter"><hgroup><h2>I</h2><p epub:type="title">Down the <em>Rabbit</em>-Hole</p></hgroup>
            <p>Alice&nbsp;was <em>very</em>
                tired&mdash;so&hellip; caf&eacute; &yuml; &amp; &lt;done&gt;<span epub:type="pagebreak" title="2">2</span></p>
            <p>Sleepy<a epub:type="noteref" href="#n1">1</a>, one<br/>two &unknown; three.</p>
            <p>AT&T, Q&A: &#8212;&#x2014; <![CDATA[<cdata> & &nbsp;]]> end.</p>
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 9 9"><title>Title page</title><text>ALICE</text></svg>
            <p>Area <math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math> done.</p>
            <table><tr><td>CHAPTER I.</td><td>Down the Rabbit-Hole</td></tr></table>
            <div role="doc-pagebreak">3</div><aside epub:type="z3998:letter z3998:footnote" id="n1"><p>A note.</p></aside></section>
            <section epub:type="endnotes"><ol><li>An endnote.</li></ol></section><nav epub:type="loi"><ol><li>Alice</li></ol></nav>
            <section epub:type="colophon"><p>Produced by volunteers.</p></section>
            <section epub:type="copyright-page"><p>May you do good and not evil.</p></section>
            <footer id="pg-footer"><h2>THE FULL PROJECT GUTENBERG LICENSE</h2></footer>
            """
        let blocks = try #require(XHTMLText.read(Data(Self.xhtml(body).utf8))).blocks
        #expect(blocks == [.heading("I"), .heading("Down the Rabbit-Hole"),
                           .paragraph("Alice was very tired—so… café ÿ & <done>"), .paragraph("Sleepy, one\u{2028}two three."),
                           .paragraph("AT&T, Q&A: —— <cdata> & &nbsp; end."), .paragraph("Area done."),
                           .paragraph("CHAPTER I. Down the Rabbit-Hole")])

        // Without xmlns:epub the chapter still reads, and its page break is still skipped
        let undeclared = #"""
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head>
            <body><section epub:type="chapter"><p>Kept<span epub:type="pagebreak">4</span>.</p></section></body></html>
            """#
        #expect(XHTMLText.read(Data(undeclared.utf8))?.blocks == [.paragraph("Kept.")])

        // Named in a DTD that is not loaded, &nbsp; would vanish and join the words
        let dtd = #"""
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body><h1>One&nbsp;Two</h1></body></html>
            """#
        #expect(XHTMLText.read(Data(dtd.utf8))?.blocks == [.heading("One Two")])
        #expect(XHTMLText.read(Data("<html><body><p>Unclosed</body></html>".utf8)) == nil)

        // Soft hyphen, word joiner, zero-width space and byte order mark: removed once for both formats, by EBookReader
        let invisible = Self.xhtml("<p>Soft\u{AD}ware joined\u{2060}—up zero\u{200B}width\u{FEFF}.</p>")
        #expect(try EBookReader.read(epub(files: [("OEBPS/text/c1.xhtml", invisible)])).chapters.map(\.blocks)
                    == [[.paragraph("Software joined—up zerowidth.")]])
    }

    @Test("U-EPUB-007 Text is counted as the spine is read: a file the spine names 10,000 times reads once; two chapters over EBookReader.maxCharacters together → tooLarge from EPUB itself")
    func textLimit() throws {
        // Two ids for one file, each named 5,000 times
        let twice = Self.chapter + #"<item id="again" href="text/./c1.xhtml#end" media-type="application/xhtml+xml"/>"#
        let spine = String(repeating: #"<itemref idref="c1"/><itemref idref="again"/>"#, count: 5_000)
        #expect(try EPUB.read(epub(manifest: twice, spine: spine)).chapters.map(\.blocks) == [[.paragraph("Alice was beginning.")]])

        // Just over half the limit each
        let half = Self.xhtml("<p>" + String(repeating: "down ", count: EBookReader.maxCharacters / 10 + 1) + "</p>")
        let manifest = #"""
            <item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>
            <item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>
            """#
        #expect(throws: EBookError.tooLarge) {
            try EPUB.read(epub(manifest: manifest, spine: #"<itemref idref="one"/><itemref idref="two"/>"#,
                               files: [("OEBPS/one.xhtml", half), ("OEBPS/two.xhtml", half)]))
        }
    }

    @Test("U-EPUB-013 The author is the first dc:creator with text, whitespace collapsed, invisible characters removed by EBookReader, and capped at 100 characters on the cover as a title is; none → nil")
    func author() throws {
        func author(_ creators: String) throws -> String? {
            try EBookReader.read(epub(metadata: "<dc:title>T</dc:title><dc:language>en</dc:language>" + creators)).author
        }
        #expect(try author("") == nil)
        #expect(try author("<dc:creator> </dc:creator>") == nil)
        #expect(try author(#"<dc:creator id="a"> </dc:creator><dc:creator opf:role="aut">  Lewis&#10;  Car\#u{AD}roll </dc:creator>"#
                           + "<dc:creator>John Tenniel</dc:creator>") == "Lewis Carroll")
        let long = String(repeating: "Author ", count: 20)
        #expect(try author("<dc:creator>" + long + "</dc:creator>") == String(long.dropLast()), "kept whole: the cover caps it")
        let cover = try TypesetBook.make(EBookReader.read(epub(metadata: "<dc:title>T</dc:title><dc:creator>\(long)</dc:creator>")),
                                         fileName: "t.epub").words(onPage: 0).map(\.text)
        #expect(cover == ["T"] + long.prefix(TypesetBook.maxTitleLength).split(separator: " ").map(String.init))
        // A contributor is not the author
        #expect(try author("<dc:contributor>John Tenniel</dc:contributor>") == nil)
    }
}
