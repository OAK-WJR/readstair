import CoreGraphics
import Foundation
import Testing
@testable import ReadStairCore

/// S-ETEXT-001…005: pages imported with their text (a typeset electronic book) in the store and the recognition queue. S-ETEXT-004, a
/// book deleted mid-import, is the Importer supplementary case run with pages with text.
@Suite("S-ETEXT Pages imported with their text", .timeLimit(.minutes(2)))
struct TypesetPageStoreTests {
    @Test("S-ETEXT-001 A page imported with its text is saved as recognized with that text")
    func savedAsRecognized() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            #expect(try await importer.importPages(count: 3, into: book.id) { typesetPage($0 + 1) } == 3)
            let pages = try await store.pages(of: book.id)
            #expect(pages.map(\.status) == [.recognized, .recognized, .recognized])
            #expect(pages.map(\.attempts) == [0, 0, 0])
            #expect(pages.map(\.width) == [202, 204, 206])
            for (i, page) in pages.enumerated() {
                #expect(page.error == nil)
                #expect(try await store.pageText(of: page.id) == typesetText(i + 1))
            }
        }
    }

    @Test("S-ETEXT-002 The queue never recognizes a page that came with its text: drain() calls the recognizer only for a photographed page of the same book")
    func neverRecognized() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let log = CallLog()
            let importer = Importer(store: store, recognizer: { image in
                log.begin(pageNumber(of: image))
                defer { log.end() }
                return fakeText(pageNumber(of: image))
            })
            try await importer.importPages(count: 2, into: book.id) { typesetPage($0 + 1) }
            try await importer.importPages(count: 1, into: book.id) { _ in pageImage(3) }
            try await importer.drain()
            #expect(log.calls == [3])
            let pages = try await store.pages(of: book.id)
            #expect(pages.map(\.status) == [.recognized, .recognized, .recognized])
            #expect(pages.map(\.attempts) == [0, 0, 1])
            #expect(try await store.pageText(of: pages[0].id) == typesetText(1))
            #expect(try await store.pageText(of: pages[2].id) == fakeText(3))
        }
    }

    @Test("S-ETEXT-003 After a schemaVersion bump the text reads as missing, and reopening the store sends only that page to recognition, whose result replaces it")
    func schemaBumpFallsBackToRecognition() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            try await importer.importPages(count: 2, into: book.id) { typesetPage($0 + 1) }
            let pages = try await store.pages(of: book.id)
            let older = PageText.schemaVersion - 1
            try await store.execute("UPDATE pageText SET schemaVersion = \(older) WHERE pageID = '\(pages[0].id.uuidString)'")
            #expect(try await store.pageText(of: pages[0].id) == nil)

            let reopened = try BookStore(root: root)
            let requeued = try await reopened.pages(of: book.id)
            #expect(requeued.map(\.status) == [.pending, .recognized])
            #expect(requeued.map(\.attempts) == [0, 0])
            let log = CallLog()
            try await Importer(store: reopened, recognizer: { image in
                log.begin(pageNumber(of: image))
                defer { log.end() }
                return fakeText(pageNumber(of: image))
            }).drain()
            #expect(log.calls == [1])
            #expect(try await reopened.pages(of: book.id).map(\.status) == [.recognized, .recognized])
            #expect(try await reopened.pageText(of: pages[0].id) == fakeText(1))
            #expect(try await reopened.pageText(of: pages[1].id) == typesetText(2))
        }
    }

    @Test("S-ETEXT-005 Page and text are written in one transaction: if the text cannot be written, the page is not saved and its image is removed")
    func pageAndTextInOneTransaction() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            try await store.execute("CREATE TRIGGER failInsert BEFORE INSERT ON pageText BEGIN SELECT RAISE(ABORT, 'injected'); END")
            let error = await #expect(throws: StoreError.self) {
                try await importer.importPages(count: 1, into: book.id) { _ in typesetPage(1) }
            }
            guard case .sqlite = error else {
                Issue.record("expected an SQLite error, got \(String(describing: error))")
                return
            }
            #expect(try await store.pages(of: book.id).isEmpty)
            #expect(heicFiles(in: root.appending(path: "Books/\(book.id.uuidString)")).isEmpty)

            try await store.execute("DROP TRIGGER failInsert")
            try await importer.importPages(count: 1, into: book.id) { _ in typesetPage(1) }
            let page = try #require(try await store.pages(of: book.id).first)
            #expect(page.status == .recognized)
            #expect(try await store.pageText(of: page.id) == typesetText(1))
        }
    }
}

/// The text of typeset page `number` (from 1), unlike `fakeText(number)`, which stands for what recognition would find.
private func typesetText(_ number: Int) -> PageText {
    let word = PageWord(surface: "peeped", lemma: "peep", kind: .word, band: 9,
                        quads: [Quad(CGRect(x: 0.06, y: 0.04, width: 0.1, height: 0.02))], sentence: 0)
    return PageText(words: [word], sentences: ["Alice peeped into page \(number)."])
}

/// Typeset page `number` (from 1): its test image (200 + 2·number wide, as `pageImage`) with its text.
private func typesetPage(_ number: Int) -> ImportPage { ImportPage(image: pageImage(number), text: typesetText(number)) }

/// The page images and thumbnails left in a book's directory.
private func heicFiles(in directory: URL) -> [String] {
    let files = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    return files.filter { $0.hasSuffix(".heic") }
}
