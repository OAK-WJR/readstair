import Foundation
import Testing
@testable import ReadStairCore

/// U-SYNC-007 (event routing in the store), 012–016, 018: what account and zone events do to local data. Sign-out forgets only what
/// the previous account holds; a deleted zone re-queues everything; deleted iCloud data resets the word list and level; late results
/// never resurrect anything; a failed step halts sync for the run.
@Suite("U-SYNC Account")
struct SyncAccountTests {
    @Test("U-SYNC-007 Event routing: each event runs exactly its rules; zone deleted re-queues everything without touching data; purged, encrypted-data reset and user-deleted zone empty the words and reset the level; never-delete events keep every word")
    func eventRouting() async throws {
        let expected: [SyncEvent: [SyncRule]] = [
            .signOut: [.forgetAccountData], .switchAccounts: [.forgetAccountData, .mergeAll], .firstEnable: [.forgetAccountData, .mergeAll],
            .signIn: [.mergeAll], .zoneDeleted: [.mergeAll],
            .zonePurged: [.resetSyncedData], .encryptedDataReset: [.resetSyncedData], .userDeletedZone: [.resetSyncedData],
        ]
        #expect(Set(expected.keys) == Set(SyncEvent.allCases))
        for (event, rules) in expected {
            #expect(SyncRules.rules(for: event) == rules, "\(event)")
        }

        // Zone deleted (by this app on another device): clear every system field and queue every word and the chosen level
        try await withTemporaryRoot { root in
            let fixture = try await Fixture.make(root)
            let kept = ["wordEntry", "wordOrigin", "profile"] + bookTables
            let before = try dumps(root, kept)
            #expect(try await fixture.store.handle(.zoneDeleted) == SyncEffects(saveZone: true, saveRecords: ["Profile", "a", "b", "c", "d"]))
            #expect(try dumps(root, kept) == before)
            // d gets a row (it predates sync); the nameless word stays device-only
            #expect(try syncRows(root) == ["a": SyncRowSnapshot(nil, Fixture.a), "b": SyncRowSnapshot(nil, Fixture.b),
                                           "c": SyncRowSnapshot(nil, Fixture.c), "d": SyncRowSnapshot(nil, Fixture.d),
                                           "Profile": SyncRowSnapshot(nil, t0)])
        }

        for event in [SyncEvent.zonePurged, .encryptedDataReset, .userDeletedZone] {
            try await withTemporaryRoot { root in
                let fixture = try await Fixture.make(root)
                let books = try dumps(root, bookTables)
                #expect(try await fixture.store.handle(event) == SyncEffects(clearEngine: true), "\(event)")
                for table in wordTables {
                    #expect(try dump(root, table).isEmpty, "\(event): \(table)")
                }
                let profile = try #require(try await fixture.store.profile())
                #expect(profile.level == 3 && SyncRules.milliseconds(profile.updatedAt) == 0 && profile.glossLanguage == "de", "\(event)")
                #expect(try dumps(root, bookTables) == books, "\(event)")
            }
        }

        // Sign-in, zone deleted and "iCloud no longer has it" never delete a word
        let neverDelete: [(String, (BookStore) async throws -> SyncEffects)] = [
            ("signIn", { try await $0.handle(.signIn) }),
            ("zoneDeleted", { try await $0.handle(.zoneDeleted) }),
            ("missing", {
                try await $0.applySent([.missing(recordName: "a", zoneMissing: true), .missing(recordName: "b", zoneMissing: false)])
            }),
        ]
        for (name, step) in neverDelete {
            try await withTemporaryRoot { root in
                let fixture = try await Fixture.make(root)
                let words = try dump(root, "wordEntry")
                _ = try await step(fixture.store)
                #expect(try dump(root, "wordEntry") == words, "\(name)")
            }
        }
    }

    @Test("U-SYNC-012 Sign-out forgets only what the account holds: confirmed words go (provenance kept), unsent and never-synced words stay device-only, a confirmed level resets to the placeholder; books untouched; idempotent")
    func signOut() async throws {
        try await withTemporaryRoot { root in
            let fixture = try await Fixture.make(root)
            let store = fixture.store
            let before = try await store.wordEntries()
            let books = try dumps(root, bookTables)
            #expect(try await store.handle(.signOut) == .nothing)

            let after = try await store.wordEntries()
            #expect(after.map(\.lemma) == ["b", "c", "d", Fixture.nameless])
            #expect(after == before.filter { $0.lemma != "a" })
            #expect(try dump(root, "wordOrigin") == [[.text("a"), .uuid(fixture.book.id), .uuid(fixture.page.id), .text("Sa")],
                                                     [.text("old"), .uuid(Fixture.oldBook), .uuid(Fixture.oldPage), .text("So")]])
            // What stays loses its system fields: those belong to the previous account
            #expect(try syncRows(root) == ["b": SyncRowSnapshot(nil, Fixture.b), "c": SyncRowSnapshot(nil, Fixture.c)])
            let profile = try #require(try await store.profile())
            #expect(profile.level == 3 && SyncRules.milliseconds(profile.updatedAt) == 0 && profile.glossLanguage == "de")
            #expect(try dumps(root, bookTables) == books)
            #expect(FileManager.default.fileExists(atPath: store.imageURL(of: fixture.page).path(percentEncoded: false)))

            let once = try dumps(root, syncTables)
            #expect(try await store.handle(.signOut) == .nothing)
            #expect(try dumps(root, syncTables) == once)
        }

        // A level chosen after the last upload is not the account's yet: it stays, and is queued without the old system fields
        try await withTemporaryRoot { root in
            let fixture = try await Fixture.make(root)
            try await fixture.store.setLevel(9, at: dateAt(t0 + 100))
            #expect(try syncRows(root)["Profile"] == SyncRowSnapshot(Data([9]), t0 + 100))
            #expect(try await fixture.store.handle(.signOut) == .nothing)
            let profile = try #require(try await fixture.store.profile())
            #expect(profile.level == 9 && SyncRules.milliseconds(profile.updatedAt) == t0 + 100 && profile.glossLanguage == "de")
            #expect(try syncRows(root)["Profile"] == SyncRowSnapshot(nil, t0 + 100))
        }

        // No level row: sign-out does not create one
        try await withTemporaryRoot { root in
            let fixture = try await Fixture.make(root, level: false)
            #expect(try await fixture.store.handle(.signOut) == .nothing)
            #expect(try await fixture.store.profile() == nil)
        }
    }

    @Test("U-SYNC-013 Sign out, then sign in to the same account: every word comes back with this device's first book, page and sentence, even when iCloud holds another device's sentence; a word marked again while signed out keeps that context, and so does every later sign-out; the word list groups by book as before")
    func provenanceSurvivesSignOut() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let (book1, page1, book2, page2, book3, page3) = (UUID(), UUID(), UUID(), UUID(), UUID(), UUID())
            // rabbit and hedge were first met here; dormouse came from iCloud, so it has iCloud's sentence and no book or page here
            try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0),
                                                 firstBookID: book1, firstPageID: page1, firstSentence: "S1"))
            try await store.upsertWord(WordEntry(lemma: "hedge", state: .known, source: .card, band: 9, updatedAt: dateAt(t0 + 1),
                                                 firstBookID: book2, firstPageID: page2, firstSentence: "S2"))
            let dormouse = remoteWord("dormouse", .learning, at: t0 + 2, sentence: "S3")
            _ = try await store.applyFetched([.saved(dormouse)])

            // What iCloud holds, by record name: what this device sent, and what other devices sent
            var icloud = ["dormouse": dormouse]
            func send(_ names: [String]) async throws {
                for name in names {
                    let record = try #require(try await store.outgoingRecord(named: name))
                    icloud[name] = record
                    try await confirm(store, name, at: record.value.updatedAt)
                }
            }
            try await send(["hedge", "rabbit"])
            // Another device met rabbit in another sentence and changed it later; its resend left its own sentence in iCloud. This
            // device adopts the change and keeps its own sentence.
            let otherDevice = remoteWord("rabbit", .known, at: t0 + 10, sentence: "S-other")
            icloud["rabbit"] = otherDevice
            _ = try await store.applyFetched([.saved(otherDevice)])

            func byBook(_ entries: [WordEntry]) -> [UUID?: [String]] {
                Dictionary(grouping: entries, by: \.firstBookID).mapValues { $0.map(\.lemma).sorted() }
            }
            func firstSeen(_ entries: [WordEntry]) -> [String: [String?]] {
                Dictionary(uniqueKeysWithValues: entries.map {
                    ($0.lemma, [$0.firstBookID?.uuidString, $0.firstPageID?.uuidString, $0.firstSentence])
                })
            }
            func fetchAll() async throws -> SyncEffects {
                try await store.applyFetched(icloud.values.map {
                    RemoteChange.saved(SyncRecord(name: $0.name, systemFields: Data([5]), value: $0.value))
                })
            }
            /// Every word is confirmed: sign out, sign back in and fetch what iCloud holds. The word list must be exactly as before.
            func signOutAndBackIn() async throws {
                let before = try await store.wordEntries()
                #expect(try await store.handle(.signOut) == .nothing)
                #expect(try await store.wordEntries().isEmpty)
                #expect(try dump(root, "wordOrigin").count == before.count)
                #expect(try await store.handle(.signIn) == .nothing)
                #expect(try await fetchAll() == .nothing)
                let after = try await store.wordEntries()
                #expect(after == before)
                #expect(byBook(after) == byBook(before))
                #expect(try dump(root, "wordOrigin").isEmpty)
                #expect(try syncRows(root) == icloud.mapValues { _ in SyncRowSnapshot(Data([5]), nil) })
            }
            try await signOutAndBackIn()
            let kept = try await store.wordEntries()
            #expect(firstSeen(kept) == ["rabbit": [book1.uuidString, page1.uuidString, "S1"],
                                        "hedge": [book2.uuidString, page2.uuidString, "S2"], "dormouse": [nil, nil, "S3"]])

            // Signed out again, rabbit and dormouse are marked in another book before iCloud returns them: they get back the context
            // they had, as if they had never left, and only hedge's stays kept
            #expect(try await store.handle(.signOut) == .nothing)
            for (lemma, ms) in [("rabbit", t0 + 20), ("dormouse", t0 + 21)] {
                try await store.upsertWord(WordEntry(lemma: lemma, state: .learning, source: .lookup, band: 5, updatedAt: dateAt(ms),
                                                     firstBookID: book3, firstPageID: page3, firstSentence: "S4"))
            }
            #expect(firstSeen(try await store.wordEntries()) == firstSeen(kept).filter { $0.key != "hedge" })
            #expect(try dump(root, "wordOrigin").map { $0[0] } == [SQLValue.text("hedge")])

            // Signed in: iCloud's older copies lose to the new marks, which are sent. The next sign-out keeps the context the words
            // have now, not an older one.
            #expect(try await store.handle(.signIn) == SyncEffects(saveZone: true, saveRecords: ["dormouse", "rabbit"]))
            #expect(try await fetchAll() == SyncEffects(saveRecords: ["dormouse", "rabbit"]))
            try await send(["dormouse", "rabbit"])
            #expect(firstSeen(try await store.wordEntries()) == firstSeen(kept))
            try await signOutAndBackIn()
            #expect(firstSeen(try await store.wordEntries()) == firstSeen(kept))
        }
    }

    @Test("U-SYNC-014 iCloud data deleted: every word (pending ones too) and all provenance are gone and never sent, the level is the placeholder; idempotent and order-independent; the next write registers the zone again, across a relaunch")
    func resetSyncedData() async throws {
        try await withTemporaryRoot { root in
            let fixture = try await Fixture.make(root)
            let store = fixture.store
            let books = try dumps(root, bookTables)
            #expect(try await store.handle(.zonePurged) == SyncEffects(clearEngine: true))
            let once = try dumps(root, syncTables)
            #expect(try await store.handle(.zonePurged) == SyncEffects(clearEngine: true))
            #expect(try dumps(root, syncTables) == once)
            for table in wordTables {
                #expect(try dump(root, table).isEmpty, "\(table)")
            }
            let profile = try #require(try await store.profile())
            #expect(profile.level == 3 && SyncRules.milliseconds(profile.updatedAt) == 0 && profile.glossLanguage == "de")
            #expect(try dumps(root, bookTables) == books)
            #expect(try await store.outgoingRecord(named: "b") == nil)
            #expect(try await store.outgoingRecord(named: "c") == nil)
            #expect(try await store.pendingEffects() == .nothing)

            let log = EffectsLog()
            try await log.observe(store)
            try await store.upsertWord(WordEntry(lemma: "e", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0)))
            #expect(log.all.last == SyncEffects(saveZone: true, saveRecords: ["e"]))
            // What WordSync registers again right after clearing the engine, in case the write landed between the reset and the clear
            #expect(try await store.pendingEffects() == SyncEffects(saveZone: true, saveRecords: ["e"]))
            #expect(try await BookStore(root: root).pendingEffects() == SyncEffects(saveZone: true, saveRecords: ["e"]))
        }

        func afterResets(_ events: [SyncEvent]) async throws -> [[[SQLValue]]] {
            try await withTemporaryRoot { root in
                let fixture = try await Fixture.make(root)
                for event in events {
                    _ = try await fixture.store.handle(event)
                }
                return try dumps(root, syncTables)
            }
        }
        let userFirst = try await afterResets([.userDeletedZone, .zonePurged])
        let purgeFirst = try await afterResets([.zonePurged, .userDeletedZone])
        #expect(userFirst == purgeFirst)

        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0)))
            #expect(try await store.handle(.zonePurged) == SyncEffects(clearEngine: true))
            #expect(try await store.profile() == nil)
        }
    }

    @Test("U-SYNC-015 Send results arriving after iCloud data was deleted write nothing and queue nothing")
    func lateResultsAfterReset() async throws {
        try await withTemporaryRoot { root in
            let fixture = try await Fixture.make(root)
            let store = fixture.store
            _ = try await store.handle(.zonePurged)
            let writes = try await auditWrites(store, root, ["wordEntry", "syncRecord", "wordOrigin", "profile"])
            let late: [SendResult] = [
                .saved(recordName: "a", systemFields: Data([1]), updatedAt: Fixture.a),
                .saved(recordName: "b", systemFields: Data([1]), updatedAt: Fixture.b),
                .saved(recordName: "Profile", systemFields: Data([1]), updatedAt: t0),
                .missing(recordName: "b", zoneMissing: true), .missing(recordName: "a", zoneMissing: false),
                .missing(recordName: "Profile", zoneMissing: true),
                .conflict(remoteWord("b", at: t0 + 99)), .conflict(remoteProfile(level: 9, at: t0 + 99)),
            ]
            #expect(try await store.applySent(late) == .nothing)
            #expect(try writes() == ["wordEntry": 0, "syncRecord": 0, "wordOrigin": 0, "profile": 0])
            #expect(try await store.outgoingRecord(named: "a") == nil)
            #expect(try await store.outgoingRecord(named: "b") == nil)
            #expect(try await store.pendingEffects() == .nothing)
        }
    }

    @Test("U-SYNC-016 Sign-in merges: local words are queued, a newer iCloud value wins and keeps this device's first-seen context, iCloud-only words arrive; repeatable; first enable with leftover system fields forgets them first")
    func signInMerges() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = UUID()
            try await store.upsertWord(WordEntry(lemma: "a", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0)))
            try await store.upsertWord(WordEntry(lemma: "b", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0 + 1),
                                                 firstBookID: book, firstSentence: "Sb"))
            #expect(try await store.handle(.signIn) == SyncEffects(saveZone: true, saveRecords: ["a", "b"]))
            #expect(try syncRows(root) == ["a": SyncRowSnapshot(nil, t0), "b": SyncRowSnapshot(nil, t0 + 1)])

            // iCloud holds a newer b and a word c this device never had
            let fetched: [RemoteChange] = [.saved(remoteWord("b", .known, at: t0 + 6, systemFields: Data([3]))),
                                           .saved(remoteWord("c", at: t0, systemFields: Data([4])))]
            #expect(try await store.applyFetched(fetched) == .nothing)
            let words = try await store.wordEntries()
            #expect(words.map(\.lemma) == ["a", "b", "c"])
            #expect(words.first { $0.lemma == "b" } == WordEntry(lemma: "b", state: .known, source: .card, band: 5, updatedAt: dateAt(t0 + 6),
                                                                  firstBookID: book, firstSentence: "Sb"))
            #expect(try syncRows(root) == ["a": SyncRowSnapshot(nil, t0), "b": SyncRowSnapshot(Data([3]), nil),
                                           "c": SyncRowSnapshot(Data([4]), nil)])
            // Only a is left to upload, into the zone that now exists: then iCloud holds a, b and c too
            #expect(try await store.pendingEffects() == SyncEffects(saveZone: false, saveRecords: ["a"]))
        }

        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            for (lemma, ms) in [("a", t0), ("b", t0 + 1)] {
                try await store.upsertWord(WordEntry(lemma: lemma, state: .learning, source: .lookup, band: 5, updatedAt: dateAt(ms)))
            }
            let first = try await store.handle(.signIn)
            let rows = try syncRows(root)
            #expect(try await store.handle(.signIn) == first)
            #expect(try syncRows(root) == rows)
        }

        // First enable on a database that already has system fields (state lost, or an older build): forget them first, then merge
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = UUID()
            try await store.upsertWord(WordEntry(lemma: "x", state: .known, source: .card, band: 5, updatedAt: dateAt(t0), firstBookID: book))
            try await confirm(store, "x", at: t0)
            try await store.upsertWord(WordEntry(lemma: "y", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0 + 1)))
            try await confirm(store, "y", at: t0)
            #expect(try syncRows(root)["y"] == SyncRowSnapshot(Data([9]), t0 + 1))
            #expect(try await store.handle(.firstEnable) == SyncEffects(saveZone: true, saveRecords: ["y"]))
            #expect(try await store.wordEntries().map(\.lemma) == ["y"])
            #expect(try dump(root, "wordOrigin") == [[.text("x"), .uuid(book), .null, .null]])
            #expect(try syncRows(root) == ["y": SyncRowSnapshot(nil, t0 + 1)])
        }
    }

    @Test("U-SYNC-018 A failed sync step rolls back and halts sync for the run: no engine state saved, nothing applied or sent; local writes go on; the next launch resumes from the last saved state")
    func failureHaltsSync() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            try await store.upsertWord(WordEntry(lemma: "hedge", state: .known, source: .card, band: 9, updatedAt: dateAt(t0)))
            try await confirm(store, "hedge", at: t0)
            try await store.upsertWord(WordEntry(lemma: "fox", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0 + 1)))
            try await store.saveEngineState(Data("s1".utf8))
            #expect(try await store.outgoingRecord(named: "fox") != nil)
            let log = EffectsLog()
            try await log.observe(store)

            // The sign-out step fails half-way (say, the disk is full): it rolls back as a whole
            try await store.execute("CREATE TRIGGER failForget BEFORE DELETE ON wordEntry BEGIN SELECT RAISE(ABORT, 'injected'); END;")
            await #expect(throws: StoreError.self) { try await store.handle(.signOut) }
            #expect(try await store.wordEntries().map(\.lemma) == ["fox", "hedge"])
            #expect(try dump(root, "wordOrigin").isEmpty)
            let rows = try syncRows(root)
            #expect(rows == ["fox": SyncRowSnapshot(nil, t0 + 1), "hedge": SyncRowSnapshot(Data([9]), nil)])

            // Halted: the saved state stays the one that matches the data, and no sync step touches anything
            try await store.saveEngineState(Data("s2".utf8))
            #expect(try await store.loadEngineState() == Data("s1".utf8))
            #expect(try await store.applyFetched([.saved(remoteWord("newword", at: t0))]) == .nothing)
            #expect(try await store.wordEntries().map(\.lemma) == ["fox", "hedge"])
            #expect(try await store.applySent([.saved(recordName: "fox", systemFields: Data([1]), updatedAt: t0 + 1)]) == .nothing)
            #expect(try syncRows(root) == rows)
            #expect(try await store.handle(.signIn) == .nothing)
            #expect(try syncRows(root) == rows)
            #expect(try await store.outgoingRecord(named: "fox") == nil)
            #expect(try await store.pendingEffects() == .nothing)

            // Words can still be marked; they are marked for upload and go out after the next launch
            try await store.upsertWord(WordEntry(lemma: "owl", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0 + 2)))
            #expect(log.all.last?.saveRecords == ["owl"])
            #expect(try syncRows(root)["owl"] == SyncRowSnapshot(nil, t0 + 2))

            // Next launch: the engine resumes from the last saved state and delivers the event again, which now succeeds
            try await store.execute("DROP TRIGGER failForget")
            let relaunched = try BookStore(root: root)
            #expect(try await relaunched.loadEngineState() == Data("s1".utf8))
            #expect(try await relaunched.outgoingRecord(named: "fox") != nil)
            #expect(try await relaunched.handle(.signOut) == .nothing)
            #expect(try await relaunched.wordEntries().map(\.lemma) == ["fox", "owl"])
            #expect(try dump(root, "wordOrigin").map { $0[0] } == [SQLValue.text("hedge")])
        }
    }
}

