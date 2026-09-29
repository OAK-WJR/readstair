import Foundation
import Synchronization
import Testing
@testable import ReadStairCore

// Shared helpers for the iCloud sync tests (U-SYNC-*, U-STA-002, P-SYNC-001). Records from iCloud are plain SyncRecord values here:
// the store never sees CloudKit types, so no test needs an iCloud account, a container or a sync engine.

/// A fixed "now" in Unix milliseconds (2027-01-15 08:00:00 UTC), far from 0, which marks the placeholder level.
let t0: Int64 = 1_800_000_000_000

/// The date of a Unix millisecond timestamp, computed the way the store stores it, so dates compare exactly.
func dateAt(_ ms: Int64) -> Date {
    Date(timeIntervalSince1970: Double(ms) / 1000)
}

/// Records what local writes ask the sync engine to register, the way WordSync's observer would.
final class EffectsLog: Sendable {
    private let entries = Mutex<[SyncEffects]>([])

    var all: [SyncEffects] { entries.withLock { $0 } }

    /// Installs this log as the store's observer; returns what was pending at that moment.
    @discardableResult
    func observe(_ store: BookStore) async throws -> SyncEffects {
        try await store.observeLocalWrites { effects in self.entries.withLock { $0.append(effects) } }
    }
}

/// A word record as another device (or iCloud) would send it.
func remoteWord(_ lemma: String, _ state: WordState = .known, source: WordEntry.Source = .card, band: Int? = 5, at updatedAt: Int64,
                sentence: String? = nil, systemFields: Data = Data([1])) -> SyncRecord {
    // A codec that fails here makes the expectations fail instead of crashing the test process
    SyncRecord(name: SyncRules.recordName(forLemma: lemma) ?? "<no record name>", systemFields: systemFields,
               value: .word(SyncedWord(lemma: SyncRules.lemmaKey(lemma), state: state, source: source, band: band, updatedAt: updatedAt,
                                       firstSentence: sentence)))
}

/// The level record as another device would send it.
func remoteProfile(level: Int, at updatedAt: Int64, systemFields: Data = Data([2])) -> SyncRecord {
    SyncRecord(name: "Profile", systemFields: systemFields, value: .profile(SyncedProfile(level: level, updatedAt: updatedAt)))
}

/// iCloud accepted the record sent for `updatedAt`: it now has system fields and, if nothing changed meanwhile, nothing pending.
func confirm(_ store: BookStore, _ name: String, at updatedAt: Int64, systemFields: Data = Data([9])) async throws {
    _ = try await store.applySent([.saved(recordName: name, systemFields: systemFields, updatedAt: updatedAt)])
}

/// One syncRecord row as the tests see it: the archived system fields and the pending timestamp in milliseconds.
struct SyncRowSnapshot: Equatable {
    var systemFields: Data?
    var pendingAt: Int64?

    init(_ systemFields: Data?, _ pendingAt: Int64?) {
        self.systemFields = systemFields
        self.pendingAt = pendingAt
    }
}

/// Every syncRecord row, by record name, read through a separate connection (committed state only).
func syncRows(_ root: URL) throws -> [String: SyncRowSnapshot] {
    var rows: [String: SyncRowSnapshot] = [:]
    for row in try inspect(root, "SELECT recordName, systemFields, pendingAt FROM syncRecord") {
        guard let name = row["recordName"].string else { continue }
        rows[name] = SyncRowSnapshot(row["systemFields"].data, row["pendingAt"].milliseconds)
    }
    return rows
}

/// A whole table, row by row, columns in schema order, sorted by the first column: for "identical before and after" checks.
func dump(_ root: URL, _ table: String) throws -> [[SQLValue]] {
    let columns = try inspect(root, "PRAGMA table_info(\(table))").compactMap { $0["name"].string }
    return try inspect(root, "SELECT * FROM \(table) ORDER BY 1").map { row in columns.map { row[$0] } }
}

/// Installs triggers counting every inserted, updated or deleted row of `tables` (call once per database). The returned reader gives
/// a count for every listed table, 0 included, so a test can assert that nothing at all was written.
func auditWrites(_ store: BookStore, _ root: URL, _ tables: [String]) async throws -> () throws -> [String: Int] {
    var sql = "CREATE TABLE writeAudit (tbl TEXT);\n"
    for table in tables {
        for event in ["INSERT", "UPDATE", "DELETE"] {
            sql += "CREATE TRIGGER audit_\(table)_\(event) AFTER \(event) ON \(table) BEGIN INSERT INTO writeAudit VALUES ('\(table)'); END;\n"
        }
    }
    try await store.execute(sql)
    return {
        var counts = Dictionary(uniqueKeysWithValues: tables.map { ($0, 0) })
        for row in try inspect(root, "SELECT tbl, COUNT(*) AS n FROM writeAudit GROUP BY tbl") {
            if let table = row["tbl"].string, let count = row["n"].int { counts[table] = count }
        }
        return counts
    }
}
