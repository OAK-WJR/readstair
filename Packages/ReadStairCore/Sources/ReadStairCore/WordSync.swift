import CloudKit
import Foundation

/// Syncs the word list and the vocabulary level through the user's private iCloud database. CKSyncEngine does the transport:
/// push, scheduling, batching, retries and account monitoring.
///
/// This type only translates. CloudKit records and engine events become the plain values in SyncRules.swift, and BookStore makes
/// every decision in one transaction per step: merging, account changes and what still has to be sent. The store's syncRecord
/// table is the authoritative list of records to send, written in the same transaction as the data; the engine's own pending list
/// is only a work queue, refilled from that table at launch. So the rules are tested without an iCloud account, and a crash between
/// a write and its upload never loses the upload.
///
/// Create exactly one per app, after opening the store, keep a strong reference to it and call `start()`. The engine holds its
/// delegate weakly, and two engines must not sync the same database in production (CKSyncEngineConfiguration.h).
public actor WordSync: CKSyncEngineDelegate {
    /// The iCloud container the app's entitlements name.
    static let containerIdentifier = "iCloud.app.readstair"
    /// The one custom zone that holds both record types. The default zone has no capabilities, so changes in it cannot be fetched
    /// incrementally.
    static let zoneID = CKRecordZone.ID(zoneName: "Vocab", ownerName: CKCurrentUserDefaultName)
    static let wordType: CKRecord.RecordType = "Word"
    static let profileType: CKRecord.RecordType = "Profile"

    /// How a failed record or zone save is handled.
    enum SaveFailure: Equatable {
        /// serverRecordChanged: merge the server's copy like a fetched record.
        case conflict
        /// unknownItem: iCloud no longer has the record; send it again from scratch.
        case recordMissing
        /// zoneNotFound: iCloud no longer has the zone; save the zone, then the record.
        case zoneMissing
        /// userDeletedZone: the user deleted the app's iCloud data in Settings; reset like a purge.
        case zoneDeletedByUser
        /// A transient error the engine waits out and retries by itself.
        case engineRetries
        /// Anything else (quotaExceeded included): stop sending the record for this run. Its pending row stays, so the next launch
        /// tries again; this bounds any failure loop to one attempt per launch.
        case giveUp
    }

    private let store: BookStore
    /// Held only to keep the engine alive: its events and batch requests come with the engine they belong to.
    private var engine: CKSyncEngine?
    /// Set before `start()` first suspends, so a second call that interleaves with the first returns instead of creating a second
    /// engine for the same database.
    private var started = false
    /// Records already sent again this run after iCloud reported them or their zone missing. A second report gives up until the next
    /// launch, which breaks a "send, zone not found, save zone, send" loop. Cleared on account changes.
    private var missingRetried: Set<String> = []
    #if DEBUG
    /// Receives the summary of every event before it is handled; set only by the self-test, whose engines then sync only when told to.
    private var testHook: (@Sendable (String) -> Void)?
    #endif

    public init(store: BookStore) {
        self.store = store
    }

    #if DEBUG
    /// An instance for the self-test (SyncSelfTest.swift): its engine syncs only through `sendChanges()` and `fetchChanges()`.
    init(store: BookStore, testHook: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.testHook = testHook
    }

    func sendChanges() async throws {
        try await engine?.sendChanges()
    }

    func fetchChanges() async throws {
        try await engine?.fetchChanges()
    }
    #endif

    /// Creates the engine and hands it everything still to be sent. Only the first call does anything.
    ///
    /// Needs the iCloud (CloudKit) and remote-notification entitlements: without them CKContainer raises an exception, so unsigned
    /// processes such as unit tests must never call it. Throws only when the store cannot read or write; sync then stays off for
    /// this run.
    public func start() async throws(StoreError) {
        guard !started else { return }
        started = true
        let saved = try await store.loadEngineState()
        // Unreadable state counts as lost: the engine starts over, and the first-enable step below makes that safe.
        let state = saved.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        if state == nil {
            // First launch with sync, an upgrade from a version without it, or lost state: the previous account is unknown. The store
            // forgets what an earlier account confirmed and queues everything else. This commits before the engine exists, so no
            // engine state can be saved ahead of it. Its effects are the pending rows, which observeLocalWrites returns below.
            _ = try await store.handle(.firstEnable)
        }
        let database = CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: self)
        #if DEBUG
        configuration.automaticallySync = testHook == nil
        #endif
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        // One store step installs the observer and reads what is pending, so no local write can fall between the two.
        let pending = try await store.observeLocalWrites { effects in Self.register(effects, in: engine) }
        Self.register(pending, in: engine)
    }

    // MARK: - CKSyncEngineDelegate

    /// The engine delivers events one at a time and waits for this method before delivering the next. Every store step commits
    /// before this returns, so a state update that follows an account or zone event is saved only after that event's changes are
    /// on disk, and a crash in between makes the engine deliver the same changes again from the older saved state.
    ///
    /// A thrown error means a store transaction failed. The store then halts sync for the rest of the run (it applies nothing, sends
    /// nothing and saves no engine state), so the next launch resumes from the last state that matches the data.
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        #if DEBUG
        // Every event, as counts and error codes only, in the log of every debug build (SyncSelfTest.swift)
        for line in Self.summary(of: event) {
            Self.debugLog.notice("\(line, privacy: .public)")
            testHook?(line)
        }
        #endif
        do {
            switch event {
            case .stateUpdate(let update):
                try await store.saveEngineState(JSONEncoder().encode(update.stateSerialization))

            case .accountChange(let change):
                let accountEvent: SyncEvent
                switch change.changeType {
                case .signIn: accountEvent = .signIn
                case .signOut: accountEvent = .signOut
                case .switchAccounts: accountEvent = .switchAccounts
                @unknown default: return    // Never delete or re-send anything on a signal this version does not know.
                }
                // The engine clears its own pending list on an account change; the store's effects refill it.
                missingRetried = []
                try await apply(store.handle(accountEvent), in: syncEngine)

            case .fetchedDatabaseChanges(let changes):
                // Zone modifications carry nothing this app needs; a deletion of the zone is an account-level event.
                for deletion in changes.deletions where deletion.zoneID == Self.zoneID {
                    guard let zoneEvent = Self.event(for: deletion.reason) else { continue }
                    try await apply(store.handle(zoneEvent), in: syncEngine)
                }

            case .fetchedRecordZoneChanges(let changes):
                // Invalid records and records from other zones are dropped here and never reach the store.
                let saved = changes.modifications.compactMap { Self.syncRecord(from: $0.record).map(RemoteChange.saved) }
                let deleted = changes.deletions.filter { $0.recordID.zoneID == Self.zoneID }
                    .map { RemoteChange.deleted(recordName: $0.recordID.recordName) }
                try await apply(store.applyFetched(saved + deleted), in: syncEngine)

            case .sentRecordZoneChanges(let sent):
                var results = sent.savedRecords.filter { $0.recordID.zoneID == Self.zoneID }.map(Self.savedResult)
                var giveUp: [CKSyncEngine.PendingRecordZoneChange] = []
                for failure in sent.failedRecordSaves where failure.record.recordID.zoneID == Self.zoneID {
                    let id = failure.record.recordID
                    switch Self.saveFailure(failure.error.code) {
                    case .conflict:
                        // A server copy this version cannot read (for example, written by a newer version) is left alone.
                        if let server = failure.error.serverRecord.flatMap(Self.syncRecord(from:)) {
                            results.append(.conflict(server))
                        } else {
                            giveUp.append(.saveRecord(id))
                        }
                    case .recordMissing, .zoneMissing:
                        if missingRetried.insert(id.recordName).inserted {
                            results.append(.missing(recordName: id.recordName, zoneMissing: failure.error.code == .zoneNotFound))
                        } else {
                            giveUp.append(.saveRecord(id))
                        }
                    case .zoneDeletedByUser:
                        // The reset empties every synced table and the engine's queue, so the other results no longer matter.
                        try await apply(store.handle(.userDeletedZone), in: syncEngine)
                        return
                    case .engineRetries:
                        break
                    case .giveUp:
                        giveUp.append(.saveRecord(id))
                    }
                }
                syncEngine.state.remove(pendingRecordZoneChanges: giveUp)
                try await apply(store.applySent(results), in: syncEngine)

            case .sentDatabaseChanges(let sent):
                for failure in sent.failedZoneSaves where failure.zone.zoneID == Self.zoneID {
                    switch Self.saveFailure(failure.error.code) {
                    case .zoneDeletedByUser:
                        try await apply(store.handle(.userDeletedZone), in: syncEngine)
                    case .engineRetries:
                        break
                    default:
                        // Not retried this run. A later record save then fails with zoneNotFound, which registers the zone once more.
                        syncEngine.state.remove(pendingDatabaseChanges: [.saveZone(failure.zone)])
                    }
                }

            default:
                // Will/did fetch and send, and cases added in later SDKs: nothing to do. A zone fetch error is not acted on either:
                // zone deletions arrive as database changes, and send errors cover the rest.
                break
            }
        } catch {
            // The store has halted sync for this run; see above.
        }
    }

    /// Builds the next batch from the engine's pending list, reading each record's current value from the store at send time, so a
    /// word changed several times goes out once with its latest value. The engine's batch initializer applies the size limits.
    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        let store = self.store
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
            if id.zoneID == Self.zoneID, let outgoing = try? await store.outgoingRecord(named: id.recordName) {
                return Self.record(for: outgoing)
            }
            // Nothing to send: the value is gone or already sent, it is the placeholder level, or sync halted. Returning nil skips
            // the change; it is also removed so it cannot come back in every batch (whether nil removes it is not documented).
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            return nil
        }
    }

    /// Registers what a store step returned. Local writes register themselves on the store's executor right after they commit, so
    /// one that commits after this step but before this call is already in the engine, and clearing the engine would remove it
    /// while its row stays pending. After a clear, whatever the store still has to send is therefore registered again: nothing,
    /// unless something was written since.
    private func apply(_ effects: SyncEffects, in engine: CKSyncEngine) async throws(StoreError) {
        Self.register(effects, in: engine)
        if effects.clearEngine {
            Self.register(try await store.pendingEffects(), in: engine)
        }
    }

    // MARK: - Translation (unit-tested without an engine, except `register`)

    /// Applies a store step's effects to the engine's work queue, records in name order. Adding a change the engine already has does
    /// nothing, and adding schedules a send. Also runs as the store's local-write observer, right after each write commits.
    static func register(_ effects: SyncEffects, in engine: CKSyncEngine) {
        let state = engine.state
        if effects.clearEngine {
            state.remove(pendingRecordZoneChanges: state.pendingRecordZoneChanges)
            state.remove(pendingDatabaseChanges: state.pendingDatabaseChanges)
        }
        if effects.saveZone {
            state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        if !effects.saveRecords.isEmpty {
            state.add(pendingRecordZoneChanges: effects.saveRecords.sorted().map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
        }
    }

    /// The store event for a deletion of the zone; nil for a reason this version does not know, which then deletes nothing.
    static func event(for reason: CKDatabase.DatabaseChange.Deletion.Reason) -> SyncEvent? {
        switch reason {
        case .deleted: .zoneDeleted
        case .purged: .zonePurged
        case .encryptedDataReset: .encryptedDataReset
        @unknown default: nil
        }
    }

    /// Classifies a save error. The engine-retried codes are exactly those CKSyncEngine documents as handled for the app
    /// (CKSyncEngine.h); anything unknown gives up for this run rather than risk a send loop.
    static func saveFailure(_ code: CKError.Code) -> SaveFailure {
        switch code {
        case .serverRecordChanged: .conflict
        case .unknownItem: .recordMissing
        case .zoneNotFound: .zoneMissing
        case .userDeletedZone: .zoneDeletedByUser
        case .notAuthenticated, .accountTemporarilyUnavailable, .networkFailure, .networkUnavailable, .requestRateLimited,
             .serviceUnavailable, .zoneBusy: .engineRetries
        default: .giveUp
        }
    }

    /// The send result for a record iCloud saved: its new system fields, and the timestamp it carried, which tells the store whether
    /// the word changed again while it was in flight.
    static func savedResult(_ record: CKRecord) -> SendResult {
        .saved(recordName: record.recordID.recordName, systemFields: archivedSystemFields(of: record),
               updatedAt: record.encryptedValues["updatedAt"])
    }

    /// The CloudKit record for a value to send. Filling in the stored system fields (the record's change tag) lets iCloud accept it
    /// as an update instead of answering serverRecordChanged; without usable ones it is a new record.
    ///
    /// Every custom field is encrypted: with Advanced Data Protection only the user holds the keys, and a field cannot become
    /// encrypted later. Word: lemma, state, source, band (optional), updatedAt (Unix ms), firstSentence (optional). Profile: level,
    /// updatedAt (Unix ms). The first book and page and the gloss language never leave the device.
    static func record(for outgoing: SyncRecord) -> CKRecord {
        let id = CKRecord.ID(recordName: outgoing.name, zoneID: zoneID)
        let type: CKRecord.RecordType
        if case .word = outgoing.value { type = wordType } else { type = profileType }
        let restored = outgoing.systemFields.flatMap(restoredRecord).flatMap { $0.recordID == id && $0.recordType == type ? $0 : nil }
        let record = restored ?? CKRecord(recordType: type, recordID: id)
        let fields = record.encryptedValues
        switch outgoing.value {
        case .word(let word):
            fields["lemma"] = word.lemma
            fields["state"] = word.state.rawValue
            fields["source"] = word.source.rawValue
            // Always written, even as nil: setting nil marks the key changed, so a band removed here is removed in iCloud too.
            fields["band"] = word.band.map(Int64.init)
            fields["updatedAt"] = word.updatedAt
            // Written only when known, so a device that never saw the sentence cannot erase another device's first sentence.
            if let sentence = word.firstSentence { fields["firstSentence"] = sentence }
        case .profile(let profile):
            fields["level"] = Int64(profile.level)
            fields["updatedAt"] = profile.updatedAt
        }
        return record
    }

    /// The plain value of a fetched record, or nil when the record is not one this version can apply: another zone, another type,
    /// a missing or mistyped field, an unknown state or source (for example, from a newer version), a lemma that does not match
    /// the record name, a level outside the valid range, or a time outside `SyncRules.validTimestamps`. Such a record is ignored,
    /// never half-applied. A band of the wrong type reads as no band.
    static func syncRecord(from record: CKRecord) -> SyncRecord? {
        guard record.recordID.zoneID == zoneID else { return nil }
        let name = record.recordID.recordName
        let fields = record.encryptedValues
        let value: SyncedValue
        switch record.recordType {
        case wordType:
            guard let lemma: String = fields["lemma"], SyncRules.recordName(forLemma: lemma) == name,
                  let state = (fields["state"] as String?).flatMap(WordState.init(rawValue:)),
                  let source = (fields["source"] as String?).flatMap(WordEntry.Source.init(rawValue:)),
                  let updatedAt: Int64 = fields["updatedAt"], SyncRules.validTimestamps.contains(updatedAt) else { return nil }
            let band = (fields["band"] as Int64?).flatMap { Int(exactly: $0) }
            value = .word(SyncedWord(lemma: SyncRules.lemmaKey(lemma), state: state, source: source, band: band,
                                     updatedAt: updatedAt, firstSentence: fields["firstSentence"]))
        case profileType:
            guard name == SyncRules.profileRecordName, let level = (fields["level"] as Int64?).flatMap({ Int(exactly: $0) }),
                  Profile.levels.contains(level), let updatedAt: Int64 = fields["updatedAt"],
                  SyncRules.validTimestamps.contains(updatedAt) else { return nil }
            value = .profile(SyncedProfile(level: level, updatedAt: updatedAt))
        default:
            return nil
        }
        return SyncRecord(name: name, systemFields: archivedSystemFields(of: record), value: value)
    }

    /// The record's system fields (ID, type, change tag) without its custom fields, which the store keeps in its own tables.
    static func archivedSystemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// A record rebuilt from archived system fields, with no custom fields; nil for data that is not such an archive.
    static func restoredRecord(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }
}
