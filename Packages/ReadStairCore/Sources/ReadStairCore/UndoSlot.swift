import Observation

/// The one pending undoable change, shown in the undo toast. A pending change is only held here, never written, so Undo just
/// empties the slot. The change is committed when its toast times out (5 s), when the next change is proposed, and when the app
/// calls `commitNow()` (on leaving the Reader and on going to the background). While VoiceOver or Switch Control runs there is no
/// timeout, so the toast stays reachable; the other triggers still commit.
@MainActor
@Observable
public final class UndoSlot<Change: Sendable> {
    /// The pending change; nil when nothing is pending.
    public private(set) var current: Change?

    private let sleep: @Sendable (Duration) async throws -> Void
    private let holdsIndefinitely: @MainActor () -> Bool
    private let commit: @MainActor (Change) async -> Void
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// - Parameters:
    ///   - sleep: Waits out the toast; tests pass a clock they control.
    ///   - holdsIndefinitely: Whether a new change waits without a timeout (VoiceOver or Switch Control running). Read when the
    ///     change is proposed.
    ///   - commit: Writes a change and handles its failure. Everything before its first `await` runs synchronously as the slot
    ///     lets go of the change: apply the change to what the app shows there, so it never looks undone in between. With the
    ///     store write as that first `await`, writes reach the store in the order the slot let go of the changes.
    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                holdsIndefinitely: @escaping @MainActor () -> Bool,
                commit: @escaping @MainActor (Change) async -> Void) {
        self.sleep = sleep
        self.holdsIndefinitely = holdsIndefinitely
        self.commit = commit
    }

    /// Makes `change` the pending one, committing the change it replaces first.
    public func propose(_ change: Change) {
        commitPending()
        current = change
        guard !holdsIndefinitely() else { return }
        timer = Task { [weak self, sleep] in
            do { try await sleep(.seconds(5)) } catch { return }
            // A timer outlived by its change (undone, replaced or committed early) was cancelled and commits nothing
            guard !Task.isCancelled else { return }
            self?.commitPending()
        }
    }

    /// Drops the pending change without writing anything.
    public func undo() {
        _ = take()
    }

    /// Commits the pending change, if any, and returns once it is written. A write the slot started earlier is already ahead of
    /// it at the store.
    public func commitNow() async {
        guard let change = take() else { return }
        await commit(change)
    }

    /// Commits the pending change, if any, in a task of its own that starts synchronously (see `commit`).
    private func commitPending() {
        guard let change = take() else { return }
        Task.immediate { await self.commit(change) }
    }

    /// Empties the slot and stops its timer; returns the change that was pending.
    private func take() -> Change? {
        timer?.cancel()
        timer = nil
        let change = current
        current = nil
        return change
    }
}
