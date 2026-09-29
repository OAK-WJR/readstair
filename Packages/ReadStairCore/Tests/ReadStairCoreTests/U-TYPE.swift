import Accelerate
import CoreGraphics
import Foundation
import NaturalLanguage
import Testing
@testable import ReadStairCore

private let hasNameAssets = NLTagger.availableTagSchemes(for: .word, language: .english).contains(.nameType)

/// U-TYPE-001–015: laying an electronic book out into pages, its cover and verse among them, and each page's words and their boxes.
/// Font metrics differ between macOS and iOS, so these check invariants and the positions the style sets, never page counts.
@Suite("U-TYPE Typesetter")
struct TypesetterTests {
    /// Chapter 1 of Alice as an electronic book: its title as a heading, then the paragraphs tools/make-fixtures.swift reads from
    /// Fixtures/source/alice-chapter-1.xhtml (those outside the chapter's hgroup, word joiners removed, whitespace collapsed).
    static func aliceChapter() throws -> [TextBlock] {
        let parser = try #require(XMLParser(contentsOf: fixtureURL("Fixtures/source/alice-chapter-1.xhtml")))
        let collector = ParagraphCollector()
        parser.delegate = collector
        try #require(parser.parse(), "\(String(describing: parser.parserError))")
        return [.heading("Down the Rabbit-Hole")] + collector.paragraphs.map(TextBlock.paragraph)
    }

    private final class ParagraphCollector: NSObject, XMLParserDelegate {
        var paragraphs: [String] = []
        private var inHeading = false
        private var current: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == "hgroup" { inHeading = true }
            if name == "p", !inHeading { current = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { current?.append(string) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "hgroup" { inHeading = false }
            if name == "p", let text = current {
                paragraphs.append(text.replacing("\u{2060}", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " "))
                current = nil
            }
        }
    }

    private let style = PageStyle.phone

    /// Alice's chapter, then a short second chapter.
    private func twoChapters() throws -> TypesetBook {
        let book = EBook(title: nil, chapters: [EBook.Chapter(blocks: try Self.aliceChapter()),
                                                EBook.Chapter(blocks: [.heading("Chapter Two"), .paragraph("Short text.")])])
        return Typesetter.paginate(book, title: nil)
    }

    /// A word too long for a line, between two short ones.
    private let long = String(repeating: "abcdefghij", count: 7)
    private func overLongWordBook() -> TypesetBook {
        Typesetter.paginate(EBook(title: nil, chapters: [EBook.Chapter(blocks: [.paragraph("Before \(long) after.")])]), title: nil)
    }

    /// Chapter II's crocodile poem, a paragraph per stanza, its lines broken as XHTMLText reads `<br/>`.
    private static let crocodile = [["“How doth the little crocodile", "Improve his shining tail,", "And pour the waters of the Nile",
                                     "On every golden scale!"],
                                    ["“How cheerfully he seems to grin,", "How neatly spread his claws,", "And welcome little fishes in",
                                     "With gently smiling jaws!”"]].map { $0.joined(separator: "\u{2028}") }
    /// The poem between two paragraphs of prose, under a heading broken in two.
    private let verse: [TextBlock] = [
        .heading("CHAPTER II.\u{2028}The Pool of Tears"),
        .paragraph("“Curiouser and curiouser!” cried Alice (she was so much surprised, that for the moment she quite forgot how to "
                   + "speak good English)."),
    ] + TypesetterTests.crocodile.map(TextBlock.paragraph) + [
        .paragraph("“I’m sure those are not the right words,” said poor Alice, and her eyes filled with tears again as she went on."),
    ]
    private func verseBook() -> TypesetBook {
        Typesetter.paginate(EBook(title: nil, chapters: [EBook.Chapter(blocks: verse)]), title: nil)
    }

    /// A paragraph under a title and an author, laid out as an e-book is: its cover first.
    private func coverBook(_ title: String = "Alice’s Adventures in Wonderland",
                           author: String? = "Lewis Carroll") throws -> TypesetBook {
        let text = "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do."
        return try TypesetBook.make(EBook(title: title, chapters: [EBook.Chapter(blocks: [.paragraph(text)])], author: author),
                                    fileName: "book.epub")
    }

    private func words(_ book: TypesetBook) -> [[RecognizedWord]] {
        (0..<book.pageCount).map { book.words(onPage: $0) }
    }

