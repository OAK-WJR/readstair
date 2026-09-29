import CoreGraphics
import Foundation
import NaturalLanguage
import Testing
@testable import ReadStairCore

/// Offline replay: CC0 book text is cut into pages of printed size and put through the app's analysis and marking
/// (`Recognition.splitAtDashes` and `PageAnalyzer`, then `Annotator.markedWords` at a level with no saved words), then scored
/// against synthetic readers from 1k to the top anchor. Clean text stands in for OCR, so recognition errors are not part of the
/// score. Each word gets a placeholder box, as OCR words have, because a word without one is never marked (U-ANN-005).
/// Output: `[EXP]` records.
/// Run it on a Mac: `READSTAIR_EXPERIMENT=1 swift test --filter SyntheticReaderReplay`.
@Suite("EXP-RPL Synthetic-reader replay", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_EXPERIMENT"] == "1", "Set READSTAIR_EXPERIMENT=1 to run"))
struct SyntheticReaderReplay {
    /// How often a reader taps a pseudoword in the vocabulary test.
    static let pseudowordTapRate = 0.05
    /// Vocabulary tests taken by each reader, one per seed.
    static let testsPerReader: UInt64 = 100
    /// A reader at every level up to the top anchor. One between anchors is marked at the anchor below, where the vocabulary test
    /// puts a reader who does not know the next anchor's band (EXP-RPL-002 shows it does); such rows are recorded, not asserted, and
    /// show what the gaps in the ladder cost.
    static let readerLevels = 1...(LevelLadder.anchors.last ?? 1)

    static func anchor(below level: Int) -> Int { LevelLadder.anchors.last { $0 <= level } ?? LevelLadder.anchors[0] }

    /// Asserts the replay's first gate: some anchor gives each book a density of 1–3%. Density depends on the book as much as on the
    /// app (a 1k reader finds most pages of any novel dense), hence "some anchor". Hit and false-mark rates are recorded only: the
    /// reader misses about one word in ten at random, easy ones included, so an 80% hit rate would need marks on 8% of the page or
    /// more, whatever the marking rule, and for an anchor reader the false-mark rate is about the noise rate by construction.
    @Test("EXP-RPL-001 Marks against synthetic readers: a density of 1–3% at some anchor for each book; hit and false-mark rates recorded")
    func marks() throws {
        ExperimentLog.recordEnvironment(test: "EXP-RPL-001")
        let nameType = NLTagger.availableTagSchemes(for: .word, language: .english).contains(.nameType)
        ExperimentLog.record(["test": "EXP-RPL-001", "name_type": nameType, "noise": SyntheticReader.noise, "seed": SyntheticReader.seed,
                              "words_per_page": ReplayBook.wordsPerPage])
        let books = try ReplayBook.all()
        try #require(!books.isEmpty, "No .xhtml books in Fixtures/source")
        let box = Quad(CGRect(x: 0, y: 0, width: 0.1, height: 0.02))
        for book in books {
            let pages = book.pages.map { page in
                PageAnalyzer.analyze(page.flatMap { Recognition.splitAtDashes(RecognizedWord(text: $0, quads: [box])) }, lexicon: .bundled)
            }
            var densities: [Double] = []
            for level in Self.readerLevels {
                let markedAt = Self.anchor(below: level)
                let score = Score(pages, reader: SyntheticReader(level: level), markedAt: markedAt)
                ExperimentLog.record(["test": "EXP-RPL-001", "book": book.name, "level": level, "marked_at": markedAt], score.fields)
                if level == markedAt { densities.append(score.density) }
            }
            #expect(densities.contains { (0.01...0.03).contains($0) },
                    "\(book.name): densities \(densities) at levels \(LevelLadder.anchors)")

            // Plain words without a band are marked at every level: rare words, and anything the lexicon cannot read
            let unlisted = pages.flatMap(\.words).filter { $0.kind == .word && $0.band == nil }
            let top = Dictionary(grouping: unlisted, by: \.lemma).sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }.prefix(12)
            ExperimentLog.record(["test": "EXP-RPL-001", "book": book.name, "unlisted_marks": unlisted.count,
                                  "top": top.map { "\($0.key):\($0.value.count)" }.joined(separator: ",")])
        }
    }

    /// A reader taps each real word it knows and each pseudoword with `pseudowordTapRate`; the same readers as EXP-RPL-001. Asserts
    /// the replay's second gate: each anchor reader gets its own anchor in at least 80% of its tests (the lowest measured is 87%, and
    /// 100 tests leave about ±3 points of sampling error). Readers between anchors are recorded only.
    @Test("EXP-RPL-002 First-launch vocabulary test taken by each synthetic reader: an anchor reader's estimate is its anchor in ≥ 80% of tests")
    func vocabularyTest() {
        ExperimentLog.recordEnvironment(test: "EXP-RPL-002")
        for level in Self.readerLevels {
            let reader = SyntheticReader(level: level), expected = Self.anchor(below: level)
            var estimates: [Int: Int] = [:], unreliable = 0
            for seed in 0..<Self.testsPerReader {
                var taps = SplitMix64(seed: SyntheticReader.seed ^ (seed << 32))
                let selected = VocabTest.items(seed: seed).filter { item in
                    item.band == 0 ? SyntheticReader.unit(taps.next()) < Self.pseudowordTapRate : reader.knows(item.word, band: item.band)
                }
                let estimate = VocabTest.estimate(selected: Set(selected))
                estimates[estimate.level, default: 0] += 1
                if estimate.unreliable { unreliable += 1 }
            }
            let expectedShare = Double(estimates[expected] ?? 0) / Double(Self.testsPerReader)
            ExperimentLog.record(["test": "EXP-RPL-002", "level": level, "expected": expected, "tests": Self.testsPerReader,
                                  "expected_pct": 100 * expectedShare,
                                  "estimates": LevelLadder.anchors.map { "\($0)k:\(estimates[$0] ?? 0)" }.joined(separator: ","),
                                  "unreliable": unreliable])
            if level == expected {
                #expect(expectedShare >= 0.8, "Reader at \(level)k: estimate \(expected)k in \(100 * expectedShare)% of tests")
            }
        }
    }
}

