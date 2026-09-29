import Foundation

// Plain values and pure rules for iCloud sync of the word list and the vocabulary level. Nothing here imports CloudKit: the store
// works only with these values, and WordSync translates between them and CloudKit records and events.

/// A word as it syncs. The first book and page never leave the device: they point at books other devices do not have.
struct SyncedWord: Sendable, Hashable {
    /// The store key: lowercased, Unicode NFC (see `SyncRules.lemmaKey`).
    var lemma: String
    var state: WordState
    var source: WordEntry.Source
    var band: Int?
    /// Unix time in whole milliseconds.
    var updatedAt: Int64
    var firstSentence: String?
}

/// The vocabulary level as it syncs.
struct SyncedProfile: Sendable, Hashable {
    var level: Int
    /// Unix time in whole milliseconds; 0 marks the placeholder written by a skipped level test, which never syncs.
    var updatedAt: Int64
}

enum SyncedValue: Sendable, Hashable {
    case word(SyncedWord)
    case profile(SyncedProfile)

    var updatedAt: Int64 {
        switch self {
        case .word(let word): word.updatedAt
        case .profile(let profile): profile.updatedAt
        }
    }

    /// What two values with the same timestamp are compared by: identical content is an echo; otherwise the larger string wins,
    /// so every device picks the same winner.
    var content: String {
        switch self {
        case .word(let word): "\(word.state.rawValue)|\(word.source.rawValue)|\(word.band.map(String.init) ?? "")"
        case .profile(let profile): "\(profile.level)"
        }
    }
}

/// One CloudKit record reduced to plain values.
struct SyncRecord: Sendable, Hashable {
    var name: String
    /// The record's archived system fields (its change tag); nil for a record iCloud does not have yet.
    var systemFields: Data?
    var value: SyncedValue
}

/// A change fetched from iCloud.
enum RemoteChange: Sendable, Hashable {
    case saved(SyncRecord)
    case deleted(recordName: String)
}

/// The outcome of sending one record.
enum SendResult: Sendable, Hashable {
    /// iCloud saved it. `updatedAt` is the timestamp read back from the saved record; nil if the record came back without fields.
    case saved(recordName: String, systemFields: Data, updatedAt: Int64?)
    /// serverRecordChanged: iCloud holds a newer copy, merged like a fetched record.
    case conflict(SyncRecord)
    /// unknownItem (`zoneMissing` false) or zoneNotFound (true): iCloud no longer has the record or its zone.
    case missing(recordName: String, zoneMissing: Bool)
}

/// Account and zone events, reduced to what the store needs to know.
enum SyncEvent: Sendable, Hashable, CaseIterable {
    /// The engine starts with no saved state: first launch with sync, an upgrade from a version without it, or lost state.
    case firstEnable
    case signIn
    case signOut
    case switchAccounts
    /// This app deleted the zone (another device, or a test).
    case zoneDeleted
    /// The user deleted this app's iCloud data in Settings.
    case zonePurged
    /// The user reset their encrypted iCloud data.
    case encryptedDataReset
    /// A save failed because the user deleted the zone in Settings.
    case userDeletedZone
}

/// A store-side rule run for an event.
enum SyncRule: Sendable, Hashable {
    /// Sign-out: drop what the previous account holds; keep unsent words and their device-only provenance.
    case forgetAccountData
    /// iCloud data deleted: return everything that syncs to its fresh-install state and never resend any of it.
    case resetSyncedData
    /// Queue every local word and a chosen level for upload; incoming records then merge word by word.
    case mergeAll
}

/// What a store step asks the sync engine to do once its transaction has committed.
struct SyncEffects: Sendable, Hashable {
    /// Register `.saveZone` for the word zone (set only together with at least one record).
    var saveZone = false
    /// Record names to register as `.saveRecord`. A set, so merging the effects of a large batch record by record stays linear.
    var saveRecords: Set<String> = []
    /// Remove every pending change from the engine, before any registration above.
    var clearEngine = false

    static let nothing = SyncEffects()

    mutating func formUnion(_ other: SyncEffects) {
        saveZone = saveZone || other.saveZone
        saveRecords.formUnion(other.saveRecords)
        clearEngine = clearEngine || other.clearEngine
    }
}

