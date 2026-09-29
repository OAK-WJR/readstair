import OSLog
import ReadStairCore
import SwiftUI
import UIKit

/// The line a page shows in the bottom capsule, and as its VoiceOver value, when its words cannot be tapped (being read, failed) or
/// do not matter (no English text).
nonisolated enum PageStatus: Hashable {
    case reading
    case failed
    case noText

    var text: LocalizedStringResource {
        switch self {
        case .reading: "Reading page…"
        case .failed: "Couldn’t read this page."
        case .noText: "No English text found on this page."
        }
    }
}

/// What a page shows now, derived from its recognition status, its text, and the words marked at the current level and word states.
struct PageLook {
    /// The text the ink is drawn from and taps hit; nil while the page is being read or failed, and for the moment its text loads.
    var text: PageText?
    /// Indices into `text.words` to underline, in reading order.
    var marked: [Int] = []
    var status: PageStatus?

    /// No marks: English text with nothing underlined. The subtitle says so; there is no capsule.
    var hasNoNewWords: Bool { text != nil && status == nil && marked.isEmpty }

    /// The page summary's VoiceOver value: the capsule's line, else the new-word count; empty for the moment the text loads.
    var summaryValue: String {
        if let status { return String(localized: status.text) }
        guard text != nil else { return "" }
        return marked.isEmpty ? String(localized: "No new words") : String(localized: "\(marked.count) new words")
    }
}

/// The state of one open Reader: the book's pages, the page on screen, the images and texts around it, and the open word card.
/// SwiftUI may build it again each time the Reader view is created, so creating it does nothing; the view's task calls
/// `reload(from:)`. Pages come from the store; which of them show, and every word state, come from the app model.
@MainActor
@Observable
final class ReaderModel {
    /// A toolbar action that presents something: `Add Pages` the document camera, the Photos picker or the camera alert; `How Many to
    /// Mark…` Settings.
    enum Action {
        case addPages
        case howManyToMark
    }

    let bookID: UUID
    /// The page the Reader was asked to open at, if any.
    let requestedPageID: UUID?

    /// The book's pages as stored, by index; nil until first read. A deleted page stays here until the store drops it; the app model
    /// says which pages show (`visiblePages`).
    private(set) var storedPages: [Page]?
    /// The page on screen, bound to the pager's scroll position.
    var currentPageID: UUID? {
        didSet { if currentPageID != oldValue { currentPageChanged() } }
    }
    /// Whether the current page is zoomed in; the pager does not page meanwhile. Zoomed in, the page loads its full image when its
    /// screen-size one is smaller (`zoomedImage`); back at fit width, or on another page, that goes.
    private(set) var isZoomed = false {
        didSet { if !isZoomed, zoomedImage != nil { zoomedImage = nil } }
    }
    /// The open word card; nil when none is. Setting another word swaps the open card's content in place. The card counts as on
    /// screen from the moment it is set until its sheet is gone (`cardDismissed()`), slide-out included.
    var card: CardWord? {
        didSet {
            guard let card else { return }
            shownCard = card
            app?.cardOnScreen = true
        }
    }
    /// The card opened last: the sheet keeps showing it while it slides away.
    private(set) var shownCard: CardWord?
    /// The Settings sheet, opened from `How Many to Mark…`.
    var showsSettings = false
    /// Images of the current page and its neighbours, decoded to fit the screen's width (`pixelWidth`).
    private var images: [UUID: CGImage] = [:]
    /// The current page's image at its stored size while it is zoomed in, where the screen-size one would blur.
    private var zoomedImage: CGImage?
    /// Thumbnails of pages up to two away: what shows until an image arrives, so a page never flashes empty.
    private var thumbnails: [UUID: CGImage] = [:]
    /// Recognized texts of the pages seen lately: at most five, the current page and its neighbours always among them.
    private var texts: [UUID: PageText] = [:] {
        didSet { marks = marks.filter { texts[$0.key] != nil } }
    }
    /// Whether each recognized page is English, worked out off the main actor once per page.
    private var english: [UUID: Bool] = [:]
    /// Recognized pages whose text cannot be read back: shown as still being read.
    private var textlessPages: Set<UUID> = []
    /// A page just deleted: it stays in the pager for one more pass after the pager has moved off it.
    private var lingeringPageID: UUID?