/// A synthetic reader: knows the lemmas whose band is at most `level` (a lemma without a band is unknown), except that the answer
/// for each lemma is flipped, either way, with probability `noise`. The flip is drawn from SplitMix64 seeded by the lemma, the
/// level and `seed`, so a lemma gets the same answer on every page, in every run and whichever books are present.
private struct SyntheticReader {
    static let noise = 0.1
    static let seed: UInt64 = 2026
    let level: Int

    func knows(_ lemma: String, band: Int?) -> Bool {
        let hash = lemma.utf8.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }  // FNV-1a
        var random = SplitMix64(seed: hash ^ (Self.seed &+ UInt64(level)))
        return ((band ?? .max) <= level) != (Self.unit(random.next()) < Self.noise)
    }

    /// A generator output as a double in 0..<1, by a fixed formula (the standard library's may change between releases).
    static func unit(_ value: UInt64) -> Double { Double(value >> 11) * 0x1p-53 }
}

/// One reader's counts over a book. Only plain words (kind `.word`) are known or unknown: names, numbers and punctuation are never
/// marked and are not vocabulary. Density counts every word on the page except punctuation.
private struct Score {
    /// `pagesInRange`: pages whose own density is 1–3%.
    var pages = 0, pagesInRange = 0, words = 0, marked = 0, unknown = 0, hits = 0, falseMarks = 0

    /// `markedAt` is the level the app marks at.
    init(_ pages: [PageText], reader: SyntheticReader, markedAt: Int) {
        self.pages = pages.count
        for page in pages {
            let marks = Set(Annotator.markedWords(in: page, level: markedAt, states: [:]))
            let pageWords = page.words.count(where: { $0.kind != .punct })
            for (index, word) in page.words.enumerated() where word.kind == .word {
                let known = reader.knows(word.lemma, band: word.band), isMarked = marks.contains(index)
                if !known { unknown += 1 }
                if isMarked, !known { hits += 1 }
                if isMarked, known { falseMarks += 1 }
            }
            words += pageWords
            marked += marks.count
            if (0.01...0.03).contains(Double(marks.count) / Double(max(pageWords, 1))) { pagesInRange += 1 }
        }
    }

