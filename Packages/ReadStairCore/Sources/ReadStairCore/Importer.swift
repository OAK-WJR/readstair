import CoreGraphics
import Foundation

/// Import and recognition queue. Page state lives in the database (pending → recognizing → recognized / failed), so the queue
/// resumes after the process is killed at any point (`BookStore.init` puts recognizing pages back to pending).
public actor Importer {
    public typealias Recognizer = @Sendable (CGImage) async throws -> PageText

    /// Free space required before importing: 1 MB per page (a page image is about 0.4 MB; the rest covers results and headroom).
    static let bytesPerPage: Int64 = 1 << 20

    nonisolated let store: BookStore
    private let recognizer: Recognizer
    private let concurrency: Int
    private let timeout: Duration
    private let availableCapacity: @Sendable () -> Int64?
    private var isDraining = false
    private var drainAgain = false

    /// - Parameters:
    ///   - recognizer: Page image → recognition result. Defaults to Vision whole-page recognition; tests inject a fake.
    ///   - concurrency: How many pages to recognize at once; defaults to `defaultConcurrency` (based on physical memory).
    ///   - timeout: Time after which a page counts as failed.
    ///   - availableCapacity: Free disk space in bytes, nil if unknown; injectable for tests.
    public init(store: BookStore,
                recognizer: @escaping Recognizer = { try await Recognition.page(from: $0) },
                concurrency: Int = Importer.defaultConcurrency,
                timeout: Duration = .seconds(30),
                availableCapacity: (@Sendable () -> Int64?)? = nil) {
        self.store = store
        self.recognizer = recognizer
        self.concurrency = max(1, concurrency)
        self.timeout = timeout
        let path = store.root.path(percentEncoded: false)
        self.availableCapacity = availableCapacity ?? {
            // A fresh URL every time: a URL caches resource values, so reusing one would keep reporting the first reading
            try? URL(filePath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
    }

    public static var defaultConcurrency: Int { concurrency(physicalMemory: ProcessInfo.processInfo.physicalMemory) }

    /// Devices below the 6 GB class recognize one page at a time, others two (each recognition takes roughly 40 MB).
    /// The cut is halfway between the 4 GB and 6 GB classes because the reported physical memory can be a little below nominal.
    static func concurrency(physicalMemory: UInt64) -> Int {
        physicalMemory < 5 << 30 ? 1 : 2
    }

    /// Saves `count` pages into a book (image files written, pages inserted), fetching one page at a time so only one is in memory.
    /// A page with `text` (a typeset electronic book, whose words and boxes are known) is saved as recognized with that text and
    /// never queued; a page without is saved as pending. A page's `chapter` is saved with the page, so a cut or resumed import never
    /// leaves a chapter without its page. `page(i)` returning nil means that page could not be read and is skipped. Checks free disk
    /// space first; on cancellation stops at the current page and keeps the pages already saved. Recognition is not done here: call
    /// `drain()` afterwards.
    /// - Returns: The number of pages actually saved.
    @discardableResult
    public nonisolated func importPages(count: Int, into bookID: UUID,
                                        page: @Sendable (Int) async -> ImportPage?) async throws(StoreError) -> Int {
        let required = Int64(count) * Self.bytesPerPage
        if let available = availableCapacity(), available < required {
            throw .insufficientDisk(required: required, available: available)
        }
        let indices = try await store.reserveIndices(in: bookID, count: count)
        var imported = 0
        for (offset, index) in indices.enumerated() {
            guard !Task.isCancelled else { break }
            guard let page = await page(offset) else { continue }
            let pageID = UUID()
            do {
                let size = try await store.writeImages(page.image, bookID: bookID, pageID: pageID)
                try await store.insertPage(id: pageID, bookID: bookID, index: index, width: size.width, height: size.height,
                                           text: page.text, chapter: page.chapter)
            } catch {
                // No image may stay on disk without a row (the launch sweep catches anything this misses). If the book was deleted
                // meanwhile, a failed write reports that rather than the file error it caused.
                store.removeImages(bookID: bookID, pageID: pageID)
                throw (try? await store.bookExists(bookID)) == false ? .bookNotFound : error
            }
            imported += 1
        }
        return imported
    }

    /// Recognizes every pending page and returns when the queue is empty, running at most `concurrency` pages at once.
    /// Call it from one long-lived task (app level, not a view's `.task`): a call made while a run is in progress only asks that run
    /// for another pass (to pick up newly imported pages) and returns at once, so if the running call is then cancelled, those pages
    /// stay pending until the next `drain()` or launch. A failing page does not throw (the failure is recorded on the page); a full
    /// disk or a database error stops the run and throws, leaving unfinished pages queued. If the caller's task is cancelled, in-flight
    /// pages are requeued without counting an attempt once their recognizer gives up (a result that still arrives is kept).
    public func drain() async throws(StoreError) {
        guard !isDraining else {
            drainAgain = true
            return
        }
        isDraining = true
        defer { isDraining = false }
        repeat {
            drainAgain = false
            try await drainOnce()
        } while drainAgain && !Task.isCancelled
    }

    private func drainOnce() async throws(StoreError) {
        var failure: StoreError?
        await withTaskGroup(of: StoreError?.self) { group in
            var running = 0
            while true {
                while failure == nil, !Task.isCancelled, running < concurrency {
                    let page: Page?
                    do throws(StoreError) {
                        page = try await store.claimNextPending()
                    } catch {
                        failure = error
                        break
                    }
                    guard let page else { break }
                    group.addTask { [store, recognizer, timeout] in
                        await Self.recognize(page, store: store, recognizer: recognizer, timeout: timeout)
                    }
                    running += 1
                }
                guard running > 0 else { break }
                let result = await group.next()
                running -= 1
                if case let error?? = result, failure == nil {
                    failure = error
                    group.cancelAll()
                }
            }
        }
        if let failure { throw failure }
    }

    /// Processes one claimed page: load the image → recognize → store the outcome. Returns a store error that must stop the queue.
    /// At the timeout the page is counted as failed and requeued, but this slot stays taken until the recognizer really returns
    /// (Vision cannot be interrupted), so no more than `concurrency` recognitions are ever in memory; a late result is still kept.
    private static func recognize(_ page: Page, store: BookStore, recognizer: @escaping Recognizer,
                                  timeout: Duration) async -> StoreError? {
        let url = store.imageURL(of: page)
        do throws(StoreError) {
            guard let image = await PageImageFile.run({ PageImageFile.load(url) }) else {
                try await store.failRecognition(page, reason: "unreadableImage")
                return nil
            }
            // The clock starts once the image is loaded: waiting for the image queue behind an import is not the page's fault
            let deadline = Task {
                try await Task.sleep(for: timeout)
                try await store.failRecognition(page, reason: "timeout")
            }
            defer { deadline.cancel() }
            let text: PageText
            do {
                // Cancelling the queue also stops the clock, so a recognizer that outlives the timeout is not counted as a failure
                text = try await withTaskCancellationHandler { try await recognizer(image) } onCancel: { deadline.cancel() }
            } catch {
                if Task.isCancelled {
                    try await store.releaseRecognition(page)
                } else {
                    try await store.failRecognition(page, reason: String(describing: error))
                }
                return nil
            }
            try await store.finishRecognition(page, text: text)
            return nil
        } catch {
            try? await store.releaseRecognition(page)
            return error
        }
    }
}
