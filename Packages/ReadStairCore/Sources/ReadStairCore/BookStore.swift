import CoreGraphics
import Foundation

public enum StoreError: Error, Equatable {
    /// Pre-import check: not enough free space (`required` bytes needed, `available` free).
    case insufficientDisk(required: Int64, available: Int64)
    /// The disk filled up during a write (SQLITE_FULL / ENOSPC).
    case diskFull
    /// The database was written by a newer app version whose schema this version does not know; refuse to open it rather than risk corrupting it.
    case incompatibleSchema(found: Int, supported: Int)
    case bookNotFound
    case file(String)
    case sqlite(code: Int32, message: String)
}

public struct Book: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var lastPageIndex: Int
}

public struct Page: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable {
        case pending, recognizing, recognized, failed
    }

    public let id: UUID
    public let bookID: UUID
    /// Position in the book (from 0; gaps are possible).
    public var index: Int
    /// Pixel size of the stored page image.
    public var width: Int
    public var height: Int
    public var status: Status
    /// How many times recognition was started (including a run cut short by the process being killed).
    public var attempts: Int
    /// Reason for the latest failure (diagnostic, never shown to the user as is).
    public var error: String?
}

/// The user's explicit state for a word, keyed by lemma: one row per word.
public struct WordEntry: Sendable, Hashable {
    public enum Source: String, Sendable {
        /// The word was tapped and looked up; it goes to the word list automatically.
        case lookup
        /// Changed by hand on the word card ("I know this" / "Mark as new").
        case card
    }

    public var lemma: String
    public var state: WordState
    public var source: Source
    public var band: Int?
    public var updatedAt: Date
    /// Book, page and sentence where the word was first met. Recorded on the first write only; may point to a deleted book.
    public var firstBookID: UUID?
    public var firstPageID: UUID?
    public var firstSentence: String?

    public init(lemma: String, state: WordState, source: Source, band: Int?, updatedAt: Date = .now,
                firstBookID: UUID? = nil, firstPageID: UUID? = nil, firstSentence: String? = nil) {
        self.lemma = lemma
        self.state = state
        self.source = source
        self.band = band
        self.updatedAt = updatedAt
        self.firstBookID = firstBookID
        self.firstPageID = firstPageID
        self.firstSentence = firstSentence
    }
}

/// The vocabulary level and gloss language: one row, absent until the first-launch level test is finished or skipped, or the
/// account's level arrives from iCloud.
public struct Profile: Sendable, Hashable {
    /// Valid levels, in thousands of words: one per 1,000-lemma band of the bundled lexicon (bands 1 to 25).
    static let levels = 1...25
    /// The level a skipped test, a sign-out or deleted iCloud data falls back to.
    public static let defaultLevel = 3

    public var level: Int
    /// Gloss target language; nil follows the device languages. Never synced: it belongs to the device, not the account.
    public var glossLanguage: String?
    /// When the level was chosen. The Unix epoch marks the placeholder of a skipped test: it never syncs and loses to any iCloud level.
    public var updatedAt: Date
}

/// A committed change, named by the table it wrote, so the app knows what to read again.
public enum StoreChange: Sendable, Hashable {
    /// A book was created, deleted or renamed, or its reading position was saved.
    case books
    /// A page of this book was added or deleted, or its recognition state or result changed.
    case pages(UUID)
    /// The word list changed.
    case words
    /// The level or the gloss language changed.
    case profile
}