    @ObservationIgnored private var app: AppModel?
    /// The screen's width in pixels, which the images near the current page are decoded to fit; zero until the Reader is laid out,
    /// and they decode at their stored size meanwhile.
    @ObservationIgnored var pixelWidth: CGFloat = 0
    /// Each loaded text's marks, and what they were worked out for: its words' state keys are normalized once per text, and the
    /// marks are worked out again only when the level, a word's state or the change waiting in the toast does.
    @ObservationIgnored private var marks: [UUID: Marks] = [:]
    /// What the toolbar asked for while a card was open; it runs once the card is gone.
    @ObservationIgnored private var queuedAction: Action?
    @ObservationIgnored private var imageLoader: Task<Void, Never>?
    @ObservationIgnored private var textLoader: Task<Void, Never>?
    /// Image files that could not be read: not tried again while this Reader is open.
    @ObservationIgnored private var unreadableImages: Set<UUID> = []
    @ObservationIgnored private var unreadableThumbnails: Set<UUID> = []
    /// Texts whose read failed; tried again after the next reload.
    @ObservationIgnored private var textFailures: Set<UUID> = []
    /// Pages with a text, least recently used first.
    @ObservationIgnored private var textUse: [UUID] = []

    private static let textCacheSize = 5
    private static let log = Logger(subsystem: "app.readstair", category: "reader")

    init(bookID: UUID, pageID: UUID?) {
        self.bookID = bookID
        requestedPageID = pageID
    }

    // MARK: Pages

    /// The pages that show, in order: stored pages minus the one waiting in the undo toast and those deleted this run.
    var visiblePages: [Page] {
        guard let app, let storedPages else { return [] }
        return app.visible(storedPages)
    }

    /// What the pager lays out: the visible pages, and a just-deleted page for the one pass it lingers.
    var pagerPages: [Page] {
        guard let app, let storedPages else { return [] }
        return app.visible(storedPages, keeping: lingeringPageID)
    }

    var currentPage: Page? {
        storedPages?.first { $0.id == currentPageID }
    }

    /// Reading while the page is queued or being read (or its text cannot be read back); Failed; No text when recognition found
    /// nothing but punctuation or the page is confidently not English; otherwise its marked words, none being No marks.
    func look(of page: Page) -> PageLook {
        switch page.status {
        case .pending, .recognizing:
            return PageLook(status: .reading)
        case .failed:
            return PageLook(status: .failed)
        case .recognized:
            guard let text = texts[page.id] else {
                return textlessPages.contains(page.id) ? PageLook(status: .reading) : PageLook()
            }
            // Its words can still be tapped, to see what was read
            if english[page.id] == false || !text.words.contains(where: { $0.kind != .punct }) {
                return PageLook(text: text, status: .noText)
            }
            return PageLook(text: text, marked: marked(on: page.id, in: text))
        }
    }

    private struct Marks {
        let keys: [String]
        var basis: AppModel.MarksBasis?
        var marked: [Int] = []
    }

    /// The page's marked words, worked out again only when what they depend on has changed. The basis is read on every call, so the
    /// view asking keeps observing it.
    private func marked(on pageID: UUID, in text: PageText) -> [Int] {
        guard let app else { return [] }
        let basis = app.marksBasis
        var entry = marks[pageID] ?? Marks(keys: text.words.map(\.stateKey))
        if entry.basis != basis {
            entry.marked = app.markedWords(in: text, keys: entry.keys)
            entry.basis = basis
            marks[pageID] = entry
        }
        return entry.marked
    }

    /// The current page's full image while it is zoomed in, else the screen-size image near the current page, else the thumbnail; nil
    /// shows a fill of the page's shape.
    func image(of page: Page) -> CGImage? {
        if page.id == currentPageID, let zoomedImage { return zoomedImage }
        return images[page.id] ?? thumbnails[page.id]
    }

    /// The current page's marked words and all its words, for the Settings sheet's `This page` line: only while the page is Marked or
    /// No marks. Every occurrence of a marked word counts; punctuation does not.
    var pageTally: (new: Int, words: Int)? {
        guard let page = currentPage else { return nil }
        let shown = look(of: page)
        guard let text = shown.text, shown.status == nil else { return nil }
        return (shown.marked.count, text.words.count(where: { $0.kind != .punct }))
    }

    /// The index of the word whose card is open, if it is on this page.
    func selectedWord(on pageID: UUID) -> Int? {
        guard case .page(_, let id, let index)? = card?.origin, id == pageID else { return nil }
        return index
    }

    // MARK: Loading

