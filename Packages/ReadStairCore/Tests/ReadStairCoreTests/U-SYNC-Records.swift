import CloudKit
import Foundation
import Testing
@testable import ReadStairCore

/// U-SYNC-011, U-SYNC-007 (adapter part) and U-SYNC-008 (invalid records): WordSync's CloudKit record mapping and its classification of
/// zone deletions and save errors. CKRecord, CKRecord.ID, CKRecordZone.ID and CKError values need no container and no entitlement, so
/// these run on the macOS host. Nothing here creates a CKContainer, CKDatabase or CKSyncEngine, or calls WordSync.start().
@Suite("U-SYNC Records")
struct SyncRecordTests {
    private static let cafe = "caf\u{E9}"

    private static func word(_ name: String = "caf%C3%A9", lemma: String = cafe, state: WordState = .learning,
                             source: WordEntry.Source = .lookup, band: Int? = nil, at updatedAt: Int64 = t0 + 123,
                             sentence: String? = "A caf\u{E9}.", systemFields: Data? = nil) -> SyncRecord {
        SyncRecord(name: name, systemFields: systemFields,
                   value: .word(SyncedWord(lemma: lemma, state: state, source: source, band: band, updatedAt: updatedAt,
                                           firstSentence: sentence)))
    }

    private static func profile(_ name: String = "Profile", level: Int = 7, at updatedAt: Int64 = t0) -> SyncRecord {
        SyncRecord(name: name, systemFields: nil, value: .profile(SyncedProfile(level: level, updatedAt: updatedAt)))
    }

    /// A valid encrypted value from `record(for:)` with one change made to its fields.
    private static func mutated(_ value: SyncRecord, _ change: (any CKRecordKeyValueSetting) -> Void) -> CKRecord {
        let record = WordSync.record(for: value)
        change(record.encryptedValues)
        return record
    }

    /// Valid word fields for "rabbit", written by hand, for records `record(for:)` cannot build: another type or zone, or the lemma
    /// left out of the encrypted fields.
    private static func setRabbitFields(_ record: CKRecord, encryptedLemma: Bool = true) {
        let fields = record.encryptedValues
        if encryptedLemma { fields["lemma"] = "rabbit" as String }
        fields["state"] = "known" as String
        fields["source"] = "card" as String
        fields["band"] = Int64(5)
        fields["updatedAt"] = t0
    }

