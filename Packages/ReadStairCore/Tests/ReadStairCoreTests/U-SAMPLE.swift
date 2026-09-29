import Foundation
import Testing
@testable import ReadStairCore

/// U-SAMPLE-001–003 and I-TOC-001: the EPUBs tools/make-epub.sh builds, read, laid out and imported as the app does. The sample book, App/ReadStair/SampleBook/alice.epub, is not in the test bundle (it carries only Fixtures/ and Data/),
/// so U-SAMPLE-001 reads it from the repository through this file's path: it is built for a Mac, or a simulator, which reads the
/// Mac's disk, but not for a device.
@Suite("U-SAMPLE Sample book and chapters.epub", .timeLimit(.minutes(2)))
struct SampleBookTests {
    /// alice-whole.epub's chapter labels: Standard Ebooks' own, from its table of contents.
    static let labels = ["I: Down the Rabbit-Hole", "II: The Pool of Tears", "III: A Caucus-Race and a Long Tale",
                         "IV: The Rabbit Sends in a Little Bill", "V: Advice from a Caterpillar", "VI: Pig and Pepper",
                         "VII: A Mad Tea-Party", "VIII: The Queen’s Croquet-Ground", "IX: The Mock Turtle’s Story",
                         "X: The Lobster Quadrille", "XI: Who Stole the Tarts?", "XII: Alice’s Evidence"]
    /// chapters.epub's entries: chapter I, then two sections of one file, the second at a fragment mid-file.
    static let chapterLabels = ["I: Down the Rabbit-Hole", "Two",
                                "Three: A Chapter Whose Title Is Long Enough to Wrap onto Two Lines on All Phones"]
    /// Chapter II's crocodile poem, its first stanza as the reader gives it: one paragraph, its lines ended by line breaks.
    static let stanza = ["“How doth the little crocodile", "Improve his shining tail,", "And pour the waters of the Nile",
                         "On every golden scale!"].joined(separator: "\u{2028}")
    static let sampleURL = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../App/ReadStair/SampleBook/alice.epub").standardized

