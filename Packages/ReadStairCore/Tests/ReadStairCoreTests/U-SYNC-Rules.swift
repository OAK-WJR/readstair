import Foundation
import Testing
@testable import ReadStairCore

/// U-SYNC-001, 002, 003, 009, 017: the record-name codec, the merge rule, clock skew, migration v2 and the placeholder level.
/// Word keys are compared as UTF-8 bytes wherever normalization matters: Swift's `==` treats NFC and NFD spellings as equal.
@Suite("U-SYNC Rules")
struct SyncRulesTests {
    @Test("U-SYNC-001 Record-name codec: NFC and NFD give one name; ASCII, at most 255, never a leading underscore, never Profile; reversible and canonical; 1000 random strings")
    func recordNameCodec() {
        let a255 = String(repeating: "a", count: 255)
        let e42 = String(repeating: "\u{E9}", count: 42)   // 84 UTF-8 bytes, 252 characters encoded: the longest that fits
        let cases: [(lemma: String, name: String)] = [
            ("rabbit", "rabbit"), ("Rabbit", "rabbit"), ("caf\u{E9}", "caf%C3%A9"), ("cafe\u{301}", "caf%C3%A9"), ("o'clock", "o%27clock"),
            ("_x", "%5Fx"), ("%", "%25"), ("a b", "a%20b"), ("well-known", "well-known"), ("e.g.", "e.g."), (a255, a255),
            (e42, String(repeating: "%C3%A9", count: 42)), ("profile", "profile"),
        ]
        for (lemma, name) in cases {
            #expect(SyncRules.recordName(forLemma: lemma) == name, "\(lemma.unicodeScalars.map(\.value))")
            #expect(SyncRules.lemma(fromRecordName: name).map { Array($0.utf8) } == Array(SyncRules.lemmaKey(lemma).utf8), "\(name)")
        }
        // Empty, and longer than CloudKit's 255 (43 x U+00E9 is 86 bytes, 258 characters encoded): nil, so the word stays on this device
        for lemma in ["", String(repeating: "a", count: 256), String(repeating: "a", count: 300), String(repeating: "\u{E9}", count: 43)] {
            #expect(SyncRules.recordName(forLemma: lemma) == nil, "length \(lemma.utf8.count)")
        }
        // The level record's name is fixed on the wire, and no word maps to it
        #expect(SyncRules.profileRecordName == "Profile")
        #expect(SyncRules.recordName(forLemma: "Profile") != "Profile")
        // Only names the encoder produces decode: no uppercase outside an escape, no lowercase hex, no truncated escape, no underscore
        for name in ["Profile", "%41", "caf%c3%a9", "caf%C3", "%zz", "%", "", "a_b", "A"] {
            #expect(SyncRules.lemma(fromRecordName: name) == nil, "\(name)")
        }
        #expect(Array(SyncRules.lemmaKey("CAFE\u{301}").utf8) == Array("caf\u{E9}".utf8))

        var generator = SplitMix64(seed: 42)
        let alphabet = ["a", "b", "c", "X", "Y", "Z", "0", "1", "9", "_", "%", "'", "-", ".", " ", "\u{E9}", "e\u{301}", "\u{DF}", "\u{130}",
                        "\u{4E2D}", "\u{1F600}", "\u{2019}", "\u{3A3}"]
        var keyByName: [String: [UInt8]] = [:]
        var named = 0
        for _ in 0..<1000 {
            let length = Int.random(in: 1...60, using: &generator)
            let lemma = (0..<length).map { _ in alphabet.randomElement(using: &generator)! }.joined()
            guard let name = SyncRules.recordName(forLemma: lemma) else { continue }
            named += 1
            let key = Array(SyncRules.lemmaKey(lemma).utf8)
            #expect(name.utf8.allSatisfy { $0 < 0x80 } && name.utf8.count <= 255 && !name.hasPrefix("_") && name != "Profile", "\(name)")
            #expect(SyncRules.lemma(fromRecordName: name).map { Array($0.utf8) } == key, "\(name)")
            if let other = keyByName.updateValue(key, forKey: name) {
                #expect(other == key, "two different keys share the name \(name)")
            }
        }
        #expect(named >= 900)
    }

