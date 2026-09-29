import Foundation
import Testing
@testable import ReadStairCore

/// Performance records for importing and the recognition queue. They measure the whole process, so they only run on their own:
/// `READSTAIR_PERF=1 swift test --filter ImportPerformanceTests`. Device thresholds apply on real devices; on a Mac the numbers are
/// recorded and only gross regressions fail.
@Suite("P-IMP Import performance", .tags(.performance), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_PERF"] == "1"))
struct ImportPerformanceTests {
    @Test("P-IMP-001 Save 30 camera-size pages (12 MP): time, file sizes, and memory stays bounded (one page at a time)")
    func saveThirtyPages() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Camera")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            let (saved, cost) = try await measure {
                try await importer.importPages(count: 30, into: book.id) { _ in testImage(width: 3024, height: 4032) }
            }
            let pages = try await store.pages(of: book.id)
            let sizes = pages.map { fileSize(store.imageURL(of: $0)) }
            let thumbs = pages.map { fileSize(store.thumbnailURL(of: $0)) }
            ExperimentLog.record(["test": "P-IMP-001", "pages": saved, "page_kb": sizes.reduce(0, +) / max(sizes.count, 1) / 1024,
                                  "thumb_kb": thumbs.reduce(0, +) / max(thumbs.count, 1) / 1024], cost.fields)
            #expect(saved == 30)
            #expect(pages.allSatisfy { $0.width == 1650 && $0.height == 2200 })
            // The 150 MB budget is checked on a device: where HEVC is encoded in software, the encoder alone needs about 56 MB of
            // working memory even for a 240 px thumbnail, on top of the 48 MB source image this test holds
            #expect(cost.increaseMB < 250, "gross regression guard")
            #expect(cost.retainedMB < 50, "nothing accumulates across pages")
            #expect(cost.elapsed < .seconds(180), "gross regression guard")
            if isDevice {
                #expect(cost.elapsed < .seconds(10), "device threshold; thermal state \(thermalState())")
            }
        }
    }

    @Test("P-IMP-002 A 600-page book: saving, then queue bookkeeping per page with an instant recognizer")
    func sixHundredPages() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Long")
            let importer = Importer(store: store, recognizer: { fakeText(pageNumber(of: $0)) }, concurrency: 2)
            let image = pageImage(1)
            var start = ContinuousClock.now
            try await importer.importPages(count: 600, into: book.id) { _ in image }
            let saving = ContinuousClock.now - start
            start = ContinuousClock.now
            try await importer.drain()
            let draining = ContinuousClock.now - start
            let perPage = draining / 600
            let database = fileSize(root.appending(path: "ReadStair.sqlite")) + fileSize(root.appending(path: "ReadStair.sqlite-wal"))
            ExperimentLog.record(["test": "P-IMP-002", "pages": 600, "save_ms": saving, "drain_ms": draining, "per_page_ms": perPage,
                                  "database_kb": database / 1024])
            #expect(try await store.pages(of: book.id).allSatisfy { $0.status == .recognized })
            #expect(perPage < .milliseconds(100), "queue overhead must stay far below recognition time (about 3 s per page)")
        }
    }
}