// MARK: - Fixture

private let bookTables = ["book", "page", "pageText", "chapter"]
private let wordTables = ["wordEntry", "syncRecord", "wordOrigin"]
private let syncTables = ["wordEntry", "syncRecord", "wordOrigin", "profile", "syncState"]

private func dumps(_ root: URL, _ tables: [String]) throws -> [[[SQLValue]]] {
    try tables.map { try dump(root, $0) }
}

/// One store holding every kind of row the account rules tell apart.
private struct Fixture {
    let store: BookStore
    let book: Book
    let page: Page

    // Local times of the words, in ms
    static let a = t0, b = t0 + 1, c = t0 + 2, d = t0 + 3, z = t0 + 4
    /// A word whose record name would be too long: it never syncs.
    static let nameless = String(repeating: "z", count: 300)
    /// Provenance left by an earlier sign-out.
    static let oldBook = UUID(), oldPage = UUID()

    /// - a: confirmed (iCloud has its latest value); first met in `book` on `page`, sentence "Sa"
    /// - b: iCloud has an older copy (system fields set, still pending)
    /// - c: pending, never uploaded
    /// - d: written before sync existed (no syncRecord row)
    /// - `nameless`: device-only
    /// - level 7 chosen at t0 and confirmed (unless `level` is false), gloss language "de"
    /// - wordOrigin ("old", oldBook, oldPage, "So"); a book with one recognized page, which starts its chapter "I"
    static func make(_ root: URL, level: Bool = true) async throws -> Fixture {
        let store = try BookStore(root: root)
        let book = try await makeBook(store, pages: 1)
        try await Importer(store: store, recognizer: { fakeText(pageNumber(of: $0)) }).drain()
        try await store.execute("INSERT INTO chapter VALUES ('\(book.id.uuidString)', 0, 'I')")
        let page = try #require(try await store.pages(of: book.id).first)
        func word(_ lemma: String, at ms: Int64) -> WordEntry {
            WordEntry(lemma: lemma, state: .learning, source: .lookup, band: 5, updatedAt: dateAt(ms))
        }
        try await store.upsertWord(WordEntry(lemma: "a", state: .known, source: .card, band: 5, updatedAt: dateAt(a),
                                             firstBookID: book.id, firstPageID: page.id, firstSentence: "Sa"))
        try await confirm(store, "a", at: a)
        try await store.upsertWord(word("b", at: b))
        try await confirm(store, "b", at: b - 1)
        try await store.upsertWord(word("c", at: c))
        try await store.upsertWord(word("d", at: d))
        try await store.execute("DELETE FROM syncRecord WHERE recordName = 'd'")
        try await store.upsertWord(word(nameless, at: z))
        var rows = ["a": SyncRowSnapshot(Data([9]), nil), "b": SyncRowSnapshot(Data([9]), b), "c": SyncRowSnapshot(nil, c)]
        if level {
            try await store.setLevel(7, at: dateAt(t0))
            try await confirm(store, "Profile", at: t0)
            try await store.execute("UPDATE profile SET glossLanguage = 'de'")
            rows["Profile"] = SyncRowSnapshot(Data([9]), nil)
        }
        try await store.execute("INSERT INTO wordOrigin VALUES ('old', '\(oldBook.uuidString)', '\(oldPage.uuidString)', 'So')")
        #expect(try syncRows(root) == rows, "fixture")
        #expect(try await store.wordEntries().count == 5, "fixture")
        return Fixture(store: store, book: book, page: page)
    }
}
