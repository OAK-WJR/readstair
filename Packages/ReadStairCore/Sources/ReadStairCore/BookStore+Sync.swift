import Foundation

// iCloud sync bookkeeping. The store is the single source of truth for what must be sent (syncRecord.pendingAt, written in the same
// transaction as the data); the sync engine's own pending list is only a work queue, rebuilt from it at launch. Every method that
// applies something from iCloud runs in one transaction and returns what to register in the engine once it has committed.
//
// The only writers of wordEntry besides upsertWord live here: merging a fetched or conflicting record, a remote deletion, forgetting
// an account's data at sign-out and resetting after the iCloud data was deleted. Deleting a page or a book triggers none of them.
extension BookStore {
    // MARK: - Engine state and launch

    /// The engine state saved by the last StateUpdate event; nil if sync never ran. Readable while halted: the next engine is built
    /// from the last state that matches the data.
    func loadEngineState() throws(StoreError) -> Data? {
        try database.query("SELECT engineState FROM syncState WHERE id = 1").first?["engineState"].data
    }

    /// Saves the engine state. Skipped while sync is halted, so the saved state never runs ahead of the data it describes: the engine
    /// then reports the unapplied changes again on the next launch.
    func saveEngineState(_ state: Data) throws(StoreError) {
        try syncTransaction(()) { () throws(StoreError) in
            try database.execute("""
                INSERT INTO syncState (id, engineState) VALUES (1, ?)
                ON CONFLICT (id) DO UPDATE SET engineState = excluded.engineState
                """, [.blob(state)])
        }
    }

    /// Everything still to be sent, to register with a new engine at launch (the engine forgets its list on account changes, and its
    /// saved state can lag behind the data). The zone is included while nothing is confirmed in iCloud yet.
    func pendingEffects() throws(StoreError) -> SyncEffects {
        try syncTransaction(.nothing) { () throws(StoreError) -> SyncEffects in
            let names = try database.query("SELECT recordName FROM syncRecord WHERE pendingAt IS NOT NULL")
                .compactMap { $0["recordName"].string }
            let confirmed = try zoneConfirmed()
            return SyncEffects(saveZone: !names.isEmpty && !confirmed, saveRecords: Set(names))
        }
    }

    /// Installs the observer for local writes and returns what is pending, in one actor turn, so no local write can fall between the
    /// two and be missed.
    func observeLocalWrites(_ observer: @escaping @Sendable (SyncEffects) -> Void) throws(StoreError) -> SyncEffects {
        syncObserver = observer
        return try pendingEffects()
    }

    // MARK: - Sending

    /// The current value of a record to send; nil when there is nothing to send: halted, no row (forgotten or reset meanwhile), not
    /// pending, the local value is gone, or it is the placeholder level, which never leaves the device. A plain read: it never halts.
    func outgoingRecord(named name: String) throws(StoreError) -> SyncRecord? {
        guard !syncHalted, let row = try syncRow(name), row.pendingAt != nil,
              let value = try currentValue(named: name), value.updatedAt > 0 else { return nil }
        return SyncRecord(name: name, systemFields: row.systemFields, value: value)
    }

    /// Send results. None of them creates a row: a late result for a record that was forgotten or reset meanwhile changes nothing, so
    /// deleted data can never come back through it. Only a conflict can change a word or the level; the rest is bookkeeping.
    func applySent(_ results: [SendResult]) throws(StoreError) -> SyncEffects {
        let conflict = results.contains { if case .conflict = $0 { true } else { false } }
        return try syncTransaction(.nothing, publishing: conflict ? [.words, .profile] : []) { () throws(StoreError) -> SyncEffects in
            var effects = SyncEffects.nothing
            for result in results {
                switch result {
                case .saved(let name, let systemFields, let updatedAt):
                    guard let row = try syncRow(name) else { continue }
                    if let pending = row.pendingAt, pending == updatedAt {
                        try database.execute("UPDATE syncRecord SET systemFields = ?, pendingAt = NULL WHERE recordName = ?",
                                             [.blob(systemFields), .text(name)])
                    } else {
                        try database.execute("UPDATE syncRecord SET systemFields = ? WHERE recordName = ?", [.blob(systemFields), .text(name)])
                        // Changed while in flight: send again. Without a timestamp in the result, leave it pending for the next launch,
                        // which bounds any resend loop to once per launch.
                        if row.pendingAt != nil, updatedAt != nil { effects.formUnion(SyncEffects(saveRecords: [name])) }
                    }
                case .conflict(let server):
                    // iCloud holds another copy: merge it like a fetched record, then send the winner if it is ours.
                    guard try syncRow(server.name) != nil else { continue }
                    effects.formUnion(try merge(server))
                case .missing(let name, let zoneMissing):
                    // The record or the zone is gone from iCloud: send this record again from scratch, and the zone first if needed.
                    // Only the failed records are touched, not the whole table.
                    guard try syncRow(name) != nil, let current = try currentValue(named: name), current.updatedAt > 0 else { continue }
                    try database.execute("""
                        UPDATE syncRecord SET systemFields = NULL, pendingAt = COALESCE(pendingAt, ?) WHERE recordName = ?
                        """, [.milliseconds(current.updatedAt), .text(name)])
                    effects.formUnion(SyncEffects(saveZone: zoneMissing, saveRecords: [name]))
                }
            }
            return effects
        }
    }

