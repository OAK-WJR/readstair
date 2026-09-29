import Foundation
import Synchronization
import Testing
@testable import ReadStairCore

// The recognition loop (the only caller of Importer.drain; supplementary cases) and the undo slot (the one pending undoable change;
// U-STA-001, with the card-open rule in S-APP-Rules.swift). Time is controlled with gates and a manual clock; a short real wait is
// used only to show that nothing more happens.

/// Time for work that should not happen to show up, were it about to.
private func settle() async throws {
    try await Task.sleep(for: .milliseconds(100))
}

/// Records whether each drain call ran in a cancelled task, in call order.
private final class CancelLog: Sendable {
    private let values = Mutex<[Bool]>([])
    var cancelled: [Bool] { values.withLock { $0 } }
    func record() { values.withLock { $0.append(Task.isCancelled) } }
}

@MainActor
private final class ErrorLog {
    var errors: [StoreError] = []
}

@Suite("Supplementary: RecognitionLoop", .timeLimit(.minutes(2)))
@MainActor
struct RecognitionLoopTests {
    @Test("Kicks during a pass coalesce into exactly one follow-up pass, which starts only after the pass returns")
    func coalescing() async throws {
        let drains = CallLog()
        let gate = AsyncGate()
        let loop = RecognitionLoop(drain: {
            defer { drains.end() }
            if drains.begin(0) == 1 { await gate.wait() }
        }, onError: { Issue.record("Unexpected error \($0)") })
        let runner = Task { await loop.run() }
        loop.kick()
        try await waitUntil { await gate.waiting == 1 }
        for _ in 0..<5 { loop.kick() }
        try await settle()
        #expect(drains.calls.count == 1)

        await gate.open()
        try await waitUntil { drains.calls.count == 2 && !loop.isRunningPass }
        try await settle()
        #expect(drains.calls.count == 2)
        #expect(drains.maxRunning == 1)

        loop.kick()
        try await waitUntil { drains.calls.count == 3 && !loop.isRunningPass }
        runner.cancel()
        await runner.value
    }

    @Test("cancelPass cancels only the running pass: a kick meanwhile waits until that pass returns (like Vision, it ignores cancellation), then runs uncancelled")
    func cancelPass() async throws {
        let drains = CallLog()
        let cancels = CancelLog()
        let gate = AsyncGate()
        let loop = RecognitionLoop(drain: {
            defer { drains.end(); cancels.record() }
            if drains.begin(0) == 1 { await gate.wait() }
        }, onError: { Issue.record("Unexpected error \($0)") })
        let runner = Task { await loop.run() }
        loop.kick()
        try await waitUntil { await gate.waiting == 1 }
        loop.cancelPass()
        loop.kick()
        try await settle()
        #expect(drains.calls.count == 1)
        #expect(loop.isRunningPass)

        await gate.open()
        try await waitUntil { drains.calls.count == 2 && !loop.isRunningPass }
        #expect(cancels.cancelled == [true, false])
        #expect(drains.maxRunning == 1)
        runner.cancel()
        await runner.value
    }

    @Test("pause: the running pass finishes, kicks start nothing; resume starts one pass")
    func pauseAndResume() async throws {
        let drains = CallLog()
        let gate = AsyncGate()
        let loop = RecognitionLoop(drain: {
            defer { drains.end() }
            if drains.begin(0) == 1 { await gate.wait() }
        }, onError: { Issue.record("Unexpected error \($0)") })
        let runner = Task { await loop.run() }
        loop.kick()
        try await waitUntil { await gate.waiting == 1 }
        loop.pause()
        loop.kick()
        await gate.open()
        try await waitUntil { !loop.isRunningPass }
        loop.kick()
        try await settle()
        #expect(drains.calls.count == 1)

        loop.resume()
        try await waitUntil { drains.calls.count == 2 && !loop.isRunningPass }
        runner.cancel()
        await runner.value
    }

