import Foundation
import Testing
@testable import ReadStairCore

/// U-IMP-001…003: requeueing failed pages, resuming after a kill, the free-space check.
@Suite("U-IMP Importer", .timeLimit(.minutes(2)))
struct ImporterTests {
    @Test("U-IMP-001 5 pending pages, recognizer throws on page 3: page 3 requeued with attempts = 1, the other 4 recognized; fails again → failed")
    func failingPageIsRequeuedThenFailed() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 5)
            let log = CallLog()
            let snapshot = SnapshotBox()
            let importer = Importer(store: store, recognizer: { image in
                let number = pageNumber(of: image)
                log.begin(number)
                defer { log.end() }
                // Page 3 after its first failure and before its second try: snapshot it while page 4 is being recognized.
                // This snapshot is the only guard of the "failed pages go to the back" order: the final states are the same either way.
                if number == 4 { snapshot.page = try await store.pages(of: book.id)[2] }
                if number == 3 { throw FakeRecognitionError() }
                return fakeText(number)
            }, concurrency: 1)
            try await importer.drain()

            let third = try #require(snapshot.page)
            #expect(third.status == .pending && third.attempts == 1)
            let pages = try await store.pages(of: book.id)
            #expect(pages.map(\.status) == [.recognized, .recognized, .failed, .recognized, .recognized])
            #expect(pages.map(\.attempts) == [1, 1, 2, 1, 1])
            #expect(log.count(of: 3) == 2)
            #expect(try await store.pageText(of: pages[2].id) == nil)
            #expect(try await store.pageText(of: pages[4].id) == fakeText(5))
        }
    }

    @Test("U-IMP-001 supplementary: page 3 fails once → succeeds on the second try, recognized with attempts = 2")
    func failingOnceThenSucceeds() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 5)
            let log = CallLog()
            let importer = Importer(store: store, recognizer: { image in
                let number = pageNumber(of: image)
                if log.begin(number) == 1, number == 3 { throw FakeRecognitionError() }
                return fakeText(number)
            }, concurrency: 2)
            try await importer.drain()
            let pages = try await store.pages(of: book.id)
            #expect(pages.allSatisfy { $0.status == .recognized })
            #expect(pages.map(\.attempts) == [1, 1, 2, 1, 1])
        }
    }

    @Test("U-IMP-002 Process killed mid-recognition, then relaunched: recognizing goes back to pending and the queue resumes")
    func resumesAfterKill() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 4)
            // First "process": the recognizer never returns, so both workers stay in recognizing
            let stuck = Importer(store: store, recognizer: { _ in
                try await Task.sleep(for: .seconds(3600))
                return fakeText(0)
            }, concurrency: 2, timeout: .seconds(3600))   // its deadline must not fire while the relaunched queue runs
            let firstRun = Task { try await stuck.drain() }
            try await waitUntil { try await store.pages(of: book.id).filter { $0.status == .recognizing }.count == 2 }

            // Killed: nothing gets to run. Relaunch = reopen the database
            let relaunched = try BookStore(root: root)
            let afterRelaunch = try await relaunched.pages(of: book.id)
            #expect(afterRelaunch.filter { $0.status == .recognizing }.isEmpty)
            #expect(afterRelaunch.map(\.status) == [.pending, .pending, .pending, .pending])
            #expect(afterRelaunch.map(\.attempts) == [1, 1, 0, 0])

            let resumed = Importer(store: relaunched, recognizer: { fakeText(pageNumber(of: $0)) }, concurrency: 2)
            try await resumed.drain()
            let pages = try await relaunched.pages(of: book.id)
            #expect(pages.allSatisfy { $0.status == .recognized })
            #expect(pages.map(\.attempts) == [2, 2, 1, 1])
            for (i, page) in pages.enumerated() {
                #expect(try await relaunched.pageText(of: page.id) == fakeText(i + 1))
            }

            // Clean up the first "process": its requeue writes only touch recognizing pages, so they cannot disturb finished results
            firstRun.cancel()
            _ = await firstRun.result
            #expect(try await relaunched.pages(of: book.id).allSatisfy { $0.status == .recognized })
        }
    }

    @Test("U-IMP-003 Free space < pages × 1 MB: import refused with insufficientDisk, nothing written")
    func rejectsWhenDiskIsLow() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let log = CallLog()
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) }, availableCapacity: { 3 << 20 })
            await #expect(throws: StoreError.insufficientDisk(required: 5 << 20, available: 3 << 20)) {
                try await importer.importPages(count: 5, into: book.id) { log.begin($0); return pageImage($0 + 1) }
            }
            #expect(log.calls.isEmpty)
            #expect(try await store.pages(of: book.id).isEmpty)
            let bookDirectory = root.appending(path: "Books").appending(path: book.id.uuidString)
            #expect(!FileManager.default.fileExists(atPath: bookDirectory.path(percentEncoded: false)))

            // Exactly enough (= pages × 1 MB) is allowed
            let enough = Importer(store: store, recognizer: { _ in fakeText(0) }, availableCapacity: { 5 << 20 })
            #expect(try await enough.importPages(count: 5, into: book.id) { pageImage($0 + 1) } == 5)
        }
    }
}