    @Test("U-SYNC-002 Merge: later updatedAt wins; same time and content is an echo (the sentence is not content); same time, different content: the larger content wins on both devices; 500 random pairs agree")
    func mergeTruthTable() {
        func word(_ state: WordState, _ source: WordEntry.Source = .card, band: Int? = 5, at updatedAt: Int64,
                  sentence: String? = nil) -> SyncedValue {
            .word(SyncedWord(lemma: "x", state: state, source: source, band: band, updatedAt: updatedAt, firstSentence: sentence))
        }
        func level(_ level: Int, at updatedAt: Int64) -> SyncedValue { .profile(SyncedProfile(level: level, updatedAt: updatedAt)) }

        // Time decides before content: the newer side wins even with the "smaller" content
        #expect(SyncRules.resolve(local: word(.known, at: 10), remote: word(.learning, at: 11)) == .adoptRemote)
        #expect(SyncRules.resolve(local: word(.learning, at: 10), remote: word(.known, at: 9)) == .keepLocal)
        #expect(SyncRules.resolve(local: word(.known, at: 10, sentence: "A."), remote: word(.known, at: 10, sentence: "B.")) == .echo)
        // "learning|card|5" > "known|card|5"
        #expect(SyncRules.resolve(local: word(.known, at: 10), remote: word(.learning, at: 10)) == .adoptRemote)
        #expect(SyncRules.resolve(local: word(.learning, at: 10), remote: word(.known, at: 10)) == .keepLocal)
        #expect(SyncRules.resolve(local: word(.known, band: nil, at: 10), remote: word(.known, band: 5, at: 10)) == .adoptRemote)
        #expect(SyncRules.resolve(local: word(.known, band: 5, at: 10), remote: word(.known, band: nil, at: 10)) == .keepLocal)
        // Any chosen level beats the placeholder; on a tie the larger string wins ("7" > "12") from both sides
        #expect(SyncRules.resolve(local: level(3, at: 0), remote: level(7, at: 1)) == .adoptRemote)
        #expect(SyncRules.resolve(local: level(12, at: 5), remote: level(7, at: 5)) == .adoptRemote)
        #expect(SyncRules.resolve(local: level(7, at: 5), remote: level(12, at: 5)) == .keepLocal)

        // Both devices must end with the same value whichever of them receives the other's record
        func stored(local: SyncedValue, remote: SyncedValue) -> SyncedValue {
            SyncRules.resolve(local: local, remote: remote) == .adoptRemote ? remote : local
        }
        var generator = SplitMix64(seed: 2)
        for _ in 0..<500 {
            func random() -> SyncedValue {
                word([.learning, .known].randomElement(using: &generator)!, [.lookup, .card].randomElement(using: &generator)!,
                     band: [nil, 1, 2].randomElement(using: &generator)!, at: t0 + Int64.random(in: 0...3, using: &generator),
                     sentence: [nil, "S."].randomElement(using: &generator)!)
            }
            let (a, b) = (random(), random())
            let (ab, ba) = (stored(local: a, remote: b), stored(local: b, remote: a))
            #expect(ab.content == ba.content && ab.updatedAt == ba.updatedAt, "\(a) vs \(b)")
            let mirrored: [SyncRules.Resolution: SyncRules.Resolution] = [.adoptRemote: .keepLocal, .keepLocal: .adoptRemote, .echo: .echo]
            #expect(mirrored[SyncRules.resolve(local: a, remote: b)] == SyncRules.resolve(local: b, remote: a), "\(a) vs \(b)")
        }

        // A local change is always strictly after the value it replaces, and never 0 (the placeholder's time)
        #expect(SyncRules.nextTimestamp(5, after: nil) == 5)
        #expect(SyncRules.nextTimestamp(5, after: 10) == 11)
        #expect(SyncRules.nextTimestamp(20, after: 10) == 20)
        #expect(SyncRules.nextTimestamp(-3, after: nil) == 1)
        #expect(SyncRules.nextTimestamp(0, after: 0) == 1)

        // Whole milliseconds, rounded, survive the local REAL-seconds column exactly; finer values from older rows round the same way
        #expect(SyncRules.milliseconds(Date(timeIntervalSince1970: 1_800_000_000.1236)) == 1_800_000_000_124)
        #expect(SQLValue.real(1_800_000_000.1236).milliseconds == 1_800_000_000_124)
        for _ in 0..<1000 {
            let ms = Int64.random(in: t0..<(t0 + 1_000_000_000), using: &generator)
            #expect(SyncRules.milliseconds(dateAt(ms)) == ms)
            #expect(SQLValue.milliseconds(ms).milliseconds == ms)
        }
        // Exact across the whole range a record may carry; a value that does not fit in Int64 reads as nil instead of trapping
        let valid = SyncRules.validTimestamps
        for ms in [valid.upperBound] + (0..<1000).map({ _ in Int64.random(in: valid, using: &generator) }) {
            #expect(SQLValue.milliseconds(ms).milliseconds == ms)
        }
        #expect(SQLValue.milliseconds(.max).milliseconds == nil)
        #expect(SQLValue.integer(.max).milliseconds == nil)
        #expect(SQLValue.real(.nan).milliseconds == nil)
        // rules(for:) is checked in U-SYNC-007
    }

