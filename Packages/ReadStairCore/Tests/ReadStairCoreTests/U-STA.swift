import Foundation
import Testing
@testable import ReadStairCore

// U-STA-001, the write rules W1 and W2 (what opening a word card writes, and the undo slot), is tested next to its private helpers:
// `EntryOnOpenTests` in S-APP-Rules.swift and `UndoSlotTests` in S-APP-Loop.swift.

/// U-STA-002: deleting a page or a book → zero writes to the word list and its sync data.
/// **Regression guard — never delete or weaken it.** Deleting a page or a book must never change a word's state, its provenance, what
/// iCloud is told, or the level. The only writers of wordEntry are upsertWord, iCloud merges and deletions (applyFetched, and the
/// conflict path of applySent), the sign-out forget step and the iCloud-data reset; page and book deletion never trigger any of them.
/// Turning pages and closing the reader are app behavior: they belong in the UI tests, not here.
@Suite("U-STA Word state")
struct WordStateTests {
    @Test("U-STA-002 Deleting a page or a book: zero writes to wordEntry, wordOrigin, syncRecord, syncState and profile (trigger counts 0, rows identical), nothing registered for upload; the book's pages, results and images are gone")
    func deletingPageOrBookNeverWritesWords() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let alice = try await makeBook(store, pages: 3, title: "Alice")
            let oz = try await makeBook(store, pages: 1, title: "Oz")
            try await Importer(store: store, recognizer: { fakeText(pageNumber(of: $0)) }).drain()
            let alicePages = try await store.pages(of: alice.id)
            let t = Date(timeIntervalSince1970: 1_800_000_000)
            for entry in [
                WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5, updatedAt: t,
                          firstBookID: alice.id, firstPageID: alicePages[0].id, firstSentence: "A White Rabbit ran by."),
                // First met on a page that outlives the deletePage step, so deleteBook still removes a page a word points to
                WordEntry(lemma: "waistcoat", state: .known, source: .card, band: 14, updatedAt: t,
                          firstBookID: alice.id, firstPageID: alicePages[2].id),
                WordEntry(lemma: "cyclone", state: .learning, source: .lookup, band: 11, updatedAt: t, firstBookID: oz.id),
            ] {
                try await store.upsertWord(entry)
            }
            // Every sync table holds rows: a word from iCloud (confirmed), provenance kept from a sign-out, a saved engine state, and
            // a chosen level waiting to upload. The provenance points at the page deleted first and at a page that goes with the
            // book, so each step deletes a page and the book a wordOrigin row names: a foreign key on either column would write it.
            _ = try await store.applyFetched([.saved(remoteWord("dormouse", at: t0))])
            try await store.execute("""
                INSERT INTO wordOrigin VALUES
                    ('march hare', '\(alice.id.uuidString)', '\(alicePages[0].id.uuidString)', 'Have some wine.'),
                    ('dodo', '\(alice.id.uuidString)', '\(alicePages[2].id.uuidString)', NULL)
                """)
            try await store.saveEngineState(Data([1]))
            try await store.setLevel(5)
            let before = try await store.wordEntries()
            let tables = ["wordEntry", "wordOrigin", "syncRecord", "syncState", "profile"]
            let rows = try tables.map { try dump(root, $0) }
            #expect(rows.allSatisfy { !$0.isEmpty })

            // Audit triggers: every insert, update or delete on these tables is counted; the log records any upload registration
            let writes = try await auditWrites(store, root, tables)
            let nothingWritten = Dictionary(uniqueKeysWithValues: tables.map { ($0, 0) })
            let log = EffectsLog()
            try await log.observe(store)

            // Deleting the page "rabbit" was first met on: the word keeps its row, first-seen context included
            try await store.deletePage(alicePages[0].id)
            #expect(try await store.pages(of: alice.id).map(\.id) == alicePages.dropFirst().map(\.id))
            #expect(try writes() == nothingWritten)
            #expect(log.all.isEmpty)
            #expect(try tables.map { try dump(root, $0) } == rows)
            #expect(try await store.wordEntries() == before)

            try await store.deleteBook(alice.id)
            #expect(try writes() == nothingWritten)
            #expect(log.all.isEmpty)
            #expect(try tables.map { try dump(root, $0) } == rows)
            #expect(try await store.wordEntries() == before)

            // The book's other data really is gone (foreign-key cascade + image directory); the other book is untouched
            #expect(try await store.bookSummaries().map(\.book).map(\.id) == [oz.id])
            #expect(try await store.pages(of: alice.id).isEmpty)
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM pageText").first?["n"].int == 1)
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Books/\(alice.id.uuidString)").path(percentEncoded: false)))
            #expect(try await store.pages(of: oz.id).count == 1)

            // Still the same after a relaunch
            #expect(try await BookStore(root: root).wordEntries() == before)

            // Check the audit itself: a real word write must count one word row and one upload mark, and reach the log (otherwise the
            // zeros above prove nothing)
            try await store.upsertWord(WordEntry(lemma: "hedge", state: .learning, source: .lookup, band: 9))
            var expected = nothingWritten
            expected["wordEntry"] = 1
            expected["syncRecord"] = 1
            #expect(try writes() == expected)
            #expect(log.all.count == 1)
        }
    }
}
