#if DEBUG
import CloudKit
import Foundation
import OSLog
import Synchronization

// Debug builds only: a one-line summary of every sync engine event, which every WordSync logs, and the device self-test of iCloud
// sync that the app runs on request.

extension WordSync {
    static let debugLog = Logger(subsystem: "app.readstair", category: "sync")

    /// The event in a line, plus one line per error code of failed saves: counts and codes only, never a word.
    static func summary(of event: CKSyncEngine.Event) -> [String] {
        switch event {
        case .stateUpdate(let update):
            return ["stateUpdate \((try? JSONEncoder().encode(update.stateSerialization))?.count ?? 0) bytes"]
        case .accountChange(let change):
            switch change.changeType {
            case .signIn: return ["accountChange signIn"]
            case .signOut: return ["accountChange signOut"]
            case .switchAccounts: return ["accountChange switchAccounts"]
            @unknown default: return ["accountChange unknown"]
            }
        case .fetchedDatabaseChanges(let changes):
            return ["fetchedDatabaseChanges \(changes.modifications.count) zones changed, \(changes.deletions.count) deleted"]
                + changes.deletions.map { "zoneDeleted \($0.zoneID.zoneName) \($0.reason)" }
        case .fetchedRecordZoneChanges(let changes):
            return ["fetchedRecordZoneChanges \(changes.modifications.count) saved, \(changes.deletions.count) deleted"]
        case .sentDatabaseChanges(let sent):
            return ["sentDatabaseChanges \(sent.savedZones.count) zones saved"]
                + failures("zoneSaveFailed", sent.failedZoneSaves.map(\.error.code))
        case .sentRecordZoneChanges(let sent):
            return ["sentRecordZoneChanges \(sent.savedRecords.count) saved"]
                + failures("recordSaveFailed", sent.failedRecordSaves.map(\.error.code))
        case .willFetchChanges: return ["willFetchChanges"]
        case .willFetchRecordZoneChanges: return ["willFetchRecordZoneChanges"]
        case .didFetchRecordZoneChanges(let done):
            return ["didFetchRecordZoneChanges" + (done.error.map { " \(name(of: $0.code))" } ?? "")]
        case .didFetchChanges: return ["didFetchChanges"]
        case .willSendChanges: return ["willSendChanges"]
        case .didSendChanges: return ["didSendChanges"]
        @unknown default: return ["unknown event"]
        }
    }

    /// "<label> <code> <count>" for each error code, e.g. "recordSaveFailed serverRecordChanged 2".
    private static func failures(_ label: String, _ codes: [CKError.Code]) -> [String] {
        Dictionary(grouping: codes.map(name(of:)), by: { $0 }).map { "\(label) \($0.key) \($0.value.count)" }.sorted()
    }

    private static func name(of code: CKError.Code) -> String {
        switch code {
        case .serverRecordChanged: "serverRecordChanged"
        case .unknownItem: "unknownItem"
        case .zoneNotFound: "zoneNotFound"
        case .userDeletedZone: "userDeletedZone"
        case .quotaExceeded: "quotaExceeded"
        default: "CKError \(code.rawValue)"
        }
    }
}

