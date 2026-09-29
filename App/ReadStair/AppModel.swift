import AVFoundation
import FoundationModels
import OSLog
import ReadStairCore
import SwiftUI
import Translation
import UIKit

/// A screen pushed on the navigation stack; Books is the root.
nonisolated enum Route: Hashable {
    /// A book's page: its cover, `Read` and its contents (`BookView`). Every book opens here from Books.
    case book(UUID)
    /// `pageID` is a page to open at; nil opens the book where the reader left it.
    case reader(bookID: UUID, pageID: UUID?)
    case wordList
}

/// Where imported pages go.
nonisolated enum ImportTarget: Hashable {
    case newBook
    case append(bookID: UUID)
}

/// What the root presents full screen.
nonisolated enum Cover: Identifiable, Hashable {
    /// The first-launch level test, shown when there is no level yet.
    case levelTest
    case scanner(ImportTarget)

    var id: Self { self }
}

/// Every alert, presented by the root.
nonisolated enum AppAlert: Hashable {
    case cameraAccessOff
    case storageFull
    case photosUnreadable
    /// Any reason a chosen book file cannot be opened: copy protection, not EPUB or text, no text, too large, or not in English.
    case bookUnopenable
    case somethingWentWrong
    case rename(bookID: UUID)
}

/// The one change waiting in the undo toast. It is only held, never written, until it commits.
nonisolated enum PendingChange: Hashable, Sendable {
    case word(WordChange)
    case deletePage(UUID)
    case deleteBook(UUID)
}

/// `I Know This` or `Mark as New` on a word card, with the card's first-seen context: without it a word the lexicon does not know,
/// such as a name, would land in the word list with no book and no sentence.
nonisolated struct WordChange: Hashable, Sendable {
    let stateKey: String
    let state: WordState
    let band: Int?
    let headword: String
    let bookID: UUID?
    let pageID: UUID?
    let sentence: String?

    /// The word's entry with this change applied: the stored one, or a new one with the card's first-seen context.
    func applied(to entry: WordEntry?) -> WordEntry {
        var entry = entry ?? WordEntry(lemma: stateKey, state: state, source: .card, band: band, firstBookID: bookID,
                                       firstPageID: pageID, firstSentence: sentence)
        entry.state = state
        entry.source = .card
        return entry
    }
}

