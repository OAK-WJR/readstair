import CoreGraphics
import Foundation
import Testing
@testable import ReadStairCore

/// Reads a store's change stream the way the app's single consumer does, through one iterator kept for the whole test (dropping an
/// iterator ends the stream). A write publishes before it returns, so once the writes have been awaited, `take()` returns exactly
/// what they published: it queues a marker behind them and reads up to it, without waiting for anything else.
private final class ChangeReader {
    private let store: BookStore
    private var iterator: AsyncStream<StoreChange>.Iterator

    init(_ store: BookStore) {
        self.store = store
        iterator = store.changes.makeAsyncIterator()
    }

    func take() async -> [StoreChange] {
        let marker = StoreChange.pages(UUID())
        let sink = await store.changeSink
        sink.yield(marker)
        var taken: [StoreChange] = []
        while let change = await iterator.next(), change != marker { taken.append(change) }
        return taken
    }
}

/// Supplementary cases: the store API the app's screens use, and the change stream that keeps them current.
@Suite("Supplementary: BookStore app API", .timeLimit(.minutes(2)))
struct StoreAppTests {
    @Test("Change stream: book and page writes publish .books or .pages(bookID) once they commit, including retry and page deletion; a write that changes no row publishes nothing")
    func bookAndPageWritesPublish() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let changes = ChangeReader(store)

            // Creating a book, then importing: reserving indices and writing image files publish nothing, each saved page does
            let book = try await makeBook(store, pages: 2)
            #expect(await changes.take() == [.books, .pages(book.id), .pages(book.id)])
            try await store.renameBook(book.id, to: "Wonderland")
            try await store.setLastPageIndex(1, of: book.id)
            #expect(await changes.take() == [.books, .books])
            try await store.renameBook(UUID(), to: "Nobody")
            try await store.setLastPageIndex(1, of: UUID())
            #expect(await changes.take() == [])

            // Recognition: a claim and every outcome that still matches it; a stale outcome writes nothing and publishes nothing
            let first = try #require(try await store.claimNextPending())
            try await store.finishRecognition(first, text: fakeText(1))
            #expect(await changes.take() == [.pages(book.id), .pages(book.id)])
            try await store.finishRecognition(first, text: fakeText(1))
            #expect(await changes.take() == [])

            let second = try #require(try await store.claimNextPending())
            try await store.releaseRecognition(second)
            #expect(await changes.take() == [.pages(book.id), .pages(book.id)])
            try await store.releaseRecognition(second)
            #expect(await changes.take() == [])

            let again = try #require(try await store.claimNextPending())
            try await store.failRecognition(again, reason: "test")
            #expect(await changes.take() == [.pages(book.id), .pages(book.id)])
            try await store.failRecognition(again, reason: "test")
            #expect(await changes.take() == [])

            let last = try #require(try await store.claimNextPending())
            try await store.failRecognition(last, reason: "test")
            #expect(try await store.pages(of: book.id).map(\.status) == [.recognized, .failed])
            #expect(try await store.claimNextPending() == nil)
            #expect(await changes.take() == [.pages(book.id), .pages(book.id)])

            // Retry finds the book through the row it changed; a page that is not failed is left alone
            try await store.retry(last.id)
            #expect(await changes.take() == [.pages(book.id)])
            try await store.retry(last.id)
            try await store.retry(first.id)
            try await store.retry(UUID())
            #expect(await changes.take() == [])

            try await store.deletePage(first.id)
            #expect(await changes.take() == [.pages(book.id)])
            try await store.deletePage(first.id)
            #expect(await changes.take() == [])