    /// Reads the book's pages: when the Reader appears, and again whenever the store changes them.
    func reload(from app: AppModel) async {
        self.app = app
        let pages: [Page]
        do {
            pages = try await app.pages(of: bookID)
        } catch {
            Self.log.error("Reading the pages failed: \(String(describing: error))")
            // Only when there is nothing to show; a later failure keeps the pages already shown
            if storedPages == nil { app.alert = .somethingWentWrong }
            return
        }
        guard !Task.isCancelled else { return }
        apply(pages)
    }

    private func apply(_ pages: [Page]) {
        let previous = storedPages
        // A page that is not recognized now keeps nothing from an earlier reading: it gets its text again when read again
        let recognized = Set(pages.lazy.filter { $0.status == .recognized }.map(\.id))
        for id in Set(texts.keys).union(english.keys).union(textlessPages) where !recognized.contains(id) {
            if texts[id] != nil { texts[id] = nil }
            if english[id] != nil { english[id] = nil }
            if textlessPages.contains(id) { textlessPages.remove(id) }
        }
        textFailures = []
        if previous != pages { storedPages = pages }
        if let previous {
            keepCurrentPage(previous: previous)
        } else {
            currentPageID = openingPage()?.id
        }
        closeCardIfItsPageChanged()
        loadWindow()
        revealFirstAddedPage()
    }

    /// Where the Reader opens: the page it was asked for, if it still shows; else the first page at or after where the reader was
    /// (this run's position, else the saved one); else the last page.
    private func openingPage() -> Page? {
        let visible = visiblePages
        if let requestedPageID, let page = visible.first(where: { $0.id == requestedPageID }) { return page }
        guard let app else { return visible.last }
        let index = app.openingIndex(of: bookID)
        return visible.first { $0.index >= index } ?? visible.last
    }

    /// The current page is gone: the page that moved up takes its place, else the last one. An empty book that got pages opens as a
    /// book would.
    private func keepCurrentPage(previous: [Page]) {
        let visible = visiblePages
        if let currentPageID, visible.contains(where: { $0.id == currentPageID }) { return }
        guard let index = previous.first(where: { $0.id == currentPageID })?.index else {
            currentPageID = openingPage()?.id
            return
        }
        currentPageID = (visible.first { $0.index >= index } ?? visible.last)?.id
    }

    /// A card closes when its page no longer shows or is no longer recognized.
    private func closeCardIfItsPageChanged() {
        guard case .page(_, let pageID, _)? = card?.origin else { return }
        if visiblePages.first(where: { $0.id == pageID })?.status != .recognized { card = nil }
    }

    /// Paging closes the card and ends any zoom; the page is remembered as where the reader is, and what is around it loads.
    private func currentPageChanged() {
        if card != nil { card = nil }
        if isZoomed { isZoomed = false }
        if let app, let page = currentPage { app.pageSettled(bookID: bookID, pageIndex: page.index) }
        loadWindow()
    }

    /// Screen-size images for the current page and one page either side, thumbnails two either side; enforced here rather than left
    /// to the lazy stack, which may keep more pages alive (their values carry no image, see `PageView.imageID`). Then loads whatever
    /// is missing, nearest first.
    private func loadWindow() {
        let distance = Dictionary(uniqueKeysWithValues: neighbors(within: 2).map { ($0.page.id, $0.distance) })
        if images.keys.contains(where: { (distance[$0] ?? .max) > 1 }) {
            images = images.filter { (distance[$0.key] ?? .max) <= 1 }
        }
        if thumbnails.keys.contains(where: { distance[$0] == nil }) {
            thumbnails = thumbnails.filter { distance[$0.key] != nil }
        }
        for neighbor in neighbors(within: 1) where texts[neighbor.page.id] != nil {
            touchText(neighbor.page.id)
        }
        loadImages()
        loadTexts()
    }

    private struct Neighbor {
        let page: Page
        let distance: Int
    }

    /// The pages that show within `radius` of the current one, nearest first; the next page before the previous one, as reading goes
    /// forward.
    private func neighbors(within radius: Int) -> [Neighbor] {
        let visible = visiblePages
        guard let index = visible.firstIndex(where: { $0.id == currentPageID }) else { return [] }
        var result = [Neighbor(page: visible[index], distance: 0)]
        for distance in 1...radius {
            if index + distance < visible.count { result.append(Neighbor(page: visible[index + distance], distance: distance)) }
            if index - distance >= 0 { result.append(Neighbor(page: visible[index - distance], distance: distance)) }
        }
        return result
    }

    // MARK: Images

    private struct ImageJob {
        enum Size {
            case thumbnail, screen, full
        }

        let page: Page
        let size: Size
    }