    @Test("U-SYNC-003 A device clock a day fast: a later local change still gets a strictly later time (+1 ms), wins, and is queued once")
    func clockFastByADay() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let day: Int64 = 86_400_000
            let remote = remoteWord("rabbit", .known, at: t0 + day)
            #expect(try await store.applyFetched([.saved(remote)]) == .nothing)
            let log = EffectsLog()
            #expect(try await log.observe(store) == .nothing)

            try await store.upsertWord(WordEntry(lemma: "rabbit", state: .learning, source: .card, band: 5, updatedAt: dateAt(t0)))
            let entry = try #require(try await store.wordEntries().first)
            #expect(SyncRules.milliseconds(entry.updatedAt) == t0 + day + 1)
            #expect(entry.state == .learning)
            // The system fields from iCloud are kept, so the upload replaces the record instead of conflicting with it
            #expect(try syncRows(root)["rabbit"] == SyncRowSnapshot(Data([1]), t0 + day + 1))
            #expect(log.all == [SyncEffects(saveZone: false, saveRecords: ["rabbit"])])
            // It wins here and on the fast device when that one receives it
            let outgoing = try #require(try await store.outgoingRecord(named: "rabbit"))
            #expect(SyncRules.resolve(local: outgoing.value, remote: remote.value) == .keepLocal)
            #expect(SyncRules.resolve(local: remote.value, remote: outgoing.value) == .adoptRemote)