/// The device checks of iCloud sync, I-SYNC-001 to I-SYNC-006, against the signed-in account's iCloud development environment.
/// Stores in a temporary folder, each with its own WordSync, stand in for devices on one account: the development environment allows
/// several engines on one database (production does not). Their engines sync only when told to, so every step happens in order.
///
/// Only for a DEBUG app built with the iCloud switch: without the iCloud entitlement CloudKit raises an exception that ends the
/// process, so no unit test may call this. It checks for the remote-notification background mode, which the same switch adds, and
/// does nothing without it. It writes test words and a level to the development environment; I-SYNC-004 and the cleanup at the end
/// delete the app's zone, so no test word or level stays behind. The app's own engine later sees a zone the app deleted, uploads
/// everything its store holds again and loses nothing.
public enum SyncSelfTest {
    /// Runs every check and reports a line for each ("[I-SYNC-001] PASS …" or "[I-SYNC-001] FAIL …"), then a summary line. Returns
    /// whether every check passed and the zone was deleted afterwards. The zone is not deleted first: this run's words carry their own
    /// prefix, and the levels it writes are stamped now or later, so they win over a level already there.
    public static func run(report: @escaping @MainActor @Sendable (String) -> Void) async -> Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        guard modes.contains("remote-notification") else {
            await report("[I-SYNC] FAIL This build has no remote-notification background mode: build it with READSTAIR_ICLOUD=YES.")
            return false
        }
        let container = CKContainer(identifier: WordSync.containerIdentifier)
        let folder = FileManager.default.temporaryDirectory.appending(path: "ReadStairSyncSelfTest-\(UUID().uuidString)",
                                                                      directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let run: Run
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                await report("[I-SYNC] FAIL iCloud account status \(status.rawValue) (1 is available): sign in to iCloud on this device.")
                return false
            }
            run = try await Run(folder: folder, database: container.privateCloudDatabase)
        } catch {
            await report("[I-SYNC] FAIL Setup: \(error)")
            return false
        }
        // I-SYNC-004 deletes the zone, so it runs last
        let checks: [(String, () async throws -> String)] = [
            ("I-SYNC-001", run.oneWay), ("I-SYNC-002", run.conflicts), ("I-SYNC-003", run.relaunch),
            ("I-SYNC-006", run.failedStep), ("I-SYNC-005", run.bulk), ("I-SYNC-004", run.zoneDeleted),
        ]
        var failed: [String] = []
        for (id, check) in checks {
            let start = ContinuousClock.now
            do {
                let detail = try await check()
                await report("[\(id)] PASS \(detail) (\(seconds(start.duration(to: .now))))")
            } catch {
                failed.append(id)
                await report("[\(id)] FAIL \(error)")
            }
        }
        do {
            try await deleteZone(in: container.privateCloudDatabase)
        } catch {
            failed.append("cleanup")
            await report("[I-SYNC] FAIL Cleanup: \(error). Delete the Vocab zone in CloudKit Console (development).")
        }
        let passed = checks.count - failed.filter { $0 != "cleanup" }.count
        await report(failed.isEmpty ? "[I-SYNC] PASSED \(passed) of \(checks.count)"
                                    : "[I-SYNC] FAILED \(failed.joined(separator: ", ")); \(passed) of \(checks.count) passed")
        return failed.isEmpty
    }

    /// Deletes the app's zone and with it every record of the account's word list; no zone is not an error.
    static func deleteZone(in database: CKDatabase) async throws {
        let results = try await database.modifyRecordZones(saving: [], deleting: [WordSync.zoneID])
        if case .failure(let error)? = results.deleteResults[WordSync.zoneID], (error as? CKError)?.code != .zoneNotFound {
            throw error
        }
    }

    static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f s", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}

// MARK: - Checks

/// One run: the devices A and B that most checks share, the events of every engine, and the prefix of this run's words.
private final class Run {
    let folder: URL
    let database: CKDatabase
    let log: EventLog
    /// Every word of this run starts with it, so words that the app or an earlier run left in iCloud are never compared.
    let prefix = "selftest-\(UUID().uuidString.prefix(6).lowercased())-"
    var a: Device
    var b: Device

    init(folder: URL, database: CKDatabase) async throws {
        let log = EventLog()
        self.folder = folder
        self.database = database
        self.log = log
        a = try await Device.start("A", in: folder, log: log)
        b = try await Device.start("B", in: folder, log: log)
    }

    /// I-SYNC-001: A writes 10 words and sends them; B fetches the same 10, and neither has anything left to send.
    func oneWay() async throws -> String {
        let group = prefix + "one-"
        for i in 0..<10 {
            try await a.store.upsertWord(WordEntry(lemma: group + "\(i)", state: i.isMultiple(of: 2) ? .learning : .known,
                                                   source: i.isMultiple(of: 3) ? .lookup : .card, band: i + 1,
                                                   firstSentence: "Sentence \(i) of the self-test."))
        }
        try await a.send()
        try await b.fetch()
        let sent = try await a.words(group)
        let received = try await b.words(group)
        try require(sent.count == 10, "A has \(sent.count) of its 10 words")
        try require(received == sent, "B has \(received.count) of the 10 words, or other values: \(received.values.sorted())")
        let idleA = try await a.idle(), idleB = try await b.idle()
        try require(idleA && idleB, "changes are still pending after sending and fetching")
        return "10 words from A to B"
    }

