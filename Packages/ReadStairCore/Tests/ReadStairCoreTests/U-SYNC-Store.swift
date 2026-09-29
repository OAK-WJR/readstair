import Foundation
import Testing
@testable import ReadStairCore

/// U-SYNC-004, 005, 006, 008 (store part), 010: the store's sync bookkeeping. A syncRecord row's pendingAt is the to-send list and its
/// system fields mean "iCloud has this record"; every check pins which of the two a step must change.
@Suite("U-SYNC Store")
struct SyncStoreTests {
    @Test("U-SYNC-004 Millisecond rounding and echo: a local write sent and fetched back is an echo; nothing is queued again; applying the same batch twice changes nothing")
    func roundingAndEcho() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let ms: Int64 = 1_800_000_000_124
            try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5,
                                                 updatedAt: Date(timeIntervalSince1970: 1_800_000_000.1236)))
            #expect(try inspect(root, "SELECT updatedAt FROM wordEntry").first?["updatedAt"] == SQLValue.real(1_800_000_000.124))
            #expect(try await store.wordEntries().map { SyncRules.milliseconds($0.updatedAt) } == [ms])

            let outgoing = try #require(try await store.outgoingRecord(named: "rabbit"))
            #expect(outgoing.value == .word(SyncedWord(lemma: "rabbit", state: .learning, source: .lookup, band: 5, updatedAt: ms,
                                                       firstSentence: nil)))
            #expect(outgoing.systemFields == nil)

            #expect(try await store.applySent([.saved(recordName: "rabbit", systemFields: Data([7]), updatedAt: ms)]) == .nothing)
            #expect(try syncRows(root) == ["rabbit": SyncRowSnapshot(Data([7]), nil)])
            #expect(try await store.outgoingRecord(named: "rabbit") == nil)

            // Another fetch brings the same value back: only the newer system fields are stored
            let entries = try await store.wordEntries()
            let echo: [RemoteChange] = [.saved(SyncRecord(name: "rabbit", systemFields: Data([8]), value: outgoing.value))]
            #expect(try await store.applyFetched(echo) == .nothing)
            #expect(try syncRows(root) == ["rabbit": SyncRowSnapshot(Data([8]), nil)])
            #expect(try await store.wordEntries() == entries)

            let (words, records) = (try dump(root, "wordEntry"), try dump(root, "syncRecord"))
            #expect(try await store.applyFetched(echo) == .nothing)
            #expect(try dump(root, "wordEntry") == words)
            #expect(try dump(root, "syncRecord") == records)
        }
    }

    @Test("U-SYNC-005 A word or level write and its upload mark are one transaction; applying iCloud data queues nothing and never overwrites this device's first book, page and sentence")
    func oneTransaction() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            try await store.upsertWord(WordEntry(lemma: "hedge", state: .learning, source: .lookup, band: 9, updatedAt: dateAt(t0)))
            #expect(try syncRows(root) == ["hedge": SyncRowSnapshot(nil, t0)])
            let log = EffectsLog()
            try await log.observe(store)

            // Any write to syncRecord fails: the word or level write must roll back with it
            try await store.execute("""
                CREATE TRIGGER failSyncInsert BEFORE INSERT ON syncRecord BEGIN SELECT RAISE(ABORT, 'injected'); END;
                CREATE TRIGGER failSyncUpdate BEFORE UPDATE ON syncRecord BEGIN SELECT RAISE(ABORT, 'injected'); END;
                """)
            await #expect(throws: StoreError.self) {
                try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0)))
            }
            await #expect(throws: StoreError.self) {
                try await store.upsertWord(WordEntry(lemma: "hedge", state: .known, source: .card, band: 9, updatedAt: dateAt(t0 + 10)))
            }
            await #expect(throws: StoreError.self) { try await store.setLevel(7, at: dateAt(t0)) }
            let words = try await store.wordEntries()
            #expect(words.map(\.lemma) == ["hedge"])
            #expect(words.map(\.state) == [.learning] && words.map { SyncRules.milliseconds($0.updatedAt) } == [t0])
            #expect(try syncRows(root) == ["hedge": SyncRowSnapshot(nil, t0)])
            #expect(try await store.profile() == nil)
            #expect(log.all.isEmpty)

            // The failures were local writes, not sync steps: once the disk accepts writes again, they work
            try await store.execute("DROP TRIGGER failSyncInsert; DROP TRIGGER failSyncUpdate;")
            try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0)))
            try await store.upsertWord(WordEntry(lemma: "hedge", state: .known, source: .card, band: 9, updatedAt: dateAt(t0 + 10)))
            try await store.setLevel(7, at: dateAt(t0))
            #expect(try await store.wordEntries().map(\.state) == [.known, .learning])
            #expect(try syncRows(root) == ["hedge": SyncRowSnapshot(nil, t0 + 10), "rabbit": SyncRowSnapshot(nil, t0),
                                           "Profile": SyncRowSnapshot(nil, t0)])
            #expect(log.all.count == 3)
        }

        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = UUID(), page = UUID()
            try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0),
                                                 firstBookID: book, firstPageID: page, firstSentence: "S1"))
            let log = EffectsLog()
            try await log.observe(store)

            // A newer value from iCloud replaces state, source, band and time; the first-seen context stays this device's
            #expect(try await store.applyFetched([.saved(remoteWord("rabbit", .known, at: t0 + 10, sentence: "S2"))]) == .nothing)
            #expect(try await store.wordEntries() == [WordEntry(lemma: "rabbit", state: .known, source: .card, band: 5,
                                                                updatedAt: dateAt(t0 + 10), firstBookID: book, firstPageID: page,
                                                                firstSentence: "S1")])
            #expect(try syncRows(root)["rabbit"] == SyncRowSnapshot(Data([1]), nil))

            // A word this device never had: only the sentence comes from iCloud (books and pages are per device)
            #expect(try await store.applyFetched([.saved(remoteWord("hare", .learning, at: t0, sentence: "S3"))]) == .nothing)
            let hare = try #require(try await store.wordEntries().first { $0.lemma == "hare" })
            #expect(hare == WordEntry(lemma: "hare", state: .learning, source: .card, band: 5, updatedAt: dateAt(t0), firstSentence: "S3"))
            #expect(try syncRows(root)["hare"] == SyncRowSnapshot(Data([1]), nil))

            // A word forgotten at sign-out gets this device's book, page and sentence back from wordOrigin, which is then emptied
            // (iCloud's sentence may be another device's, not on this page)
            try await store.execute("INSERT INTO wordOrigin VALUES ('dormouse', '\(book.uuidString)', '\(page.uuidString)', 'S0')")
            #expect(try await store.applyFetched([.saved(remoteWord("dormouse", at: t0, sentence: "S4"))]) == .nothing)
            let dormouse = try #require(try await store.wordEntries().first { $0.lemma == "dormouse" })
            #expect(dormouse.firstBookID == book && dormouse.firstPageID == page && dormouse.firstSentence == "S0")
            #expect(try dump(root, "wordOrigin").isEmpty)
            #expect(try syncRows(root)["dormouse"] == SyncRowSnapshot(Data([1]), nil))
            #expect(log.all.isEmpty)
            #expect(try await store.pendingEffects() == .nothing)
        }
    }

    @Test("U-SYNC-006 Send results: saved clears; changed in flight requeues; a conflict adopts a newer server value, or keeps a newer local one with the server's fields; a missing record or zone resends only that record; none creates a row")
    func sendResults() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            func rabbit() throws -> SyncRowSnapshot? { try syncRows(root)["rabbit"] }
            func upsert(_ lemma: String, _ state: WordState = .learning, at ms: Int64) async throws {
                try await store.upsertWord(WordEntry(lemma: lemma, state: state, source: .lookup, band: 5, updatedAt: dateAt(ms)))
            }
            try await upsert("rabbit", at: t0)

            #expect(try await store.applySent([.saved(recordName: "rabbit", systemFields: Data([7]), updatedAt: t0)]) == .nothing)
            #expect(try rabbit() == SyncRowSnapshot(Data([7]), nil))

            // Changed while the t0 copy was in flight: the newer value still has to go
            try await upsert("rabbit", at: t0 + 10)
            #expect(try await store.applySent([.saved(recordName: "rabbit", systemFields: Data([8]), updatedAt: t0)])
                    == SyncEffects(saveRecords: ["rabbit"]))
            #expect(try rabbit() == SyncRowSnapshot(Data([8]), t0 + 10))
            // Saved without a readable time: keep it pending for the next launch, but do not requeue (no resend loop)
            #expect(try await store.applySent([.saved(recordName: "rabbit", systemFields: Data([9]), updatedAt: nil)]) == .nothing)
            #expect(try rabbit() == SyncRowSnapshot(Data([9]), t0 + 10))

            // Conflict, server newer: adopt its value and system fields; nothing left to send
            let newer = remoteWord("rabbit", .known, band: 6, at: t0 + 20, systemFields: Data([10]))
            #expect(try await store.applySent([.conflict(newer)]) == .nothing)
            let adopted = try #require(try await store.wordEntries().first)
            #expect(adopted.state == .known && adopted.band == 6 && SyncRules.milliseconds(adopted.updatedAt) == t0 + 20)
            #expect(try rabbit() == SyncRowSnapshot(Data([10]), nil))

            // Conflict, local newer: keep the value, store the server's system fields so the resend replaces its copy
            try await upsert("rabbit", at: t0 + 30)
            let local = try await store.wordEntries()
            #expect(try await store.applySent([.conflict(remoteWord("rabbit", .known, at: t0 + 25, systemFields: Data([11])))])
                    == SyncEffects(saveRecords: ["rabbit"]))
            #expect(try await store.wordEntries() == local)
            #expect(try rabbit() == SyncRowSnapshot(Data([11]), t0 + 30))

            // The zone is gone: resend this record into a recreated zone, and touch no other record
            try await upsert("hedge", at: t0)
            try await confirm(store, "hedge", at: t0)
            #expect(try syncRows(root)["hedge"] == SyncRowSnapshot(Data([9]), nil))
            #expect(try await store.applySent([.missing(recordName: "rabbit", zoneMissing: true)])
                    == SyncEffects(saveZone: true, saveRecords: ["rabbit"]))
            #expect(try rabbit() == SyncRowSnapshot(nil, t0 + 30))
            #expect(try syncRows(root)["hedge"] == SyncRowSnapshot(Data([9]), nil))
            // A confirmed record iCloud no longer has: queue it again at its current time
            #expect(try await store.applySent([.missing(recordName: "hedge", zoneMissing: false)]) == SyncEffects(saveRecords: ["hedge"]))
            #expect(try syncRows(root)["hedge"] == SyncRowSnapshot(nil, t0))

            try await store.setLevel(7, at: dateAt(t0))
            #expect(try await store.applySent([.saved(recordName: "Profile", systemFields: Data([12]), updatedAt: t0)]) == .nothing)
            #expect(try syncRows(root)["Profile"] == SyncRowSnapshot(Data([12]), nil))

            // Results for a record the store does not track change nothing
            let words = try dump(root, "wordEntry"), records = try dump(root, "syncRecord")
            let strays: [SendResult] = [.saved(recordName: "nothere", systemFields: Data([1]), updatedAt: t0),
                                        .missing(recordName: "nothere", zoneMissing: true), .conflict(remoteWord("nothere", at: t0))]
            for result in strays {
                #expect(try await store.applySent([result]) == .nothing, "\(result)")
            }
            #expect(try dump(root, "wordEntry") == words)
            #expect(try dump(root, "syncRecord") == records)
        }
    }

    @Test("U-SYNC-008 Remote deletions: an unsent change is kept and rebuilt, a confirmed word goes, the level falls back to the placeholder; unknown names and invalid values write nothing")
    func remoteDeletionsAndInvalidValues() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = UUID()
            try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .lookup, band: 5, updatedAt: dateAt(t0)))
            try await confirm(store, "rabbit", at: t0 - 1, systemFields: Data([1]))
            #expect(try syncRows(root)["rabbit"] == SyncRowSnapshot(Data([1]), t0))
            let rabbit = try await store.wordEntries()
            #expect(try await store.applyFetched([.deleted(recordName: "rabbit")]) == SyncEffects(saveRecords: ["rabbit"]))
            #expect(try await store.wordEntries() == rabbit)
            #expect(try syncRows(root)["rabbit"] == SyncRowSnapshot(nil, t0))

            // Deleted in iCloud and nothing unsent here: the word goes too, and is not kept as provenance (the account no longer has it)
            try await store.upsertWord(WordEntry(lemma: "hedge", state: .known, source: .card, band: 9, updatedAt: dateAt(t0),
                                                 firstBookID: book))
            try await confirm(store, "hedge", at: t0)
            #expect(try await store.applyFetched([.deleted(recordName: "hedge")]) == .nothing)
            #expect(try await store.wordEntries().map(\.lemma) == ["rabbit"])
            #expect(try syncRows(root)["hedge"] == nil)
            #expect(try dump(root, "wordOrigin").isEmpty)

            // The level record deleted: back to the placeholder, the row stays (the level test does not come back)
            try await store.setLevel(7, at: dateAt(t0))
            try await store.execute("UPDATE profile SET glossLanguage = 'de'")
            try await confirm(store, "Profile", at: t0)
            #expect(try await store.applyFetched([.deleted(recordName: "Profile")]) == .nothing)
            let profile = try #require(try await store.profile())
            #expect(profile.level == 3 && SyncRules.milliseconds(profile.updatedAt) == 0 && profile.glossLanguage == "de")
            #expect(try syncRows(root)["Profile"] == nil)

            // Values that would change something if accepted: each must be ignored without a single write
            try await store.setLevel(7, at: dateAt(t0))
            let writes = try await auditWrites(store, root, ["wordEntry", "syncRecord", "wordOrigin", "profile"])
            let hare = SyncedWord(lemma: "hare", state: .known, source: .card, band: 5, updatedAt: t0 + 100, firstSentence: nil)
            let profileWord = SyncedWord(lemma: "profile", state: .known, source: .card, band: 5, updatedAt: t0 + 100, firstSentence: nil)
            let invalid: [RemoteChange] = [
                .deleted(recordName: "nothere"), .deleted(recordName: "%zz"), .deleted(recordName: ""),
                .saved(SyncRecord(name: "rabbit", systemFields: Data([3]), value: .word(hare))),
                .saved(SyncRecord(name: "Profile", systemFields: Data([3]), value: .word(profileWord))),
                .saved(remoteProfile(level: 0, at: t0 + 100)), .saved(remoteProfile(level: 26, at: t0 + 100)),
                .saved(remoteProfile(level: 9, at: 0)), .saved(remoteProfile(level: 9, at: -5)),
                .saved(SyncRecord(name: "profile", systemFields: Data([3]), value: .profile(SyncedProfile(level: 9, updatedAt: t0 + 100)))),
                // Times this app never sends: 0, and Int64.max, which would read back from the REAL-seconds column as more than Int64
                // holds. Both the existing word and the level would otherwise take the newer one.
                .saved(remoteWord("rabbit", at: .max)), .saved(remoteWord("owl", at: .max)), .saved(remoteWord("owl", at: 0)),
                .saved(remoteProfile(level: 9, at: .max)),
            ]
            for change in invalid {
                #expect(try await store.applyFetched([change]) == .nothing, "\(change)")
            }
            #expect(try writes() == ["wordEntry": 0, "syncRecord": 0, "wordOrigin": 0, "profile": 0])
        }
    }

    @Test("U-SYNC-010 100 concurrent local writes interleaved with 100 fetched batches: all succeed, one row per word, pending marks match the data")
    func concurrency() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<100 {
                    group.addTask { try await store.upsertWord(WordEntry(lemma: "word\(i)", state: .learning, source: .lookup, band: 5)) }
                    group.addTask {
                        try await store.upsertWord(WordEntry(lemma: "hot\(i % 10)", state: i.isMultiple(of: 2) ? .known : .learning,
                                                             source: .card, band: 7))
                    }
                    group.addTask {
                        _ = try await store.applyFetched([.saved(remoteWord("hot\(i % 10)", at: t0 + Int64(i), systemFields: Data([UInt8(i)]))),
                                                          .saved(remoteWord("remote\(i)", at: t0 + Int64(i)))])
                    }
                }
                try await group.waitForAll()
            }
            func count(_ sql: String) throws -> Int? { try inspect(root, sql).first?["n"].int }
            #expect(try count("SELECT COUNT(*) AS n FROM wordEntry") == 210)
            // Every pending mark is the word's current time (the word lemmas here are their own record names)
            #expect(try count("""
                SELECT COUNT(*) AS n FROM syncRecord JOIN wordEntry ON lemma = recordName
                WHERE pendingAt IS NOT NULL AND ROUND(pendingAt * 1000) <> ROUND(updatedAt * 1000)
                """) == 0)
            #expect(try count("SELECT COUNT(*) AS n FROM syncRecord WHERE recordName NOT IN (SELECT lemma FROM wordEntry)") == 0)
            #expect(try count("SELECT COUNT(*) AS n FROM wordEntry WHERE lemma NOT IN (SELECT recordName FROM syncRecord)") == 0)
            let pending = Set(try syncRows(root).filter { $0.value.pendingAt != nil }.keys)
            #expect(try await store.pendingEffects().saveRecords == pending)
            #expect(pending.count >= 100)
        }
    }
}