            // The level follows the same rule
            #expect(try await store.applyFetched([.saved(remoteProfile(level: 9, at: t0 + day))]) == .nothing)
            try await store.setLevel(4, at: dateAt(t0))
            let profile = try #require(try await store.profile())
            #expect(profile.level == 4)
            #expect(SyncRules.milliseconds(profile.updatedAt) == t0 + day + 1)
            #expect(try syncRows(root)["Profile"] == SyncRowSnapshot(Data([2]), t0 + day + 1))
            #expect(log.all.last == SyncEffects(saveZone: false, saveRecords: ["Profile"]))
            #expect(log.all.count == 2)
        }
    }

    @Test("U-SYNC-009 Migration v1 → v2 with data: rows kept, existing level gets 1 ms, new tables empty; engine state and pending words survive a relaunch; a pre-sync level uploads on first enable")
    func migrationFromV1() async throws {
        try await withTemporaryRoot { root in
            let bookID = UUID()
            try makeDatabase(root, version: 1) { v1 in
                try v1.execute("INSERT INTO book (id, title, createdAt, lastPageIndex) VALUES (?, 'Alice', 1800000000.0, 0)", [.uuid(bookID)])
                try v1.execute("""
                    INSERT INTO wordEntry (lemma, state, source, band, updatedAt, firstBookID, firstPageID, firstSentence)
                    VALUES ('rabbit', 'learning', 'lookup', 5, 1800000000.25, ?, NULL, 'A White Rabbit.')
                    """, [.uuid(bookID)])
                try v1.execute("INSERT INTO profile (id, level, glossLanguage) VALUES (1, 5, 'de')")
            }
            let words = try dump(root, "wordEntry")
            let books = try dump(root, "book")
            #expect(words.count == 1 && books.count == 1)

            let store = try BookStore(root: root)
            #expect(try inspect(root, "PRAGMA user_version").first?["user_version"].int == BookStore.migrations.count)
            #expect(try dump(root, "wordEntry") == words)
            #expect(try dump(root, "book") == books)
            // Compared in SQL, so the literal is parsed the same way on both sides
            let level = try #require(try inspect(root, "SELECT typeof(updatedAt) AS type, updatedAt = 0.001 AS same FROM profile").first)
            #expect(level["type"].string == "real" && level["same"].int == 1)
            let profile = try #require(try await store.profile())
            #expect(profile.level == 5 && profile.glossLanguage == "de" && SyncRules.milliseconds(profile.updatedAt) == 1)
            for table in ["syncState", "syncRecord", "wordOrigin"] {
                #expect(try dump(root, table).isEmpty, "\(table)")
            }

            // What the next launch starts from: the saved engine state and the pending list, both read back from disk
            try await store.saveEngineState(Data([1, 2, 3]))
            try await store.upsertWord(WordEntry(lemma: "hedge", state: .learning, source: .lookup, band: 9, updatedAt: dateAt(t0)))
            let reopened = try BookStore(root: root)
            #expect(try await reopened.loadEngineState() == Data([1, 2, 3]))
            #expect(try await reopened.pendingEffects() == SyncEffects(saveZone: true, saveRecords: ["hedge"]))

            // First enable queues the v1 word (its REAL time read as whole ms) and the pre-sync level (1 ms: it uploads, and any level
            // chosen later on any device beats it)
            #expect(try await reopened.handle(.firstEnable) == SyncEffects(saveZone: true, saveRecords: ["Profile", "hedge", "rabbit"]))
            #expect(try syncRows(root)["Profile"] == SyncRowSnapshot(nil, 1))
            #expect(try syncRows(root)["rabbit"] == SyncRowSnapshot(nil, 1_800_000_000_250))
            #expect(try await reopened.outgoingRecord(named: "Profile")?.value == .profile(SyncedProfile(level: 5, updatedAt: 1)))
        }

        // A v1 database without a level: still none after the migration (the first-launch test is shown)
        try await withTemporaryRoot { root in
            try makeDatabase(root, version: 1) { _ in }
            #expect(try await BookStore(root: root).profile() == nil)
        }
    }

    @Test("U-SYNC-017 Placeholder level: Skip writes 3 at time 0, never queued, loses to any iCloud level; a chosen level is later than anything seen and queued; invalid iCloud levels are ignored; resets never create the row")
    func placeholderLevel() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            #expect(try await store.profile() == nil)
            let log = EffectsLog()
            try await log.observe(store)

            try await store.skipLevelTest()
            var profile = try #require(try await store.profile())
            #expect(profile.level == 3 && SyncRules.milliseconds(profile.updatedAt) == 0 && profile.glossLanguage == nil)
            #expect(try syncRows(root).isEmpty)
            #expect(log.all.isEmpty)

            try await store.execute("UPDATE profile SET glossLanguage = 'de'")
            try await store.setLevel(7, at: dateAt(t0))
            profile = try #require(try await store.profile())
            #expect(profile.level == 7 && SyncRules.milliseconds(profile.updatedAt) == t0 && profile.glossLanguage == "de")
            #expect(try syncRows(root) == ["Profile": SyncRowSnapshot(nil, t0)])
            #expect(log.all == [SyncEffects(saveZone: true, saveRecords: ["Profile"])])

            // Skip never overwrites a level; a level chosen with a slow clock is still later than the one it replaces
            try await store.skipLevelTest()
            profile = try #require(try await store.profile())
            #expect(profile.level == 7 && SyncRules.milliseconds(profile.updatedAt) == t0)
            #expect(log.all.count == 1)
            try await store.setLevel(8, at: dateAt(t0 - 3_600_000))
            profile = try #require(try await store.profile())
            #expect(profile.level == 8 && SyncRules.milliseconds(profile.updatedAt) == t0 + 1)
        }

        // Sign-in never queues the placeholder, only a chosen level
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            try await store.skipLevelTest()
            #expect(try await store.handle(.signIn) == .nothing)
            #expect(try syncRows(root).isEmpty)
            try await store.setLevel(6, at: dateAt(t0))
            #expect(try await store.handle(.signIn).saveRecords.contains("Profile"))
        }

        // An iCloud level replaces the placeholder; invalid ones (time 0 or before, level outside 1...25) are ignored, even where
        // they would otherwise win, and the highest level, 25, is accepted
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            try await store.skipLevelTest()
            let invalid = [remoteProfile(level: 9, at: 0), remoteProfile(level: 9, at: -5), remoteProfile(level: 0, at: t0),
                           remoteProfile(level: 26, at: t0)]
            for record in invalid {
                #expect(try await store.applyFetched([.saved(record)]) == .nothing)
            }
            var profile = try #require(try await store.profile())
            #expect(profile.level == 3 && SyncRules.milliseconds(profile.updatedAt) == 0)
            #expect(try syncRows(root).isEmpty)

            #expect(try await store.applyFetched([.saved(remoteProfile(level: 9, at: 5))]) == .nothing)
            profile = try #require(try await store.profile())
            #expect(profile.level == 9 && SyncRules.milliseconds(profile.updatedAt) == 5)
            #expect(try syncRows(root) == ["Profile": SyncRowSnapshot(Data([2]), nil)])

            let rows = try syncRows(root)
            for record in invalid.dropFirst(2) {
                #expect(try await store.applyFetched([.saved(record)]) == .nothing)
            }
            profile = try #require(try await store.profile())
            #expect(profile.level == 9 && SyncRules.milliseconds(profile.updatedAt) == 5)
            #expect(try syncRows(root) == rows)

            #expect(try await store.applyFetched([.saved(remoteProfile(level: 25, at: t0))]) == .nothing)
            profile = try #require(try await store.profile())
            #expect(profile.level == 25 && SyncRules.milliseconds(profile.updatedAt) == t0)
        }

        // The account's level reaching a new device creates the row, so the next launch skips the test
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            #expect(try await store.applyFetched([.saved(remoteProfile(level: 6, at: t0))]) == .nothing)
            let profile = try #require(try await store.profile())
            #expect(profile.level == 6 && SyncRules.milliseconds(profile.updatedAt) == t0 && profile.glossLanguage == nil)
            #expect(try syncRows(root) == ["Profile": SyncRowSnapshot(Data([2]), nil)])
        }

        // No event and no deletion creates the row: resets only UPDATE it
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            for event in [SyncEvent.firstEnable, .signIn, .signOut, .switchAccounts, .zoneDeleted, .zonePurged, .encryptedDataReset,
                          .userDeletedZone] {
                _ = try await store.handle(event)
                #expect(try await store.profile() == nil, "\(event)")
            }
            #expect(try await store.applyFetched([.deleted(recordName: "Profile")]) == .nothing)
            #expect(try await store.profile() == nil)
            // (UI-SYNC-001, "the level test shows iff there is no row, decided once at launch", is a UI test.)
        }
    }
}
