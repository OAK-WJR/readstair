import Foundation
import Testing
@testable import ReadStairCore

/// Performance record for building the Word List (P-DB-001 on the host). It measures wall-clock time, so it only runs on its own, on
/// an idle machine, and in a release build, the build its threshold is for:
/// `READSTAIR_PERF=1 swift test -c release --filter WordListPerformanceTests`.
/// It builds the sections 10 times: the slowest build must take under 200 ms; the median is recorded next to it.
@Suite("P-DB Word List performance", .tags(.performance), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_PERF"] == "1"))
struct WordListPerformanceTests {
    @Test("P-DB-001 Word List of 2,000 learning words (plus 1,000 known) over 40 books: building the sections takes under 200 ms")
    func twoThousandEntries() {
        let books = (0..<40).map { Book(id: UUID(), title: "Book \($0)", createdAt: .now, lastPageIndex: 0) }
        func entry(_ lemma: String, band: Int?, book: UUID?, state: WordState = .learning) -> WordEntry {
            WordEntry(lemma: lemma, state: state, source: .lookup, band: band, firstBookID: book)
        }
        let deleted = UUID()
        let learning = (0..<2000).map { i in
            let first: UUID? = switch i % 10 {
            case 0: nil
            case 1: deleted
            default: books[i % 40].id
            }
            return entry("w\((i * 7919) % 2000)-\(i)", band: i % 20 == 2 ? nil : 1 + (i * 31) % 25, book: first)
        }
        let known = (0..<1000).map { entry("known\($0)", band: 3, book: books[$0 % 40].id, state: .known) }
        let entries = learning + known
        var sections: [WordListSections.Section] = []
        let times = (0..<10).map { _ in
            ContinuousClock().measure { sections = WordListSections.make(entries: entries, books: books, hiddenBookID: books[3].id) }
        }
        let slowest = times.max() ?? .zero
        ExperimentLog.record(["test": "P-DB-001", "entries": entries.count, "sections": sections.count,
                              "median_ms": percentile(0.5, times), "max_ms": slowest])
        #expect(sections.reduce(0) { $0 + $1.entries.count } == 2000)
        let listed = Set(sections.compactMap(\.id))
        #expect(sections.dropLast().compactMap(\.id) == books.map(\.id).filter { listed.contains($0) } && sections.last?.id == nil)
        for section in sections {
            let keys = section.entries.map { ($0.band ?? .max, $0.lemma) }
            #expect(zip(keys, keys.dropFirst()).allSatisfy { $0 <= $1 })
        }
        #expect(slowest < .milliseconds(200))
    }
}
