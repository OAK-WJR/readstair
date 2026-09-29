import Foundation
import Testing
@testable import ReadStairCore

/// Performance records for applying fetched iCloud records. Measured on the whole process, so they only run on their own, on an idle
/// machine, and in a release build, the build their 1 s threshold is for: `READSTAIR_PERF=1 swift test -c release --filter
/// SyncPerformanceTests`.
@Suite("P-SYNC Sync performance", .tags(.performance), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_PERF"] == "1"))
struct SyncPerformanceTests {
    @Test("P-SYNC-001 Apply 5000 fetched word records (1.6 KB of system fields each, the real archive size) in one transaction: under 1 s on a Mac")
    func applyFiveThousandRecords() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let changes = (0..<5000).map { i in
                RemoteChange.saved(remoteWord("word\(i)", at: t0 + Int64(i), sentence: "A sentence of ordinary length for word \(i).",
                                              systemFields: Data(repeating: 7, count: 1600)))
            }
            var start = ContinuousClock.now
            let effects = try await store.applyFetched(changes)
            let first = ContinuousClock.now - start
            // The same batch again: every record is an echo (what a re-delivered fetch costs)
            start = ContinuousClock.now
            _ = try await store.applyFetched(changes)
            let echoes = ContinuousClock.now - start
            ExperimentLog.record(["test": "P-SYNC-001", "records": changes.count, "new_ms": first, "echo_ms": echoes])
            #expect(effects == .nothing)
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM wordEntry").first?["n"].int == 5000)
            #expect(first < .seconds(1))
        }
    }

    /// A device back online after a long time, or a first sync between two devices that both have the words: every fetched record
    /// is older than this device's copy, so each one is kept and queued to be sent again.
    @Test("P-SYNC-002 Apply 5000 fetched word records, each older than this device's copy, in one transaction: all 5000 queued again, under 1 s on a Mac")
    func applyFiveThousandOlderRecords() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            for i in 0..<5000 {
                try await store.upsertWord(WordEntry(lemma: "word\(i)", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0 + 10)))
            }
            let changes = (0..<5000).map { RemoteChange.saved(remoteWord("word\($0)", at: t0, systemFields: Data(repeating: 7, count: 1600))) }
            let start = ContinuousClock.now
            let effects = try await store.applyFetched(changes)
            let elapsed = ContinuousClock.now - start
            ExperimentLog.record(["test": "P-SYNC-002", "records": changes.count, "queued": effects.saveRecords.count, "ms": elapsed])
            #expect(effects.saveRecords.count == 5000)
            #expect(elapsed < .seconds(1))
        }
    }
}