    @Test("A pass that stops on a store error reports it; the loop goes on and the next kick runs a pass")
    func errorReported() async throws {
        let drains = CallLog()
        let log = ErrorLog()
        let loop = RecognitionLoop(drain: { () throws(StoreError) in
            defer { drains.end() }
            if drains.begin(0) == 1 { throw .diskFull }
        }, onError: { log.errors.append($0) })
        let runner = Task { await loop.run() }
        loop.kick()
        try await waitUntil { log.errors == [.diskFull] && !loop.isRunningPass }
        loop.kick()
        try await waitUntil { drains.calls.count == 2 && !loop.isRunningPass }
        #expect(log.errors == [.diskFull])
        runner.cancel()
        await runner.value
    }

    @Test("Real importer: a page imported while a cancelled pass waits for its recognizer is recognized once that pass returns; no page stays pending and drains never overlap")
    func noStrandedPage() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await makeBook(store, pages: 1)
            let gate = AsyncGate()
            let recognized = CallLog()
            let importer = Importer(store: store, recognizer: { image in
                let number = pageNumber(of: image)
                defer { recognized.end() }
                if recognized.begin(number) == 1, number == 1 { await gate.wait() }
                return fakeText(number)
            }, concurrency: 1)
            let drains = CallLog()
            let loop = RecognitionLoop(drain: { () throws(StoreError) in
                drains.begin(0)
                defer { drains.end() }
                try await importer.drain()
            }, onError: { Issue.record("Unexpected error \($0)") })
            let runner = Task { await loop.run() }

            loop.kick()
            try await waitUntil { await gate.waiting == 1 }
            loop.cancelPass()
            let imported = try await importer.importPages(count: 1, into: book.id) { _ in pageImage(2) }
            #expect(imported == 1)
            loop.kick()
            await gate.open()

            try await waitUntil { try await store.pages(of: book.id).allSatisfy { $0.status == .recognized } && !loop.isRunningPass }
            #expect(recognized.calls == [1, 2])
            #expect(drains.calls.count == 2)
            #expect(drains.maxRunning == 1)
            runner.cancel()
            await runner.value
        }
    }
}

/// A stand-in for `Task.sleep`: each call waits until the test fires it and ignores cancellation, so a timer that outlives its
/// change still wakes up.
private actor ManualClock {
    private var sleepers: [CheckedContinuation<Void, Never>?] = []
    private(set) var durations: [Duration] = []

    var count: Int { sleepers.count }

    func sleep(_ duration: Duration) async {
        durations.append(duration)
        await withCheckedContinuation { sleepers.append($0) }
    }

    /// Ends the `index`-th sleep (from 0).
    func fire(_ index: Int) {
        sleepers[index]?.resume()
        sleepers[index] = nil
    }
}

/// What the undo slot's commit closure did: `settled` is recorded before its first suspension, `written` after the write.
@MainActor
private final class CommitLog {
    var settled: [String] = []
    var written: [String] = []
    var holds = false
}

/// An undo slot over string changes whose commit settles, awaits `write`, then records the write. `write` runs on the main actor,
/// as the app's store call starts there, so a store actor it awaits is reached straight from the main actor.
@MainActor
private func makeSlot(_ clock: ManualClock, _ log: CommitLog,
                      write: @escaping @MainActor (String) async -> Void = { _ in }) -> UndoSlot<String> {
    UndoSlot(sleep: { await clock.sleep($0) }, holdsIndefinitely: { log.holds }, commit: { change in
        log.settled.append(change)
        await write(change)
        log.written.append(change)
    })
}

/// Stands in for the store actor: records the order writes arrive in. The write of "c" then stays open until the gate opens
/// (the actor is free meanwhile, so a later write can arrive).
private actor ArrivalLog {
    private(set) var order: [String] = []
    let gate = AsyncGate()

    func write(_ change: String) async {
        order.append(change)
        if change == "c" { await gate.wait() }
    }
}

