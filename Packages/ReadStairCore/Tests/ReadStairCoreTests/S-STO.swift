import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ReadStairCore

/// Supplementary cases: BookStore image files, launch-time recovery and edge cases.
@Suite("Supplementary: BookStore", .timeLimit(.minutes(2)))
struct StoreEdgeTests {
    @Test("Page images: large images shrink to a 2200 px long edge, thumbnails to 240; small images are not enlarged; files are HEIC with no temporary files left")
    func pageImages() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            let sources = [testImage(width: 3000, height: 4000), testImage(width: 400, height: 600)]
            try await importer.importPages(count: 2, into: book.id) { sources[$0] }
            let pages = try await store.pages(of: book.id)
            #expect(pages.map { [$0.width, $0.height] } == [[1650, 2200], [400, 600]])

            for (page, thumbnail) in zip(pages, [[180, 240], [160, 240]]) {
                let image = try #require(PageImageFile.load(store.imageURL(of: page)))
                #expect(image.width == page.width && image.height == page.height)
                let thumb = try #require(PageImageFile.load(store.thumbnailURL(of: page)))
                #expect([thumb.width, thumb.height] as [Int] == thumbnail)
                let source = try #require(CGImageSourceCreateWithURL(store.imageURL(of: page) as CFURL, nil))
                #expect(CGImageSourceGetType(source) as String? == "public.heic")
            }
            let directory = root.appending(path: "Books/\(book.id.uuidString)")
            let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
            let expected = ["thumbs"] + pages.flatMap { ["\($0.id.uuidString).heic", "thumbs/\($0.id.uuidString).heic"] }
            #expect(files == expected.sorted())
        }
    }

    @Test("Launch sweep: directories of unknown books, images and thumbnails of unknown pages, temporary files and strays are removed; known images stay")
    func reclaimsOrphans() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 1)
            let page = try #require(try await store.pages(of: book.id).first)
            let books = root.appending(path: "Books")
            let bookDirectory = books.appending(path: book.id.uuidString)
            let strays = [
                books.appending(path: "\(UUID().uuidString)/\(UUID().uuidString).heic"),   // left over from a book deletion
                books.appending(path: "not-a-book/x.heic"),
                bookDirectory.appending(path: "\(UUID().uuidString).heic"),                // written just before a crash
                bookDirectory.appending(path: "thumbs/\(UUID().uuidString).heic"),
                bookDirectory.appending(path: ".dat.nosync1234.tmp"),                        // temporary file of an atomic write
            ]
            for url in strays {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
            try Data("x".utf8).write(to: books.appending(path: "stray-file"))

            _ = try BookStore(root: root)
            for url in strays { #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), "\(url.lastPathComponent)") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: books.path(percentEncoded: false)) == [book.id.uuidString])
            #expect(FileManager.default.fileExists(atPath: store.imageURL(of: page).path(percentEncoded: false)))
            #expect(FileManager.default.fileExists(atPath: store.thumbnailURL(of: page).path(percentEncoded: false)))
        }
    }

    @Test("Crash-loop guard: at launch a recognizing page with 2 started attempts is marked failed (interrupted); one with 1 goes back to pending")
    func crashLoopProtection() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 2)
            let pages = try await store.pages(of: book.id)
            try await store.execute("UPDATE page SET status = 'recognizing', attempts = 2 WHERE id = '\(pages[0].id.uuidString)'")
            try await store.execute("UPDATE page SET status = 'recognizing', attempts = 1 WHERE id = '\(pages[1].id.uuidString)'")
            let after = try await BookStore(root: root).pages(of: book.id)
            #expect(after.map(\.status) == [.failed, .pending])
            #expect(after.map(\.error) == ["interrupted", nil])
            #expect(after.map(\.attempts) == [2, 1])
        }
    }

    @Test("Retry: failed → pending with attempts and error cleared; no effect on other pages")
    func retry() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 2)
            let importer = Importer(store: store, recognizer: { image in
                if pageNumber(of: image) == 1 { throw FakeRecognitionError() }
                return fakeText(2)
            })
            try await importer.drain()
            var pages = try await store.pages(of: book.id)
            #expect(pages.map(\.status) == [.failed, .recognized])
            try await store.retry(pages[0].id)
            try await store.retry(pages[1].id)
            pages = try await store.pages(of: book.id)
            #expect(pages.map(\.status) == [.pending, .recognized])
            #expect(pages.map(\.attempts) == [0, 1])
            #expect(pages[0].error == nil)
        }
    }

    @Test("Deleting a page: its row, result, image and thumbnail are gone; the other pages keep their indices and results; the book row is untouched; deleting again or an unknown id does nothing")
    func deletePage() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 3)
            try await Importer(store: store, recognizer: { fakeText(pageNumber(of: $0)) }).drain()
            let pages = try await store.pages(of: book.id)
            let booksBefore = try await store.bookSummaries().map(\.book)
            let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
            #expect(exists(store.imageURL(of: pages[1])) && exists(store.thumbnailURL(of: pages[1])))

            try await store.deletePage(pages[1].id)
            let remaining = try await store.pages(of: book.id)
            #expect(remaining.map(\.id) == [pages[0].id, pages[2].id])
            #expect(remaining.map(\.index) == [0, 2])
            let results = try inspect(root, "SELECT pageID FROM pageText").compactMap { $0["pageID"].uuid }
            #expect(Set(results) == [pages[0].id, pages[2].id])
            #expect(try await store.pageText(of: pages[2].id) == fakeText(3))
            #expect(!exists(store.imageURL(of: pages[1])) && !exists(store.thumbnailURL(of: pages[1])))
            #expect(remaining.allSatisfy { exists(store.imageURL(of: $0)) && exists(store.thumbnailURL(of: $0)) })
            #expect(try await store.bookSummaries().map(\.book) == booksBefore)

            try await store.deletePage(pages[1].id)
            try await store.deletePage(UUID())
            #expect(try await store.pages(of: book.id) == remaining)
        }
    }

    @Test("Deleting a book's only page leaves the book in place with zero pages")
    func deleteLastPage() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 1)
            let page = try #require(try await store.pages(of: book.id).first)
            try await store.deletePage(page.id)
            #expect(try await store.bookSummaries().map(\.book).map(\.id) == [book.id])
            #expect(try await store.pages(of: book.id).isEmpty)
        }
    }

    @Test("Deleting a book mid-recognition: the result is not stored, nothing throws, the image directory is removed, no orphan pageText")
    func deleteBookWhileRecognizing() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 1)
            let gate = AsyncGate()
            let importer = Importer(store: store, recognizer: { _ in
                await gate.wait()
                return fakeText(1)
            })
            let running = Task { try await importer.drain() }
            try await waitUntil { await gate.waiting == 1 }   // the recognizer is running, so its result will really be dropped
            try await store.deleteBook(book.id)
            await gate.open()
            try await running.value
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM pageText").first?["n"].int == 0)
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM page").first?["n"].int == 0)
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Books/\(book.id.uuidString)").path(percentEncoded: false)))
        }
    }

    @Test("Deleting a page mid-recognition: the late result is dropped by the claim guard, nothing throws, no pageText row or image files remain")
    func deletePageWhileRecognizing() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 1)
            let page = try #require(try await store.pages(of: book.id).first)
            let gate = AsyncGate()
            let importer = Importer(store: store, recognizer: { _ in
                await gate.wait()
                return fakeText(1)
            })
            let running = Task { try await importer.drain() }
            try await waitUntil { await gate.waiting == 1 }   // the recognizer is running, so its result will really be dropped
            try await store.deletePage(page.id)
            await gate.open()
            try await running.value
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM pageText").first?["n"].int == 0)
            #expect(try await store.pages(of: book.id).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.imageURL(of: page).path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: store.thumbnailURL(of: page).path(percentEncoded: false)))
        }
    }

    @Test("A result from an older analysis version reads as unrecognized, and the next launch queues only that page again, with a fresh attempt count; apostrophes, curly quotes, non-ASCII and emoji round-trip")
    func pageTextVersionAndUnicode() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 2)
            let text = PageText(words: [], sentences: ["Don't \u{2019}twas café 🐇"])
            try await Importer(store: store, recognizer: { _ in text }).drain()
            let pages = try await store.pages(of: book.id)
            try #require(pages.map(\.status) == [.recognized, .recognized])
            #expect(try await store.pageText(of: pages[0].id) == text)
            try await store.execute("UPDATE pageText SET schemaVersion = 0 WHERE pageID = '\(pages[0].id.uuidString)'")
            #expect(try await store.pageText(of: pages[0].id) == nil)

            let reopened = try BookStore(root: root)
            let requeued = try await reopened.pages(of: book.id)
            #expect(requeued.map(\.status) == [.pending, .recognized])
            #expect(requeued.map(\.attempts) == [0, 1])
            #expect(requeued[0].error == nil)
            try await Importer(store: reopened, recognizer: { _ in text }).drain()
            #expect(try await reopened.pageText(of: pages[0].id) == text)

            // With bound parameters an apostrophe is ordinary text (spliced SQL would break on don't)
            for lemma in ["don't", "o'clock", "naïve"] {
                try await store.upsertWord(WordEntry(lemma: lemma, state: .learning, source: .lookup, band: 3))
            }
            #expect(try await store.wordEntries().map(\.lemma) == ["don't", "naïve", "o'clock"])
        }
    }

    @Test("Claim token: a stale claim can neither finish, fail nor release a newer claim of the same page")
    func staleClaimsAreIgnored() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 1)
            let first = try #require(try await store.claimNextPending())
            try await store.failRecognition(first, reason: "timeout")
            let second = try #require(try await store.claimNextPending())
            #expect(second.attempts == 2)
            try await store.releaseRecognition(first)
            try await store.failRecognition(first, reason: "late")
            try await store.finishRecognition(first, text: fakeText(1))
            var page = try #require(try await store.pages(of: book.id).first)
            #expect(page.status == .recognizing && page.attempts == 2 && page.error == "timeout")
            #expect(try await store.pageText(of: page.id) == nil)

            try await store.finishRecognition(second, text: fakeText(2))
            page = try #require(try await store.pages(of: book.id).first)
            #expect(page.status == .recognized && page.error == nil)
            #expect(try await store.pageText(of: page.id) == fakeText(2))
        }
    }

    @Test("Image coding runs on the dedicated page-image queue, never on the Swift cooperative pool (where it can deadlock)")
    func imageCodingQueue() async {
        let label = await PageImageFile.run { String(cString: __dispatch_queue_get_label(nil)) }
        #expect(label == "app.readstair.page-image")
    }

    @Test("SQL wrapper: an empty blob stays an empty blob, not NULL; NULL, integer, real and text round-trip")
    func sqlValues() throws {
        let database = try SQLiteConnection(path: ":memory:")
        try database.execute("CREATE TABLE t (a, b, c, d, e)")
        try database.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?)", [.blob(Data()), .null, .integer(-42), .real(0.5), .text("é")])
        let row = try #require(try database.query("SELECT * FROM t").first)
        #expect(row["a"] == .blob(Data()))
        #expect(row["b"] == .null)
        #expect(row["c"] == .integer(-42))
        #expect(row["d"] == .real(0.5))
        #expect(row["e"] == .text("é"))
        #expect(try database.query("SELECT typeof(a) AS t FROM t").first?["t"] == .text("blob"))
    }
}