    /// A word's first box, in pixels from the page's top left.
    private func pixels(_ word: RecognizedWord) throws -> CGRect {
        let box = bounds(try #require(word.quads.first, "\(word.text) has no box"))
        return CGRect(x: box.minX * CGFloat(style.width), y: box.minY * CGFloat(style.height), width: box.width * CGFloat(style.width),
                      height: box.height * CGFloat(style.height))
    }

    /// Words grouped into lines by their first box's top, top line first.
    private func lines(_ words: [RecognizedWord]) throws -> [[CGRect]] {
        let boxes = try words.map(pixels)
        return Dictionary(grouping: boxes) { ($0.minY * 1000).rounded() }.sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.minX < $1.minX } }
    }

    /// The words a text's pages must hold, in order: its blocks split at whitespace, then at dashes.
    private func expectedWords(_ blocks: [TextBlock]) -> [String] {
        blocks.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }
            .flatMap { Recognition.splitAtDashes(RecognizedWord(text: String($0), quads: [])).map(\.text) }
    }

    private func bounds(_ quad: Quad) -> CGRect {
        let xs = quad.corners.map(\.x), ys = quad.corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    @Test("U-TYPE-001 Every word of the text is on exactly one page, in order: none lost or doubled at a page break or a line break")
    func coversTheText() throws {
        let book = try twoChapters()
        let expected = expectedWords(try Self.aliceChapter() + [.heading("Chapter Two"), .paragraph("Short text.")])
        #expect(book.pageCount > 2)
        #expect(words(book).joined().map(\.text) == expected)
        #expect(expected.contains("—"), "the text has words joined by a dash, so splitting them is covered")
        #expect(words(verseBook()).joined().map(\.text) == expectedWords(verse))
    }

    @Test("U-TYPE-002 Every box lies inside the margins and has a size; the page image is 1200×1800 px")
    func boxesLieOnThePage() throws {
        let book = try twoChapters()
        // Within a pixel: a first line's ascent can reach a fraction of one above the frame, and an opening quote left of it
        let margin = CGRect(x: 0, y: 0, width: 1, height: 1)
            .insetBy(dx: (style.margin - 1) / CGFloat(style.width), dy: (style.margin - 1) / CGFloat(style.height))
        for (page, words) in words(book).enumerated() {
            for word in words {
                #expect(!word.quads.isEmpty, "page \(page): \(word.text) has no box")
                for quad in word.quads {
                    #expect(margin.contains(bounds(quad)), "page \(page): \(word.text) at \(bounds(quad))")
                    #expect(quad.topLeft.x < quad.topRight.x && quad.topLeft.y < quad.bottomLeft.y, "page \(page): \(word.text)")
                }
            }
        }
        let image = try #require(book.page(0)).image
        #expect(image.width == 1200 && image.height == 1800)
    }

    @Test("U-TYPE-003 A page's words read in order: line by line down the page, left to right within a line")
    func readingOrder() throws {
        for (page, words) in words(try twoChapters()).enumerated() {
            for (previous, word) in zip(words, words.dropFirst()) {
                let a = bounds(try #require(previous.quads.last)), b = bounds(try #require(word.quads.first))
                let inOrder = b.minY == a.minY ? b.minX >= a.maxX - 1e-9 : b.minY > a.minY
                #expect(inOrder, "page \(page): \(previous.text) at \(a), then \(word.text) at \(b)")
            }
        }
    }

    /// Checks the boxes against the pixels on every page, so also on pages that start mid-paragraph, words split at a dash and a
    /// word broken across lines: a box ending at the baseline would leave the descenders of g, p and y outside, and a misplaced box
    /// would leave its word's glyphs outside or hold no ink.
    @Test("U-TYPE-004 Every inked pixel of every page lies in a word box, down to the descenders, and every box holds ink; covers, black or white on a color, and verse too, where a line break draws nothing")
    func boxesCoverTheInk() throws {
        let books = [("two chapters", try twoChapters()), ("over-long word", overLongWordBook()), ("cover", try coverBook()),
                     ("long cover", try coverBook(Self.longTitle, author: "Daniel Defoe")),
                     ("wide cover", try coverBook(Self.wideTitle, author: "Lewis Carroll")),
                     ("brown cover", try coverBook("Middlemarch", author: "George Eliot")), ("verse", verseBook())]
        for (name, book) in books {
            for index in 0..<book.pageCount {
                try checkInk(try #require(book.page(index)), "\(name), page \(index)")
            }
        }
    }

    private typealias Box = (x: Int, y: Int, maxX: Int, maxY: Int)

    /// Ink is pixels far in gray from the page's background, read at its top left corner: black text on white, or a cover's black or
    /// white text on its color. How far is measured against the text's own distance, the farthest any pixel is: a quarter of it for ink,
    /// half of it for a box's ink, which for black on white is 63 and 127.
    private func checkInk(_ page: ImportPage, _ label: String) throws {
        let width = page.image.width, height = page.image.height
        // Box edges rounded outward, plus room for antialiasing and a glyph's overhang past its advance, which grows with the type:
        // 2 px for body text, 3% of the box's height for the cover's (the hook of a semibold f at 104 px reaches 3 px past it);
        // pixel rows top down
        let boxes: [Box] = try #require(page.text).words.flatMap(\.quads).map { quad in
            let box = bounds(quad), pad = max(2, Int((box.height * CGFloat(height) * 0.03).rounded(.up)))
            return (x: max(0, Int((box.minX * CGFloat(width)).rounded(.down)) - pad),
                    y: max(0, Int((box.minY * CGFloat(height)).rounded(.down)) - pad),
                    maxX: min(width, Int((box.maxX * CGFloat(width)).rounded(.up)) + pad),
                    maxY: min(height, Int((box.maxY * CGFloat(height)).rounded(.up)) + pad))
        }
        var pixels = [UInt8](repeating: 255, count: width * height)
        var inked = 0, empty = 0, stray = 0, background = 255, text = 255
        try pixels.withUnsafeMutableBufferPointer { pixels in
            let context = try #require(CGContext(data: pixels.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                                 bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.draw(page.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            background = Int(pixels[0])
            // Counted by vImage: a Swift loop over every pixel takes about 2 s a page in a debug build
            func histogram(of box: Box) -> [vImagePixelCount] {
                var buffer = vImage_Buffer(data: pixels.baseAddress! + box.y * width + box.x,
                                           height: vImagePixelCount(box.maxY - box.y), width: vImagePixelCount(box.maxX - box.x),
                                           rowBytes: width)
                var histogram = [vImagePixelCount](repeating: 0, count: 256)
                vImageHistogramCalculation_Planar8(&buffer, &histogram, vImage_Flags(kvImageNoFlags))
                return histogram
            }
            func ink(in box: Box, beyond distance: Int) -> Int {
                let histogram = histogram(of: box)
                return histogram.indices.reduce(0) { abs($1 - background) > distance ? $0 + Int(histogram[$1]) : $0 }
            }
            let all: Box = (0, 0, width, height)
            let whole = histogram(of: all)
            text = whole.indices.reduce(0) { whole[$1] > 0 ? max($0, abs($1 - background)) : $0 }
            inked = ink(in: all, beyond: text / 4)
            empty = boxes.count { ink(in: $0, beyond: text / 2) == 0 }
            // With every box painted the background, no ink is left
            context.setFillColor(gray: CGFloat(background) / 255, alpha: 1)
            context.fill(boxes.map { CGRect(x: $0.x, y: height - $0.maxY, width: $0.maxX - $0.x, height: $0.maxY - $0.y) })
            stray = ink(in: all, beyond: text / 4)
        }
        let first = stray == 0 ? 0 : pixels.firstIndex { abs(Int($0) - background) > text / 4 } ?? 0
        #expect(inked > 5_000, "\(label): the page has text")
        #expect(stray == 0, "\(label): \(stray) inked pixels outside every box, the first at \((first % width, first / width))")
        #expect(empty == 0, "\(label): \(empty) boxes hold no ink")
    }

    @Test("U-TYPE-005 Each chapter starts on a new page, its heading centred at the top")
    func chaptersStartPages() throws {
        let pages = words(try twoChapters())
        let last = try #require(pages.last), previous = try #require(pages.dropLast().last)
        #expect(last.map(\.text) == ["Chapter", "Two", "Short", "text."])
        #expect(previous.last?.text == "cake.", "chapter 1 ends on the page before")
        for heading in [pages[0].prefix(3), last.prefix(2)] {
            let left = bounds(try #require(heading.first?.quads.first)), right = bounds(try #require(heading.last?.quads.first))
            #expect(abs((left.minX + right.maxX) / 2 - 0.5) < 0.005, "centred: \(heading.map(\.text))")
            #expect(left.minY > style.margin / CGFloat(style.height) - 1e-6 && left.minY < 0.07, "at the top: \(heading.map(\.text))")
        }
        #expect(pages[0].prefix(3).map(\.text) == ["Down", "the", "Rabbit-Hole"])
    }

    @Test("U-TYPE-006 Chapters with no text make no pages; a page out of range is nil and has no words")
    func emptyChapters() {
        let chapters: [[TextBlock]] = [[], [.paragraph(" \n ")], [.paragraph("One.")], []]
        let book = Typesetter.paginate(EBook(title: "T", chapters: chapters.map { EBook.Chapter(blocks: $0) }), title: "T")
        #expect(book.title == "T")
        #expect(book.pageCount == 2, "the cover, then one page of text")
        #expect(book.words(onPage: 0).map(\.text) == ["T"] && book.words(onPage: 1).map(\.text) == ["One."])
        #expect(book.page(-1) == nil && book.page(2) == nil && book.words(onPage: 2).isEmpty)
        #expect(Typesetter.paginate(EBook(title: nil, chapters: []), title: nil).pageCount == 0)
    }

    @Test("U-TYPE-007 An over-long word breaks across lines rather than vanish: one word with a box on each line")
    func overLongWord() throws {
        let book = overLongWordBook()
        let words = book.words(onPage: 0)
        #expect(book.pageCount == 1)
        #expect(words.map(\.text) == ["Before", long, "after."])
        let boxes = try #require(words.first { $0.text == long }).quads.map(bounds)
        #expect(boxes.count >= 2)
        #expect(zip(boxes, boxes.dropFirst()).allSatisfy { $1.minY > $0.maxY - 1e-9 }, "each box on a lower line: \(boxes)")
    }

    @Test("U-TYPE-008 Pagination is deterministic, and a page's text is analyzed: words have bands, and Alice is a name")
    func deterministicAndAnalyzed() throws {
        // Core Text's centring can differ in the tenth decimal place between runs, so boxes are compared to a millionth of the page
        let first = try twoChapters(), second = try twoChapters()
        let a = words(first), b = words(second)
        #expect(a.map { $0.map { "\($0.text) \($0.quads.count)" } } == b.map { $0.map { "\($0.text) \($0.quads.count)" } })
        let corners = zip(a.joined(), b.joined()).flatMap { zip($0.quads, $1.quads) }.flatMap { zip($0.corners, $1.corners) }
        #expect(corners.allSatisfy { abs($0.x - $1.x) < 1e-6 && abs($0.y - $1.y) < 1e-6 })
        let text = try #require(first.page(0)?.text)
        #expect(text.words.map(\.surface) == first.words(onPage: 0).map(\.text))
        #expect(text.words.contains { $0.band != nil })
        #expect(!text.sentences.isEmpty)
        if hasNameAssets {
            #expect(text.words.contains { $0.surface == "Alice" && $0.kind == .name })
        }
    }

    /// Each compound is 77 characters, longer than a line in any font metrics, so it always breaks at a hyphen and most lines end
    /// inside one: so would most pages, if a page could end inside a word.
    @Test("U-TYPE-009 A page never ends inside a word: long hyphenated compounds broken across lines stay whole at a page break")
    func wordsStayOnOnePage() throws {
        let parts = ["rabbit", "hole", "daisy", "chain", "waistcoat", "pocket", "cherry", "tart", "three", "legged", "glass", "table"]
        let compounds = (0..<150).map { i in (0..<12).map { parts[(i + 5 * $0) % parts.count] }.joined(separator: "-") }
        let blocks = stride(from: 0, to: 150, by: 10).map { TextBlock.paragraph(compounds[$0..<$0 + 10].joined(separator: " ")) }
        let book = Typesetter.paginate(EBook(title: nil, chapters: [EBook.Chapter(blocks: blocks)]), title: nil)
        let all = words(book).joined()
        #expect(book.pageCount > 5)
        #expect(all.map(\.text) == expectedWords(blocks))
        #expect(all.allSatisfy { $0.quads.count > 1 }, "every compound is broken across lines")
    }

    @Test("U-TYPE-010 A 50,000-character paragraph is set in pieces cut at sentence ends, every word kept; layout time recorded")
    func longParagraph() throws {
        let alice = try Self.aliceChapter().compactMap { block in
            if case .paragraph(let text) = block { text } else { nil }
        }.joined(separator: " ")
        let text = String(String(repeating: alice + " ", count: 50_000 / alice.count + 1).prefix(50_000))
        let start = ContinuousClock.now
        let book = Typesetter.paginate(EBook(title: nil, chapters: [EBook.Chapter(blocks: [.paragraph(text)])]), title: nil)
        let elapsed = ContinuousClock.now - start
        ExperimentLog.record(["test": "U-TYPE-010", "characters": text.count, "pages": book.pageCount, "ms": elapsed])
        #expect(words(book).joined().map(\.text) == expectedWords([.paragraph(text)]))
        // A block is cut after the last sentence end that fits, else at the last space, else at the limit
        let limit = Typesetter.maxBlockLength
        #expect(Typesetter.pieces(of: "One. “Two?” " + String(repeating: "x ", count: limit)).first == "One. “Two?”")
        #expect(Typesetter.pieces(of: String(repeating: "abcd ", count: 1_000)).map(\.count) == [limit - 1, 5_000 - limit])
        #expect(Typesetter.pieces(of: String(repeating: "x", count: 2 * limit + 1)).map(\.count) == [limit, limit, 1])
    }

    @Test("U-TYPE-011 The title is the book's, else the file name's, trimmed and capped at 100; a book with no page of text is .empty")
    func titleAndEmpty() async throws {
        let text = [EBook.Chapter(blocks: [.paragraph("Some text.")])]
        #expect(try TypesetBook.make(EBook(title: " Alice\n", chapters: text), fileName: "a.epub").title == "Alice")
        #expect(try TypesetBook.make(EBook(title: " \n ", chapters: text), fileName: " Notes.txt").title == "Notes")
        #expect(try TypesetBook.make(EBook(title: " " + String(repeating: "t", count: 300), chapters: text), fileName: "a.epub").title
                == String(repeating: "t", count: 100))
        #expect(TypesetBook.title(fromFileName: String(repeating: "n", count: 300) + ".txt") == String(repeating: "n", count: 100))
        #expect(throws: EBookError.empty) {
            try TypesetBook.make(EBook(title: nil, chapters: [EBook.Chapter(blocks: [.paragraph(" ")])]), fileName: "a")
        }
        let book = try await TypesetBook.make(from: Data("Hello there.".utf8), fileName: "Hello.txt")
        #expect(book.title == "Hello" && book.pageCount == 2)
        #expect(book.words(onPage: 0).map(\.text) == ["Hello"] && book.words(onPage: 1).map(\.text) == ["Hello", "there."])
    }

    @Test("U-TYPE-012 A chapter's title is on its first page only, and that page carries it; untitled and empty chapters between titled ones shift nothing")
    func chapterTitles() throws {
        let alice = try Self.aliceChapter(), between: [TextBlock] = [.paragraph("Between.")]
        let two: [TextBlock] = [.heading("Chapter Two"), .paragraph("Short text.")]
        let titled = EBook(title: nil, chapters: [
            EBook.Chapter(title: "I: Down the Rabbit-Hole", blocks: alice), EBook.Chapter(blocks: between),
            EBook.Chapter(title: "Empty", blocks: []), EBook.Chapter(title: "Blank", blocks: [.paragraph(" \n ")]),
            EBook.Chapter(title: "Two", blocks: two),
        ])
        let book = Typesetter.paginate(titled, title: nil)
        let pages = words(book).map { $0.map(\.text) }
        // The same pages as the text with no titles and no empty chapters
        let untitled = EBook(title: nil, chapters: [alice, between, two].map { EBook.Chapter(blocks: $0) })
        #expect(pages == words(Typesetter.paginate(untitled, title: nil)).map { $0.map(\.text) })

        // Alice's chapter on several pages, then the untitled chapter on one and chapter Two on the last, each starting a page
        let last = book.pageCount - 1
        #expect(last > 3)
        #expect(pages[0].prefix(3) == ["Down", "the", "Rabbit-Hole"] && pages[last - 2].last == "cake.")
        #expect(pages[last - 1] == ["Between."] && pages[last] == ["Chapter", "Two", "Short", "text."])
        var expected = [String?](repeating: nil, count: book.pageCount)
        expected[0] = "I: Down the Rabbit-Hole"
        expected[last] = "Two"
        let titles = (0..<book.pageCount).map(book.chapterTitle(onPage:))
        #expect(titles == expected)
        #expect(book.chapterTitle(onPage: -1) == nil && book.chapterTitle(onPage: book.pageCount) == nil)
        for index in 0..<book.pageCount {
            #expect(try #require(book.page(index)).chapter == titles[index], "page \(index)")
        }
        let again = Typesetter.paginate(titled, title: nil)
        #expect((0..<again.pageCount).map(again.chapterTitle(onPage:)) == titles, "deterministic")
    }

    /// 80 characters: several lines at the cover's title size.
    static let longTitle = "The Life and Strange Surprizing Adventures of Robinson Crusoe, of York, Mariner"
    /// 100 characters, the cap, in wide capitals: too tall for the cover's largest size, so it is set smaller.
    static let wideTitle = String(repeating: "WWWW ", count: 19) + "WWWWW"

    @Test("U-TYPE-013 An e-book opens with a cover: its title (first line 30% down) and author (64 px below, smaller), centred and wrapped within the margins, white where it reaches 3:1 on the title's color and black elsewhere, with boxes and analysis, never marked by the level, in smaller type when that leaves some out; untitled; the text's pages follow unchanged; no text, no cover; deterministic")
    func cover() throws {
        let alice = try Self.aliceChapter()
        let book = try TypesetBook.make(EBook(title: "Alice’s Adventures in Wonderland",
                                              chapters: [EBook.Chapter(title: "I: Down the Rabbit-Hole", blocks: alice)],
                                              author: " Lewis Carroll\n"), fileName: "alice.epub")
        let cover = book.words(onPage: 0)
        #expect(cover.map(\.text) == ["Alice’s", "Adventures", "in", "Wonderland", "Lewis", "Carroll"])
        let page = try #require(book.page(0))
        #expect(try #require(page.text).words.map(\.surface) == cover.map(\.text))
        #expect(page.chapter == nil && book.chapterTitle(onPage: 0) == nil && book.chapterTitle(onPage: 1) == "I: Down the Rabbit-Hole")

        // Black or white on the title's color (U-TYPE-015 pins which color): in each channel every pixel is the background's value,
        // the text's or a blend of the two, and thousands are the text's
        let color = style.coverColor(title: "Alice’s Adventures in Wonderland")
        let ink = PageStyle.coverTextColor(on: color).components?.first == 1 ? 255 : 0
        let (corner, histograms) = try colors(of: page.image)
        #expect(style.coverColors.contains(color) && corner == color, "the background is \(String(corner, radix: 16))")
        for (channel, histogram) in histograms.enumerated() {
            let background = Int(color >> UInt32(16 - 8 * channel) & 0xFF)
            let used = histogram.indices.filter { histogram[$0] > 0 }
            #expect(used.first == min(background, ink) && used.last == max(background, ink) && histogram[ink] > 5_000,
                    "channel \(channel): \(histogram)")
        }
        // Its words are names with their lexicon bands, which would be marked as a recognized page's words: no level marks them and
        // opening a card saves nothing, yet a tap finds them; the text's pages are marked as ever
        let analyzed = try #require(page.text), plain = PageAnalyzer.analyze(cover, lexicon: .bundled)
        let size = CGSize(width: style.width, height: style.height)
        #expect(analyzed.words.allSatisfy { $0.kind == .name } && analyzed.words.map(\.band) == plain.words.map(\.band))
        #expect(plain.words.contains { Annotator.isMarked($0, level: Profile.levels.lowerBound, state: nil) })
        for level in Profile.levels {
            #expect(analyzed.words.allSatisfy { !Annotator.isMarked($0, level: level, state: nil) }, "level \(level)")
            #expect(analyzed.words.allSatisfy {
                WordEntry.entryOnOpen(word: $0, state: nil, level: level, bookID: UUID(), pageID: UUID(), sentence: nil) == nil
            }, "level \(level)")
        }
        let wonderland = try #require(analyzed.words.firstIndex { $0.surface == "Wonderland" })
        #expect(Annotator.hit(analyzed.words[wonderland].quads[0].scaled(to: size).center, in: analyzed, size: size) == wonderland)
        #expect(try #require(book.page(1)?.text).words.contains { Annotator.isMarked($0, level: Profile.levels.lowerBound, state: nil) })
        // After it, the pages of the same text without a title
        let text = Typesetter.paginate(EBook(title: nil, chapters: [EBook.Chapter(blocks: alice)]), title: nil)
        #expect(words(book).dropFirst().map { $0.map(\.text) } == words(text).map { $0.map(\.text) })

        // The title's first line 30% down; each line centred; the author 64 px below the title's last line, in smaller type
        let title = try lines(Array(cover.prefix(4))), author = try lines(Array(cover.suffix(2)))
        let top = try #require(title.first?.first), last = try #require(title.last?.first), byline = try #require(author.first?.first)
        #expect(abs(top.minY - 0.3 * CGFloat(style.height)) < 1, "the title's first line starts at \(top.minY) px")
        #expect(abs(byline.minY - last.maxY - style.authorSpace) < 1, "\(byline.minY - last.maxY) px from the title to the author")
        let sizes = try #require(style.coverSizes.first)
        #expect(abs(top.height / byline.height - sizes.title / sizes.author) < 0.05, "\(top.height) and \(byline.height) px high")
        for line in title + author {
            let centre = ((line.first?.minX ?? 0) + (line.last?.maxX ?? 0)) / 2
            #expect(abs(centre - CGFloat(style.width) / 2) < 6, "centred: \(line)")
        }

        // A long title wraps over several lines, every word inside the margins; without an author, only the title
        let long = try coverBook(Self.longTitle, author: nil).words(onPage: 0)
        #expect(long.map(\.text) == Self.longTitle.split(separator: " ").map(String.init))
        #expect(try lines(long).count >= 3)
        let margins = style.textRect.insetBy(dx: -1, dy: -1)
        #expect(try long.map(pixels).allSatisfy { margins.contains($0) && $0.minY >= top.minY - 1 })

        // A title too tall for 30% down in the largest size is set smaller, still from 30% down, whole
        let wide = try coverBook(Self.wideTitle, author: "Lewis Carroll").words(onPage: 0)
        #expect(wide.map(\.text) == (Self.wideTitle + " Lewis Carroll").split(separator: " ").map(String.init))
        let wideTop = try pixels(try #require(wide.first))
        #expect(abs(wideTop.minY - top.minY) < 1, "the wide title's first line starts at \(wideTop.minY) px")
        #expect(wideTop.height < top.height - 1, "the wide title is set smaller: \(wideTop.height) against \(top.height) px")
        #expect(try wide.map(pixels).allSatisfy(margins.contains))
        // The smallest size fits a title and an author both at the 100-character cap in wide capitals, whole, from 30% down
        let widest = try coverBook(Self.wideTitle, author: Self.wideTitle).words(onPage: 0)
        #expect(widest.map(\.text) == (Self.wideTitle + " " + Self.wideTitle).split(separator: " ").map(String.init))
        let widestTop = try pixels(try #require(widest.first))
        #expect(abs(widestTop.minY - top.minY) < 1, "the widest cover's first line starts at \(widestTop.minY) px")
        #expect(try widest.map(pixels).allSatisfy(margins.contains))

        // No text, no cover: still .empty
        #expect(throws: EBookError.empty) {
            try TypesetBook.make(EBook(title: "Alice", chapters: [EBook.Chapter(blocks: [.paragraph(" ")])], author: "Lewis Carroll"),
                                 fileName: "alice.epub")
        }
        #expect(Typesetter.paginate(EBook(title: "T", chapters: [], author: "A"), title: "T").pageCount == 0)

        let again = try TypesetBook.make(EBook(title: "Alice’s Adventures in Wonderland", chapters: [EBook.Chapter(blocks: alice)],
                                               author: "Lewis Carroll"), fileName: "alice.epub").words(onPage: 0)
        #expect(again.map(\.text) == cover.map(\.text))
        let corners = zip(cover, again).flatMap { zip($0.quads, $1.quads) }.flatMap { zip($0.corners, $1.corners) }
        #expect(corners.allSatisfy { abs($0.x - $1.x) < 1e-6 && abs($0.y - $1.y) < 1e-6 }, "deterministic")
    }

    /// A page image's top left pixel as sRGB 0xRRGGBB, and a histogram of each of its red, green and blue channels.
    private func colors(of image: CGImage) throws -> (corner: UInt32, histograms: [[vImagePixelCount]]) {
        let width = image.width, height = image.height, space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: 4 * width * height), counts = [vImagePixelCount](repeating: 0, count: 4 * 256)
        try pixels.withUnsafeMutableBufferPointer { pixels in
            let context = try #require(CGContext(data: pixels.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: 4 * width, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var buffer = vImage_Buffer(data: pixels.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                       rowBytes: 4 * width)
            counts.withUnsafeMutableBufferPointer { counts in
                var channels = (0..<4).map { Optional(counts.baseAddress! + 256 * $0) }
                _ = vImageHistogramCalculation_ARGB8888(&buffer, &channels, vImage_Flags(kvImageNoFlags))
            }
        }
        return (pixels[..<3].reduce(0) { $0 << 8 | UInt32($1) }, (0..<3).map { Array(counts[256 * $0..<256 * ($0 + 1)]) })
    }

    @Test("U-TYPE-014 A line break (U+2028) starts a new line in the same block: a verse's lines share a left edge with no first-line indent, its stanzas stand apart, and a heading with one sets two centred lines")
    func verseLayout() throws {
        let abc = Typesetter.paginate(EBook(title: nil, chapters: [EBook.Chapter(blocks: [.paragraph("a\u{2028}b\u{2028}c")])]), title: nil)
        let letters = try abc.words(onPage: 0).map(pixels)
        #expect(abc.pageCount == 1 && abc.words(onPage: 0).map(\.text) == ["a", "b", "c"])
        #expect(letters.allSatisfy { abs($0.minX - style.margin) < 1 }, "no indent: \(letters)")
        #expect(zip(letters, letters.dropFirst()).allSatisfy { $1.minY > $0.maxY - 1 }, "one line each: \(letters)")

        // The crocodile: two stanzas of four lines of their own words, aligned at the margin, while prose keeps its indent
        let page = verseBook().words(onPage: 0)
        let lineWords = Self.crocodile.flatMap { $0.split(separator: "\u{2028}").map { $0.split(separator: " ").map(String.init) } }
        let start = try #require(page.firstIndex { $0.text == "“How" })
        let poemLines = try lines(Array(page[start..<start + lineWords.joined().count]))
        try #require(poemLines.map(\.count) == lineWords.map(\.count))
        #expect(poemLines.allSatisfy { abs(($0.first?.minX ?? 0) - style.margin) < 1 }, "aligned: \(poemLines.map { $0.first?.minX })")
        // Between the stanzas, more than a line's pitch: the space after the first
        let tops = poemLines.map { $0.first?.minY ?? 0 }
        let pitch = tops[1] - tops[0], gap = tops[4] - tops[3]
        #expect(gap > pitch + style.fontSize / 4, "stanzas \(gap) px apart, lines \(pitch) px")
        let prose = try pixels(try #require(page.first { $0.text == "“Curiouser" }))
        #expect(abs(prose.minX - style.margin - style.indent) < 2, "prose indented at \(prose.minX)")
        let heading = try lines(Array(page.prefix(6)))
        #expect(heading.map(\.count) == [2, 4], "CHAPTER II. | The Pool of Tears")
        for line in heading {
            let centre = ((line.first?.minX ?? 0) + (line.last?.maxX ?? 0)) / 2
            #expect(abs(centre - CGFloat(style.width) / 2) < 6, "centred: \(line)")
        }
    }

    @Test("U-TYPE-015 A cover's color is one of nine of Apple's standard system colors (no red, pink or green), its text white wherever white reaches 3:1 (WCAG 2, large text) and black elsewhere, picked by the title's FNV-1a hash, so a title has the same one on every launch")
    func coverColors() {
        func luminance(_ rgb: UInt32) -> Double {
            let linear = [16, 8, 0].map { shift in
                let value = Double(rgb >> UInt32(shift) & 0xFF) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        func contrast(_ a: UInt32, _ b: UInt32) -> Double {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        // The formula against known ratios: #767676 is the lightest gray that passes on white, #777777 fails
        #expect(abs(contrast(0x767676, 0xFFFFFF) - 4.54) < 0.01 && abs(contrast(0x777777, 0xFFFFFF) - 4.48) < 0.01)
        #expect(Set(style.coverColors).count == 9)
        for color in style.coverColors {
            let white = PageStyle.coverTextColor(on: color).components?.first == 1
            #expect(white == (contrast(color, 0xFFFFFF) >= 3), "#\(String(color, radix: 16)): \(contrast(color, 0xFFFFFF)):1 on white")
        }
        // Palette indices worked out apart from the app (64-bit FNV-1a over UTF-8, modulo 9), one title for each color
        let titles = ["D": 0, "G": 1, "F": 2, "A": 3, "Three Chapters": 4, "rabbit-hole": 5, "B": 6, "M": 7, "Middlemarch": 8]
        for (title, index) in titles {
            #expect(style.coverColor(title: title) == style.coverColors[index], "\(title)")
        }
    }
}