    @Test("U-SYNC-011 Word and Profile ↔ CKRecord round trips in zone Vocab with encrypted fields only; system fields archive and restore; a nil band is cleared, a nil sentence is left alone; corrupt or foreign system fields give a fresh record")
    func roundTrips() throws {
        // A word without a band, with a sentence
        let word = Self.word()
        let record = WordSync.record(for: word)
        #expect(record.recordType == "Word")
        #expect(record.recordID.recordName == "caf%C3%A9")
        #expect(record.recordID.zoneID == WordSync.zoneID)
        #expect(WordSync.zoneID.zoneName == "Vocab")
        #expect(WordSync.zoneID.ownerName == CKCurrentUserDefaultName)
        #expect(record["lemma"] == nil, "custom fields are never stored unencrypted")
        let fields = record.encryptedValues
        #expect(fields["lemma"] as String? == Self.cafe)
        #expect(fields["state"] as String? == "learning")
        #expect(fields["source"] as String? == "lookup")
        #expect(fields["updatedAt"] as Int64? == t0 + 123)
        #expect(fields["firstSentence"] as String? == "A caf\u{E9}.")
        #expect(fields["band"] as Int64? == nil)
        #expect(!record.allKeys().contains("band"))
        let back = try #require(WordSync.syncRecord(from: record))
        #expect(back.name == word.name)
        #expect(back.value == word.value)
        #expect(back.systemFields != nil)

        // A band round-trips as Int64
        let banded = Self.word(band: 12)
        let bandedRecord = WordSync.record(for: banded)
        #expect(bandedRecord.encryptedValues["band"] as Int64? == 12)
        #expect(WordSync.syncRecord(from: bandedRecord)?.value == banded.value)

        // The level
        let level = Self.profile()
        let levelRecord = WordSync.record(for: level)
        #expect(levelRecord.recordType == "Profile")
        #expect(levelRecord.recordID.recordName == "Profile")
        #expect(levelRecord.recordID.zoneID == WordSync.zoneID)
        #expect(levelRecord.encryptedValues["level"] as Int64? == 7)
        #expect(levelRecord.encryptedValues["updatedAt"] as Int64? == t0)
        let levelBack = try #require(WordSync.syncRecord(from: levelRecord))
        #expect(levelBack.name == "Profile")
        #expect(levelBack.value == level.value)

        // What a successful send reports: the name, the timestamp the record carried, and its system fields
        let sent = WordSync.savedResult(record)
        guard case .saved(let sentName, let sentFields, let sentAt) = sent else {
            Issue.record("Expected a saved result, got \(sent)")
            return
        }
        #expect(sentName == "caf%C3%A9")
        #expect(sentAt == t0 + 123)
        #expect(WordSync.restoredRecord(sentFields)?.recordID == record.recordID)

        // System fields: ID and type without custom fields
        let systemFields = WordSync.archivedSystemFields(of: record)
        let restored = try #require(WordSync.restoredRecord(systemFields))
        #expect(restored.recordID == record.recordID)
        #expect(restored.recordType == "Word")
        #expect(restored.allKeys().isEmpty)

        // Sending again on top of them: the same record, new values, band cleared in iCloud, first sentence left alone
        let update = Self.word(state: .known, source: .card, band: nil, at: t0 + 500, sentence: nil, systemFields: systemFields)
        let updated = WordSync.record(for: update)
        #expect(updated.recordID == record.recordID)
        #expect(updated.encryptedValues["state"] as String? == "known")
        #expect(updated.encryptedValues["source"] as String? == "card")
        #expect(updated.encryptedValues["updatedAt"] as Int64? == t0 + 500)
        #expect(!updated.changedKeys().contains("firstSentence"))
        #expect(updated.changedKeys().contains("band"))

        // Corrupt system fields, or those of another record, never crash and give a fresh record with the right name
        #expect(WordSync.restoredRecord(Data("x".utf8)) == nil)
        #expect(WordSync.restoredRecord(Data()) == nil)
        let hareFields = WordSync.archivedSystemFields(of: WordSync.record(for: Self.word("hare", lemma: "hare")))
        for unusable in [Data("x".utf8), hareFields] {
            let fresh = WordSync.record(for: Self.word(systemFields: unusable))
            #expect(fresh.recordID.recordName == "caf%C3%A9")
            #expect(fresh.recordID.zoneID == WordSync.zoneID)
            #expect(fresh.recordType == "Word")
            #expect(WordSync.syncRecord(from: fresh)?.value == Self.word().value)
        }
        // A level's system fields do not restore a word record of the same name either
        let profileFields = WordSync.archivedSystemFields(of: WordSync.record(for: Self.profile()))
        #expect(WordSync.record(for: Self.word("Profile", systemFields: profileFields)).recordType == "Word")
    }

    @Test("U-SYNC-007 Adapter mapping: zone deletion reasons → store events; save errors → conflict / missing / user-deleted zone / engine retries / give up; a conflict's server record parses")
    func adapterMapping() throws {
        #expect(WordSync.event(for: .deleted) == .zoneDeleted)
        #expect(WordSync.event(for: .purged) == .zonePurged)
        #expect(WordSync.event(for: .encryptedDataReset) == .encryptedDataReset)

        let expected: [(CKError.Code, WordSync.SaveFailure)] = [
            (.serverRecordChanged, .conflict),
            (.unknownItem, .recordMissing),
            (.zoneNotFound, .zoneMissing),
            (.userDeletedZone, .zoneDeletedByUser),
            // The errors CKSyncEngine retries by itself
            (.notAuthenticated, .engineRetries),
            (.accountTemporarilyUnavailable, .engineRetries),
            (.networkFailure, .engineRetries),
            (.networkUnavailable, .engineRetries),
            (.requestRateLimited, .engineRetries),
            (.serviceUnavailable, .engineRetries),
            (.zoneBusy, .engineRetries),
            // Everything else stops for this run; nothing is ever deleted because of it
            (.quotaExceeded, .giveUp),
            (.limitExceeded, .giveUp),
            (.batchRequestFailed, .giveUp),
            (.serverRejectedRequest, .giveUp),
            (.internalError, .giveUp),
            (.invalidArguments, .giveUp),
            (.operationCancelled, .giveUp),
            (.partialFailure, .giveUp),
        ]
        for (code, failure) in expected {
            #expect(WordSync.saveFailure(code) == failure, "\(code)")
            // Only the user deleting the zone in Settings resets synced data
            #expect((WordSync.saveFailure(code) == .zoneDeletedByUser) == (code == .userDeletedZone), "\(code)")
        }

        // serverRecordChanged carries the server's copy, which merges like a fetched record
        let server = WordSync.record(for: Self.word("rabbit", lemma: "rabbit", state: .known, source: .card, band: 5, at: t0 + 7))
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        #expect(WordSync.saveFailure(conflict.code) == .conflict)
        let parsed = try #require(conflict.serverRecord.flatMap(WordSync.syncRecord(from:)))
        let direct = try #require(WordSync.syncRecord(from: server))
        #expect(parsed.name == direct.name)
        #expect(parsed.value == direct.value)
        #expect(parsed.systemFields != nil)
    }