/// User data: books, pages, recognition results, electronic books' chapters and word states (system SQLite), plus page images (files).
/// Layout: `<root>/ReadStair.sqlite`, `<root>/Books/<bookID>/<pageID>.heic`, `<root>/Books/<bookID>/thumbs/<pageID>.heic`.
public actor BookStore {
    /// How many times recognition may start on one page; after that the page is marked failed until the user retries it.
    static let maxAttempts = 2

    nonisolated let root: URL
    /// Every change once it has committed, in commit order, for a single consumer (the app model), so recognition progress, imports
    /// and iCloud changes reach the UI without polling. It is created with the store and buffers without limit, so changes made
    /// before the consumer starts (recognition resumed at launch, the first import) are not lost. A write that fails, rolls back or
    /// changes no row publishes nothing. Launch-time recovery in `init` publishes nothing either: the app reads everything after
    /// opening the store.
    public nonisolated let changes: AsyncStream<StoreChange>
    /// The producer side of `changes`; yielded to only after a write has committed. Separate from `syncObserver`, which belongs to
    /// the sync engine.
    let changeSink: AsyncStream<StoreChange>.Continuation
    let database: SQLiteConnection
    /// Upper bound of page indices handed out to imports still in progress. Concurrent imports into one book each get their own contiguous range.
    private var reservedIndices: [UUID: Int] = [:]
    /// Called after a local word or level write commits, with what to register in the sync engine. Installed by WordSync; nil until
    /// sync starts, and the pending rows written meanwhile are picked up when it does.
    var syncObserver: (@Sendable (SyncEffects) -> Void)?
    /// Set when a sync step fails (for example, the disk is full): for the rest of this run nothing from iCloud is applied, nothing is
    /// sent and the engine state is not saved, so the next launch resumes from the last saved state, which still matches the data.
    var syncHalted = false

    /// Opens (or creates) the database and runs launch-time recovery: migrate the schema, requeue recognition cut short last time and
    /// pages analyzed by an older pipeline, reclaim orphan files.
    public init(root: URL) throws(StoreError) {
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        } catch {
            throw .file(error.localizedDescription)
        }
        let database = try SQLiteConnection(path: root.appending(path: "ReadStair.sqlite").path(percentEncoded: false))
        try Self.migrate(database)
        try Self.recoverInterrupted(database)
        try Self.requeueOutdated(database)
        try Self.reclaimOrphans(database, books: books)
        let (changes, changeSink) = AsyncStream.makeStream(of: StoreChange.self, bufferingPolicy: .unbounded)
        self.root = root
        self.changes = changes
        self.changeSink = changeSink
        self.database = database
    }

    // MARK: - Books

    /// Creates a book with no pages. A caller that must name the book before it exists (the sample import records the id it resumes)
    /// passes its own `id`; an id already in use throws and changes nothing.
    public func createBook(id: UUID = UUID(), title: String, at date: Date = .now) throws(StoreError) -> Book {
        let book = Book(id: id, title: title, createdAt: date, lastPageIndex: 0)
        try database.execute("INSERT INTO book (id, title, createdAt, lastPageIndex) VALUES (?, ?, ?, 0)",
                             [.uuid(book.id), .text(title), .date(date)])
        changeSink.yield(.books)
        return book
    }

    /// Stores the title as given (trimming and length limits are the UI's job). An unknown id changes nothing.
    public func renameBook(_ id: UUID, to title: String) throws(StoreError) {
        try database.execute("UPDATE book SET title = ? WHERE id = ?", [.text(title), .uuid(id)])
        if database.changes > 0 { changeSink.yield(.books) }
    }

    /// Saves the page index a book reopens at. An unknown id changes nothing.
    public func setLastPageIndex(_ index: Int, of bookID: UUID) throws(StoreError) {
        try database.execute("UPDATE book SET lastPageIndex = ? WHERE id = ?", [.int(index), .uuid(bookID)])
        if database.changes > 0 { changeSink.yield(.books) }
    }

    /// Deletes a book: pages, recognition results and chapters go with it through foreign-key cascades, then its image directory is
    /// removed (whatever cannot be removed is reclaimed at next launch). Never touches wordEntry, wordOrigin, syncRecord, syncState or
    /// profile (U-STA-002): a word stays in the word list regardless of the book it first appeared in, so `firstBookID` may point to a
    /// deleted book, and since sync only reads those tables, deleting a book can never remove a word on another device.
    public func deleteBook(_ id: UUID) throws(StoreError) {
        try database.execute("DELETE FROM book WHERE id = ?", [.uuid(id)])
        // Counts only the book row itself, not the pages removed by the cascade
        if database.changes > 0 { changeSink.yield(.books) }
        reservedIndices[id] = nil
        try? FileManager.default.removeItem(at: directory(of: id))
    }

    // MARK: - Pages

    public func pages(of bookID: UUID) throws(StoreError) -> [Page] {
        try database.query("SELECT * FROM page WHERE bookID = ? ORDER BY \"index\"", [.uuid(bookID)]).map(Self.page)
    }

    /// Where each titled entry of an electronic book's own table of contents starts, by page index, in index order; none for a
    /// photographed book or an electronic book imported before chapters were kept. A chapter is saved with the page it starts on, so
    /// `.pages(bookID)` covers it. Its page may have been deleted since: `ChapterStart.contents(_:pages:)` resolves it to a page.
    public func chapters(of bookID: UUID) throws(StoreError) -> [ChapterStart] {
        try database.query("SELECT pageIndex, title FROM chapter WHERE bookID = ? ORDER BY pageIndex", [.uuid(bookID)]).map {
            ChapterStart(pageIndex: $0["pageIndex"].int ?? 0, title: $0["title"].string ?? "")
        }
    }

    /// The recognition result; nil if the page is not recognized yet or was analyzed by an older pipeline (opening the store queues
    /// such a page again).
    public func pageText(of pageID: UUID) throws(StoreError) -> PageText? {
        let rows = try database.query("SELECT schemaVersion, json FROM pageText WHERE pageID = ?", [.uuid(pageID)])
        guard let row = rows.first, row["schemaVersion"].int == PageText.schemaVersion, let json = row["json"].data else { return nil }
        return try? JSONDecoder().decode(PageText.self, from: json)
    }

    nonisolated func imageURL(of page: Page) -> URL { imageURL(bookID: page.bookID, pageID: page.id) }

    nonisolated func thumbnailURL(of page: Page) -> URL { thumbnailURL(bookID: page.bookID, pageID: page.id) }

    /// Puts a failed page back in the queue with a fresh attempt count. Does nothing for a page that is not failed.
    public func retry(_ pageID: UUID) throws(StoreError) {
        let retried = try database.query("""
            UPDATE page SET status = 'pending', attempts = 0, error = NULL WHERE id = ? AND status = 'failed' RETURNING bookID
            """, [.uuid(pageID)])
        if let bookID = retried.first?["bookID"].uuid { changeSink.yield(.pages(bookID)) }
    }

    /// Deletes a page: its recognition result goes with it through the foreign-key cascade, then its image and thumbnail are removed
    /// (whatever cannot be removed is reclaimed at next launch). Does nothing for an unknown or already deleted id. The other pages keep
    /// their indices (gaps are fine, order is what counts) and the book may be left with no pages. A recognizer still running on the
    /// page is not stopped: its result matches no claim and is dropped. Never touches wordEntry, wordOrigin, syncRecord, syncState, book
    /// or profile (U-STA-002), so the book's `lastPageIndex` may point into the gap and `firstPageID` may point to a deleted page. Undo
    /// in the UI is expected to delay this call, not to restore rows afterwards. A chapter starting on the page keeps its row, which is
    /// keyed by page index, so the chapter now opens at its next page, or is hidden while it has none.
    public func deletePage(_ id: UUID) throws(StoreError) {
        let deleted = try database.query("DELETE FROM page WHERE id = ? RETURNING bookID", [.uuid(id)])
        guard let bookID = deleted.first?["bookID"].uuid else { return }
        changeSink.yield(.pages(bookID))
        removeImages(bookID: bookID, pageID: id)
    }

    // MARK: - Words

    /// Writes a word's state. One row per lemma (lowercased, then Unicode NFC, so an accented word typed with a combining accent and
    /// its precomposed spelling are one word): later writes replace the state; the first-seen context is kept. The stored time is
    /// whole milliseconds and always later than the value it replaces, so this change wins over anything the device has already
    /// seen, even when another device's clock runs ahead. The word is marked for upload in the same transaction, so a crash can never
    /// lose the upload. A word with no valid iCloud record name (only OCR garbage over 255 bytes) stays on this device. A word removed
    /// at sign-out and marked again before iCloud returns it gets back the first-seen context it had, as if it had never left.
    /// With `onlyIfAbsent` (what opening a word card writes), a word that already has a row is left as it is: nothing is written,
    /// marked for upload or published. The check is against the database, not the app's cached copy, so a state that has arrived
    /// from iCloud but that the app has not read back yet is never replaced.
    public func upsertWord(_ entry: WordEntry, onlyIfAbsent: Bool = false) throws(StoreError) {
        let lemma = SyncRules.lemmaKey(entry.lemma)
        // No suspension point between this check and the write, and this actor owns the only connection, so nothing can come between
        if onlyIfAbsent, try !database.query("SELECT 1 FROM wordEntry WHERE lemma = ?", [.text(lemma)]).isEmpty { return }
        let effects = try database.transaction { () throws(StoreError) -> SyncEffects? in
            let previous = try database.query("SELECT updatedAt FROM wordEntry WHERE lemma = ?", [.text(lemma)]).first?["updatedAt"].milliseconds
            let updatedAt = SyncRules.nextTimestamp(SyncRules.milliseconds(entry.updatedAt), after: previous)
            let first = try takeOrigin(of: lemma) ?? [.uuid(entry.firstBookID), .uuid(entry.firstPageID), .text(entry.firstSentence)]
            try database.execute("""
                INSERT INTO wordEntry (lemma, state, source, band, updatedAt, firstBookID, firstPageID, firstSentence)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (lemma) DO UPDATE SET
                    state = excluded.state, source = excluded.source, band = excluded.band, updatedAt = excluded.updatedAt
                """, [.text(lemma), .text(entry.state.rawValue), .text(entry.source.rawValue), .int(entry.band),
                      .milliseconds(updatedAt)] + first)
            guard let name = SyncRules.recordName(forLemma: lemma) else { return nil }
            return try markPending(name, at: updatedAt)
        }
        changeSink.yield(.words)
        if let effects { syncObserver?(effects) }
    }

    public func wordEntries() throws(StoreError) -> [WordEntry] {
        try database.query("SELECT * FROM wordEntry ORDER BY lemma").compactMap { row in
            guard let lemma = row["lemma"].string, let state = row["state"].string.flatMap(WordState.init),
                  let source = row["source"].string.flatMap(WordEntry.Source.init) else { return nil }
            return WordEntry(lemma: lemma, state: state, source: source, band: row["band"].int,
                             updatedAt: row["updatedAt"].date ?? .distantPast, firstBookID: row["firstBookID"].uuid,
                             firstPageID: row["firstPageID"].uuid, firstSentence: row["firstSentence"].string)
        }
    }

    // MARK: - Level

    /// The level and gloss language; nil until the first-launch test is finished or skipped, or the account's level arrives from
    /// iCloud. Whether it is nil decides whether the test is shown.
    public func profile() throws(StoreError) -> Profile? {
        try database.query("SELECT level, glossLanguage, updatedAt FROM profile WHERE id = 1").first.map {
            Profile(level: $0["level"].int ?? Profile.defaultLevel, glossLanguage: $0["glossLanguage"].string,
                    updatedAt: $0["updatedAt"].date ?? .distantPast)
        }
    }

    /// The user chose a level (finished the test or picked one). Like a word, it gets a strictly later timestamp and is marked for
    /// upload in the same transaction, so it becomes the level on every device. Keeps the gloss language.
    public func setLevel(_ level: Int, at date: Date = .now) throws(StoreError) {
        precondition(Profile.levels.contains(level), "Level out of range: \(level)")
        let effects = try database.transaction { () throws(StoreError) -> SyncEffects in
            let previous = try database.query("SELECT updatedAt FROM profile WHERE id = 1").first?["updatedAt"].milliseconds
            let updatedAt = SyncRules.nextTimestamp(SyncRules.milliseconds(date), after: previous)
            try database.execute("""
                INSERT INTO profile (id, level, updatedAt) VALUES (1, ?, ?)
                ON CONFLICT (id) DO UPDATE SET level = excluded.level, updatedAt = excluded.updatedAt
                """, [.int(level), .milliseconds(updatedAt)])
            return try markPending(SyncRules.profileRecordName, at: updatedAt)
        }
        changeSink.yield(.profile)
        syncObserver?(effects)
    }

    /// "Skip" on the first-launch test: writes the default level as a placeholder (time 0) so the test does not come back. It is never
    /// uploaded and any level from iCloud replaces it, so skipping on a new device cannot overwrite the account's real level. Does
    /// nothing if a level exists.
    public func skipLevelTest() throws(StoreError) {
        try database.execute("INSERT INTO profile (id, level, updatedAt) VALUES (1, ?, 0) ON CONFLICT DO NOTHING",
                             [.int(Profile.defaultLevel)])
        if database.changes > 0 { changeSink.yield(.profile) }
    }

    /// Saves the gloss language (nil follows the device languages). Only updates the existing row, never creates one: a new row would
    /// count as a finished level test and invent a level the user never chose, so without a row this changes nothing. The setting
    /// belongs to this device: it is never marked for upload, and the level and its time stay as they are.
    public func setGlossLanguage(_ language: String?) throws(StoreError) {
        try database.execute("UPDATE profile SET glossLanguage = ? WHERE id = 1", [.text(language)])
        if database.changes > 0 { changeSink.yield(.profile) }
    }

    // MARK: - Sync bookkeeping for local writes

    /// Marks a record for upload inside the caller's transaction and returns what to register once it commits. The zone is saved
    /// along with it while no record is confirmed in iCloud (first sync, or after the app's iCloud data was deleted). This is derived
    /// from the data rather than kept in a flag, so it survives a relaunch: otherwise the first write after a reset would be sent
    /// into a zone that no longer exists, fail with userDeletedZone and reset the data again, taking the new word with it.
    func markPending(_ name: String, at updatedAt: Int64) throws(StoreError) -> SyncEffects {
        try database.execute("""
            INSERT INTO syncRecord (recordName, pendingAt) VALUES (?, ?)
            ON CONFLICT (recordName) DO UPDATE SET pendingAt = excluded.pendingAt
            """, [.text(name), .milliseconds(updatedAt)])
        let confirmed = try zoneConfirmed()
        return SyncEffects(saveZone: !confirmed, saveRecords: [name])
    }

    /// Whether any record is known to exist in iCloud (it has system fields), which means the zone exists too.
    func zoneConfirmed() throws(StoreError) -> Bool {
        try !database.query("SELECT 1 FROM syncRecord WHERE systemFields IS NOT NULL LIMIT 1").isEmpty
    }

    /// Removes and returns the first book, page and sentence kept for a word at sign-out (in wordEntry's column order), or nil. Called
    /// whenever the word gets a row again, from iCloud or a local write, so a word is never in wordEntry and wordOrigin at once: the
    /// next sign-out then always keeps the word's current context, never an older one.
    func takeOrigin(of lemma: String) throws(StoreError) -> [SQLValue]? {
        try database.query("DELETE FROM wordOrigin WHERE lemma = ? RETURNING firstBookID, firstPageID, firstSentence", [.text(lemma)])
            .first.map { [$0["firstBookID"], $0["firstPageID"], $0["firstSentence"]] }
    }

    // MARK: - Import and recognition queue (used by Importer)

    func bookExists(_ id: UUID) throws(StoreError) -> Bool {
        try !database.query("SELECT 1 FROM book WHERE id = ?", [.uuid(id)]).isEmpty
    }

    /// Reserves a contiguous range of indices for `count` pages about to be imported, after the book's existing pages and any imports in progress.
    /// First deletes the book's chapters from its next free index on. A chapter is saved with its page, so every page such a chapter
    /// had was deleted, and it must not give its title to the pages about to come. The range's start would miss one: the reservation
    /// high-water mark outlives this run's imports and can sit above a deleted last page. It publishes nothing: the rows it removes
    /// resolve to no page, so no book's contents change. Accepted: if pages that a running import already saved at the end of the
    /// book are deleted, and another import into the same book then starts, a chapter starting on one of those pages is lost, and
    /// the pages the running import still adds fall into the chapter before.
    func reserveIndices(in bookID: UUID, count: Int) throws(StoreError) -> Range<Int> {
        guard try bookExists(bookID) else { throw .bookNotFound }
        let row = try database.query("SELECT COALESCE(MAX(\"index\") + 1, 0) AS next FROM page WHERE bookID = ?", [.uuid(bookID)])
        let next = row.first?["next"].int ?? 0
        try database.execute("DELETE FROM chapter WHERE bookID = ? AND pageIndex >= ?", [.uuid(bookID), .int(next)])
        let start = max(next, reservedIndices[bookID] ?? 0)
        reservedIndices[bookID] = start + count
        return start..<(start + count)
    }

    /// Encodes and atomically writes the page image and its thumbnail; returns the page image's pixel size. Runs on the page-image queue, not on this actor.
    nonisolated func writeImages(_ image: CGImage, bookID: UUID, pageID: UUID) async throws(StoreError) -> (width: Int, height: Int) {
        let pageURL = imageURL(bookID: bookID, pageID: pageID)
        let thumbnailURL = thumbnailURL(bookID: bookID, pageID: pageID)
        return try await PageImageFile.run { () throws(StoreError) in
            let page = try PageImageFile.fitting(image, maxPixelSize: PageImageFile.maxPixelSize)
            let thumbnail = try PageImageFile.fitting(page, maxPixelSize: PageImageFile.thumbnailPixelSize)
            try PageImageFile.write(PageImageFile.heic(page), to: pageURL)
            try PageImageFile.write(PageImageFile.heic(thumbnail), to: thumbnailURL)
            return (page.width, page.height)
        }
    }

    /// Removes a page's image and thumbnail, ignoring errors (the launch sweep reclaims leftovers): for a deleted page, or an import
    /// that failed before its row was written.
    nonisolated func removeImages(bookID: UUID, pageID: UUID) {
        try? FileManager.default.removeItem(at: imageURL(bookID: bookID, pageID: pageID))
        try? FileManager.default.removeItem(at: thumbnailURL(bookID: bookID, pageID: pageID))
    }

    /// Inserts a page whose image is already on disk: as pending, or, given its `text` (a typeset electronic book), as recognized with
    /// that text, plus the `chapter` that starts on it, if any, in one transaction, so no chapter is ever saved without its page.
    /// Throws `bookNotFound` if the book was deleted; the caller then removes the files it wrote.
    func insertPage(id: UUID, bookID: UUID, index: Int, width: Int, height: Int, text: PageText? = nil,
                    chapter: String? = nil) throws(StoreError) {
        guard try bookExists(bookID) else { throw .bookNotFound }
        let json = try text.map { text throws(StoreError) in try Self.encode(text) }
        try database.transaction { () throws(StoreError) in
            try database.execute("INSERT INTO page (id, bookID, \"index\", width, height, status) VALUES (?, ?, ?, ?, ?, ?)",
                                 [.uuid(id), .uuid(bookID), .int(index), .int(width), .int(height),
                                  .text(json == nil ? "pending" : "recognized")])
            if let json {
                try database.execute("INSERT OR REPLACE INTO pageText (pageID, schemaVersion, json) VALUES (?, ?, ?)",
                                     [.uuid(id), .int(PageText.schemaVersion), .blob(json)])
            }
            if let chapter {
                try database.execute("INSERT OR REPLACE INTO chapter (bookID, pageIndex, title) VALUES (?, ?, ?)",
                                     [.uuid(bookID), .int(index), .text(chapter)])
            }
        }
        changeSink.yield(.pages(bookID))
    }

    private static func encode(_ text: PageText) throws(StoreError) -> Data {
        do { return try JSONEncoder().encode(text) } catch { throw .file(error.localizedDescription) }
    }

    /// Takes the next pending page, marks it recognizing and counts an attempt, in a single statement so two workers never get the same page.
    /// Order: pages that never failed come first in queue order; pages that failed before (`error` set) go to the back. Pages cut short by
    /// a killed process have no error and keep their place: they are most likely the first pages, the ones the user is looking at.
    /// Attempts are counted when recognition starts, not when it fails: a page that crashes the app is marked failed after two launches
    /// instead of crashing it forever. The returned page's `attempts` identifies this claim: the calls below take effect only while it
    /// still matches, so a recognizer that returns late cannot overwrite a newer claim of the same page (after a user retry resets the
    /// count, an old claim can match again; harmless, as it recognized the same image).
    func claimNextPending() throws(StoreError) -> Page? {
        let claimed = try database.query("""
            UPDATE page SET status = 'recognizing', attempts = attempts + 1
            WHERE id = (SELECT id FROM page WHERE status = 'pending' ORDER BY error IS NOT NULL, rowid LIMIT 1)
            RETURNING *
            """).first.map(Self.page)
        if let claimed { changeSink.yield(.pages(claimed.bookID)) }
        return claimed
    }

    /// Recognition succeeded: store the result and mark the page recognized. A late result is still kept if the page timed out
    /// (requeued or failed) but nobody claimed it again. Writes nothing if the page was deleted or claimed again meanwhile.
    func finishRecognition(_ claim: Page, text: PageText) throws(StoreError) {
        let json = try Self.encode(text)
        let finished = try database.transaction { () throws(StoreError) -> Bool in
            try database.execute("UPDATE page SET status = 'recognized', error = NULL WHERE id = ? AND attempts = ? AND status <> 'recognized'",
                                 [.uuid(claim.id), .int(claim.attempts)])
            guard database.changes == 1 else { return false }
            try database.execute("INSERT OR REPLACE INTO pageText (pageID, schemaVersion, json) VALUES (?, ?, ?)",
                                 [.uuid(claim.id), .int(PageText.schemaVersion), .blob(json)])
            return true
        }
        if finished { changeSink.yield(.pages(claim.bookID)) }
    }

    /// Recognition failed (threw, timed out, unreadable image): requeue while attempts remain, otherwise mark failed.
    func failRecognition(_ claim: Page, reason: String) throws(StoreError) {
        try database.execute("""
            UPDATE page SET status = CASE WHEN attempts >= ? THEN 'failed' ELSE 'pending' END, error = ?
            WHERE id = ? AND attempts = ? AND status = 'recognizing'
            """, [.int(Self.maxAttempts), .text(reason), .uuid(claim.id), .int(claim.attempts)])
        if database.changes > 0 { changeSink.yield(.pages(claim.bookID)) }
    }

    /// Recognition was interrupted through no fault of the page (queue cancelled, store error): requeue and give the attempt back.
    func releaseRecognition(_ claim: Page) throws(StoreError) {
        try database.execute("""
            UPDATE page SET status = 'pending', attempts = MAX(attempts - 1, 0)
            WHERE id = ? AND attempts = ? AND status = 'recognizing'
            """, [.uuid(claim.id), .int(claim.attempts)])
        if database.changes > 0 { changeSink.yield(.pages(claim.bookID)) }
    }

    // MARK: - Testing

    /// For tests: run raw SQL (e.g. install audit triggers, cap the database size to simulate a full disk).
    func execute(_ sql: String) throws(StoreError) {
        try database.execute(sql)
    }

    // MARK: - Private

    private nonisolated func directory(of bookID: UUID) -> URL {
        root.appending(path: "Books").appending(path: bookID.uuidString, directoryHint: .isDirectory)
    }

    private nonisolated func imageURL(bookID: UUID, pageID: UUID) -> URL {
        directory(of: bookID).appending(path: Self.fileName(pageID))
    }

    private nonisolated func thumbnailURL(bookID: UUID, pageID: UUID) -> URL {
        directory(of: bookID).appending(path: "thumbs").appending(path: Self.fileName(pageID))
    }

    private static func fileName(_ pageID: UUID) -> String { "\(pageID.uuidString).heic" }

    // MARK: - Row mapping (also used by the summaries in BookStore+App.swift)

    static func book(_ row: SQLRow) -> Book {
        Book(id: row["id"].uuid!, title: row["title"].string ?? "", createdAt: row["createdAt"].date ?? .distantPast,
             lastPageIndex: row["lastPageIndex"].int ?? 0)
    }

    static func page(_ row: SQLRow) -> Page {
        Page(id: row["id"].uuid!, bookID: row["bookID"].uuid!, index: row["index"].int ?? 0,
             width: row["width"].int ?? 0, height: row["height"].int ?? 0,
             status: row["status"].string.flatMap(Page.Status.init) ?? .pending,
             attempts: row["attempts"].int ?? 0, error: row["error"].string)
    }
}