    // MARK: - Fetching

    /// Fetched records and deletions, applied in one transaction. Applying iCloud data never marks anything for upload, which would
    /// echo it back forever, except a local value that is newer than iCloud's or an unsent change to a record iCloud deleted.
    func applyFetched(_ changes: [RemoteChange]) throws(StoreError) -> SyncEffects {
        try syncTransaction(.nothing, publishing: changes.isEmpty ? [] : [.words, .profile]) { () throws(StoreError) -> SyncEffects in
            var effects = SyncEffects.nothing
            for change in changes {
                switch change {
                case .saved(let record): effects.formUnion(try merge(record))
                case .deleted(let name): effects.formUnion(try remoteDeletion(name))
                }
            }
            return effects
        }
    }

    // MARK: - Account and zone events

    /// Runs the rules for an account or zone event in one transaction. Only these events ever remove synced data; errors such as no
    /// account, no network or a full iCloud never reach here.
    func handle(_ event: SyncEvent) throws(StoreError) -> SyncEffects {
        let rules = SyncRules.rules(for: event)
        // Merging only queues uploads; forgetting and resetting remove words and change the level
        let writesData = rules.contains { $0 != .mergeAll }
        return try syncTransaction(.nothing, publishing: writesData ? [.words, .profile] : []) { () throws(StoreError) -> SyncEffects in
            var effects = SyncEffects.nothing
            for rule in rules {
                switch rule {
                case .forgetAccountData: try forgetAccountData()
                case .resetSyncedData: effects.formUnion(try resetSyncedData())
                case .mergeAll: effects.formUnion(try mergeAll())
                }
            }
            return effects
        }
    }

    // MARK: - Private

    private struct SyncRow {
        var systemFields: Data?
        var pendingAt: Int64?
    }

    /// Runs one sync step in a transaction, or returns `skipped` without touching the database while halted. A failure halts sync for
    /// the rest of this run (the transaction has already rolled back), so no later step builds on data that was never written.
    /// `published` goes to `changes` once the step commits: `.words` and `.profile` for a step that can change words or the level,
    /// nothing for one that only touches the sync bookkeeping (syncState, syncRecord, wordOrigin). A skipped or failed step publishes
    /// nothing.
    private func syncTransaction<T>(_ skipped: T, publishing published: [StoreChange] = [],
                                    _ body: () throws(StoreError) -> T) throws(StoreError) -> T {
        guard !syncHalted else { return skipped }
        do {
            let result = try database.transaction(body)
            for change in published { changeSink.yield(change) }
            return result
        } catch {
            syncHalted = true
            throw error
        }
    }

    private func syncRow(_ name: String) throws(StoreError) -> SyncRow? {
        try database.query("SELECT systemFields, pendingAt FROM syncRecord WHERE recordName = ?", [.text(name)]).first.map {
            SyncRow(systemFields: $0["systemFields"].data, pendingAt: $0["pendingAt"].milliseconds)
        }
    }

    /// The local value a record name stands for; nil if there is none, or the name is not one this app produces.
    private func currentValue(named name: String) throws(StoreError) -> SyncedValue? {
        if name == SyncRules.profileRecordName {
            return try database.query("SELECT level, updatedAt FROM profile WHERE id = 1").first.flatMap { row in
                guard let level = row["level"].int, let updatedAt = row["updatedAt"].milliseconds else { return nil }
                return .profile(SyncedProfile(level: level, updatedAt: updatedAt))
            }
        }
        guard let lemma = SyncRules.lemma(fromRecordName: name) else { return nil }
        return try localWord(lemma).map(SyncedValue.word)
    }