    /// I-SYNC-002: A changes a word, then B changes it a second later, in four orders of sending and fetching; then the level the
    /// same way. Both devices end with B's change. In the first two orders one device sends over the other's change, which iCloud
    /// answers with serverRecordChanged.
    func conflicts() async throws -> String {
        let start = log.count
        let a = self.a, b = self.b
        let orders: [[() async throws -> Void]] = [
            [a.send, b.send, a.fetch, b.fetch],
            [b.send, a.send, a.fetch, b.fetch],
            [a.send, b.fetch, b.send, a.fetch],
            [b.send, a.fetch, a.send, b.fetch],
        ]
        for (k, order) in orders.enumerated() {
            let lemma = prefix + "two-\(k)"
            try await a.store.upsertWord(WordEntry(lemma: lemma, state: .learning, source: .lookup, band: 4, firstSentence: "Two."))
            try await a.send()
            try await b.fetch()
            let now = Date.now
            try await a.store.upsertWord(WordEntry(lemma: lemma, state: .known, source: .card, band: 4, updatedAt: now))
            try await b.store.upsertWord(WordEntry(lemma: lemma, state: .learning, source: .card, band: 6, updatedAt: now + 1))
            let expected = try await b.words(lemma)
            for step in order { try await step() }
            try require(try await settle([a, b]), "word, order \(k + 1): changes still pending after three rounds")
            let onA = try await a.words(lemma), onB = try await b.words(lemma)
            try require(onA == expected && onB == expected,
                        "word, order \(k + 1): A \(onA.values), B \(onB.values), expected \(expected.values)")
        }
        try await a.store.setLevel(2)
        try await a.send()
        try await b.fetch()
        for (k, order) in orders.enumerated() {
            // Ten seconds apart per order, so each order's times are later than the one before
            let time = Date.now.addingTimeInterval(Double(k) * 10)
            try await a.store.setLevel(4 + k, at: time)
            try await b.store.setLevel(10 + k, at: time + 1)
            let expected = try await b.level()
            for step in order { try await step() }
            try require(try await settle([a, b]), "level, order \(k + 1): changes still pending after three rounds")
            let onA = try await a.level(), onB = try await b.level()
            try require(onA == expected && onB == expected,
                        "level, order \(k + 1): A \(onA ?? "none"), B \(onB ?? "none"), expected \(expected ?? "none")")
        }
        let conflicts = total("recordSaveFailed serverRecordChanged", in: log.since(start))
        try require(conflicts >= 4, "\(conflicts) serverRecordChanged answers; orders 1 and 2 give one each for the word and the level")
        return "4 orders for a word and for the level; \(conflicts) serverRecordChanged merged"
    }

    /// I-SYNC-003: A changes a word and is killed before sending it; A opened again from its saved engine state still sends it, and
    /// B receives it.
    func relaunch() async throws -> String {
        let lemma = prefix + "three-0"
        let saved = try await a.store.loadEngineState()
        try require(saved != nil, "A has never saved an engine state")
        try await a.store.upsertWord(WordEntry(lemma: lemma, state: .known, source: .card, band: 7, firstSentence: "Killed first."))
        a = try await a.relaunched(log: log)
        try await a.send()
        try await b.fetch()
        let sent = try await a.words(lemma)
        let received = try await b.words(lemma)
        try require(sent.count == 1 && received == sent, "B has \(received.values), A has \(sent.values)")
        return "the word written before the kill reached B"
    }