    @Test("U-SYNC-008 Invalid records are ignored (nil, never half-applied): unknown state or source, lemma not matching the name, missing or mistyped fields, unencrypted lemma, level out of range, a time of 0 or less or past the valid range (Int64.max included), wrong Profile name, other type or zone; a mistyped band reads as no band")
    func invalidRecords() throws {
        let rabbit = Self.word("rabbit", lemma: "rabbit", state: .known, source: .card, band: 5, at: t0, sentence: nil)
        #expect(WordSync.syncRecord(from: WordSync.record(for: rabbit))?.value == rabbit.value, "the unmutated record is valid")
        let latest = SyncRules.validTimestamps.upperBound
        #expect(WordSync.syncRecord(from: Self.mutated(rabbit) { $0["updatedAt"] = latest })?.value.updatedAt == latest)
        #expect(WordSync.syncRecord(from: WordSync.record(for: Self.profile(level: 25)))?.value == Self.profile(level: 25).value,
                "the highest level")

        let invalid: [(String, CKRecord)] = [
            ("unknown state", Self.mutated(rabbit) { $0["state"] = "ignored" as String }),
            ("unknown source", Self.mutated(rabbit) { $0["source"] = "import" as String }),
            ("lemma does not match the name", Self.mutated(rabbit) { $0["lemma"] = "hare" as String }),
            ("lemma missing", Self.mutated(rabbit) { $0["lemma"] = nil as String? }),
            ("state missing", Self.mutated(rabbit) { $0["state"] = nil as String? }),
            ("updatedAt missing", Self.mutated(rabbit) { $0["updatedAt"] = nil as Int64? }),
            ("updatedAt as a string", Self.mutated(rabbit) { $0["updatedAt"] = "5" as String }),
            ("updatedAt 0", Self.mutated(rabbit) { $0["updatedAt"] = Int64(0) }),
            ("updatedAt past the valid range", Self.mutated(rabbit) { $0["updatedAt"] = SyncRules.validTimestamps.upperBound + 1 }),
            ("updatedAt Int64.max", Self.mutated(rabbit) { $0["updatedAt"] = Int64.max }),
            ("level 0", Self.mutated(Self.profile()) { $0["level"] = Int64(0) }),
            ("level 26", Self.mutated(Self.profile()) { $0["level"] = Int64(26) }),
            ("level updatedAt 0", Self.mutated(Self.profile()) { $0["updatedAt"] = Int64(0) }),
            ("level updatedAt -5", Self.mutated(Self.profile()) { $0["updatedAt"] = Int64(-5) }),
            ("level updatedAt Int64.max", Self.mutated(Self.profile()) { $0["updatedAt"] = Int64.max }),
            ("level record named profile", WordSync.record(for: Self.profile("profile"))),
        ]
        for (reason, record) in invalid {
            #expect(WordSync.syncRecord(from: record) == nil, "\(reason)")
        }

        // The lemma only in a plain (unencrypted) field
        let plain = CKRecord(recordType: "Word", recordID: CKRecord.ID(recordName: "rabbit", zoneID: WordSync.zoneID))
        Self.setRabbitFields(plain, encryptedLemma: false)
        plain.setObject("rabbit" as NSString, forKey: "lemma")
        #expect(WordSync.syncRecord(from: plain) == nil)

        // Another record type, and another zone (with otherwise valid fields; the control parses)
        let control = CKRecord(recordType: "Word", recordID: CKRecord.ID(recordName: "rabbit", zoneID: WordSync.zoneID))
        Self.setRabbitFields(control)
        #expect(WordSync.syncRecord(from: control)?.value == rabbit.value)
        let book = CKRecord(recordType: "Book", recordID: CKRecord.ID(recordName: "rabbit", zoneID: WordSync.zoneID))
        Self.setRabbitFields(book)
        #expect(WordSync.syncRecord(from: book) == nil)
        let otherZone = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)
        let elsewhere = CKRecord(recordType: "Word", recordID: CKRecord.ID(recordName: "rabbit", zoneID: otherZone))
        Self.setRabbitFields(elsewhere)
        #expect(WordSync.syncRecord(from: elsewhere) == nil)

        // A band of the wrong type: the word is still accepted, without a band
        let parsed = try #require(WordSync.syncRecord(from: Self.mutated(rabbit) { $0["band"] = "5" as String }))
        guard case .word(let word) = parsed.value else {
            Issue.record("Expected a word, got \(parsed.value)")
            return
        }
        #expect(word.band == nil)
        #expect(word.state == .known)
    }
}