    private func localWord(_ lemma: String) throws(StoreError) -> SyncedWord? {
        try database.query("SELECT state, source, band, updatedAt, firstSentence FROM wordEntry WHERE lemma = ?", [.text(lemma)]).first.flatMap { row in
            guard let state = row["state"].string.flatMap(WordState.init), let source = row["source"].string.flatMap(WordEntry.Source.init),
                  let updatedAt = row["updatedAt"].milliseconds else { return nil }
            return SyncedWord(lemma: lemma, state: state, source: source, band: row["band"].int, updatedAt: updatedAt,
                              firstSentence: row["firstSentence"].string)
        }
    }

    private func recordSynced(_ name: String, systemFields: Data?, pendingAt: Int64?) throws(StoreError) {
        try database.execute("""
            INSERT INTO syncRecord (recordName, systemFields, pendingAt) VALUES (?, ?, ?)
            ON CONFLICT (recordName) DO UPDATE SET systemFields = excluded.systemFields, pendingAt = excluded.pendingAt
            """, [.text(name), .blob(systemFields), pendingAt.map(SQLValue.milliseconds) ?? .null])
    }

    /// Merges one record from iCloud: the later change wins, and this device's first book, page and sentence are never overwritten.
    /// Every case stores iCloud's system fields, so the next send updates that copy instead of conflicting with it.
    private func merge(_ remote: SyncRecord) throws(StoreError) -> SyncEffects {
        switch remote.value {
        case .word(let word):
            guard SyncRules.recordName(forLemma: word.lemma) == remote.name, SyncRules.validTimestamps.contains(word.updatedAt) else {
                return .nothing
            }
            guard let local = try localWord(word.lemma).map(SyncedValue.word) else {
                // A new word here. If it was removed at sign-out, this device's first book, page and sentence come back with it;
                // otherwise only iCloud's sentence (books and pages are per device).
                let first = try takeOrigin(of: word.lemma) ?? [.null, .null, .text(word.firstSentence)]
                try database.execute("""
                    INSERT INTO wordEntry (lemma, state, source, band, updatedAt, firstBookID, firstPageID, firstSentence)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.text(word.lemma), .text(word.state.rawValue), .text(word.source.rawValue), .int(word.band),
                          .milliseconds(word.updatedAt)] + first)
                try recordSynced(remote.name, systemFields: remote.systemFields, pendingAt: nil)
                return .nothing
            }
            return try resolve(local: local, remote: remote) { () throws(StoreError) in
                try database.execute("UPDATE wordEntry SET state = ?, source = ?, band = ?, updatedAt = ? WHERE lemma = ?",
                                     [.text(word.state.rawValue), .text(word.source.rawValue), .int(word.band),
                                      .milliseconds(word.updatedAt), .text(word.lemma)])
            }
        case .profile(let profile):
            guard remote.name == SyncRules.profileRecordName, Profile.levels.contains(profile.level),
                  SyncRules.validTimestamps.contains(profile.updatedAt) else { return .nothing }
            guard let local = try currentValue(named: remote.name) else {
                // The account's real level reached a device that has none: the next launch skips the level test. A test already on
                // screen stays, because the UI decides once at launch.
                try database.execute("INSERT INTO profile (id, level, updatedAt) VALUES (1, ?, ?)",
                                     [.int(profile.level), .milliseconds(profile.updatedAt)])
                try recordSynced(remote.name, systemFields: remote.systemFields, pendingAt: nil)
                return .nothing
            }
            return try resolve(local: local, remote: remote) { () throws(StoreError) in
                try database.execute("UPDATE profile SET level = ?, updatedAt = ? WHERE id = 1",
                                     [.int(profile.level), .milliseconds(profile.updatedAt)])
            }
        }
    }

    /// Applies the merge decision for a record that exists on both sides. Only a newer local value is registered, to push it up.
    private func resolve(local: SyncedValue, remote: SyncRecord, adopt: () throws(StoreError) -> Void) throws(StoreError) -> SyncEffects {
        switch SyncRules.resolve(local: local, remote: remote.value) {
        case .adoptRemote:
            try adopt()
            try recordSynced(remote.name, systemFields: remote.systemFields, pendingAt: nil)
            return .nothing
        case .echo:
            try recordSynced(remote.name, systemFields: remote.systemFields, pendingAt: nil)
            return .nothing
        case .keepLocal:
            try recordSynced(remote.name, systemFields: remote.systemFields, pendingAt: local.updatedAt)
            return SyncEffects(saveRecords: [remote.name])
        }
    }

    /// iCloud deleted a record (this app never deletes one): an unsent local change is kept and sent again as a new record; otherwise
    /// the local copy goes too. A level falls back to the default placeholder rather than disappearing, so the level test does not
    /// come back. A name unknown here writes nothing.
    private func remoteDeletion(_ name: String) throws(StoreError) -> SyncEffects {
        guard let row = try syncRow(name) else { return .nothing }
        if row.pendingAt != nil {
            try database.execute("UPDATE syncRecord SET systemFields = NULL WHERE recordName = ?", [.text(name)])
            return SyncEffects(saveRecords: [name])
        }
        if name == SyncRules.profileRecordName {
            try resetLevelToPlaceholder()
        } else if let lemma = SyncRules.lemma(fromRecordName: name) {
            try database.execute("DELETE FROM wordEntry WHERE lemma = ?", [.text(lemma)])
        }
        try database.execute("DELETE FROM syncRecord WHERE recordName = ?", [.text(name)])
        return .nothing
    }

    /// Sign-out (and the first half of an account switch): removes only rows whose latest value the previous account holds (system
    /// fields set, nothing pending), keeping their first book, page and sentence in wordOrigin for when they come back. No older
    /// wordOrigin row can be there for them (`takeOrigin` removes it whenever the word gets a row again), so OR IGNORE never keeps a
    /// stale context. Unsent and never-synced words stay as device-only words, because this device has the only copy. Idempotent.
    /// Registers nothing: the engine clears its own pending list on an account change. The level is only ever updated, never
    /// inserted, so an event during the level test cannot hide the test.
    private func forgetAccountData() throws(StoreError) {
        let confirmed = try database.query("SELECT recordName FROM syncRecord WHERE systemFields IS NOT NULL AND pendingAt IS NULL")
            .compactMap { $0["recordName"].string }
        for name in confirmed {
            if name == SyncRules.profileRecordName {
                try resetLevelToPlaceholder()
            } else if let lemma = SyncRules.lemma(fromRecordName: name) {
                try database.execute("""
                    INSERT OR IGNORE INTO wordOrigin (lemma, firstBookID, firstPageID, firstSentence)
                    SELECT lemma, firstBookID, firstPageID, firstSentence FROM wordEntry WHERE lemma = ?
                    """, [.text(lemma)])
                try database.execute("DELETE FROM wordEntry WHERE lemma = ?", [.text(lemma)])
            }
            try database.execute("DELETE FROM syncRecord WHERE recordName = ?", [.text(name)])
        }
        try database.execute("UPDATE syncRecord SET systemFields = NULL WHERE systemFields IS NOT NULL")
    }

    /// The app's iCloud data was deleted in Settings or reset: every device must delete its copy and never send it again. The word
    /// list empties and the level returns to the default placeholder; books, pages and the gloss language stay. Idempotent, and the
    /// same whichever trigger arrives first. Nothing is registered: the next explicit write registers the zone and its record, because
    /// no record is confirmed any more.
    private func resetSyncedData() throws(StoreError) -> SyncEffects {
        try database.execute("DELETE FROM wordEntry; DELETE FROM syncRecord; DELETE FROM wordOrigin;")
        try resetLevelToPlaceholder()
        return SyncEffects(clearEngine: true)
    }

    /// The level falls back to the default placeholder (time 0): kept on this device, never sent, replaced by any level from iCloud.
    /// Only ever an update, so it never creates the row that hides the level test.
    private func resetLevelToPlaceholder() throws(StoreError) {
        try database.execute("UPDATE profile SET level = ?, updatedAt = 0 WHERE id = 1", [.int(Profile.defaultLevel)])
    }

    /// Sign-in, the second half of an account switch, first enable, or a zone this app deleted: queue every local word, and the level
    /// if the user chose one, for upload without system fields. Incoming records then merge word by word, so the result is the union
    /// of both sides with no duplicates and nothing local deleted. Idempotent.
    private func mergeAll() throws(StoreError) -> SyncEffects {
        try database.execute("UPDATE syncRecord SET systemFields = NULL WHERE systemFields IS NOT NULL")
        var names: Set<String> = []
        for row in try database.query("SELECT lemma, updatedAt FROM wordEntry") {
            guard let lemma = row["lemma"].string, let name = SyncRules.recordName(forLemma: lemma),
                  let updatedAt = row["updatedAt"].milliseconds else { continue }
            try recordSynced(name, systemFields: nil, pendingAt: updatedAt)
            names.insert(name)
        }
        if let updatedAt = try database.query("SELECT updatedAt FROM profile WHERE id = 1").first?["updatedAt"].milliseconds, updatedAt > 0 {
            try recordSynced(SyncRules.profileRecordName, systemFields: nil, pendingAt: updatedAt)
            names.insert(SyncRules.profileRecordName)
        }
        return SyncEffects(saveZone: !names.isEmpty, saveRecords: names)
    }
}
