/// The single long-lived caller of `Importer.drain()`. Each `kick()` asks for a recognition pass; kicks that arrive while a pass
/// runs are coalesced into one follow-up pass. A pass starts only after the previous one has returned, including a cancelled one
/// still waiting for Vision, so `drain()` is never called during a run: such a call only flags the run to go again, which a
/// cancelled run skips, and the pages imported meanwhile would stay pending until the next launch.
@MainActor
public final class RecognitionLoop {
    private let drain: @Sendable () async throws(StoreError) -> Void
    private let onError: @MainActor (StoreError) -> Void
    /// Holds at most one wake: any number of kicks during a pass leave exactly one pass to run after it.
    private let wakes: AsyncStream<Void>
    private let waker: AsyncStream<Void>.Continuation
    private var pass: Task<Result<Void, StoreError>, Never>?
    private var paused = false

    /// - Parameters:
    ///   - drain: One recognition pass: `importer.drain` (a closure literal needs the signature `() throws(StoreError) in`).
    ///   - onError: Called with the error a pass stopped on (a full disk or a database error); the pages stay queued, and the next
    ///     kick resumes them.
    public init(drain: @escaping @Sendable () async throws(StoreError) -> Void,
                onError: @escaping @MainActor (StoreError) -> Void) {
        self.drain = drain
        self.onError = onError
        let (wakes, waker) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.wakes = wakes
        self.waker = waker
    }

    /// Serves kicks until the task running it is cancelled. Start it once, from a task that lives as long as the app; cancelling
    /// that task ends the loop for good, after the running pass returns (the pass itself is not cancelled).
    public func run() async {
        for await _ in wakes {
            guard !paused else { continue }
            let pass = Task { [drain] () async -> Result<Void, StoreError> in
                do throws(StoreError) {
                    try await drain()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            self.pass = pass
            let result = await pass.value
            self.pass = nil
            if case .failure(let error) = result { onError(error) }
        }
    }

    /// Asks for a pass: one starts now if none is running, otherwise one more runs after the current pass.
    public func kick() {
        waker.yield()
    }

    /// Starts no new pass until `resume()`; a pass already running continues. Kicks meanwhile are dropped: `resume()` kicks.
    public func pause() {
        paused = true
    }

    public func resume() {
        paused = false
        kick()
    }

    /// Cancels the running pass only; the loop keeps serving kicks. Its in-flight pages go back to the queue once their recognizer
    /// returns, and no pass starts before then. Safe to call from a background task's expiration handler, which runs on the main
    /// actor.
    public func cancelPass() {
        pass?.cancel()
    }

    /// Whether a pass is running, cancelled or not.
    public var isRunningPass: Bool { pass != nil }
}