/// The app's single model: it owns the store and every service, holds what the screens show, and is the only path that writes.
/// Views never call the store.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case opening
        case ready
        case failed
    }

    /// The longest book title a rename saves: the cap on a title that comes with a book file.
    static let maxTitleLength = TypesetBook.maxTitleLength

    /// A cover's long edge in pixels, for every slot and device: about the largest slot at 3x. A grid slot on the widest phones is
    /// 294 pt tall (882 px); the book page's 180 pt slot draws it smaller.
    static let coverPixelSize = 900

    // MARK: State the screens read

    private(set) var phase = Phase.opening
    /// Every book with its page count and saved position, newest first, pending deletions included (see `visibleBooks`).
    private(set) var books: [BookSummary] = []
    /// Stored word states, keyed by `PageWord.stateKey`. Screens read them through `effectiveState(of:)`.
    private(set) var entries: [String: WordEntry] = [:] {
        didSet { entriesVersion += 1 }
    }
    /// Counts changes to `entries`, so a page's marks can tell whether they are still current.
    private(set) var entriesVersion = 0
    /// Pages and books deleted during this run: hidden at once, before the store's change comes back.
    private(set) var deletedIDs: Set<UUID> = []
    private(set) var level = Profile.defaultLevel
    /// The chosen gloss language: nil follows the device languages, `"en"` means no translation.
    private(set) var glossSetting: String?
    /// The language word cards translate into; nil for none (English, no other preferred language, or not supported).
    private(set) var translationTarget: Locale.Language?
    /// Set by a word card when the user turned down the language download; the rest of this run shows no translation.
    var translationDeclined = false
    /// Bumped for a book whenever its pages change; the Reader reloads its pages when its book's revision changes.
    private(set) var pageRevision: [UUID: Int] = [:]
    /// Whether Apple Intelligence can explain a word in its sentence; read at launch and on every return to the foreground.
    private(set) var meaningAvailable = false
    /// Whether Apple Intelligence is turned off in Settings: of the reasons it is missing, the one the user can change (unlike a device
    /// that cannot run it, or a model still downloading). Read with `meaningAvailable`.
    private(set) var appleIntelligenceOff = false
    /// Whether a word card has ever shown the hint to turn on Apple Intelligence: read from UserDefaults at launch, then saved there
    /// together with this (see `appleIntelligenceHintSeen()`).
    private(set) var appleIntelligenceHintShown = AppModel.savedAppleIntelligenceHint()
    /// The first page an import added to the book on top of the navigation stack. The Reader scrolls to it once the page is in its
    /// list, then calls `firstAddedPageShown()`.
    private(set) var firstAddedPage: Page?

    var path: [Route] = []
    var cover: Cover? {
        didSet { if cover != nil { coverOnScreen = true } }
    }
    /// Whether a full-screen cover is on screen, from when it is set until it has slid away: no alert shows over it meanwhile.
    private(set) var coverOnScreen = false
    /// Where the photos being picked go; the root shows the Photos picker while it is set.
    var photosTarget: ImportTarget?
    /// Whether the root shows the system's file picker, for a book file that becomes a new book.
    var showsFileImporter = false
    /// Shown by the root once no word card is on screen; the Reader and the Word List close their cards when one is set.
    var alert: AppAlert?
    /// Whether a word card is on screen, from when it opens until its sheet is gone. Nothing is presented over it (P1, P2).
    var cardOnScreen = false

    // MARK: Services and bookkeeping (not observed)

    @ObservationIgnored private var store: BookStore?
    @ObservationIgnored private var importer: Importer?
    @ObservationIgnored private var loop: RecognitionLoop?
    #if READSTAIR_ICLOUD
    /// iCloud sync of words and the level (see `startWordSync`). Held here because the engine holds its delegate weakly.
    @ObservationIgnored private var sync: WordSync?
    #endif
    @ObservationIgnored let speaker = Speaker()
    @ObservationIgnored private(set) lazy var undoSlot = UndoSlot<PendingChange>(
        holdsIndefinitely: { UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning || AppModel.holdsUndo },
        commit: { [weak self] change in await self?.commit(change) })
    @ObservationIgnored private lazy var background = BackgroundToken { [weak self] in self?.cancelBackgroundWork() }
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    /// Photo and scan imports, which the background cancels (see `cancelBackgroundWork`); an e-book import is not among them.
    @ObservationIgnored private var imports: [UUID: Task<Void, Never>] = [:]
    /// Scan imports that have not ended: each reads its pages from the document camera's files (see `removeScannedPages`).
    @ObservationIgnored private var scanImports = 0
    /// Whether a chosen book file is being read and laid out, until its import starts: `Choose from Files` does nothing meanwhile.
    @ObservationIgnored private var openingFile = false
    /// Cancels recognition and photo and scan imports shortly before the background time runs out.
    @ObservationIgnored private var backgroundCancel: Task<Void, Never>?
    @ObservationIgnored private var pendingChanges: Set<StoreChange> = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// The page index each book was last at rest on, this run only; saved when its Reader closes or the app goes to the background.
    @ObservationIgnored private var lastViewed: [UUID: Int] = [:]
    /// Only spares decoding a cover twice, keyed by page ID; inserting does not notify observers. At most 24, about 52 MB if all
    /// were typeset pages (600 × 900 px).
    @ObservationIgnored private let covers = {
        let cache = NSCache<NSUUID, CGImage>()
        cache.countLimit = 24
        return cache
    }()
    /// Local word writes: a reload of the word list is dropped if one was in flight or finished while it ran.
    @ObservationIgnored private var writesInFlight = 0
    @ObservationIgnored private var writesCompleted = 0
    @ObservationIgnored private var recognitionAlertShown = false
    @ObservationIgnored private var translationSupported: [String: Bool] = [:]
    /// What to do once the full-screen cover is gone (an alert or an import must not start under it).
    @ObservationIgnored private var afterCover: (() -> Void)?
    /// The Word List's groups and what they were built from (see `wordListSections`).
    @ObservationIgnored private var sectionsCache: (basis: SectionsBasis, value: [WordListSections.Section])?

    private static let log = Logger(subsystem: "app.readstair", category: "app")
    private static let appleIntelligenceHintKey = "appleIntelligenceHintShown"

    // MARK: Derived

    /// The change waiting in the undo toast.
    var pendingChange: PendingChange? { undoSlot.current }

    var hiddenPageID: UUID? {
        if case .deletePage(let id)? = undoSlot.current { id } else { nil }
    }

    var hiddenBookID: UUID? {
        if case .deleteBook(let id)? = undoSlot.current { id } else { nil }
    }

    /// The shelf: every book not deleted or waiting to be. What hides one is read once (see `visible(_:keeping:)`).
    var visibleBooks: [BookSummary] {
        let hidden = hiddenBookID, deleted = deletedIDs
        return books.filter { $0.book.id != hidden && !deleted.contains($0.book.id) }
    }

    func book(_ id: UUID) -> Book? {
        books.first { $0.book.id == id }?.book
    }

    /// Whether a page shows: not deleted and not waiting to be.
    func isVisible(page id: UUID) -> Bool {
        id != hiddenPageID && !deletedIDs.contains(id)
    }

    /// The pages among these that show, in order, plus `lingering` if it is among them. What hides a page is read once, not once per
    /// page: reading the undo toast's change builds a key path every time, and over the hundreds of pages of a long book that took
    /// most of the main actor's time while an import refreshed the Reader four times a second.
    func visible(_ pages: [Page], keeping lingering: UUID? = nil) -> [Page] {
        let hidden = hiddenPageID, deleted = deletedIDs
        return pages.filter { ($0.id != hidden && !deleted.contains($0.id)) || $0.id == lingering }
    }

    /// A word's state with the change waiting in the undo toast applied.
    func effectiveState(of stateKey: String) -> WordState? {
        if case .word(let change)? = undoSlot.current, change.stateKey == stateKey { return change.state }
        return entries[stateKey]?.state
    }

    /// Everything a page's underlines depend on besides its text: the level, the stored word states, and the change waiting in the toast.
    struct MarksBasis: Equatable {
        let level: Int
        let entriesVersion: Int
        let pending: PendingChange?
    }

    var marksBasis: MarksBasis {
        MarksBasis(level: level, entriesVersion: entriesVersion, pending: undoSlot.current)
    }

    /// Everything the Word List's groups depend on: the stored words, the change waiting in the toast, and the books on the shelf.
    struct SectionsBasis: Equatable {
        let entriesVersion: Int
        let pending: PendingChange?
        let books: [Book]
    }

    /// The Word List's groups, from the entries with the change waiting in the undo toast applied: `I Know This` takes a row away at
    /// once and Undo puts it back; a book waiting to be deleted gives its words to Other. Built again only when its basis changes, so
    /// opening and closing a card on the list does not rebuild it.
    var wordListSections: [WordListSections.Section] {
        let basis = SectionsBasis(entriesVersion: entriesVersion, pending: undoSlot.current, books: visibleBooks.map(\.book))
        if let sectionsCache, sectionsCache.basis == basis { return sectionsCache.value }
        var effective = entries
        if case .word(let change)? = basis.pending { effective[change.stateKey] = change.applied(to: entries[change.stateKey]) }
        let sections = WordListSections.make(entries: effective.values, books: basis.books, hiddenBookID: hiddenBookID)
        sectionsCache = (basis, sections)
        return sections
    }

    /// The words to underline on a page at the current level and effective states, in reading order. `keys` are the words' state keys.
    func markedWords(in text: PageText, keys: [String]) -> [Int] {
        Annotator.markedWords(in: text, level: level) { effectiveState(of: keys[$0]) }
    }

    /// Whether the card's word is underlined now: `I Know This` if so, `Mark as New` if not.
    func isMarked(_ card: CardWord) -> Bool {
        Annotator.isMarked(card.word, level: level, state: effectiveState(of: card.stateKey))
    }

    /// The page index a book opens at: where it was last at rest this run, else where it was saved.
    func openingIndex(of bookID: UUID) -> Int {
        lastViewed[bookID] ?? book(bookID)?.lastPageIndex ?? 0
    }

    // MARK: Reads for the screens

    func pages(of bookID: UUID) async throws(StoreError) -> [Page] {
        guard let store else { return [] }
        return try await store.pages(of: bookID)
    }

    func pageText(of pageID: UUID) async throws(StoreError) -> PageText? {
        guard let store else { return nil }
        return try await store.pageText(of: pageID)
    }

    /// The page image decoded off the main actor: at its stored size, or with its long edge at most `maxPixelSize` (never enlarged);
    /// nil if its file is missing.
    func image(of page: Page, maxPixelSize: Int? = nil) async -> CGImage? {
        guard let store else { return nil }
        guard let maxPixelSize else { return await store.loadImage(of: page) }
        return await store.loadImage(of: page, maxPixelSize: maxPixelSize)
    }

    /// The page's 240 px thumbnail, decoded off the main actor; nil if its file is missing.
    func thumbnail(of page: Page) async -> CGImage? {
        await store?.loadThumbnail(of: page)
    }

    /// A book's cover: its first page, downsampled to `coverPixelSize` off the main actor, and decoded again only once the cache has
    /// let it go; nil if its file is missing.
    func cover(of page: Page) async -> CGImage? {
        let key = page.id as NSUUID
        if let cached = covers.object(forKey: key) { return cached }
        guard let image = await store?.loadImage(of: page, maxPixelSize: Self.coverPixelSize) else { return nil }
        covers.setObject(image, forKey: key)
        return image
    }

    /// A book's contents: each chapter of its own table of contents with the first page that shows in its range. Empty for a book
    /// without chapters, and when reading fails (the book page then shows no rows).
    func contents(of bookID: UUID) async -> [ContentsEntry] {
        guard let store else { return [] }
        do {
            let chapters = try await store.chapters(of: bookID)
            let pages = try await store.pages(of: bookID)
            return ChapterStart.contents(chapters, pages: visible(pages))
        } catch {
            Self.log.error("Reading the contents failed: \(String(describing: error))")
            return []
        }
    }

    // MARK: Launch

    /// Opens the store and starts the services. Idempotent: later calls wait for the first; after a failure, `retryLaunch()` runs it again.
    func launch() async {
        if launchTask == nil {
            launchTask = Task { await run() }
        }
        await launchTask?.value
    }

    func retryLaunch() {
        phase = .opening
        Task { await launch() }
    }

    private func run() async {
        do throws(StoreError) {
            let store = try await Self.openStore(at: Self.dataRoot)
            // One actor: these run one after another whichever way they are written
            let profile = try await store.profile()
            let summaries = try await store.bookSummaries()
            let words = try await store.wordEntries()
            self.store = store
            books = summaries
            entries = Self.keyed(words)
            level = profile?.level ?? Profile.defaultLevel
            glossSetting = profile?.glossLanguage
            // The phase and, on a new store, the level test's cover, together and before the services start: the shelf waits for the
            // cover to close (RootView), so it never shows first. Decided here, once: a level that arrives from iCloud later neither
            // closes the test nor brings it back.
            if profile == nil { showLevelTest(store) }
            phase = .ready
            start(store)
            // A new sample only on a new store, as the store itself tells: no level yet and no book. Otherwise the marker says whether
            // a kill cut the sample's import short (see `addSampleBook`).
            if profile == nil, summaries.isEmpty, Self.addsSampleBook {
                addSampleBook(store, resuming: nil)
            } else if let sample = Self.unfinishedSample, summaries.contains(where: { $0.book.id == sample.id }) {
                addSampleBook(store, resuming: sample)
            } else {
                Self.sampleImportEnded()
            }
        } catch {
            Self.log.error("Opening the store failed: \(String(describing: error))")
            phase = .failed
            launchTask = nil
        }
    }

    /// The first-launch level test. In DEBUG runs with `-ReadStairCloudLevel`, a level then arrives as if from iCloud while it is open.
    private func showLevelTest(_ store: BookStore) {
        cover = .levelTest
        #if DEBUG
        if let level = DebugLaunch.cloudLevel {
            Task {
                try? await Task.sleep(for: .seconds(3))
                try? await store.applyCloudLevelForTesting(level)
            }
        }
        #endif
    }

    /// The sample book: chapter I of Alice's Adventures in Wonderland, from the EPUB in the app bundle (the later chapters would rate
    /// the app 13+). It is laid out and saved behind the level test like a chosen book file, so its pages come already read, but it is not
    /// among `imports`, never opens the Reader and never shows an alert: the user did not ask for it, so a failure is only logged.
    /// Only a store with neither a level nor a book gets one (see `run()`): a deleted sample never comes back, and a level test shown
    /// again after a kill adds no second copy.
    ///
    /// The import takes a few seconds, and a kill can still cut it short. The marker file names the book and its page count from before
    /// the book is created until the import ends, and the next launch carries on after the last page saved (`resuming`). It ends when
    /// the import returns or the book is gone; after any other failure the book stays for the next launch to finish, unless it has no
    /// page yet: then it is removed, also on a resume, when it has been on the shelf since launch. Known limits: pages the user adds to
    /// the sample during its first import, then a kill, leave it unfinished; its last saved page, deleted by the user during the
    /// import, comes back on resume; once a page is saved, a resume that lays the book out to a different page count (a new app or iOS
    /// version) adds nothing and leaves it unfinished, but a new layout with the same count goes unnoticed.
    private func addSampleBook(_ store: BookStore, resuming resumed: UnfinishedSample?) {
        guard let importer, let url = Bundle.main.url(forResource: "alice", withExtension: "epub") else {
            Self.log.error("The sample book is missing")
            return
        }
        background.retain()
        Task {
            defer { background.release() }
            let id = resumed?.id ?? UUID()
            do {
                // Laid out off the main actor, and each page drawn off it when the import asks for it (`ImportSource.page`)
                let book = try await TypesetBook.make(from: Data(contentsOf: url), fileName: url.lastPathComponent)
                let source = ImportSource.ebook(book)
                let next: Int
                if let resumed {
                    next = (try await store.pages(of: id).last?.index ?? -1) + 1
                    // Pages from another layout would double or skip a page at the seam and shift every chapter after it
                    if next > 0, resumed.pageCount != source.count {
                        Self.log.error("The sample book now takes \(source.count) pages, not \(resumed.pageCount); it stays unfinished")
                        Self.sampleImportEnded()
                        return
                    }
                } else {
                    try Data("\(id.uuidString) \(source.count)".utf8).write(to: Self.sampleMarker, options: .atomic)
                    _ = try await store.createBook(id: id, title: book.title ?? "")
                    next = 0
                }
                if next < source.count {
                    try await importer.importPages(count: source.count - next, into: id) { await source.page(next + $0) }
                }
                Self.sampleImportEnded()
            } catch {
                Self.log.error("Adding the sample book failed: \(String(describing: error))")
                if error as? StoreError == .bookNotFound {
                    Self.sampleImportEnded()
                } else if (try? await store.pages(of: id))?.isEmpty == true {
                    do {
                        // Nothing to remove if it was never created
                        try await store.deleteBook(id)
                        Self.sampleImportEnded()
                    } catch {
                        Self.log.error("Removing the sample book failed: \(String(describing: error))")
                    }
                }
            }
        }
    }

    /// `SampleBook.importing` in the data root: "<id> <page count>" of the sample book, while its import has not ended (see
    /// `addSampleBook`).
    private static var sampleMarker: URL {
        dataRoot.appending(path: "SampleBook.importing", directoryHint: .notDirectory)
    }

    /// The book the marker names and its page count when its import started.
    private typealias UnfinishedSample = (id: UUID, pageCount: Int)

    /// Nil when there is no marker, or it does not hold both fields.
    private static var unfinishedSample: UnfinishedSample? {
        guard let fields = (try? String(contentsOf: sampleMarker, encoding: .utf8))?.split(separator: " "), fields.count == 2,
              let id = UUID(uuidString: String(fields[0])), let pageCount = Int(fields[1]) else { return nil }
        return (id, pageCount)
    }

    private static func sampleImportEnded() {
        try? FileManager.default.removeItem(at: sampleMarker)
    }

    /// Migration, recovery of interrupted recognition and the orphan sweep all run in `BookStore.init`, off the main actor.
    @concurrent
    private static func openStore(at root: URL) async throws(StoreError) -> BookStore {
        try BookStore(root: root)
    }

    /// Books, pages and the database live together here, backed up with the device, with default file protection so recognition and
    /// sync keep working while the phone is locked.
    private static var dataRoot: URL {
        #if DEBUG
        if let root = DebugLaunch.dataRoot { return root }
        #endif
        return URL.applicationSupportDirectory.appending(path: "ReadStair", directoryHint: .isDirectory)
    }

    private func start(_ store: BookStore) {
        importer = Importer(store: store, recognizer: Self.recognizer, timeout: Self.recognizerTimeout)
        let loop = RecognitionLoop(drain: { [weak self] () async throws(StoreError) in
            try await self?.recognitionPass()
        }, onError: { [weak self] error in
            self?.recognitionStopped(error)
        })
        self.loop = loop
        // The loop and the change consumer live as long as the app; neither is ever cancelled
        Task { await loop.run() }
        loop.kick()
        Task { [weak self] in
            for await change in store.changes {
                self?.noteChanges([change])
            }
        }
        startWordSync(store)
        refreshMeaningAvailable()
        Task { await refreshTranslationTarget() }
        // No scan can be open or waiting yet
        Task { await Self.removeScannedPageFiles() }
    }

    /// Starts iCloud sync of words and the level, in a task of its own so that the first merge of a long word list never holds up
    /// launch. Nothing else feeds it: every word or level write registers itself with the engine as it commits, and what arrives
    /// from iCloud comes back through `store.changes` like any other write. The engine waits for an iCloud account by itself.
    /// Compiled only into builds made with the iCloud switch (`READSTAIR_ICLOUD`), which also adds the entitlement and the
    /// remote-notification background mode: without the entitlement CloudKit raises an exception that ends the app. Not started on
    /// a DEBUG test store (`-ReadStairDataRoot`), so UI tests never send fixture words to the developer's iCloud.
    private func startWordSync(_ store: BookStore) {
        #if READSTAIR_ICLOUD
        #if DEBUG
        guard DebugLaunch.dataRoot == nil else { return }
        #endif
        let sync = WordSync(store: store)
        self.sync = sync
        Task {
            do {
                try await sync.start()
            } catch {
                Self.log.error("iCloud sync did not start: \(String(describing: error))")
            }
        }
        #endif
    }

    private static var recognizer: Importer.Recognizer {
        #if DEBUG
        switch DebugLaunch.recognizer {
        case .fail?: return { _ in throw DebugLaunch.RecognizerFailure() }
        // Reading until the recognizer's timeout ends it
        case .stall?: return { _ in try await Task.sleep(for: .seconds(3600)); throw DebugLaunch.RecognizerFailure() }
        case nil: break
        }
        #endif
        return { try await Recognition.page(from: $0) }
    }

    /// Whether the undo toast waits until something commits it besides VoiceOver and Switch Control: in DEBUG runs with
    /// `-ReadStairHoldsUndo YES`, so a UI test can use the toast without racing its 5 seconds.
    private static var holdsUndo: Bool {
        #if DEBUG
        DebugLaunch.holdsUndo
        #else
        false
        #endif
    }

    /// Whether a new store gets the sample book: always, except a DEBUG test store (`-ReadStairDataRoot`) without
    /// `-ReadStairSampleBook YES`, so UI tests keep their empty shelf and read no pages they did not add.
    private static var addsSampleBook: Bool {
        #if DEBUG
        DebugLaunch.dataRoot == nil || DebugLaunch.sampleBook
        #else
        true
        #endif
    }

    private static var recognizerTimeout: Duration {
        #if DEBUG
        if let timeout = DebugLaunch.recognizerTimeout { return timeout }
        #endif
        return .seconds(30)
    }

    private static func keyed(_ words: [WordEntry]) -> [String: WordEntry] {
        // The store keys rows by the same normalized lemma as PageWord.stateKey
        Dictionary(words.map { ($0.lemma, $0) }, uniquingKeysWith: { $1 })
    }

    // MARK: Store changes

    /// Changes are coalesced for 250 ms, then read back once: recognition progress, imports and iCloud changes all arrive this way.
    private func noteChanges(_ changes: Set<StoreChange>) {
        pendingChanges.formUnion(changes)
        guard flushTask == nil else { return }
        flushTask = Task {
            repeat {
                try? await Task.sleep(for: .milliseconds(250))
                await flush()
            } while !pendingChanges.isEmpty
            flushTask = nil
        }
    }

    private func flush() async {
        guard let store else { return }
        let changes = pendingChanges
        pendingChanges = []
        var changedBooks: Set<UUID> = []
        for case .pages(let bookID) in changes { changedBooks.insert(bookID) }
        for bookID in changedBooks { pageRevision[bookID, default: 0] += 1 }
        if changes.contains(.books) || !changedBooks.isEmpty {
            do {
                let summaries = try await store.bookSummaries()
                if summaries != books { books = summaries }
            } catch {
                Self.log.error("Reading the books failed: \(String(describing: error))")
            }
        }
        if changes.contains(.words) { await reloadWords(store) }
        if changes.contains(.profile) {
            do {
                let profile = try await store.profile()
                level = profile?.level ?? Profile.defaultLevel
                if glossSetting != profile?.glossLanguage {
                    glossSetting = profile?.glossLanguage
                    await refreshTranslationTarget()
                }
            } catch {
                Self.log.error("Reading the profile failed: \(String(describing: error))")
            }
        }
    }

    /// A reload that a local word write overlapped is dropped: it may predate the write and would flash the old state. Every local
    /// word write queues another reload when it finishes, so a dropped one is always replaced.
    private func reloadWords(_ store: BookStore) async {
        guard writesInFlight == 0 else { return }
        let completed = writesCompleted
        do {
            let words = try await store.wordEntries()
            guard writesInFlight == 0, writesCompleted == completed else { return }
            entries = Self.keyed(words)
        } catch {
            Self.log.error("Reading the word list failed: \(String(describing: error))")
        }
    }

    private func trackWordWrite(_ write: () async throws(StoreError) -> Void) async throws(StoreError) {
        writesInFlight += 1
        defer {
            writesInFlight -= 1
            writesCompleted += 1
            noteChanges([.words])
        }
        try await write()
    }

    // MARK: Recognition

    /// One pass of the recognition loop, holding background time while it runs.
    private func recognitionPass() async throws(StoreError) {
        guard let importer else { return }
        background.retain()
        defer { background.release() }
        try await importer.drain()
    }

    /// A pass stopped on a full disk or a database error; the pages stay queued and the next kick resumes them.
    private func recognitionStopped(_ error: StoreError) {
        Self.log.error("Recognition stopped: \(String(describing: error))")
        guard !recognitionAlertShown else { return }
        recognitionAlertShown = true
        show(error)
    }

    // MARK: Foreground and background

    /// `.inactive` does nothing: Control Center or a notification must not commit the pending undo.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background: enterBackground()
        case .active: becomeActive()
        default: break
        }
    }

    private func enterBackground() {
        // Background time is taken before anything waits
        background.retain()
        Task.immediate {
            await self.undoSlot.commitNow()
            await self.saveReadingPositions()
            self.background.release()
        }
        guard let loop else { return }
        loop.pause()
        guard loop.isRunningPass || !imports.isEmpty else { return }
        // Vision cannot be stopped mid-page and the expiration handler cannot wait, so cancel 10 s before the time runs out: the pages
        // in flight go back to the queue without counting an attempt. In the foreground the remaining time is huge, hence the cap.
        let delay = max(0, min(UIApplication.shared.backgroundTimeRemaining, 30) - 10)
        backgroundCancel?.cancel()
        backgroundCancel = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            cancelBackgroundWork()
        }
    }

    private func becomeActive() {
        backgroundCancel?.cancel()
        backgroundCancel = nil
        loop?.resume()
        refreshMeaningAvailable()
    }

    /// Recognition and photo and scan imports stop; pages already saved stay, and `Add Pages` can add the rest. An e-book import
    /// carries on (see `openFile`).
    private func cancelBackgroundWork() {
        loop?.cancelPass()
        for task in imports.values { task.cancel() }
    }

    private func saveReadingPositions() async {
        for bookID in lastViewed.keys { await saveReadingPosition(of: bookID) }
    }

    private func saveReadingPosition(of bookID: UUID) async {
        guard let store, let index = lastViewed[bookID], let book = book(bookID), book.lastPageIndex != index else { return }
        do {
            try await store.setLastPageIndex(index, of: bookID)
        } catch {
            Self.log.error("Saving the reading position failed: \(String(describing: error))")
        }
    }

    // MARK: Import

    /// Whether this device has the document camera (the simulator does not).
    static var canScan: Bool { DocumentScanner.isSupported }

    /// Opens the document camera, or explains that camera access is off. The system asks for access itself the first time.
    func scanPages(into target: ImportTarget) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: alert = .cameraAccessOff
        default: cover = .scanner(target)
        }
    }

    func choosePhotos(into target: ImportTarget) {
        #if DEBUG
        if let files = DebugLaunch.seedPages {
            importPages(.files(files), into: target)
            return
        }
        #endif
        photosTarget = target
    }

    /// `Choose from Files`: the system's file picker, for an EPUB or a plain text file. In DEBUG runs with `-ReadStairSeedFile`, that
    /// file instead. Nothing while a file is being opened: a second one would be read and laid out alongside it.
    func chooseFile() {
        guard !openingFile else { return }
        #if DEBUG
        if let file = DebugLaunch.seedFile {
            openFile(file)
            return
        }
        #endif
        showsFileImporter = true
    }

    /// Reads a chosen book file once, lays it out into pages on the device and imports them into a new book, already read (see
    /// `ImportSource.ebook`). The file itself is not kept. Whatever keeps it from opening, one alert says what can be opened. The
    /// Reader opens only if nothing was opened or closed since the file was chosen. Neither this nor its import is among the
    /// `imports` the background cancels: no typeset page waits on Vision, and a book cut short could not be finished, since `Add
    /// Pages` only adds photos or scans. Like the sample book, it pauses with the app and carries on when the app comes back. Known
    /// limit: a kill meanwhile leaves the book with the pages saved so far, and nothing marks it unfinished.
    func openFile(_ url: URL) {
        let pathAtStart = path, started = ContinuousClock.now
        openingFile = true
        background.retain()
        Task {
            defer {
                openingFile = false
                background.release()
            }
            do {
                let data = try await Self.contents(of: url)
                let book = try await TypesetBook.make(from: data, fileName: url.lastPathComponent)
                importPages(.ebook(book), into: .newBook, pathAtStart: pathAtStart)
            } catch {
                Self.log.error("Opening a book file failed: \(String(describing: error))")
                // A file that fails at once would bring the alert while the file picker is still sliding away, and it could be dropped
                try? await Task.sleep(until: started + .milliseconds(600))
                alert = .bookUnopenable
            }
        }
    }

    /// A chosen file's bytes, read within its security scope and through a file coordinator, so a file in iCloud Drive that is not on
    /// this iPhone yet is downloaded first; the coordinator waits for that on a queue of its own, not on a Swift concurrency thread. A
    /// file over the size limit is turned down before any of it is read. The bytes are copied, not mapped: once the coordinated read
    /// has ended, nothing depends on the file.
    @concurrent
    private static func contents(of url: URL) async throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let intent = NSFileAccessIntent.readingIntent(with: url)
        return try await withCheckedThrowingContinuation { continuation in
            NSFileCoordinator().coordinate(with: [intent], queue: OperationQueue()) { error in
                continuation.resume(with: Result {
                    if let error { throw error }
                    let file = try FileHandle(forReadingFrom: intent.url)
                    defer { try? file.close() }
                    guard try file.seekToEnd() <= EBookReader.maxFileBytes else { throw EBookError.tooLarge }
                    try file.seek(toOffset: 0)
                    return try file.readToEnd() ?? Data()
                })
            }
        }
    }

    /// The Reader's camera button: the document camera, or the Photos picker where there is none.
    func addPages(to bookID: UUID) {
        if Self.canScan {
            scanPages(into: .append(bookID: bookID))
        } else {
            choosePhotos(into: .append(bookID: bookID))
        }
    }

    /// The document camera is done; what follows waits until it has closed.
    func scannerFinished(_ outcome: ScanOutcome, target: ImportTarget) {
        switch outcome {
        case .cancelled: afterCover = nil
        case .failed: afterCover = { [weak self] in self?.alert = .somethingWentWrong }
        case .scanned(let source): afterCover = { [weak self] in self?.importPages(source, into: target) }
        }
        cover = nil
    }

    func coverDismissed() {
        coverOnScreen = false
        let action = afterCover
        afterCover = nil
        action?()
    }

    /// Starts one import, run by the app rather than a view, holding background time until it ends. A new book opens in the Reader,
    /// over its book page, only if the navigation stack is still as it was at `pathAtStart`, by default now. Only photos and scans
    /// are among the `imports` the background cancels (see `openFile`).
    func importPages(_ source: ImportSource, into target: ImportTarget, pathAtStart: [Route]? = nil) {
        guard importer != nil else { return }
        let id = UUID(), pathAtStart = pathAtStart ?? path
        background.retain()
        // Runs after this returns, on the main actor, so it is listed before it can end
        let task = Task {
            await runImport(source, into: target, pathAtStart: pathAtStart)
            imports[id] = nil
            if source.kind == .scanner {
                scanImports -= 1
                removeScannedPages()
            }
            background.release()
        }
        if source.kind != .ebook { imports[id] = task }
        if source.kind == .scanner { scanImports += 1 }
    }

    /// Once the last scan import has ended, and no scan is open or waiting to be imported (see `removeScannedPageFiles`).
    private func removeScannedPages() {
        guard scanImports == 0, !coverOnScreen, afterCover == nil else { return }
        Task { await Self.removeScannedPageFiles() }
    }

    /// The document camera keeps every page it scans as image files in the app's caches and never removes them: hundreds of
    /// megabytes after a few dozen pages. A scan's import reads its pages from them until it ends, so they go at launch and after the
    /// last scan import (`removeScannedPages`).
    @concurrent
    private static func removeScannedPageFiles() async {
        try? FileManager.default.removeItem(at: URL.cachesDirectory.appending(path: "com.apple.DocumentCamera/Scans"))
    }

    private func runImport(_ source: ImportSource, into target: ImportTarget, pathAtStart: [Route]) async {
        guard let store, let importer else { return }
        let bookID: UUID
        switch target {
        case .newBook:
            do throws(StoreError) {
                let title = source.title ?? Date.now.formatted(date: .abbreviated, time: .shortened)
                bookID = try await store.createBook(title: title).id
            } catch {
                show(error)
                return
            }
        case .append(let id):
            bookID = id
        }
        let isNew = target == .newBook
        var pagesBefore: Set<UUID> = []
        if !isNew { pagesBefore = Set(((try? await store.pages(of: bookID)) ?? []).map(\.id)) }
        let progress = ImportProgress()
        var saved = 0
        var failure: StoreError?
        do throws(StoreError) {
            // The first page is saved once a page has come back and the next one is asked for (the one before may have been
            // unreadable and skipped), or once the import returns with a page saved
            saved = try await importer.importPages(count: source.count, into: bookID, page: { @MainActor [weak self] index in
                if progress.hasPage, !progress.announced {
                    progress.announced = true
                    await self?.firstPageSaved(bookID: bookID, isNew: isNew, pathAtStart: pathAtStart, pagesBefore: pagesBefore)
                }
                let page = await source.page(index)
                if page != nil { progress.hasPage = true }
                return page
            })
        } catch {
            failure = error
        }
        if saved > 0, !progress.announced {
            progress.announced = true
            await firstPageSaved(bookID: bookID, isNew: isNew, pathAtStart: pathAtStart, pagesBefore: pagesBefore)
        }
        loop?.kick()
        // A new book that ended with no page, for whatever reason, is removed; a book emptied later by Delete Page never is
        if isNew, saved == 0 {
            do { try await store.deleteBook(bookID) } catch { Self.log.error("Removing an empty book failed: \(String(describing: error))") }
        }
        if let failure {
            show(failure)
        } else if saved == 0, !Task.isCancelled {
            alert = switch source.kind {
            case .photos: .photosUnreadable
            case .ebook: .bookUnopenable
            case .scanner: .somethingWentWrong
            }
        }
    }

    private func firstPageSaved(bookID: UUID, isNew: Bool, pathAtStart: [Route], pagesBefore: Set<UUID>) async {
        loop?.kick()
        if isNew {
            // Only if nothing was opened or closed since the import began, and the book is not waiting to be deleted. New books start
            // from Books, so Back from the Reader leads to the book's page, then to Books.
            guard path == pathAtStart, hiddenBookID != bookID, !deletedIDs.contains(bookID) else { return }
            path.append(contentsOf: [.book(bookID), .reader(bookID: bookID, pageID: nil)])
        } else {
            guard case .reader(bookID, _)? = path.last,
                  let pages = try? await store?.pages(of: bookID),
                  let first = pages.first(where: { !pagesBefore.contains($0.id) }) else { return }
            firstAddedPage = first
        }
    }

    func firstAddedPageShown() {
        firstAddedPage = nil
    }

    // MARK: Books

    func deleteBook(_ id: UUID) {
        undoSlot.propose(.deleteBook(id))
    }

    func rename(_ bookID: UUID, to title: String) {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitleLength))
        guard let store, !title.isEmpty, let index = books.firstIndex(where: { $0.book.id == bookID }) else { return }
        let old = books[index].book.title
        guard title != old else { return }
        books[index].book.title = title
        Task {
            do throws(StoreError) {
                try await store.renameBook(bookID, to: title)
            } catch {
                if let index = books.firstIndex(where: { $0.book.id == bookID }), books[index].book.title == title {
                    books[index].book.title = old
                }
                show(error)
            }
        }
    }

    // MARK: Reader

    /// The Reader's page came to rest; remembered in memory only.
    func pageSettled(bookID: UUID, pageIndex: Int) {
        lastViewed[bookID] = pageIndex
    }

    /// The Reader left the navigation stack: its card went with it, the pending undo commits, and the reading position is saved if it
    /// moved.
    func readerClosed(bookID: UUID) {
        cardOnScreen = false
        Task.immediate {
            await self.undoSlot.commitNow()
            await self.saveReadingPosition(of: bookID)
        }
    }

    /// `Try Again` on a page whose reading failed.
    func retry(pageID: UUID) {
        guard let store else { return }
        Task {
            do throws(StoreError) { try await store.retry(pageID) } catch { show(error) }
            loop?.kick()
        }
    }

    func deletePage(_ pageID: UUID) {
        undoSlot.propose(.deletePage(pageID))
    }

    /// Opening a word's card in the Reader adds the word to the word list when the level is what marks it (it has no state of its
    /// own, is a plain word, and its band is above the level). It never changes an underline, so nothing waits for it; a failure is
    /// only logged, since the user did not ask for the write.
    func openCard(_ word: PageWord, sentence: String?, pageID: UUID, bookID: UUID) {
        guard let store,
              let entry = WordEntry.entryOnOpen(word: word, state: effectiveState(of: word.stateKey), level: level, bookID: bookID,
                                                pageID: pageID, sentence: sentence) else { return }
        Task {
            do {
                try await trackWordWrite { () async throws(StoreError) in try await store.upsertWord(entry, onlyIfAbsent: true) }
            } catch {
                Self.log.error("Adding a looked-up word failed: \(String(describing: error))")
            }
        }
    }

    // MARK: Word card

    /// `I Know This` or `Mark as New`, whichever the card shows: proposed to the undo toast.
    func primary(_ card: CardWord) {
        let (bookID, pageID): (UUID?, UUID?) = switch card.origin {
        case .page(let bookID, let pageID, _): (bookID, pageID)
        case .list(let bookID, let pageID): (bookID, pageID)
        }
        undoSlot.propose(.word(WordChange(stateKey: card.stateKey, state: isMarked(card) ? .known : .learning, band: card.word.band,
                                          headword: card.headword, bookID: bookID, pageID: pageID, sentence: card.sentence)))
    }

    // MARK: Undo

    func undo() {
        undoSlot.undo()
    }

    /// Writes a change the undo toast let go of. Everything before the first `await` runs as the slot lets go, so what the screens
    /// show never flashes back to the undone state; a failed write puts back what was shown, if nothing replaced it meanwhile.
    private func commit(_ change: PendingChange) async {
        guard let store else { return }
        background.retain()
        defer { background.release() }
        switch change {
        case .word(let change):
            let old = entries[change.stateKey]
            let shown = change.applied(to: old)
            entries[change.stateKey] = shown
            // Always with the card's first-seen context: the store keeps a context it already has
            let entry = WordEntry(lemma: change.stateKey, state: change.state, source: .card, band: change.band,
                                  firstBookID: change.bookID, firstPageID: change.pageID, firstSentence: change.sentence)
            do throws(StoreError) {
                try await trackWordWrite { () async throws(StoreError) in try await store.upsertWord(entry) }
            } catch {
                if entries[change.stateKey] == shown { entries[change.stateKey] = old }
                show(error)
            }
        case .deletePage(let pageID):
            deletedIDs.insert(pageID)
            do throws(StoreError) {
                try await store.deletePage(pageID)
            } catch {
                deletedIDs.remove(pageID)
                show(error)
            }
        case .deleteBook(let bookID):
            deletedIDs.insert(bookID)
            do throws(StoreError) {
                try await store.deleteBook(bookID)
            } catch {
                deletedIDs.remove(bookID)
                show(error)
            }
        }
    }

    // MARK: Level and translation language

    /// A level row: saved at once, with no toast; tapping the row checked before takes it back.
    func setLevel(_ newLevel: Int) {
        guard newLevel != level else { return }
        saveLevel(newLevel)
    }

    /// Continue on the level test: the level its answers estimate, saved like a chosen one, so it becomes the level on every device.
    /// Returns whether the answers say too little to trust it.
    func finishTest(_ known: Set<VocabTest.Item>) -> Bool {
        let estimate = VocabTest.estimate(selected: known)
        saveLevel(estimate.level)
        return estimate.unreliable
    }

    /// Skip on the level test: the default level, kept as a placeholder that never syncs and that any level from iCloud replaces (one
    /// already here from iCloud stays). The test closes at once and the level is written behind it; if the write fails, the alert
    /// comes once the test is closed, and the test comes back at the next launch.
    func skipTest() {
        guard let store else { return }
        cover = nil
        Task {
            do throws(StoreError) { try await store.skipLevelTest() } catch { show(error) }
        }
    }

    /// Translate To: `"en"` for Off, else a language identifier. A choice no longer follows the device languages, and it clears a
    /// download turned down earlier in this run, so cards offer the download again.
    func setGloss(_ language: String) {
        guard let store, language != glossSetting else { return }
        let old = glossSetting
        glossSetting = language
        translationDeclined = false
        Task {
            await refreshTranslationTarget()
            do throws(StoreError) {
                try await store.setGlossLanguage(language)
            } catch {
                if glossSetting == language {
                    glossSetting = old
                    await refreshTranslationTarget()
                }
                show(error)
            }
        }
    }

    /// Shows the level at once and saves it; a failed write puts back the level shown before, unless another has replaced it.
    private func saveLevel(_ newLevel: Int) {
        guard let store else { return }
        let old = level
        level = newLevel
        Task {
            do throws(StoreError) {
                try await store.setLevel(newLevel)
            } catch {
                if level == newLevel { level = old }
                show(error)
            }
        }
    }

    // MARK: Word card services

    /// The target language comes from the setting, else the device languages; one the Translation framework does not support at all
    /// is dropped (checked once per language per run; checking never downloads anything).
    private func refreshTranslationTarget() async {
        let setting = glossSetting
        let language: Locale.Language? = switch setting {
        case nil: Gloss.defaultTargetLanguage()
        case "en"?: nil
        case let identifier?: Locale.Language(identifier: identifier)
        }
        guard let language, language.languageCode != .english else {
            translationTarget = nil
            return
        }
        let key = language.maximalIdentifier
        if translationSupported[key] == nil {
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: language)
            translationSupported[key] = status != .unsupported
        }
        // A choice made while the check ran has its own refresh, which must not be overwritten with this one's language
        guard glossSetting == setting else { return }
        translationTarget = translationSupported[key] == true ? language : nil
    }

    private func refreshMeaningAvailable() {
        let availability = Self.appleIntelligence
        meaningAvailable = availability == .available
        appleIntelligenceOff = availability == .unavailable(.appleIntelligenceNotEnabled)
    }

    /// In DEBUG runs `-ReadStairAppleIntelligence` stands in for the device's answer.
    private static var appleIntelligence: SystemLanguageModel.Availability {
        #if DEBUG
        if let forced = DebugLaunch.appleIntelligence { return forced }
        #endif
        return SystemLanguageModel.default.availability
    }

    /// Called by the word card once the user can see its hint to turn Apple Intelligence on (an app can neither turn it on nor download
    /// its model, only Settings can). Saved at once, so no other card shows it, in this run or a later one.
    func appleIntelligenceHintSeen() {
        appleIntelligenceHintShown = true
        UserDefaults.standard.set(true, forKey: Self.appleIntelligenceHintKey)
    }

    /// In DEBUG runs `-ReadStairResetAppleIntelligenceHint YES` clears it first, so a UI test starts as if it had never been shown.
    private static func savedAppleIntelligenceHint() -> Bool {
        #if DEBUG
        if DebugLaunch.resetsAppleIntelligenceHint { UserDefaults.standard.removeObject(forKey: appleIntelligenceHintKey) }
        #endif
        return UserDefaults.standard.bool(forKey: appleIntelligenceHintKey)
    }

    // MARK: Alerts

    private func show(_ error: StoreError) {
        switch error {
        case .insufficientDisk, .diskFull: alert = .storageFull
        // The book was deleted while pages were being added to it: nothing to say
        case .bookNotFound: break
        default: alert = .somethingWentWrong
        }
    }
}