enum SyncRules {
    /// Name of the single level record. Word record names contain no uppercase letter outside a %XX escape, so no word maps to it.
    static let profileRecordName = "Profile"

    /// The word list's primary key and the source of a word's record name: lowercased, then Unicode NFC, so "Café" typed with a
    /// combining accent and "café" are one word.
    static func lemmaKey(_ lemma: String) -> String {
        lemma.lowercased().precomposedStringWithCanonicalMapping
    }

    /// CloudKit record name for a word: the key's UTF-8 bytes with a-z, 0-9, "-" and "." kept and every other byte written as %XX
    /// (uppercase hex). The result is ASCII, reversible, never starts with "_" and never equals `profileRecordName`. Nil when it would
    /// be empty or longer than 255 characters: CloudKit throws an exception (a crash) for such names, so the word stays on this device.
    static func recordName(forLemma lemma: String) -> String? {
        let hex = Array("0123456789ABCDEF".utf8)
        var name: [UInt8] = []
        for byte in lemmaKey(lemma).utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."):
                name.append(byte)
            default:
                name += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
            }
            if name.count > 255 { return nil }
        }
        return name.isEmpty ? nil : String(decoding: name, as: UTF8.self)
    }

    /// The word key a record name stands for; nil for any name `recordName(forLemma:)` does not produce.
    static func lemma(fromRecordName name: String) -> String? {
        func digit(_ byte: UInt8?) -> UInt8? {
            switch byte {
            case let b? where b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"): b - UInt8(ascii: "0")
            case let b? where b >= UInt8(ascii: "A") && b <= UInt8(ascii: "F"): b - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        var bytes: [UInt8] = []
        var iterator = name.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%") {
                guard let high = digit(iterator.next()), let low = digit(iterator.next()) else { return nil }
                bytes.append(high << 4 | low)
            } else {
                bytes.append(byte)
            }
        }
        guard let lemma = String(validating: bytes, as: UTF8.self), recordName(forLemma: lemma) == name else { return nil }
        return lemma
    }

    /// The times a record from iCloud may carry, in Unix ms. This app never sends 0 or less (0 marks the placeholder level) nor
    /// anything near 10^15 (over 30,000 years from 1970), so a record outside this range did not come from it and is ignored. The
    /// upper bound also keeps the local REAL-seconds column exact to the millisecond; a value near Int64.max would read back as
    /// more than Int64 holds.
    static let validTimestamps: ClosedRange<Int64> = 1...1_000_000_000_000_000

    /// A date as whole Unix milliseconds. Every stored and synced timestamp goes through this, so a record that comes back from
    /// iCloud compares equal to the local value it was made from.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The timestamp for a local change: the requested time, but always after the value it replaces (`previous`), so a change made
    /// after seeing a value wins over it even when another device's clock runs ahead. Always at least 1: 0 marks the placeholder level.
    static func nextTimestamp(_ requested: Int64, after previous: Int64?) -> Int64 {
        max(requested, (previous ?? 0) + 1)
    }

    enum Resolution: Sendable, Hashable {
        case adoptRemote, keepLocal, echo
    }

    /// Last writer wins by `updatedAt`; equal timestamps with equal content are this device's own write coming back.
    static func resolve(local: SyncedValue, remote: SyncedValue) -> Resolution {
        if remote.updatedAt != local.updatedAt { return remote.updatedAt > local.updatedAt ? .adoptRemote : .keepLocal }
        if remote.content == local.content { return .echo }
        return remote.content > local.content ? .adoptRemote : .keepLocal
    }

    /// Which rules an event runs, in order, in one transaction. Nothing else ever deletes synced data.
    static func rules(for event: SyncEvent) -> [SyncRule] {
        switch event {
        case .signOut: [.forgetAccountData]
        case .switchAccounts, .firstEnable: [.forgetAccountData, .mergeAll]
        case .signIn, .zoneDeleted: [.mergeAll]
        case .zonePurged, .encryptedDataReset, .userDeletedZone: [.resetSyncedData]
        }
    }
}
