import CoreGraphics
import Foundation
import Testing
@testable import ReadStairCore

/// Builds the perf store that the app's device performance gates run on (App/ReadStairUITests/PerformanceGates.swift): a heavy user's
/// store. It has one book of 600 read pages, each a copy of alice-p1 with that page's recognized text, and 2,000 words being
/// learned, 1,500 first met in the book and 500 under Other, at level 3 (a skipped level test). It is made through the store's own API,
/// so its schema and its page-text version are the app's.
///
/// This is not a test. It runs only when `READSTAIR_PERF_STORE` names a folder that does not exist yet:
///
///     READSTAIR_PERF_STORE="$PWD/../../build/perf-store" swift test --filter PerfStoreFixture
///
/// Build it again whenever the store's schema or `PageText.schemaVersion` changes. The gates then report the store as out of date,
/// because the app queues all 600 pages to be read again.
@Suite("Perf store fixture", .serialized, .timeLimit(.minutes(60)),
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_PERF_STORE"] != nil))
struct PerfStoreFixture {
    static let pageCount = 600
    static let wordCount = 2_000

    @Test("Build the perf store: 600 read pages and 2,000 learning words")
    func build() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["READSTAIR_PERF_STORE"])
        let root = URL(filePath: path, directoryHint: .isDirectory)
        try #require(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)),
                     "\(path) already exists: delete it, or name a new folder")

        // Recognized once, for real; every page gets the same result
        let image = try await fixturePage()
        let text = try await Recognition.page(from: image)
        let store = try BookStore(root: root)
        try await store.skipLevelTest()
        let book = try await store.createBook(title: "Alice\u{2019}s Adventures in Wonderland")
        let importer = Importer(store: store, recognizer: { _ in text }, concurrency: 2, timeout: .seconds(600))
        let saved = try await importer.importPages(count: Self.pageCount, into: book.id) { _ in image }
        try #require(saved == Self.pageCount)
        try await importer.drain()
        let pages = try await store.pages(of: book.id)
        try #require(pages.count == Self.pageCount && pages.allSatisfy { $0.status == .recognized }, "Not every page was read")

        // Real lemmas past level 3, in frequency order; three in four first met on a page of the book, the rest under Other
        let lemmas = try learningLemmas(Self.wordCount, above: Profile.defaultLevel)
        for (index, (lemma, band)) in lemmas.enumerated() {
            let inBook = index % 4 != 3
            try await store.upsertWord(WordEntry(
                lemma: lemma, state: .learning, source: .lookup, band: band,
                updatedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
                firstBookID: inBook ? book.id : nil, firstPageID: inBook ? pages[index % pages.count].id : nil,
                firstSentence: "\u{201C}I never met the word \(lemma) before,\u{201D} said Alice, and she read the whole page "
                    + "again to see what it could mean."))
        }
        let entries = try await store.wordEntries()
        #expect(entries.filter { $0.state == .learning }.count == Self.wordCount)
        print("[PERF-STORE] root=\(path) pages=\(pages.count) words=\(entries.count) pageTextSchema=\(PageText.schemaVersion)")
    }

    /// The first `count` lemmas of the bundled band table whose band is above `level`, letters only, most frequent first.
    private func learningLemmas(_ count: Int, above level: Int) throws -> [(String, Int)] {
        let directory = try #require(Lexicon.directory, "The lexicon is not bundled")
        let table = try String(contentsOf: directory.appending(path: "bands.tsv"), encoding: .utf8)
        var lemmas: [(String, Int)] = []
        Lexicon.rows(table) { lemma, value in
            guard lemmas.count < count, let band = Int(value), band > level, lemma.allSatisfy(\.isLetter) else { return }
            lemmas.append((lemma, band))
        }
        try #require(lemmas.count == count, "The band table has only \(lemmas.count) such lemmas")
        return lemmas
    }
}