    /// One image at a time, looking again at what is needed after each: a fast swipe never queues decodes for pages already passed.
    private func loadImages() {
        guard imageLoader == nil else { return }
        imageLoader = Task { [weak self] in
            while let job = self?.nextImageJob() {
                let image = await self?.load(job)
                self?.finish(job, image: image)
            }
            self?.imageLoader = nil
        }
    }

    /// The current page's full image first while it is zoomed in, if its screen-size one is smaller. Then a page's thumbnail while it
    /// has no image (it decodes fast and fills the page), and its screen-size image if it is the current page or next to it; the
    /// current page first, then the next, the previous, and the thumbnails two pages out.
    private func nextImageJob() -> ImageJob? {
        if isZoomed, zoomedImage == nil, let page = currentPage, screenPixelSize(of: page) != nil, !unreadableImages.contains(page.id) {
            return ImageJob(page: page, size: .full)
        }
        for neighbor in neighbors(within: 2) {
            let id = neighbor.page.id
            if images[id] == nil, thumbnails[id] == nil, !unreadableThumbnails.contains(id) {
                return ImageJob(page: neighbor.page, size: .thumbnail)
            }
            if neighbor.distance <= 1, images[id] == nil, !unreadableImages.contains(id) {
                return ImageJob(page: neighbor.page, size: .screen)
            }
        }
        return nil
    }

    private func load(_ job: ImageJob) async -> CGImage? {
        guard let app else { return nil }
        switch job.size {
        case .thumbnail: return await app.thumbnail(of: job.page)
        case .screen: return await app.image(of: job.page, maxPixelSize: screenPixelSize(of: job.page))
        case .full: return await app.image(of: job.page)
        }
    }

    /// The long edge that gives the page the screen's width in pixels (at fit width it is that less its margins); nil when the page
    /// is stored no wider, or before the width is known, and its screen-size image is then the stored one.
    private func screenPixelSize(of page: Page) -> Int? {
        guard pixelWidth > 0, CGFloat(page.width) > pixelWidth else { return nil }
        return Int((pixelWidth * CGFloat(max(page.width, page.height)) / CGFloat(page.width)).rounded(.up))
    }

    /// Kept only if the page is still near enough, or still zoomed in for its full image; a file that cannot be read is not tried
    /// again (the page shows its thumbnail, or a fill, and `Delete Page` can remove it).
    private func finish(_ job: ImageJob, image: CGImage?) {
        let id = job.page.id
        guard let image else {
            if job.size == .thumbnail { unreadableThumbnails.insert(id) } else { unreadableImages.insert(id) }
            return
        }
        let distance = neighbors(within: 2).first { $0.page.id == id }?.distance
        switch job.size {
        case .thumbnail: if distance != nil { thumbnails[id] = image }
        case .screen: if let distance, distance <= 1 { images[id] = image }
        case .full: if isZoomed, id == currentPageID { zoomedImage = image }
        }
    }

    // MARK: Texts

    private func loadTexts() {
        guard textLoader == nil else { return }
        textLoader = Task { [weak self] in
            while let page = self?.nextTextJob() {
                await self?.loadText(of: page)
            }
            self?.textLoader = nil
        }
    }

    /// The current page's text first, then the next page's and the previous page's.
    private func nextTextJob() -> Page? {
        neighbors(within: 1).map(\.page).first { page in
            page.status == .recognized && texts[page.id] == nil && !textlessPages.contains(page.id) && !textFailures.contains(page.id)
        }
    }

    private func loadText(of page: Page) async {
        guard let app else { return }
        let text: PageText?
        do {
            text = try await app.pageText(of: page.id)
        } catch {
            Self.log.error("Reading a page's text failed: \(String(describing: error))")
            textFailures.insert(page.id)
            return
        }
        var isEnglish = english[page.id]
        if isEnglish == nil, let text { isEnglish = await Self.isEnglish(text) }
        // The page may have been deleted or queued again meanwhile
        guard storedPages?.first(where: { $0.id == page.id })?.status == .recognized else { return }
        guard let text else {
            textlessPages.insert(page.id)
            return
        }
        // Set together with the text, so the page never shows its marks before it is known to be English
        if english[page.id] != isEnglish { english[page.id] = isEnglish }
        texts[page.id] = text
        touchText(page.id)
        evictTexts()
    }

    /// NLLanguageRecognizer takes several milliseconds on a full page, more on its first use.
    @concurrent
    private static func isEnglish(_ text: PageText) async -> Bool {
        PageLanguage.isEnglish(text)
    }