            // Deleting a book publishes .books only, although its pages go with it
            try await store.deleteBook(book.id)
            #expect(await changes.take() == [.books])
            try await store.deleteBook(book.id)
            try await store.deleteBook(UUID())
            #expect(await changes.take() == [])
        }
    }

    @Test("Change stream: a word write publishes .words; the level, the skip placeholder and the gloss language publish .profile; a skip or gloss language that changes no row publishes nothing")
    func wordAndLevelWritesPublish() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let changes = ChangeReader(store)
            try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5))
            #expect(await changes.take() == [.words])

            try await store.setGlossLanguage("fr")
            #expect(await changes.take() == [])
            try await store.skipLevelTest()
            #expect(await changes.take() == [.profile])
            try await store.skipLevelTest()
            #expect(await changes.take() == [])
            try await store.setLevel(7)
            try await store.setGlossLanguage("fr")
            #expect(await changes.take() == [.profile, .profile])
        }
    }

    @Test("Card-open write (onlyIfAbsent): a word already stored, here known from iCloud but not yet read back by the app, is kept: nothing is written, marked for upload or published; an absent word is written like upsertWord")
    func cardOpenWriteKeepsStoredWord() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let log = EffectsLog()
            try await log.observe(store)
            _ = try await store.applyFetched([.saved(remoteWord("peep", .known, band: 9, at: t0))])
            let changes = ChangeReader(store)
            _ = await changes.take()
            let stored = try await store.wordEntries()
            let tables = ["syncRecord", "syncState", "wordEntry", "wordOrigin"]
            let writes = try await auditWrites(store, root, tables)

            // The app's cache still has no state for peep, so the card rule asks for a write
            let bookID = UUID(), pageID = UUID()
            func opened(_ lemma: String) throws -> WordEntry {
                try #require(WordEntry.entryOnOpen(word: PageWord(surface: lemma, lemma: lemma, kind: .word, band: 9, quads: [], sentence: 0),
                                                   state: nil, level: 3, bookID: bookID, pageID: pageID, sentence: "She peeped."))
            }
            try await store.upsertWord(opened("peep"), onlyIfAbsent: true)
            #expect(try await store.wordEntries() == stored)
            #expect(try writes() == Dictionary(uniqueKeysWithValues: tables.map { ($0, 0) }))
            #expect(await changes.take() == [])
            #expect(log.all.isEmpty)

            var hedge = try opened("hedge")
            hedge.updatedAt = dateAt(t0)
            try await store.upsertWord(hedge, onlyIfAbsent: true)
            #expect(try await store.wordEntries() == [hedge] + stored)
            #expect(await changes.take() == [.words])
            #expect(log.all == [SyncEffects(saveZone: false, saveRecords: ["hedge"])])
        }
    }

    @Test("Change stream: iCloud steps that can change words or the level (fetched records, a send conflict, sign-out, deleted iCloud data) publish .words and .profile after they commit; bookkeeping-only steps publish nothing")
    func syncStepsPublish() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let changes = ChangeReader(store)

            try await store.saveEngineState(Data([1]))
            _ = try await store.loadEngineState()
            try await EffectsLog().observe(store)
            try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0)))
            _ = try await store.outgoingRecord(named: "rabbit")
            _ = try await store.pendingEffects()
            #expect(await changes.take() == [.words])

            // Send results that only touch syncRecord
            _ = try await store.applySent([.saved(recordName: "rabbit", systemFields: Data([7]), updatedAt: t0)])
            _ = try await store.applySent([.missing(recordName: "rabbit", zoneMissing: false)])
            _ = try await store.applySent([])
            #expect(await changes.take() == [])

            // A conflict merges iCloud's newer copy into wordEntry
            _ = try await store.applySent([.conflict(remoteWord("rabbit", .known, at: t0 + 10))])
            #expect(await changes.take() == [.words, .profile])
            #expect(try await store.wordEntries().map(\.state) == [.known])

            // Fetched records, published once the merge has committed
            _ = try await store.applyFetched([.saved(remoteWord("hare", at: t0)), .saved(remoteProfile(level: 8, at: t0))])
            #expect(await changes.take() == [.words, .profile])
            #expect(try await store.wordEntries().map(\.lemma) == ["hare", "rabbit"])
            #expect(try await store.profile()?.level == 8)
            _ = try await store.applyFetched([])
            #expect(await changes.take() == [])

            // Sign-out forgets the account's words and level; sign-in only queues uploads; deleted iCloud data resets both
            _ = try await store.handle(.signOut)
            #expect(await changes.take() == [.words, .profile])
            #expect(try await store.wordEntries().isEmpty)
            #expect(try await store.profile()?.level == Profile.defaultLevel)
            _ = try await store.handle(.signIn)
            #expect(await changes.take() == [])
            _ = try await store.handle(.userDeletedZone)
            #expect(await changes.take() == [.words, .profile])
        }
    }

    @Test("Change stream: a write that fails publishes nothing, including a transaction rolled back after its first statement; a halted sync step publishes nothing")
    func failedWritesPublishNothing() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 1)
            try await store.skipLevelTest()
            let claim = try #require(try await store.claimNextPending())
            let changes = ChangeReader(store)
            _ = await changes.take()   // what the setup published

            try await store.execute("""
                CREATE TRIGGER failBookUpdate BEFORE UPDATE ON book BEGIN SELECT RAISE(ABORT, 'injected'); END;
                CREATE TRIGGER failBookDelete BEFORE DELETE ON book BEGIN SELECT RAISE(ABORT, 'injected'); END;
                CREATE TRIGGER failPageText BEFORE INSERT ON pageText BEGIN SELECT RAISE(ABORT, 'injected'); END;
                CREATE TRIGGER failProfile BEFORE UPDATE ON profile BEGIN SELECT RAISE(ABORT, 'injected'); END;
                CREATE TRIGGER failSyncRecord BEFORE INSERT ON syncRecord BEGIN SELECT RAISE(ABORT, 'injected'); END;
                """)
            await #expect(throws: StoreError.self) { try await store.renameBook(book.id, to: "Wonderland") }
            await #expect(throws: StoreError.self) { try await store.setLastPageIndex(1, of: book.id) }
            await #expect(throws: StoreError.self) { try await store.deleteBook(book.id) }
            await #expect(throws: StoreError.self) { try await store.setGlossLanguage("fr") }
            // The page is marked recognized, then storing its result fails: both roll back
            await #expect(throws: StoreError.self) { try await store.finishRecognition(claim, text: fakeText(1)) }
            #expect(try await store.pages(of: book.id).map(\.status) == [.recognizing])
            // The word or level is written, then marking it for upload fails
            await #expect(throws: StoreError.self) {
                try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5))
            }
            await #expect(throws: StoreError.self) { try await store.setLevel(7) }
            // A fetched word is inserted, then recording its iCloud copy fails
            await #expect(throws: StoreError.self) { try await store.applyFetched([.saved(remoteWord("hare", at: t0))]) }
            #expect(try await store.wordEntries().isEmpty)
            #expect(await changes.take() == [])

            // The failed step halted sync for this run: later steps are skipped and publish nothing
            try await store.execute("DROP TRIGGER failSyncRecord;")
            #expect(try await store.applyFetched([.saved(remoteWord("hare", at: t0))]) == .nothing)
            #expect(try await store.handle(.signOut) == .nothing)
            #expect(try await store.wordEntries().isEmpty)
            #expect(await changes.take() == [])
        }
    }

    @Test("Change stream: created with the store and buffered, so a consumer that starts after the writes still gets every change in order; opening a store publishes nothing")
    func bufferedFromInit() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 2)
            try await Importer(store: store, recognizer: { fakeText(pageNumber(of: $0)) }).drain()
            try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5))

            // Two saved pages, then a claim and a result for each
            let expected: [StoreChange] = [.books] + Array(repeating: StoreChange.pages(book.id), count: 6) + [.words]
            #expect(await ChangeReader(store).take() == expected)

            // Launch-time recovery requeues a page cut short, without publishing: the app reads everything after opening
            try await store.execute("UPDATE page SET status = 'recognizing' WHERE bookID = '\(book.id.uuidString)'")
            let reopened = try BookStore(root: root)
            #expect(try await reopened.pages(of: book.id).map(\.status) == [.pending, .pending])
            #expect(await ChangeReader(reopened).take() == [])
        }
    }

    @Test("renameBook stores the title as given and setLastPageIndex the page to reopen at, for that book only; an unknown id changes nothing")
    func renameAndLastPageIndex() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let alice = try await store.createBook(title: "Alice", at: Date(timeIntervalSince1970: 1))
            let other = try await store.createBook(title: "Other", at: Date(timeIntervalSince1970: 2))
            let title = "  Alice's Adventures in Wonderland \u{1F407} "
            try await store.renameBook(alice.id, to: title)
            try await store.setLastPageIndex(41, of: alice.id)
            try await store.renameBook(UUID(), to: "Nobody")
            try await store.setLastPageIndex(9, of: UUID())
            #expect(try await store.bookSummaries().map(\.book) == [other, Book(id: alice.id, title: title, createdAt: alice.createdAt, lastPageIndex: 41)])
        }
    }

    @Test("createBook keeps an id given to it; an id already in use throws, changes nothing and publishes nothing")
    func createBookWithID() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let changes = ChangeReader(store)
            let id = UUID()
            let book = try await store.createBook(id: id, title: "Alice", at: Date(timeIntervalSince1970: 1))
            #expect(book == Book(id: id, title: "Alice", createdAt: Date(timeIntervalSince1970: 1), lastPageIndex: 0))
            await #expect(throws: StoreError.self) { try await store.createBook(id: id, title: "Again") }
            #expect(try await store.bookSummaries().map(\.book) == [book])
            #expect(await changes.take() == [.books])
        }
    }

    @Test("setGlossLanguage without a level row leaves no row; with one it changes only the gloss language, never the level, its time or the upload queue")
    func glossLanguage() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            try await store.setGlossLanguage("fr")
            #expect(try await store.profile() == nil)
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM profile").first?["n"].int == 0)

            try await store.setLevel(7, at: dateAt(t0))
            let records = try dump(root, "syncRecord")
            let tables = ["syncRecord", "syncState", "wordEntry", "wordOrigin"]
            let writes = try await auditWrites(store, root, tables)
            try await store.setGlossLanguage("fr")
            #expect(try await store.profile() == Profile(level: 7, glossLanguage: "fr", updatedAt: dateAt(t0)))
            try await store.setGlossLanguage(nil)
            #expect(try await store.profile() == Profile(level: 7, glossLanguage: nil, updatedAt: dateAt(t0)))
            let nothingWritten = Dictionary(uniqueKeysWithValues: tables.map { ($0, 0) })
            #expect(try writes() == nothingWritten)
            #expect(try dump(root, "syncRecord") == records)

            // A later level choice keeps it
            try await store.setGlossLanguage("de")
            try await store.setLevel(8, at: dateAt(t0 + 10))
            #expect(try await store.profile() == Profile(level: 8, glossLanguage: "de", updatedAt: dateAt(t0 + 10)))
        }
    }

    #if DEBUG
    @Test("Debug hook: a level delivered as if from iCloud goes through the fetched-record merge and publishes .profile: with no level row it becomes the level, not marked for upload; Skip's placeholder does not replace it; the level test's result, chosen after it, wins and is marked for upload")
    func cloudLevelForTesting() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let changes = ChangeReader(store)
            try await store.applyCloudLevelForTesting(12, at: dateAt(t0))
            #expect(await changes.take() == [.words, .profile])
            #expect(try await store.profile() == Profile(level: 12, glossLanguage: nil, updatedAt: dateAt(t0)))
            #expect(try syncRows(root) == ["Profile": SyncRowSnapshot(nil, nil)])

            try await store.skipLevelTest()
            #expect(try await store.profile()?.level == 12)
            #expect(await changes.take() == [])

            // A device clock behind iCloud's still makes the choice the later one
            try await store.setLevel(5, at: dateAt(t0 - 1000))
            #expect(try await store.profile() == Profile(level: 5, glossLanguage: nil, updatedAt: dateAt(t0 + 1)))
            #expect(try syncRows(root) == ["Profile": SyncRowSnapshot(nil, t0 + 1)])
        }
    }
    #endif

    @Test("bookSummaries: saved page count, pages before the saved position (the page it opens at, as the Reader numbers it, and how far in), the lowest-index page, newest first like books(); a book with no pages has zero counts and no first page")
    func bookSummaries() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let alice = try await store.createBook(title: "Alice", at: Date(timeIntervalSince1970: 1))
            let hare = try await store.createBook(title: "Hare", at: Date(timeIntervalSince1970: 2))
            _ = try await store.createBook(title: "Empty", at: Date(timeIntervalSince1970: 3))
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            try await importer.importPages(count: 5, into: alice.id) { pageImage($0 + 1) }
            try await importer.importPages(count: 1, into: hare.id) { pageImage($0 + 1) }

            // Index 0 deleted, so the first page is index 1; the pages' statuses do not count
            let imported = try await store.pages(of: alice.id)
            try await store.deletePage(imported[0].id)
            for (page, status) in zip(imported.dropFirst(), ["recognized", "recognizing", "failed", "pending"]) {
                try await store.execute("UPDATE page SET status = '\(status)' WHERE id = '\(page.id.uuidString)'")
            }

            let books = try await store.bookSummaries().map(\.book)
            let alicePages = try await store.pages(of: alice.id)
            let harePages = try await store.pages(of: hare.id)
            let summaries = try await store.bookSummaries()
            #expect(summaries.map(\.book) == books)
            #expect(summaries == [
                BookSummary(book: books[0], pageCount: 0, pagesBefore: 0, firstPage: nil),
                BookSummary(book: books[1], pageCount: 1, pagesBefore: 0, firstPage: harePages.first),
                BookSummary(book: books[2], pageCount: 4, pagesBefore: 0, firstPage: alicePages.first),
            ])
            #expect(summaries.map(\.book.title) == ["Empty", "Hare", "Alice"])
            #expect(summaries[2].firstPage?.index == 1)
            #expect(summaries.map(\.openingPageNumber) == [0, 1, 1])
            #expect(summaries.map(\.progress) == [0, 0, 0])

            // Saved position 0 falls in the deleted gap, so Alice opens on index 1, page 1, as the Reader does; index 3 is page 3 of 4;
            // past the end is the last page
            for (index, before, number, progress) in [(3, 2, 3, 2.0 / 3), (9, 4, 4, 1.0)] {
                try await store.setLastPageIndex(index, of: alice.id)
                let summary = try #require(try await store.bookSummaries().first { $0.book.id == alice.id })
                #expect(summary.pagesBefore == before && summary.openingPageNumber == number && summary.progress == progress)
            }
        }
    }

    @Test("loadImage and loadThumbnail decode the page image (long edge 2200 px) and its thumbnail (240 px); nil once the files are gone")
    func loadImages() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            try await importer.importPages(count: 1, into: book.id) { _ in testImage(width: 3000, height: 4000) }
            let page = try #require(try await store.pages(of: book.id).first)

            let image = try #require(await store.loadImage(of: page))
            #expect([image.width, image.height] as [Int] == [1650, 2200])
            let thumbnail = try #require(await store.loadThumbnail(of: page))
            #expect([thumbnail.width, thumbnail.height] as [Int] == [180, 240])

            try await store.deletePage(page.id)
            let missingImage = await store.loadImage(of: page)
            let missingThumbnail = await store.loadThumbnail(of: page)
            #expect(missingImage == nil && missingThumbnail == nil)
        }
    }
}