    #if os(macOS) || targetEnvironment(simulator)
    @Test("U-SAMPLE-001 The sample book: chapter I byte for byte with its author and the edition's cover, and no navigation document, other image or branding; typeset, a cover page showing that cover, then the chapter's pages, as many as alice-chapter-1.epub gives")
    func sampleBook() async throws {
        let data = try #require(try? Data(contentsOf: Self.sampleURL), "\(Self.sampleURL.path) is read from the repository, on a Mac")
        let cover = try Data(contentsOf: fixtureURL("Fixtures/source/alice-cover.jpg"))
        #expect(data.count < cover.count + 20_000, "\(data.count) bytes")
        let archive = try ZipArchive(data)
        #expect(try archive.data(at: "OEBPS/text/chapter-1.xhtml") == Data(contentsOf: fixtureURL("Fixtures/source/alice-chapter-1.xhtml")))
        // mimetype first, as OCF requires, and nothing else: chapter I only, its cover, and no other image or stray file
        #expect(archive.paths == ["mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/images/cover.jpg",
                                  "OEBPS/text/chapter-1.xhtml"])

        let book = try EBookReader.read(data)
        #expect(book.cover == cover)
        #expect(book.title == "Alice’s Adventures in Wonderland")
        #expect(book.author == "Lewis Carroll")
        #expect(book.chapters.map(\.title) == [nil], "one chapter, which no table of contents names")
        let blocks = book.chapters.flatMap(\.blocks).map(\.text)
        for branding in ["Tenniel", "Standard Ebooks", "Illustrat"] {
            #expect(!blocks.contains { $0.contains(branding) }, "\(branding)")
        }

        let typeset = try await TypesetBook.make(from: data, fileName: "alice.epub")
        let fixture = try await TypesetBook.make(from: Data(contentsOf: fixtureURL("Fixtures/alice-chapter-1.epub")), fileName: "alice.epub")
        #expect(typeset.pageCount == fixture.pageCount, "the cover, then chapter I's pages")
        #expect(typeset.words(onPage: 0).map(\.text) == ["Alice’s", "Adventures", "in", "Wonderland", "Lewis", "Carroll"], "the cover")
        let image = try #require(await typeset.importPage(0)).image
        #expect(image.width == 1200 && image.height == 1800, "the edition's cover, at the page's size")
        #expect((0..<typeset.pageCount).allSatisfy { typeset.chapterTitle(onPage: $0) == nil }, "no chapter starts: no contents")
    }
    #endif

    @Test("U-SAMPLE-003 alice-whole.epub, the long book tests import: chapters I–XII byte for byte under their 12 labels, with no image, cover or branding and its verse lines kept; typeset, a cover page, then one titled page per chapter")
    func wholeBook() async throws {
        let data = try Data(contentsOf: fixtureURL("Fixtures/alice-whole.epub"))
        #expect(data.count < 200_000, "\(data.count) bytes")
        let archive = try ZipArchive(data)
        for number in 1...12 {
            let source = number == 1 ? "Fixtures/source/alice-chapter-1.xhtml" : "Fixtures/sample/chapter-\(number).xhtml"
            #expect(try archive.data(at: "OEBPS/text/chapter-\(number).xhtml") == Data(contentsOf: fixtureURL(source)), "\(source)")
        }
        // mimetype first, as OCF requires, and nothing else: no image, cover or stray file
        #expect(archive.paths == ["mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml"]
                + (1...12).map { "OEBPS/text/chapter-\($0).xhtml" })

        let book = try EBookReader.read(data)
        #expect(book.title == "Alice’s Adventures in Wonderland")
        #expect(book.author == "Lewis Carroll")
        #expect(book.chapters.map(\.title) == Self.labels.map(Optional.some))
        let blocks = book.chapters.flatMap(\.blocks).map(\.text)
        for branding in ["Tenniel", "Standard Ebooks", "Illustrat"] {
            #expect(!blocks.contains { $0.contains(branding) }, "\(branding)")
        }
        let chapterII = try #require(book.chapters.dropFirst().first).blocks.map(\.text)
        #expect(chapterII.contains(Self.stanza), "the crocodile's first stanza, its lines ended by line breaks")

        let typeset = try await TypesetBook.make(from: data, fileName: "alice-whole.epub")
        #expect(typeset.pageCount >= 150, "\(typeset.pageCount) pages")
        #expect(typeset.words(onPage: 0).map(\.text) == ["Alice’s", "Adventures", "in", "Wonderland", "Lewis", "Carroll"], "the cover")
        #expect(typeset.chapterTitle(onPage: 0) == nil)
        #expect(typeset.chapterTitle(onPage: 1) == "I: Down the Rabbit-Hole")
        let titled = (0..<typeset.pageCount).filter { typeset.chapterTitle(onPage: $0) != nil }
        #expect(titled.compactMap(typeset.chapterTitle(onPage:)) == Self.labels)

        // The stanza typeset as verse: each of its lines on a line of its own, down the page, all four at one left edge. As prose
        // its lines would run on, the first indented
        let lineWords = Self.stanza.split(separator: "\u{2028}").map { $0.split(separator: " ").map(String.init) }
        let start = try #require(titled.dropFirst().first, "chapter II's first page")
        let page = try #require((start..<typeset.pageCount).lazy.map(typeset.words(onPage:))
            .first { $0.contains { $0.text == "crocodile" } })
        let first = try #require(page.firstIndex { $0.text == "crocodile" }) - 4, count = lineWords.joined().count
        try #require(first >= 0 && first + count <= page.count, "the stanza on one page: \(page.map(\.text))")
        let words = Array(page[first..<first + count])
        #expect(words.map(\.text) == Array(lineWords.joined()))
        try #require(words.allSatisfy { $0.quads.count == 1 }, "no word broken across lines")
        // Each line's words' top left corners: words [0, 5), [5, 9), [9, 16) and [16, 20)
        let ends = lineWords.reduce(into: [0]) { $0.append($0.last! + $1.count) }
        let lines = zip(ends, ends.dropFirst()).map { words[$0..<$1].map(\.quads[0].topLeft) }
        let tops = lines.map { $0[0].y }
        #expect(zip(lines, tops).allSatisfy { line, top in line.allSatisfy { abs($0.y - top) < 1e-9 } }, "one line each: \(lines)")
        #expect(zip(tops, tops.dropFirst()).allSatisfy { $0 < $1 }, "down the page: \(tops)")
        // Within a pixel: the first line's opening quote hangs a fraction of one left of the margin
        let pixel = 1 / CGFloat(PageStyle.phone.width)
        #expect(lines.allSatisfy { abs($0[0].x - lines[0][0].x) < pixel }, "one left edge: \(lines.map { $0[0].x })")
    }

    @Test("U-SAMPLE-002 chapters.epub: an untitled title page, chapter I, and two entries of one file; typeset, a cover page, the title page, then titled pages third, second-last and last")
    func chaptersFixture() async throws {
        let data = try Data(contentsOf: fixtureURL("Fixtures/chapters.epub"))
        let book = try EBookReader.read(data)
        #expect(book.title == "Three Chapters" && book.author == nil)
        #expect(book.chapters.map(\.title) == [nil] + Self.chapterLabels.map(Optional.some))
        #expect(book.chapters.first?.blocks == [.heading("Three Chapters"), .paragraph("A test book dedicated to the public domain.")])
        let alice = try EBookReader.read(Data(contentsOf: fixtureURL("Fixtures/alice-chapter-1.epub")))
        #expect(book.chapters.dropFirst().first?.blocks == alice.chapters.first?.blocks, "chapter I, as alice-chapter-1.epub reads it")
        #expect(book.chapters.suffix(2).map(\.blocks)
                == Self.chapterLabels.suffix(2).map { [TextBlock.heading($0), .paragraph("One short paragraph.")] })

        let typeset = try await TypesetBook.make(from: data, fileName: "chapters.epub")
        let last = typeset.pageCount - 1
        try #require(last >= 5, "\(typeset.pageCount) pages: a cover, a title page, chapter I on several, then one for each entry")
        #expect(typeset.words(onPage: 0).map(\.text) == ["Three", "Chapters"], "the cover: the title, and no author")
        #expect(typeset.words(onPage: 1).map(\.text).joined(separator: " ") == "Three Chapters A test book dedicated to the public domain.")
        var expected = [String?](repeating: nil, count: typeset.pageCount)
        expected[2] = Self.chapterLabels[0]
        expected[last - 1] = Self.chapterLabels[1]
        expected[last] = Self.chapterLabels[2]
        #expect((0..<typeset.pageCount).map(typeset.chapterTitle(onPage:)) == expected)
    }

    @Test("I-TOC-001 chapters.epub typeset and imported through the Importer: the store holds its 3 entries at their typeset pages, and the contents open those pages in order")
    func importedContents() async throws {
        let typeset = try await TypesetBook.make(from: Data(contentsOf: fixtureURL("Fixtures/chapters.epub")), fileName: "chapters.epub")
        let starts = (0..<typeset.pageCount).compactMap { index in
            typeset.chapterTitle(onPage: index).map { ChapterStart(pageIndex: index, title: $0) }
        }
        #expect(starts.map(\.title) == Self.chapterLabels)
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: typeset.title ?? "")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            #expect(try await importer.importPages(count: typeset.pageCount, into: book.id) { typeset.page($0) } == typeset.pageCount)
            let pages = try await store.pages(of: book.id)
            try #require(pages.map(\.index) == Array(0..<typeset.pageCount))
            let chapters = try await store.chapters(of: book.id)
            #expect(chapters == starts)
            let contents = ChapterStart.contents(chapters, pages: pages)
            #expect(contents.map(\.title) == Self.chapterLabels)
            #expect(contents.map(\.page) == starts.map { pages[$0.pageIndex] })
        }
    }
}