    private func touchText(_ id: UUID) {
        textUse.removeAll { $0 == id }
        textUse.append(id)
    }

    private func evictTexts() {
        let kept = Set(neighbors(within: 1).map(\.page.id))
        while texts.count > Self.textCacheSize, let oldest = textUse.first(where: { !kept.contains($0) }) {
            textUse.removeAll { $0 == oldest }
            texts[oldest] = nil
        }
    }

    // MARK: Interaction

    /// A tap on a word, or VoiceOver activating one: opens its card, or swaps the open card to it in place. Opening adds the word to
    /// the word list if the level is what marks it (the app model decides); it never changes an underline.
    func select(_ index: Int, onPage pageID: UUID) {
        guard let app, pageID == currentPageID, currentPage?.status == .recognized,
              let text = texts[pageID], text.words.indices.contains(index) else { return }
        let word = text.words[index]
        let sentence = text.sentences.indices.contains(word.sentence) ? text.sentences[word.sentence] : nil
        let selection = CardWord(word: word, sentence: sentence, origin: .page(bookID: bookID, pageID: pageID, index: index))
        guard selection.id != card?.id else { return }
        card = selection
        app.openCard(word, sentence: sentence, pageID: pageID, bookID: bookID)
    }

    func zoomChanged(_ zoomed: Bool, onPage pageID: UUID) {
        guard pageID == currentPageID, zoomed != isZoomed else { return }
        isZoomed = zoomed
        if zoomed { loadImages() }
    }

    /// `Try Again` on a page whose reading failed; it shows as being read once the store has queued it again.
    func retryCurrentPage() {
        guard let app, let page = currentPage, page.status == .failed else { return }
        app.retry(pageID: page.id)
    }

    /// With a card on screen, even one sliding away, the card closes first and the action waits until it is gone: a cover or an alert
    /// never goes over a live card.
    func perform(_ action: Action) {
        guard app?.cardOnScreen == true else { return run(action) }
        queuedAction = action
        card = nil
    }

    /// The card's sheet is gone: runs what was waiting for it, unless another card has opened meanwhile.
    func cardDismissed() {
        let action = queuedAction
        queuedAction = nil
        guard card == nil else { return }
        app?.cardOnScreen = false
        if let action { run(action) }
    }

    private func run(_ action: Action) {
        guard let app else { return }
        switch action {
        case .addPages: app.addPages(to: bookID)
        case .howManyToMark: showsSettings = true
        }
    }

    /// `Delete Page`: the page goes at once and the Reader stays put, showing the page that moves up (the next one, or the previous
    /// one after the last page); the undo toast can bring it back. In two passes: the pager first moves to that page with the deleted
    /// one still laid out (it no longer counts), and drops it on the next pass. Both at once lay the pager out on the previous page
    /// for a frame.
    func deleteCurrentPage() {
        let visible = visiblePages
        guard let app, let index = visible.firstIndex(where: { $0.id == currentPageID }) else { return }
        let deleted = visible[index].id
        let next: Page? = index + 1 < visible.count ? visible[index + 1] : index > 0 ? visible[index - 1] : nil
        // Outside the instant transaction, so the toast still fades in
        app.deletePage(deleted)
        withTransaction(Self.instant) {
            lingeringPageID = deleted
            currentPageID = next?.id
        }
        Task { [weak self] in
            withTransaction(Self.instant) {
                if self?.lingeringPageID == deleted { self?.lingeringPageID = nil }
            }
        }
    }

    /// The page that was waiting in the undo toast no longer is. If it shows again (Undo rather than a commit), the pager goes to it.
    func pageMayHaveReturned(_ pageID: UUID?) {
        guard let app, let pageID, app.isVisible(page: pageID), storedPages?.contains(where: { $0.id == pageID }) == true else { return }
        go(to: pageID)
    }

    /// Pages added from this Reader: once the first new page is in the list, the pager goes to it.
    func revealFirstAddedPage() {
        guard let app, let page = app.firstAddedPage, page.bookID == bookID,
              visiblePages.contains(where: { $0.id == page.id }) else { return }
        app.firstAddedPageShown()
        go(to: page.id)
    }

    /// Scrolls on the next pass, once the page is laid out: inserting a page and scrolling in the same pass starts the scroll a page
    /// off. Instant under Reduce Motion.
    private func go(to pageID: UUID) {
        let animated = !UIAccessibility.isReduceMotionEnabled
        Task { [weak self] in
            withAnimation(animated ? .default : nil) { self?.currentPageID = pageID }
        }
    }

    private static var instant: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }
}