extension OSLog {
    /// Signpost intervals that the UI tests measure with XCTOSSignpostMetric and that Instruments shows.
    static let performance = OSLog(subsystem: "app.readstair", category: "performance")
}

extension PendingChange {
    /// The toast's text, also announced to VoiceOver when the toast appears.
    var toastText: String {
        switch self {
        case .word(let change) where change.state == .known: String(localized: "Marked “\(change.headword)” as known")
        case .word(let change): String(localized: "Marked “\(change.headword)” as new")
        case .deletePage: String(localized: "Page deleted")
        case .deleteBook: String(localized: "Book deleted")
        }
    }
}

/// Whether an import has fetched a readable page yet, and whether its first saved page has been acted on.
private final class ImportProgress {
    var hasPage = false
    var announced = false
}

/// One app-wide background task, held while any import, recognition pass or commit runs: begun when the first holder takes it, ended
/// when the last lets go. When the time runs out the handler cancels recognition and photo and scan imports and ends the task at once;
/// it cannot wait for Vision. What is left, such as an e-book import, is suspended with the app.
private final class BackgroundToken {
    private var holders = 0
    private var task = UIBackgroundTaskIdentifier.invalid
    private let expire: () -> Void

    init(expire: @escaping () -> Void) {
        self.expire = expire
    }