// MARK: - Schema and launch-time recovery

extension BookStore {
    /// Schema migrations, run in order; after script n, `user_version = n`. Append only: a shipped script is never edited.
    static let migrations: [String] = [
        // v1. wordEntry.first* have no foreign keys: a cascading SET NULL on book deletion would write wordEntry, which U-STA-002 forbids.
        """
        CREATE TABLE book (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            createdAt REAL NOT NULL,
            lastPageIndex INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE page (
            id TEXT PRIMARY KEY NOT NULL,
            bookID TEXT NOT NULL REFERENCES book (id) ON DELETE CASCADE,
            "index" INTEGER NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'recognizing', 'recognized', 'failed')),
            attempts INTEGER NOT NULL DEFAULT 0,
            error TEXT,
            UNIQUE (bookID, "index")
        );
        CREATE INDEX page_status ON page (status);
        CREATE TABLE pageText (
            pageID TEXT PRIMARY KEY NOT NULL REFERENCES page (id) ON DELETE CASCADE,
            schemaVersion INTEGER NOT NULL,
            json BLOB NOT NULL
        );
        CREATE TABLE wordEntry (
            lemma TEXT PRIMARY KEY NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('learning', 'known')),
            source TEXT NOT NULL,
            band INTEGER,
            updatedAt REAL NOT NULL,
            firstBookID TEXT,
            firstPageID TEXT,
            firstSentence TEXT
        );
        CREATE TABLE profile (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            level INTEGER NOT NULL,
            glossLanguage TEXT
        );
        """,
        // v2: iCloud sync of words and the level. Adds tables and one column; v1 data is untouched. Existing levels get the
        // oldest real time (1 ms) so they upload once and lose to any later choice.
        // - syncState: the sync engine's saved state (JSON); no row means sync never ran.
        // - syncRecord: one row per iCloud record (a word's encoded lemma, or "Profile"). systemFields is the record's archived
        //   change tag, NULL while iCloud does not have it; pendingAt is non-NULL while the record must be sent and is the
        //   authoritative list of what to send, written in the same transaction as the data.
        // - wordOrigin: the first book, page and sentence this device had for words removed at sign-out, restored as they were when
        //   the word gets a row again. The sentence is kept too because iCloud holds whichever sentence was sent last, possibly
        //   another device's, which would not be on the restored page. No foreign keys: a cascade would write it when a book or a
        //   page is deleted.
        // No indexes: every lookup is by primary key, and the two full scans (the pending list, the zone check) cover at most about
        // 20k rows.
        """
        ALTER TABLE profile ADD COLUMN updatedAt REAL NOT NULL DEFAULT 0;
        UPDATE profile SET updatedAt = 0.001;
        CREATE TABLE syncState (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            engineState BLOB
        );
        CREATE TABLE syncRecord (
            recordName TEXT PRIMARY KEY NOT NULL,
            systemFields BLOB,
            pendingAt REAL
        );
        CREATE TABLE wordOrigin (
            lemma TEXT PRIMARY KEY NOT NULL,
            firstBookID TEXT,
            firstPageID TEXT,
            firstSentence TEXT
        );
        """,
        // v3: an electronic book's contents. One row per page that starts a titled entry of the book's own table of contents: its
        // page index (page."index" space; no foreign key to page, so deleting that page moves the entry to the next page of its range)
        // and the book's label. Written in the same transaction as that page. Photographed books have none. Local only: never synced.
        """
        CREATE TABLE chapter (
            bookID TEXT NOT NULL REFERENCES book (id) ON DELETE CASCADE,
            pageIndex INTEGER NOT NULL,
            title TEXT NOT NULL,
            PRIMARY KEY (bookID, pageIndex)
        );
        """,
    ]

