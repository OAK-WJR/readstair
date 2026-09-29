import Foundation
import Testing
@testable import ReadStairCore

/// U-DB-001…004: schema migration, concurrent writes, one row per lemma, migrating a store with data.
@Suite("U-DB Store")
struct StoreDatabaseTests {
    @Test("U-DB-001 Empty database → latest schema (v3): all three migrations succeed, user_version = 3, exactly the expected tables and columns; reopening does not migrate again; a newer database is refused")
    func migration() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let latest = BookStore.migrations.count
            #expect(latest == 3)
            #expect(try inspect(root, "PRAGMA user_version").first?["user_version"].int == 3)

            let expected: [String: [String]] = [
                "book": ["id", "title", "createdAt", "lastPageIndex"],
                "page": ["id", "bookID", "index", "width", "height", "status", "attempts", "error"],
                "pageText": ["pageID", "schemaVersion", "json"],
                "wordEntry": ["lemma", "state", "source", "band", "updatedAt", "firstBookID", "firstPageID", "firstSentence"],
                "profile": ["id", "level", "glossLanguage", "updatedAt"],
                "syncState": ["id", "engineState"],
                "syncRecord": ["recordName", "systemFields", "pendingAt"],
                "wordOrigin": ["lemma", "firstBookID", "firstPageID", "firstSentence"],
                "chapter": ["bookID", "pageIndex", "title"],
            ]
            let tables = try inspect(root, "SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0["name"].string }
            #expect(Set(tables) == Set(expected.keys))
            for (table, columns) in expected {
                #expect(try inspect(root, "PRAGMA table_info(\(table))").compactMap { $0["name"].string } == columns)
            }

            // Reopen: the migration does not run again (a second CREATE TABLE would fail) and the data is still there
            let book = try await store.createBook(title: "Alice")
            let reopened = try BookStore(root: root)
            #expect(try await reopened.bookSummaries().map(\.book).map(\.id) == [book.id])
            #expect(try inspect(root, "PRAGMA user_version").first?["user_version"].int == latest)

            // A database written by a newer app (higher version): refused, data untouched
            _ = try inspect(root, "PRAGMA user_version = \(latest + 1)")
            #expect(throws: StoreError.incompatibleSchema(found: latest + 1, supported: latest)) { try BookStore(root: root) }
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM book").first?["n"].int == 1)
        }
    }

    @Test("U-DB-002 100 concurrent wordEntry upserts all succeed: one row per word")
    func concurrentUpserts() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            // 100 distinct words + 100 writes onto 10 words (the same word written by several tasks at once)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<100 {
                    group.addTask { try await store.upsertWord(WordEntry(lemma: "word\(i)", state: .learning, source: .lookup, band: 5)) }
                    group.addTask { try await store.upsertWord(WordEntry(lemma: "hot\(i % 10)", state: i.isMultiple(of: 2) ? .known : .learning,
                                                                         source: .card, band: 7)) }
                }
                try await group.waitForAll()
            }
            let entries = try await store.wordEntries()
            #expect(entries.count == 110)
            #expect(entries.filter { $0.lemma.hasPrefix("hot") }.count == 10)
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM wordEntry").first?["n"].int == 110)
        }
    }

    @Test("U-DB-003 Same lemma written 3 times: one row with the last state and updatedAt; first-seen context kept; case folded; Unicode NFC folded")
    func upsertKeepsOneRow() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = UUID(), page = UUID()
            let t = Date(timeIntervalSince1970: 1_800_000_000)
            try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5, updatedAt: t,
                                                 firstBookID: book, firstPageID: page, firstSentence: "A White Rabbit ran by."))
            try await store.upsertWord(WordEntry(lemma: "Rabbit", state: .known, source: .card, band: 5, updatedAt: t + 60,
                                                 firstBookID: UUID(), firstSentence: "another"))
            try await store.upsertWord(WordEntry(lemma: "RABBIT", state: .learning, source: .card, band: 6, updatedAt: t + 120))
            let entries = try await store.wordEntries()
            #expect(entries == [WordEntry(lemma: "rabbit", state: .learning, source: .card, band: 6, updatedAt: t + 120,
                                          firstBookID: book, firstPageID: page, firstSentence: "A White Rabbit ran by.")])

            // A decomposed spelling (e + combining acute) and the precomposed one are one word, stored under the NFC key. Swift's ==
            // treats both spellings as equal, so the key is compared byte by byte.
            try await store.upsertWord(WordEntry(lemma: "Cafe\u{301}", state: .learning, source: .lookup, band: 8))
            try await store.upsertWord(WordEntry(lemma: "caf\u{E9}", state: .known, source: .card, band: 8))
            let others = try await store.wordEntries().filter { $0.lemma != "rabbit" }
            #expect(others.map { Array($0.lemma.utf8) } == [Array("caf\u{E9}".utf8)])
            #expect(others.map(\.state) == [.known])
        }
    }

    @Test("U-DB-004 A v2 store with data (an electronic book, a photographed book, words, the level, sync rows) migrates to v3: every old table is identical, `chapter` is empty and takes rows; reopening does not migrate again")
    func migrationFromV2() async throws {
        try await withTemporaryRoot { root in
            let ebook = UUID(), photos = UUID(), typeset = UUID(), photo = UUID(), failed = UUID()
            try makeDatabase(root, version: 2) { v2 in
                try v2.execute("INSERT INTO book VALUES (?, 'Alice', 1800000000.0, 0), (?, 'Notes', 1800000001.0, 1)",
                               [.uuid(ebook), .uuid(photos)])
                try v2.execute("""
                    INSERT INTO page (id, bookID, "index", width, height, status, attempts, error) VALUES
                        (?, ?, 0, 1200, 1800, 'recognized', 0, NULL), (?, ?, 0, 1650, 2200, 'pending', 0, NULL),
                        (?, ?, 1, 1650, 2200, 'failed', 2, 'timeout')
                    """, [.uuid(typeset), .uuid(ebook), .uuid(photo), .uuid(photos), .uuid(failed), .uuid(photos)])
                try v2.execute("INSERT INTO pageText (pageID, schemaVersion, json) VALUES (?, ?, ?)",
                               [.uuid(typeset), .int(PageText.schemaVersion), .blob(try JSONEncoder().encode(fakeText(1)))])
                try v2.execute("""
                    INSERT INTO wordEntry (lemma, state, source, band, updatedAt, firstBookID, firstPageID, firstSentence)
                    VALUES ('rabbit', 'learning', 'lookup', 5, 1800000000.25, ?, ?, 'A White Rabbit.')
                    """, [.uuid(ebook), .uuid(typeset)])
                try v2.execute("INSERT INTO profile (id, level, glossLanguage, updatedAt) VALUES (1, 5, 'de', 1800000000.5)")
                try v2.execute("INSERT INTO syncState (id, engineState) VALUES (1, ?)", [.blob(Data([1, 2, 3]))])
                try v2.execute("INSERT INTO syncRecord VALUES ('rabbit', ?, NULL), ('Profile', NULL, 1800000000.5)",
                               [.blob(Data([9]))])
                try v2.execute("INSERT INTO wordOrigin VALUES ('hedge', ?, NULL, 'In the hedge.')", [.uuid(photos)])
            }
            let tables = ["book", "page", "pageText", "wordEntry", "profile", "syncState", "syncRecord", "wordOrigin"]
            let before = try tables.map { try dump(root, $0) }
            #expect(before.allSatisfy { !$0.isEmpty })

            let store = try BookStore(root: root)
            #expect(try inspect(root, "PRAGMA user_version").first?["user_version"].int == 3)
            #expect(try tables.map { try dump(root, $0) } == before)
            #expect(try dump(root, "chapter").isEmpty)

            // Reopening runs no migration (a second CREATE TABLE would throw) and changes nothing
            let reopened = try BookStore(root: root)
            #expect(try inspect(root, "PRAGMA user_version").first?["user_version"].int == 3)
            #expect(try tables.map { try dump(root, $0) } == before)

            // The old e-book has no chapters; a page added to it can bring one
            #expect(try await store.chapters(of: ebook).isEmpty)
            try await reopened.insertPage(id: UUID(), bookID: ebook, index: 1, width: 1200, height: 1800, chapter: "II")
            #expect(try await reopened.chapters(of: ebook) == [ChapterStart(pageIndex: 1, title: "II")])
        }
    }
}

/// Creates a database as an older app left it: the first `version` migrations only, user_version `version`, filled by `fill`. The
/// connection is closed before BookStore opens the file.
func makeDatabase(_ root: URL, version: Int, _ fill: (SQLiteConnection) throws -> Void) throws {
    let old = try SQLiteConnection(path: root.appending(path: "ReadStair.sqlite").path(percentEncoded: false))
    for script in BookStore.migrations.prefix(version) { try old.execute(script) }
    try old.execute("PRAGMA user_version = \(version)")
    try fill(old)
}