    func retain() {
        holders += 1
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "ReadStair") { [weak self] in
            self?.expire()
            self?.end()
        }
    }

    func release() {
        holders = max(0, holders - 1)
        if holders == 0 { end() }
    }

    /// Idempotent: the task is ended once, whether the last holder or the expiration handler gets there first.
    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

#if DEBUG
/// Launch arguments for UI tests, in DEBUG builds only.
enum DebugLaunch {
    /// `-ReadStairDataRoot <dir>`: a store of its own (fresh, or prepared in advance). A relative path is looked up in the app's
    /// Documents: a device cannot read the Mac's files, so the perf store is copied there.
    static var dataRoot: URL? {
        UserDefaults.standard.string(forKey: "ReadStairDataRoot").map { path in
            path.hasPrefix("/") ? URL(filePath: path, directoryHint: .isDirectory)
                : URL.documentsDirectory.appending(path: path, directoryHint: .isDirectory)
        }
    }

    /// `-ReadStairSeedPages <path,…>`: `Choose from Photos` imports these files instead of opening the picker, which runs out of process
    /// where UI tests cannot drive it. Simulator runs only: the paths are the Mac's.
    static var seedPages: [URL]? {
        UserDefaults.standard.string(forKey: "ReadStairSeedPages").map { $0.split(separator: ",").map { URL(filePath: String($0)) } }
    }

