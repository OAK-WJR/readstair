import CoreGraphics
import Foundation
import Testing
@testable import ReadStairCore

/// Supplementary cases: Importer timeouts, concurrency, cancellation and extremes (killed process, duplicate imports, full disk).
/// No wall-clock assertions (they flake when tests run in parallel); anything that could hang is caught by the time limit.
@Suite("Supplementary: Importer", .timeLimit(.minutes(2)))
struct ImporterEdgeTests {
    @Test("Timeout: a stuck page (ignoring cancellation, like Vision) is counted as failed and requeued at the deadline but keeps its slot until the recognizer returns; the late result is kept")
    func timeoutKeepsSlotAndLateResult() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 2)
            let stuck = AsyncGate()
            let log = CallLog()
            let importer = Importer(store: store, recognizer: { image in
                let number = pageNumber(of: image)
                log.begin(number)
                defer { log.end() }
                if number == 1 { await stuck.wait() }
                return fakeText(number)
            }, concurrency: 1, timeout: .milliseconds(200))
            let running = Task { try await importer.drain() }
            try await waitUntil { try await store.pages(of: book.id)[0].error == "timeout" }
            try await Task.sleep(for: .milliseconds(400))   // time for a released slot to start page 2, were it released
            var pages = try await store.pages(of: book.id)
            #expect(pages[0].status == .pending && pages[0].attempts == 1)
            // The only slot is still taken by the stuck recognizer, so page 2 has not started: memory stays within the limit
            #expect(pages[1].status == .pending)
            #expect(log.calls == [1])

            await stuck.open()
            try await running.value
            pages = try await store.pages(of: book.id)
            #expect(pages.map(\.status) == [.recognized, .recognized])
            #expect(pages[0].error == nil)
            #expect(log.calls == [1, 2])   // the late result was kept: page 1 was not recognized again
            #expect(log.maxRunning == 1)
        }
    }

    @Test("Concurrency cap: with concurrency = 2 at most 2 pages run, and they do run in parallel; with 1 they run one by one", arguments: [1, 2])
    func concurrencyCap(limit: Int) async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 6)
            let log = CallLog()
            let importer = Importer(store: store, recognizer: { image in
                log.begin(pageNumber(of: image))
                defer { log.end() }
                try await Task.sleep(for: .milliseconds(80))
                return fakeText(pageNumber(of: image))
            }, concurrency: limit)
            try await importer.drain()
            #expect(log.maxRunning == limit)
            #expect(Set(log.calls) == Set(1...6))
            #expect(try await store.pages(of: book.id).allSatisfy { $0.status == .recognized })
        }
    }

    @Test("Cancellation: in-flight pages go back to pending, no attempt counted, no result written")
    func cancellationReleasesPages() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 3)
            let importer = Importer(store: store, recognizer: { _ in
                try await Task.sleep(for: .seconds(3600))
                return fakeText(0)
            }, concurrency: 2)
            let running = Task { try await importer.drain() }
            try await waitUntil { try await store.pages(of: book.id).filter { $0.status == .recognizing }.count == 2 }
            running.cancel()
            try await running.value   // If cancellation never reached the recognizer this waits 3600 s: the suite time limit fails the test
            let pages = try await store.pages(of: book.id)
            #expect(pages.map(\.status) == [.pending, .pending, .pending])
            #expect(pages.map(\.attempts) == [0, 0, 0])
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM pageText").first?["n"].int == 0)
        }
    }

    @Test("Duplicate imports: two imports into one book at once get no index clashes; each import's pages stay contiguous and in order")
    func concurrentImportsIntoSameBook() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            async let first = importer.importPages(count: 5, into: book.id) { pageImage($0 + 1) }        // widths 202…210
            async let second = importer.importPages(count: 5, into: book.id) { pageImage($0 + 101) }     // widths 402…410
            #expect(try await [first, second] == [5, 5])
            let pages = try await store.pages(of: book.id)
            #expect(pages.map(\.index) == Array(0..<10))
            let widths = pages.map(\.width)
            #expect(widths == [202, 204, 206, 208, 210, 402, 404, 406, 408, 410]
                    || widths == [402, 404, 406, 408, 410, 202, 204, 206, 208, 210])
            // Another import after both finish continues after them
            try await importer.importPages(count: 2, into: book.id) { pageImage($0 + 1) }
            #expect(try await store.pages(of: book.id).map(\.index) == Array(0..<12))
        }
    }

    @Test("Full disk (result cannot be stored): the queue stops with diskFull and the page is requeued without an attempt; with space again it resumes")
    func diskFullStopsQueue() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 2)
            // A large result: storing it needs new database pages
            let big = PageText(words: [], sentences: (0..<4000).map { "sentence number \($0) with some padding text" })
            let importer = Importer(store: store, recognizer: { _ in big }, concurrency: 1)
            try await store.execute("PRAGMA max_page_count = 1")   // cannot go below the current size, so this freezes the database at its current size
            await #expect(throws: StoreError.diskFull) { try await importer.drain() }
            var pages = try await store.pages(of: book.id)
            #expect(pages.map(\.status) == [.pending, .pending])
            #expect(pages.map(\.attempts) == [0, 0])
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM pageText").first?["n"].int == 0)

            try await store.execute("PRAGMA max_page_count = 1073741823")
            try await importer.drain()
            pages = try await store.pages(of: book.id)
            #expect(pages.allSatisfy { $0.status == .recognized && $0.attempts == 1 })
        }
    }

    @Test("A store error other than a full disk stops the queue and requeues the page instead of leaving it recognizing")
    func storeErrorRequeuesPage() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 1)
            let importer = Importer(store: store, recognizer: { fakeText(pageNumber(of: $0)) })
            try await store.execute("CREATE TRIGGER failInsert BEFORE INSERT ON pageText BEGIN SELECT RAISE(ABORT, 'injected'); END")
            let error = await #expect(throws: StoreError.self) { try await importer.drain() }
            guard case .sqlite = error else {
                Issue.record("expected an SQLite error, got \(String(describing: error))")
                return
            }
            var page = try #require(try await store.pages(of: book.id).first)
            #expect(page.status == .pending && page.attempts == 0)

            try await store.execute("DROP TRIGGER failInsert")
            try await importer.drain()
            page = try #require(try await store.pages(of: book.id).first)
            #expect(page.status == .recognized)
        }
    }

    @Test("Importing and calling drain while the queue runs: returns at once, and the running pass recognizes the new pages")
    func drainPicksUpPagesAddedWhileRunning() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 2)
            let gate = AsyncGate()
            let importer = Importer(store: store, recognizer: { image in
                await gate.wait()
                return fakeText(pageNumber(of: image))
            }, concurrency: 2)
            let running = Task { try await importer.drain() }
            try await waitUntil { try await store.pages(of: book.id).filter { $0.status == .recognizing }.count == 2 }
            try await importer.importPages(count: 2, into: book.id) { pageImage($0 + 3) }
            try await importer.drain()   // already running: only asks for another pass
            await gate.open()
            try await running.value
            let pages = try await store.pages(of: book.id)
            #expect(pages.count == 4)
            #expect(pages.allSatisfy { $0.status == .recognized })
        }
    }

    @Test("Book deleted mid-import, with image-only pages or pages with their text: throws bookNotFound, no page, text or page image stays behind (and the directory is reclaimed at relaunch)",
          arguments: [false, true])
    func bookDeletedDuringImport(withText: Bool) async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            await #expect(throws: StoreError.bookNotFound) {
                try await importer.importPages(count: 4, into: book.id) { i in
                    if i == 2 { try? await store.deleteBook(book.id) }
                    return ImportPage(image: pageImage(i + 1), text: withText ? fakeText(i + 1) : nil)
                }
            }
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM page").first?["n"].int == 0)
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM pageText").first?["n"].int == 0)
            let directory = root.appending(path: "Books/\(book.id.uuidString)")
            let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
            #expect(leftovers.filter { $0.hasSuffix(".heic") }.isEmpty)
            _ = try BookStore(root: root)
            #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        }
    }

    @Test("A page's chapter is saved in the page's own transaction: when writing it fails (an injected trigger), the import throws and neither the page, its text, the chapter nor an image stays behind; a page without a chapter is unaffected")
    func chapterSavedWithPage() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            try await importer.importPages(count: 2, into: book.id) { i in
                ImportPage(image: pageImage(i + 1), text: fakeText(i + 1), chapter: i == 0 ? "I" : nil)
            }
            #expect(try await store.chapters(of: book.id) == [ChapterStart(pageIndex: 0, title: "I")])

            try await store.execute("CREATE TRIGGER failChapter BEFORE INSERT ON chapter BEGIN SELECT RAISE(ABORT, 'injected'); END")
            let error = await #expect(throws: StoreError.self) {
                try await importer.importPages(count: 1, into: book.id) { _ in
                    ImportPage(image: pageImage(3), text: fakeText(3), chapter: "II")
                }
            }
            guard case .sqlite = error else {
                Issue.record("expected an SQLite error, got \(String(describing: error))")
                return
            }
            #expect(try await store.pages(of: book.id).map(\.index) == [0, 1])
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM pageText").first?["n"].int == 2)
            #expect(try await store.chapters(of: book.id) == [ChapterStart(pageIndex: 0, title: "I")])
            let directory = root.appending(path: "Books/\(book.id.uuidString)").path(percentEncoded: false)
            #expect(try FileManager.default.subpathsOfDirectory(atPath: directory).filter { $0.hasSuffix(".heic") }.count == 4)

            #expect(try await importer.importPages(count: 1, into: book.id) { _ in ImportPage(image: pageImage(4)) } == 1)
        }
    }

    @Test("16 simultaneous imports do not deadlock: image coding stays off the Swift cooperative pool (16 concurrent encodes on it always deadlock)")
    func manyConcurrentImportsDoNotDeadlock() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            let image = testImage(width: 1000, height: 1400)
            let imported = try await withThrowingTaskGroup(of: Int.self) { group in
                for i in 0..<16 {
                    group.addTask {
                        let book = try await store.createBook(title: "Book \(i)")
                        return try await importer.importPages(count: 1, into: book.id) { _ in image }
                    }
                }
                return try await group.reduce(0, +)
            }
            #expect(imported == 16)
        }
    }

    @Test("A cancelled import finishes the page in hand, then stops; saved pages stay")
    func cancelledImportKeepsSavedPages() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            let slowSource = AsyncGate()
            let importing = Task {
                try await importer.importPages(count: 5, into: book.id) { i in
                    if i == 2 { await slowSource.wait() }
                    return pageImage(i + 1)
                }
            }
            try await waitUntil { await slowSource.waiting == 1 }
            importing.cancel()
            await slowSource.open()
            #expect(try await importing.value == 3)
            #expect(try await store.pages(of: book.id).map(\.index) == [0, 1, 2])
        }
    }

    @Test("A page whose source image cannot be read is skipped; the others keep their positions")
    func unreadableSourceIsSkipped() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            #expect(try await importer.importPages(count: 3, into: book.id) { $0 == 1 ? nil : pageImage($0 + 1) } == 2)
            let pages = try await store.pages(of: book.id)
            #expect(pages.map(\.index) == [0, 2])
            #expect(pages.map(\.width) == [202, 206])
        }
    }

    @Test("A stored page image that cannot be read fails recognition (unreadableImage) without calling the recognizer")
    func unreadableStoredImageFails() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 1)
            let page = try #require(try await store.pages(of: book.id).first)
            try Data("not an image".utf8).write(to: store.imageURL(of: page))
            let log = CallLog()
            try await Importer(store: store, recognizer: { log.begin(0); return fakeText(pageNumber(of: $0)) }).drain()
            let failed = try #require(try await store.pages(of: book.id).first)
            #expect(failed.status == .failed && failed.attempts == 2 && failed.error == "unreadableImage")
            #expect(log.calls.isEmpty)
        }
    }

    @Test("Cancelling the queue stops the page's clock: a recognizer that outlives the timeout does not get the page counted as failed")
    func cancellationStopsTimeout() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 1)
            let stuck = AsyncGate()
            let importer = Importer(store: store, recognizer: { image in
                await stuck.wait()
                try Task.checkCancellation()   // like Recognition.page: Vision finishes, then the cancelled task gives up
                return fakeText(pageNumber(of: image))
            }, concurrency: 1, timeout: .milliseconds(200))
            let running = Task { try await importer.drain() }
            try await waitUntil { await stuck.waiting == 1 }
            running.cancel()
            try await Task.sleep(for: .milliseconds(400))   // past the timeout while the recognizer is still stuck
            await stuck.open()
            try await running.value
            let page = try #require(try await store.pages(of: book.id).first)
            #expect(page.status == .pending && page.attempts == 0 && page.error == nil)
        }
    }

    @Test("Concurrency by physical memory: 1 for the 4 GB class, 2 for 6 GB and up (reported values can be slightly below nominal)",
          arguments: [(4.0, 1), (3.6, 1), (4.8, 1), (5.5, 2), (6.0, 2), (8.0, 2), (12.0, 2)])
    func concurrencyByMemory(gibibytes: Double, expected: Int) {
        #expect(Importer.concurrency(physicalMemory: UInt64(gibibytes * 1_073_741_824)) == expected)
    }
}