@Suite("U-STA UndoSlot", .timeLimit(.minutes(2)))
@MainActor
struct UndoSlotTests {
    @Test("U-STA-001 Timeout: the pending change shows until its 5 s toast times out, then commits")
    func timeout() async throws {
        let clock = ManualClock()
        let log = CommitLog()
        let slot = makeSlot(clock, log)
        slot.propose("c")
        #expect(slot.current == "c")
        try await waitUntil { await clock.count == 1 }
        #expect(await clock.durations == [.seconds(5)])
        #expect(log.settled.isEmpty)

        await clock.fire(0)
        try await waitUntil { log.written == ["c"] }
        #expect(slot.current == nil)
    }

    @Test("U-STA-001 Undo empties the slot and writes nothing, even when the timer wakes up afterwards")
    func undoWritesNothing() async throws {
        let clock = ManualClock()
        let log = CommitLog()
        let slot = makeSlot(clock, log)
        slot.propose("c")
        try await waitUntil { await clock.count == 1 }
        slot.undo()
        #expect(slot.current == nil)

        await clock.fire(0)
        try await settle()
        #expect(log.settled.isEmpty)
        #expect(slot.current == nil)
    }

    @Test("U-STA-001 The next proposal commits the pending change, settled before propose returns; the replaced change's timer never commits the new one")
    func nextProposalCommits() async throws {
        let clock = ManualClock()
        let log = CommitLog()
        let slot = makeSlot(clock, log)
        slot.propose("c")
        try await waitUntil { await clock.count == 1 }
        slot.propose("d")
        #expect(log.settled == ["c"])
        #expect(slot.current == "d")
        try await waitUntil { log.written == ["c"] }

        try await waitUntil { await clock.count == 2 }
        await clock.fire(0)
        try await settle()
        #expect(slot.current == "d")
        #expect(log.settled == ["c"])

        await clock.fire(1)
        try await waitUntil { log.written == ["c", "d"] }
    }

    @Test("U-STA-001 commitNow (leaving the Reader, going to the background) commits the pending change and returns once it is written; with nothing pending it writes nothing")
    func commitNow() async throws {
        let clock = ManualClock()
        let log = CommitLog()
        let slot = makeSlot(clock, log)
        await slot.commitNow()
        #expect(log.settled.isEmpty)

        slot.propose("c")
        await slot.commitNow()
        #expect(log.written == ["c"])
        #expect(slot.current == nil)

        try await waitUntil { await clock.count == 1 }
        await clock.fire(0)
        try await settle()
        #expect(log.settled == ["c"])
    }

    @Test("U-STA-001 VoiceOver or Switch Control is read at propose time: a change proposed while it runs has no timer and waits for another trigger; one proposed without it keeps its timer")
    func holdReadAtPropose() async throws {
        let clock = ManualClock()
        let log = CommitLog()
        let slot = makeSlot(clock, log)
        log.holds = true
        slot.propose("c")
        log.holds = false
        try await settle()
        #expect(await clock.count == 0)
        #expect(slot.current == "c")

        slot.propose("d")
        #expect(log.settled == ["c"])
        try await waitUntil { await clock.count == 1 }
        log.holds = true
        await clock.fire(0)
        try await waitUntil { log.written == ["c", "d"] }
    }

    @Test("U-STA-001 A proposal during a slow commit shows at once; both changes settle synchronously and their writes reach the store in call order")
    func proposeDuringSlowCommit() async throws {
        let clock = ManualClock()
        let log = CommitLog()
        let store = ArrivalLog()
        let slot = makeSlot(clock, log) { await store.write($0) }
        slot.propose("c")
        slot.propose("d")
        #expect(slot.current == "d")
        #expect(log.settled == ["c"])

        let committing = Task.immediate { await slot.commitNow() }
        #expect(log.settled == ["c", "d"])
        #expect(slot.current == nil)
        try await waitUntil { await store.order.count == 2 }
        #expect(await store.order == ["c", "d"])

        await store.gate.open()
        await committing.value
        try await waitUntil { Set(log.written) == ["c", "d"] }
    }
}