    /// `-ReadStairSeedFile <path>`: `Choose from Files` opens this book file instead of the file picker, which runs out of process too.
    /// Simulator runs only: the path is the Mac's.
    static var seedFile: URL? {
        UserDefaults.standard.string(forKey: "ReadStairSeedFile").map { URL(filePath: $0) }
    }

    /// `-ReadStairRecognizerTimeout <seconds>`: a slower machine needs longer than the 30 s a page gets on a phone.
    static var recognizerTimeout: Duration? {
        let seconds = UserDefaults.standard.double(forKey: "ReadStairRecognizerTimeout")
        return seconds > 0 ? .seconds(seconds) : nil
    }

    /// `-ReadStairRecognizer fail`: every page fails to read; `stall`: every page stays Reading until the recognizer's timeout.
    static var recognizer: Recognizer? {
        UserDefaults.standard.string(forKey: "ReadStairRecognizer").flatMap(Recognizer.init)
    }

    enum Recognizer: String {
        case fail, stall
    }

    /// `-ReadStairHoldsUndo YES`: the undo toast stays until something commits it, as with VoiceOver on.
    static var holdsUndo: Bool {
        UserDefaults.standard.bool(forKey: "ReadStairHoldsUndo")
    }

    /// `-ReadStairSampleBook YES`: a new `-ReadStairDataRoot` store gets the sample book too, as a new store outside the tests does.
    static var sampleBook: Bool {
        UserDefaults.standard.bool(forKey: "ReadStairSampleBook")
    }