    var hitRate: Double { unknown == 0 ? 1 : Double(hits) / Double(unknown) }
    var falseMarkRate: Double { marked == 0 ? 0 : Double(falseMarks) / Double(marked) }
    var density: Double { words == 0 ? 0 : Double(marked) / Double(words) }

    var fields: KeyValuePairs<String, Any> {
        ["pages": pages, "pages_with_density_1_3_pct": pagesInRange, "words": words, "marked": marked, "density_pct": 100 * density,
         "unknown": unknown, "hit_pct": 100 * hitRate, "false_mark_pct": 100 * falseMarkRate]
    }
}

/// A CC0 book for the replay, from Standard Ebooks XHTML in Fixtures/source: each .xhtml file there is one book, and so is each
/// folder there, made of its .xhtml files in Finder order (a Standard Ebooks repository's src/epub/text, say). Only paragraph text is
/// kept, as a printed page shows it: chapter headings, the title page, imprint, colophon, endnotes and note numbers are left out.
/// Words are split at whitespace, as OCR returns them (`conversations?”` is one word).
struct ReplayBook {
    static let wordsPerPage = 300

    var name: String
    var words: [String]

    /// The words in pages of `wordsPerPage`; the last page holds the rest.
    var pages: [ArraySlice<String>] {
        stride(from: 0, to: words.count, by: Self.wordsPerPage).map { words[$0..<min($0 + Self.wordsPerPage, words.count)] }
    }

    static func all() throws -> [ReplayBook] {
        let files = FileManager.default
        func contents(_ url: URL) throws -> [URL] {
            try files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        return try contents(fixtureURL("Fixtures/source")).compactMap { url in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let parts = try (isFolder ? contents(url) : [url]).filter { $0.pathExtension == "xhtml" }
            guard !parts.isEmpty else { return nil }
            return ReplayBook(name: url.deletingPathExtension().lastPathComponent, words: try parts.flatMap(Self.words(in:)))
        }
    }

    private static func words(in url: URL) throws -> [String] {
        let parser = try #require(XMLParser(contentsOf: url), "Cannot read \(url.lastPathComponent)")
        let collector = ParagraphCollector()
        parser.delegate = collector
        try #require(parser.parse(), "\(url.lastPathComponent): \(String(describing: parser.parserError))")
        return collector.words
    }
}

/// Collects the words of `<p>` elements, skipping headings (`hgroup`) and elements whose `epub:type` is not printed body text.
/// A line break inside a paragraph (verse) separates words; the word joiners Standard Ebooks puts next to dashes are dropped.
private final class ParagraphCollector: NSObject, XMLParserDelegate {
    private static let skipped: Set<Substring> = ["titlepage", "halftitlepage", "imprint", "colophon", "copyright-page", "endnotes",
                                                  "toc", "loi", "noteref"]
    private(set) var words: [String] = []
    private var paragraph: String?
    /// Above zero inside a skipped element: counts the elements open inside it.
    private var skipDepth = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if skipDepth > 0 || name == "hgroup" || !Self.skipped.isDisjoint(with: (attributes["epub:type"] ?? "").split(separator: " ")) {
            skipDepth += 1
        } else if name == "p" {
            paragraph = ""
        } else if name == "br" {
            paragraph?.append(" ")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if skipDepth == 0 { paragraph?.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skipDepth > 0 {
            skipDepth -= 1
        } else if name == "p", let text = paragraph {
            words += text.replacing("\u{2060}", with: "").split(whereSeparator: \.isWhitespace).map(String.init)
            paragraph = nil
        }
    }
}

/// The replay books are read only by the gated replay, so they are checked on every run: a malformed file dropped into
/// Fixtures/source shows up here.
@Suite("Supplementary: Replay books")
struct ReplayBookTests {
    @Test("Every book in Fixtures/source parses and has words; Alice's chapter I is its 2,140 paragraph words, from the first, without the heading")
    func books() throws {
        let books = try ReplayBook.all()
        let alice = try #require(books.first { $0.name == "alice-chapter-1" })
        #expect(alice.words.prefix(4) == ["Alice", "was", "beginning", "to"])
        #expect(alice.words.count == 2140)
        for book in books {
            #expect(!book.words.isEmpty, "\(book.name)")
        }
    }
}