    /// I-SYNC-006: a store step that fails (as on a full disk) halts sync for the run: B applies nothing and saves no engine state,
    /// and B opened again gets the same change once more from its last saved state. Also lists the first events of a new engine:
    /// whether it signals a sign-in, and whether a state update comes before it.
    func failedStep() async throws -> String {
        let lemma = prefix + "six-0"
        try await a.store.upsertWord(WordEntry(lemma: lemma, state: .learning, source: .lookup, band: 8, firstSentence: "Second try."))
        try await a.send()
        let saved = try await b.store.loadEngineState()
        let start = log.count
        try await b.store.execute("CREATE TRIGGER selfTestFailure BEFORE INSERT ON wordEntry BEGIN SELECT RAISE(ABORT, 'x'); END;")
        try await b.fetch()
        try await b.store.execute("DROP TRIGGER selfTestFailure;")
        let halted = log.since(start)
        let applied = try await b.words(lemma)
        let savedSince = try await b.store.loadEngineState()
        try require(halted.contains { $0.hasPrefix("B fetchedRecordZoneChanges") }, "B fetched nothing: \(halted)")
        try require(applied.isEmpty, "B applied the word although its store step failed")
        try require(savedSince == saved, "B saved an engine state after the failed step")
        b = try await b.relaunched(log: log)
        try await b.fetch()
        let sent = try await a.words(lemma)
        let received = try await b.words(lemma)
        try require(!sent.isEmpty && received == sent, "B opened again did not get the word from its last saved state")

        let fresh = log.count
        let n = try await Device.start("N", in: folder, log: log)
        try await n.fetch()
        let first = log.since(fresh).filter { $0.hasPrefix("N ") }.map { $0.dropFirst(2) }
        let dropped = total("B stateUpdate", in: halted, counting: false)
        return "\(dropped) state updates not saved while halted; the change came again after relaunch. "
            + "First events of a new engine: \(first.joined(separator: ", "))"
    }

    /// I-SYNC-005: a first upload of 2,000 words (a device that had them before sync) and a full fetch on a new device; 100 of them
    /// sent once more without system fields by a third device; and the engine state with 20,000 changes waiting, never sent.
    func bulk() async throws -> String {
        let group = prefix + "bulk-"
        let time = SyncRules.milliseconds(.now)
        var clock = ContinuousClock.now
        let g = try await Device.start("G", in: folder, log: log, preload: Self.preload(group, count: 2_000, at: time))
        let enable = SyncSelfTest.seconds(clock.duration(to: .now))
        clock = .now
        try await g.send()
        let upload = SyncSelfTest.seconds(clock.duration(to: .now))
        try require(try await g.idle(), "G still has words to send after sending")
        clock = .now
        let h = try await Device.start("H", in: folder, log: log)
        try await h.fetch()
        let fetch = SyncSelfTest.seconds(clock.duration(to: .now))
        let sent = try await g.words(group)
        let fetched = try await h.words(group)
        try require(sent.count == 2_000 && fetched == sent, "H fetched \(fetched.count) of the 2,000 words, or other values")

        let start = log.count
        let i = try await Device.start("I", in: folder, log: log, preload: Self.preload(group, count: 100, at: time))
        try require(try await settle([i]), "I still has words to send after three rounds")
        let merged = try await i.words(group)
        try require(merged == sent, "I has \(merged.count) of the 2,000 words after merging, or other values")
        let conflicts = total("I recordSaveFailed serverRecordChanged", in: log.since(start))

        clock = .now
        let f = try await Device.start("F", in: folder, log: log, preload: Self.preload(prefix + "wait-", count: 20_000, at: time))
        let enableLarge = SyncSelfTest.seconds(clock.duration(to: .now))
        // The engine reports its state asynchronously: wait until the saved state stops changing (at most 30 s)
        var state: Data?
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            let latest = try await f.store.loadEngineState()
            if latest != nil && latest == state { break }
            state = latest
        }
        var waiting = "no engine state saved within 30 s"
        if let state {
            clock = .now
            try await f.store.saveEngineState(state)
            waiting = "engine state \(state.count / 1024) KB, saved in \(SyncSelfTest.seconds(clock.duration(to: .now)))"
        }
        return "2,000 words: first enable \(enable), upload \(upload), fetch on a new device \(fetch); "
            + "100 sent again without system fields: \(conflicts) serverRecordChanged, merged; "
            + "20,000 waiting: first enable \(enableLarge), \(waiting)"
    }

    /// I-SYNC-004: the app's zone is deleted from outside, as another device of this app could do. A and B both learn that the app
    /// deleted it and upload everything again; nothing is lost on either device or in iCloud, where a new device C finds it all.
    func zoneDeleted() async throws -> String {
        let words = try await a.words(prefix)
        let level = try await a.level()
        try await SyncSelfTest.deleteZone(in: database)
        let start = log.count
        try await a.fetch()
        try await b.fetch()
        let seen = log.since(start)
        try require(seen.contains("A zoneDeleted Vocab deleted") && seen.contains("B zoneDeleted Vocab deleted"),
                    "A and B did not both get the zone deletion with reason deleted: \(seen)")
        try require(try await settle([a, b]), "changes still pending after three rounds")
        let onA = try await a.words(prefix), onB = try await b.words(prefix)
        try require(onA == words && onB == words, "a device lost or changed words: A \(onA.count), B \(onB.count) of \(words.count)")
        let c = try await Device.start("C", in: folder, log: log)
        try await c.fetch()
        let inCloud = try await c.words(prefix)
        let levelInCloud = try await c.level()
        try require(inCloud == words && levelInCloud == level,
                    "iCloud has \(inCloud.count) of \(words.count) words, level \(levelInCloud ?? "none")")
        return "\(words.count) words and the level uploaded again by A and B"
    }

    /// Sends and fetches on every device until none has anything left to send; false after three rounds.
    private func settle(_ devices: [Device]) async throws -> Bool {
        for _ in 0..<3 {
            for device in devices { try await device.send() }
            for device in devices { try await device.fetch() }
            var idle = true
            for device in devices {
                if try await !device.idle() { idle = false }
            }
            if idle { return true }
        }
        return false
    }

    /// `count` learning words "<prefix>00000"… with one timestamp, written straight into the table, as a version without sync
    /// would have left them.
    private static func preload(_ prefix: String, count: Int, at time: Int64) -> String {
        """
        WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < \(count - 1))
        INSERT INTO wordEntry (lemma, state, source, band, updatedAt)
        SELECT '\(prefix)' || printf('%05d', i), 'learning', 'lookup', 5, \(Double(time) / 1000) FROM n;
        """
    }
}