    /// `-ReadStairCloudLevel <n>`: three seconds into the first-launch level test, level n arrives as if from iCloud, through the store's
    /// own merge of fetched records.
    static var cloudLevel: Int? {
        let level = UserDefaults.standard.integer(forKey: "ReadStairCloudLevel")
        return level > 0 ? level : nil
    }

    /// `-ReadStairAppleIntelligence notEnabled|available|unavailable`: Apple Intelligence turned off in Settings (the word card's
    /// one-time hint), on, or not possible on this device, whatever the simulator reports.
    static var appleIntelligence: SystemLanguageModel.Availability? {
        switch UserDefaults.standard.string(forKey: "ReadStairAppleIntelligence") {
        case "notEnabled"?: .unavailable(.appleIntelligenceNotEnabled)
        case "available"?: .available
        case "unavailable"?: .unavailable(.deviceNotEligible)
        default: nil
        }
    }

    /// `-ReadStairResetAppleIntelligenceHint YES`: the saved flag that the hint was shown is cleared at launch, so a relaunch without it
    /// reads what this run saved.
    static var resetsAppleIntelligenceHint: Bool {
        UserDefaults.standard.bool(forKey: "ReadStairResetAppleIntelligenceHint")
    }

    nonisolated struct RecognizerFailure: Error {}
}
#endif
