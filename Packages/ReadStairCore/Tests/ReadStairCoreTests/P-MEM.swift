import CoreGraphics
import Foundation
import Testing
@testable import ReadStairCore

/// Memory of recognition and saving, measured in the test process as a proxy for the app (footprint sampled every 20 ms), and
/// whether recognizing two pages at once pays off. Run the suite on its own: `READSTAIR_EXPERIMENT=1 swift test --filter
/// RecognitionMemoryTests`, or xcodebuild with `TEST_RUNNER_READSTAIR_EXPERIMENT=1` and `-only-testing:ReadStairCoreTests/RecognitionMemoryTests`.
/// The app's 150 MB budget is asserted on a device only. The simulator and a Mac run Vision on the CPU and encode HEIC in software,
/// which takes far more memory, so there the numbers are recorded and only gross regressions fail.
@Suite("P-MEM Recognition memory", .tags(.performance), .serialized, .timeLimit(.minutes(30)),
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_EXPERIMENT"] == "1"))
struct RecognitionMemoryTests {
    @Test("P-MEM-002 One recognition: footprint peak and settled, the first time in the process and again warm")
    func oneRecognition() async throws {
        let image = try await fixturePage()
        ExperimentLog.recordEnvironment(test: "P-MEM-002")
        // The first run also loads Vision's models and the lexicon (unless an earlier test in the process did), and they stay
        // loaded: its retained memory is what the app keeps after its first page; the warm run's increase is the cost of one page
        for run in ["first", "warm"] {
            let (page, cost) = try await measure { try await Recognition.page(from: image) }
            ExperimentLog.record(["test": "P-MEM-002", "run": run, "words": page.words.count, "thermal": thermalState()], cost.fields)
            Self.expectWithinBudget(cost)
        }
    }

    @Test("P-MEM-003 Two recognitions at once, after a warm-up (as in the app after its first page): footprint peak and settled")
    func twoRecognitions() async throws {
        let image = try await fixturePage()
        ExperimentLog.recordEnvironment(test: "P-MEM-003")
        _ = try await Recognition.page(from: image)
        let (words, cost) = try await measure {
            async let first = Recognition.page(from: image)
            async let second = Recognition.page(from: image)
            return try await first.words.count + second.words.count
        }
        ExperimentLog.record(["test": "P-MEM-003", "recognitions": 2, "words": words, "thermal": thermalState()], cost.fields)
        Self.expectWithinBudget(cost, concurrent: 2)
    }

    /// Whether the Importer should recognize two pages at once on devices with 6 GB or more: worth it only if it is clearly faster
    /// and stays within the budget. Both runs start warm and, where the thermal state allows, cool.
    @Test("P-MEM-004 The Importer with real recognition: 10 fixture pages at concurrency 1, then 2; time and footprint of each run")
    func importerConcurrency() async throws {
        let image = try await fixturePage()
        ExperimentLog.recordEnvironment(test: "P-MEM-004")
        _ = try await Recognition.page(from: image)
        var times: [Duration] = []
        for concurrency in [1, 2] {
            times.append(try await withTemporaryRoot { root in
                let store = try BookStore(root: root)
                let book = try await store.createBook(title: "Alice")
                // This measures throughput, so no page may time out and be recognized twice (a Mac takes up to about 40 s a page)
                let importer = Importer(store: store, concurrency: concurrency, timeout: .seconds(600))
                let imported = try await importer.importPages(count: 10, into: book.id) { _ in image }
                #expect(imported == 10)
                let waited = try await coolDown()
                let (_, cost) = try await measure { try await importer.drain() }
                let pages = try await store.pages(of: book.id)
                ExperimentLog.record(["test": "P-MEM-004", "concurrency": concurrency, "pages": pages.count,
                                      "per_page_ms": cost.elapsed / max(pages.count, 1), "cooldown_ms": waited, "thermal": thermalState()],
                                     cost.fields)
                #expect(pages.allSatisfy { $0.status == .recognized && $0.attempts == 1 })
                Self.expectWithinBudget(cost, concurrent: concurrency)
                return cost.elapsed
            })
        }
        ExperimentLog.record(["test": "P-MEM-004", "summary": "concurrency", "ms_1": times[0], "ms_2": times[1],
                              "speedup": times[0] / times[1]])
    }

    /// Unlike P-IMP-001's synthetic 12 MP images, which compress to a few KB, this saves a real typeset page close to the stored
    /// page size, so encoding time and file size are realistic.
    @Test("P-MEM-005 Save 30 fixture pages without recognizing them: time, page file size and footprint")
    func saveThirtyPages() async throws {
        let image = try await fixturePage()
        ExperimentLog.recordEnvironment(test: "P-MEM-005")
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store)
            let (saved, cost) = try await measure { try await importer.importPages(count: 30, into: book.id) { _ in image } }
            let bytes = try await store.pages(of: book.id).reduce(0) { $0 + fileSize(store.imageURL(of: $1)) }
            ExperimentLog.record(["test": "P-MEM-005", "pages": saved, "page_kb": bytes / max(saved, 1) / 1024,
                                  "thermal": thermalState()], cost.fields)
            #expect(saved == 30)
            Self.expectWithinBudget(cost)
        }
    }

    /// On a device the whole process must stay within the app's 150 MB budget. Elsewhere only gross regressions fail: about three
    /// times the simulator's measured +100 MB per recognition, and nothing piling up afterwards.
    private static func expectWithinBudget(_ cost: Cost, concurrent: Int = 1) {
        if isDevice {
            #expect(cost.peakMB < 150, "peak \(Int(cost.peakMB)) MB is over the 150 MB budget")
        } else {
            #expect(cost.increaseMB < 300 * Double(concurrent), "gross regression guard: peak +\(Int(cost.increaseMB)) MB")
            #expect(cost.retainedMB < 100, "gross regression guard: +\(Int(cost.retainedMB)) MB left after the work")
        }
    }
}