/// One simulated device: a store of its own and a WordSync whose engine syncs only when told to.
private struct Device: Sendable {
    let name: String
    let folder: URL
    let store: BookStore
    let sync: WordSync

    /// Opens (or creates) the store `folder/name` and starts sync on it. `preload` is SQL run on the store first.
    static func start(_ name: String, in folder: URL, log: EventLog, preload: String? = nil) async throws -> Device {
        let store = try BookStore(root: folder.appending(path: name, directoryHint: .isDirectory))
        if let preload { try await store.execute(preload) }
        let sync = WordSync(store: store, testHook: log.hook(name))
        try await sync.start()
        return Device(name: name, folder: folder, store: store, sync: sync)
    }

    /// The same store opened again with a new engine from its saved state, as after the app was killed.
    func relaunched(log: EventLog) async throws -> Device {
        try await Device.start(name, in: folder, log: log)
    }

    func send() async throws { try await sync.sendChanges() }
    func fetch() async throws { try await sync.fetchChanges() }
    func idle() async throws -> Bool { try await store.pendingEffects() == .nothing }

    /// The words whose lemma starts with `prefix`, as "state source band updatedAt(ms) sentence" by lemma.
    func words(_ prefix: String) async throws -> [String: String] {
        var words: [String: String] = [:]
        for entry in try await store.wordEntries() where entry.lemma.hasPrefix(prefix) {
            words[entry.lemma] = "\(entry.state.rawValue) \(entry.source.rawValue) \(entry.band.map(String.init) ?? "-") "
                + "\(SyncRules.milliseconds(entry.updatedAt)) \(entry.firstSentence ?? "-")"
        }
        return words
    }

    /// The level as "level updatedAt(ms)"; nil without one.
    func level() async throws -> String? {
        try await store.profile().map { "\($0.level) \(SyncRules.milliseconds($0.updatedAt))" }
    }
}

/// Every engine's event summaries in delivery order, as "<device> <summary>".
private final class EventLog: Sendable {
    private let lines = Mutex<[String]>([])

    func hook(_ device: String) -> @Sendable (String) -> Void {
        { line in self.lines.withLock { $0.append("\(device) \(line)") } }
    }

    var count: Int { lines.withLock { $0.count } }

    func since(_ start: Int) -> [String] {
        lines.withLock { Array($0[start...]) }
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw Failure(description: message()) }
}

/// The lines that contain `text`: the sum of their last numbers, or with `counting` false how many there are.
private func total(_ text: String, in lines: [String], counting: Bool = true) -> Int {
    let matching = lines.filter { $0.contains(text) }
    return counting ? matching.compactMap { $0.split(separator: " ").last.flatMap { Int($0) } }.reduce(0, +) : matching.count
}
#endif