    static func migrate(_ database: SQLiteConnection) throws(StoreError) {
        let version = try database.query("PRAGMA user_version").first?["user_version"].int ?? 0
        guard version <= migrations.count else { throw .incompatibleSchema(found: version, supported: migrations.count) }
        for (index, script) in migrations.enumerated().dropFirst(version) {
            try database.transaction { () throws(StoreError) in
                try database.execute(script)
                try database.execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }

    /// The previous process ended mid-recognition (killed or crashed): requeue, or mark failed once `maxAttempts` runs have started.
    static func recoverInterrupted(_ database: SQLiteConnection) throws(StoreError) {
        try database.execute("""
            UPDATE page SET
                status = CASE WHEN attempts >= ? THEN 'failed' ELSE 'pending' END,
                error = CASE WHEN attempts >= ? THEN 'interrupted' ELSE error END
            WHERE status = 'recognizing'
            """, [.int(maxAttempts), .int(maxAttempts)])
    }

    /// A page recognized by an older analysis pipeline has a result `pageText(of:)` no longer reads: put it back in the queue with a
    /// fresh attempt count, or it would stay recognized with no words forever.
    static func requeueOutdated(_ database: SQLiteConnection) throws(StoreError) {
        try database.execute("""
            UPDATE page SET status = 'pending', attempts = 0, error = NULL
            WHERE status = 'recognized' AND id IN (SELECT pageID FROM pageText WHERE schemaVersion <> ?)
            """, [.int(PageText.schemaVersion)])
    }

    /// Removes image directories and files with no matching database row (left over from a book deletion, half-written temporary files,
    /// images written just before a crash). Called only when opening, before any import can be writing files, so it never races one.
    static func reclaimOrphans(_ database: SQLiteConnection, books: URL) throws(StoreError) {
        var known: [UUID: Set<String>] = [:]
        for row in try database.query("SELECT id FROM book") {
            if let id = row["id"].uuid { known[id] = [] }
        }
        for row in try database.query("SELECT id, bookID FROM page") {
            if let id = row["id"].uuid, let bookID = row["bookID"].uuid { known[bookID]?.insert(fileName(id)) }
        }
        let files = FileManager.default
        func contents(_ url: URL) -> [URL] { (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] }
        for directory in contents(books) {
            guard let bookID = UUID(uuidString: directory.lastPathComponent), let pages = known[bookID] else {
                try? files.removeItem(at: directory)
                continue
            }
            for item in contents(directory) + contents(directory.appending(path: "thumbs")) {
                let name = item.lastPathComponent
                if name != "thumbs", !pages.contains(name) { try? files.removeItem(at: item) }
            }
        }
    }
}
