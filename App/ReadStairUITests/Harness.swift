import UIKit
import XCTest

/// Every UI test stops at its first failure: each step builds on the one before.
class UITestCase: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }
}

/// How a run is set up, from the test runner's environment. xcodebuild hands `TEST_RUNNER_<NAME>=<value>` to the runner as `<NAME>`,
/// so a screenshot run looks like `TEST_RUNNER_READSTAIR_APPEARANCE=dark TEST_RUNNER_READSTAIR_CONTENT_SIZE=AX5 xcodebuild test …`.
@MainActor
enum Config {
    /// `READSTAIR_APPEARANCE`: `light` or `dark`. Unset leaves the simulator's appearance as it is.
    static var appearance: XCUIDevice.Appearance? {
        switch ProcessInfo.processInfo.environment["READSTAIR_APPEARANCE"]?.lowercased() {
        case "light"?: return XCUIDevice.Appearance.light
        case "dark"?: return XCUIDevice.Appearance.dark
        default: return nil
        }
    }

    /// `READSTAIR_CONTENT_SIZE`: `AX5`, or any UIContentSizeCategory raw value. Unset is the default size. It is passed to the app at every
    /// launch, so the simulator's own text size never leaks into a run.
    static var contentSize: UIContentSizeCategory {
        switch ProcessInfo.processInfo.environment["READSTAIR_CONTENT_SIZE"] {
        case nil, ""?, "default"?: return UIContentSizeCategory.large
        case "AX5"?: return UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        case let raw?: return UIContentSizeCategory(rawValue: raw)
        }
    }

    /// A text size as screenshot and audit names give it.
    static func name(of size: UIContentSizeCategory) -> String {
        switch size {
        case .large: "default"
        case .accessibilityExtraExtraExtraLarge: "AX5"
        default: size.rawValue
        }
    }

    /// `READSTAIR_TRANSLATE_INTO`: a language whose Apple Translation pack is already installed on the simulator, e.g. `zh-Hans`. It follows
    /// English in the app's languages, so word cards translate into it. Unset, the app runs in English only and cards translate
    /// nothing, so no test ever brings up the system's language download.
    static var translationLanguage: String? {
        guard let value = ProcessInfo.processInfo.environment["READSTAIR_TRANSLATE_INTO"], !value.isEmpty else { return nil }
        return value
    }
}

/// The app's English strings the tests look for, exactly as the String Catalog has them (curly apostrophes and quotes, `…`).
enum Strings {
    static let noBooks = "No Books Yet"
    static let noBooksMessage = "Scan pages from a printed English book. ReadStair underlines only the words you may not know."
    static let cannotOpen = "Can\u{2019}t Open Your Books"
    static let cannotOpenMessage = "Free up some space on this iPhone or update ReadStair, then try again."
    static let tryAgain = "Try Again"
    static let reading = "Reading page\u{2026}"
    static let failed = "Couldn\u{2019}t read this page."
    static let noText = "No English text found on this page."
    static let noNewWords = "No new words"
    static let noPages = "No Pages"
    static let noPagesMessage = "Scan pages to add them to this book."
    static let pageDeleted = "Page deleted"
    static let bookDeleted = "Book deleted"
    static let iKnowThis = "I Know This"
    static let markAsNew = "Mark as New"
    static let translationUnavailable = "Translation unavailable"
    static let photosUnreadable = "Couldn\u{2019}t Add These Photos"
    static let photosUnreadableMessage = "Choose photos of printed pages that are saved on this iPhone."
    static let bookUnopenable = "Couldn\u{2019}t Open This Book"
    static let bookUnopenableMessage = "Choose an English book in EPUB format without copy protection, or a plain text file."
    static let renameBook = "Rename Book"
    static let rename = "Rename\u{2026}"
    static let read = "Read"
    static let deleteBook = "Delete Book"
    static let whichWords = "Which Words Do You Know?"
    static let estimateNote = "This is an estimate. You can change it anytime."
    static let unreliableNote = "Some words you tapped aren\u{2019}t real words, so this is only a starting point."
    static let off = "Off"
    static let privacy = "Your books and pages stay on this iPhone and in its backups. Your word list and vocabulary level sync through your iCloud account. ReadStair doesn\u{2019}t collect any data. Privacy Policy"
    static let privacyPolicy = "Privacy Policy"
    static let wordData = "Word data: wordfreq 3.1.1 (CC BY-SA 4.0), NGSL (CC BY-SA 4.0) and WordNet 3.0 (WordNet License)."
    static let sampleCredit = "Sample book: Alice\u{2019}s Adventures in Wonderland by Lewis Carroll (1865). Public domain."
    static let wordList = "Word List"
    static let noWords = "No Words Yet"
    static let noWordsMessage = "New words you tap while reading show up here."
    static let other = "Other"
    static let inThisSentence = "In This Sentence"
    static let appleIntelligenceHint = "Turn on Apple Intelligence in Settings to see what this word means in this sentence."
    static let openSettings = "Open Settings"

    static func markedKnown(_ headword: String) -> String { "Marked \u{201C}\(headword)\u{201D} as known" }
    static func markedNew(_ headword: String) -> String { "Marked \u{201C}\(headword)\u{201D} as new" }
    static func page(_ index: Int, of count: Int) -> String { "Page \(index) of \(count)" }
    static func pageWithoutMarks(_ index: Int, of count: Int) -> String { "Page \(index) of \(count) \u{00B7} No new words" }
    /// The level test's result heading, e.g. `About 3,000 Words`.
    static func about(_ words: String) -> String { "About \(words) Words" }
    static let startLow = "Let\u{2019}s Start at 1,000 Words"
}

/// Where the Reader stands: `Page index of count` in its navigation subtitle.
struct Position: Equatable {
    let index: Int
    let count: Int
}

/// A group of the Word List as the screen shows it: its header and its words, top to bottom. Headers compare without case, since a
/// list may show them in capitals.
struct WordGroup: Equatable, CustomStringConvertible {
    let title: String
    let words: [String]

    init(_ title: String, _ words: [String]) {
        self.title = title.lowercased()
        self.words = words
    }

    var description: String { "\(title): \(words.joined(separator: ", "))" }
}

/// Whether a menu picker shows `choice`: it reads as its title with the choice as its value; some systems put the choice in the label.
@MainActor
func shows(_ picker: XCUIElement, _ choice: String) -> Bool {
    (picker.value as? String) == choice || picker.label.hasSuffix(choice)
}

/// A Word List row's word: VoiceOver reads the row as the word, then its translation when there is one, then its sentence.
private func rowWord(_ label: String) -> String {
    String(label.prefix { $0.isLetter || $0.isNumber || "-'\u{2019}".contains($0) })
}

/// An element with an identifier, from one snapshot of the app: one round trip for the whole screen.
struct Node {
    let id: String
    let label: String
    let value: String?
    let frame: CGRect
    let isSelected: Bool
    /// The element that holds this one, numbered within one snapshot: a page's summary and its words share it.
    let container: Int
}

/// One test's app and its data. A test starts from a store of its own (`-ReadStairDataRoot`), fills it through the app's own import
/// (`-ReadStairSeedPages` stands in for the Photos picker, which runs out of process), and relaunches on the same store to see what
/// was saved.
@MainActor
final class Session {
    /// What reads the pages: Vision, a recognizer that fails every page, or one that keeps every page Reading until its timeout.
    enum Recognizer: String {
        case vision, fail, stall
    }

    /// Apple Intelligence as the app takes it to be: turned off in Settings, available, or unavailable for another reason.
    enum AppleIntelligence: String {
        case notEnabled, available, unavailable
    }

    let app = XCUIApplication()
    /// The app's data folder; nil on a device, where the app keeps its own.
    let root: URL?
    /// Whether the next launch opens on the first-launch level test: a new store has no level until the test is skipped or finished.
    /// A test that finishes it sets this to false.
    var levelTestPending: Bool
    /// The text size of the next launch; nil is the run's (`READSTAIR_CONTENT_SIZE`). The accessibility audit sets both of its sizes.
    var contentSize: UIContentSizeCategory?
    /// Whether the next launch's undo toast waits until something commits it, as with VoiceOver on, instead of 5 seconds.
    var holdsUndo = false
    /// Whether the next launch adds the sample book to a new store, as a first launch outside the tests does. Off, a test store
    /// starts with an empty shelf.
    var sampleBook = false
    /// Apple Intelligence's state for the next launch: unavailable unless a test says otherwise, never the device's own, so only the
    /// tests of the hint to turn it on ever see that hint.
    var appleIntelligence = AppleIntelligence.unavailable
    /// Whether the next launch first forgets that the hint to turn on Apple Intelligence was shown. The app keeps that flag in its
    /// UserDefaults, not in the store, so it outlives the store and the run.
    var resetsHint = false
    private var cachedWindow: CGRect?

    init(root: URL?, levelTestPending: Bool = false) {
        self.root = root
        self.levelTestPending = levelTestPending
    }

    /// A session on an empty store of its own. Simulator only: the app reads the fixtures and its data folder from the Mac's disk.
    static func fresh() throws -> Session {
        #if targetEnvironment(simulator)
        return Session(root: Paths.newDataRoot(), levelTestPending: true)
        #else
        throw XCTSkip("Runs on the simulator: the app reads the fixtures and its data folder from the Mac's disk.")
        #endif
    }

    // MARK: Launching

    /// The arguments for the next launch: English, a fixed text size, the store, and optionally photos for `Choose from Photos`, a book
    /// file for `Choose from Files`, a recognizer other than Vision, an undo toast that waits (`holdsUndo`), the sample book
    /// (`sampleBook`), Apple Intelligence's state (`appleIntelligence`) and the hint to turn it on forgotten (`resetsHint`).
    func configure(seeds: [URL] = [], seedFile: URL? = nil, recognizer: Recognizer = .vision) {
        let languages = ["en"] + (Config.translationLanguage.map { [$0] } ?? [])
        var arguments = [
            "-AppleLanguages", "(\(languages.joined(separator: ", ")))",
            "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", (contentSize ?? Config.contentSize).rawValue,
            // A slow simulator takes up to about 40 s to read a page; the app allows 30 s
            "-ReadStairRecognizerTimeout", "180",
        ]
        if let root { arguments += ["-ReadStairDataRoot", root.path(percentEncoded: false)] }
        if recognizer != .vision { arguments += ["-ReadStairRecognizer", recognizer.rawValue] }
        if holdsUndo { arguments += ["-ReadStairHoldsUndo", "YES"] }
        if sampleBook { arguments += ["-ReadStairSampleBook", "YES"] }
        arguments += ["-ReadStairAppleIntelligence", appleIntelligence.rawValue]
        if resetsHint { arguments += ["-ReadStairResetAppleIntelligenceHint", "YES"] }
        if !seeds.isEmpty { arguments += ["-ReadStairSeedPages", seeds.map { $0.path(percentEncoded: false) }.joined(separator: ",")] }
        if let seedFile { arguments += ["-ReadStairSeedFile", seedFile.path(percentEncoded: false)] }
        app.launchArguments = arguments
        if let appearance = Config.appearance { XCUIDevice.shared.appearance = appearance }
    }

    /// Launches; on a new store, taps `Skip` on the level test the way a user would (the default level), unless `stopsAtLevelTest`.
    func launch(seeds: [URL] = [], seedFile: URL? = nil, recognizer: Recognizer = .vision, stopsAtLevelTest: Bool = false) {
        configure(seeds: seeds, seedFile: seedFile, recognizer: recognizer)
        app.launch()
        if levelTestPending && !stopsAtLevelTest { skipLevelTest() }
    }

    /// Ends the app and launches it again on the same store.
    func relaunch(seeds: [URL] = [], seedFile: URL? = nil, recognizer: Recognizer = .vision) {
        app.terminate()
        launch(seeds: seeds, seedFile: seedFile, recognizer: recognizer)
    }

    /// Makes the store impossible to open: a file where its folder of page images goes. Removing the returned file clears the problem.
    func blockDataRoot() throws -> URL {
        let folder = try XCTUnwrap(self.root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appending(path: "Books")
        try Data("Not a folder.".utf8).write(to: blocker)
        return blocker
    }

    // MARK: Waiting

    /// Polls until the condition holds or the time is up, and says whether it held. Polling, not XCTWaiter: on a loaded Mac one query
    /// can outlast a waiter's timeout, and XCTest then aborts the runner as stalled.
    @discardableResult
    func eventually(_ timeout: TimeInterval = 20, interval: TimeInterval = 0.3, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            if interval > 0 { Thread.sleep(forTimeInterval: interval) }
        }
        return condition()
    }

    /// Lets animations and scrolling come to rest.
    func settle(_ seconds: TimeInterval = 1) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Polls `read` once a second until its value holds still and `accept` takes it, and returns the value and when it last changed;
    /// nil if that never happens in time. A nil read, as from a failed snapshot, changes nothing. Still means for `minimum` seconds, or
    /// for three times the longest the value has taken to change if that is longer: under load one step can take seconds. The wait for
    /// the first value never counts toward the longest, nor, with `skipFirstGap`, the wait for its first change.
    func waitUntilStill(timeout: TimeInterval, minimum: TimeInterval, skipFirstGap: Bool = false, _ read: () -> Int?,
                        accepting accept: (Int) -> Bool = { _ in true }) -> (value: Int, at: Date)? {
        var value: Int?
        var changed = Date.now
        var skipsGap = skipFirstGap
        var longestGap: TimeInterval = 0
        let still = eventually(timeout, interval: 1) {
            guard let current = read() else { return false }
            if current != value {
                if value != nil {
                    if skipsGap { skipsGap = false } else { longestGap = max(longestGap, Date.now.timeIntervalSince(changed)) }
                }
                (value, changed) = (current, .now)
            }
            return Date.now.timeIntervalSince(changed) >= max(minimum, 3 * longestGap) && accept(current)
        }
        guard still, let value else { return nil }
        return (value, changed)
    }

    // MARK: Reading the screen

    /// The app window's frame; portrait only, so it never changes once known.
    var window: CGRect {
        if let cachedWindow { return cachedWindow }
        let frame = app.windows.firstMatch.frame
        if !frame.isEmpty { cachedWindow = frame }
        return frame
    }

    /// Every element that has an identifier, its frame on screen like XCUIElement.frame and `window`. A snapshot gives frames in the
    /// app's own points, which are the screen's on an iPhone; an iPhone app on an iPad is scaled into a window, and there they differ.
    func nodes() -> [Node] {
        guard let snapshot = try? app.snapshot() else { return [] }
        // Only an app smaller than its window is scaled; on an iPhone every frame stays exactly as the snapshot gives it
        let (own, screen) = (snapshot.frame, window)
        let scaled = !own.isEmpty && own.width < screen.width
        let (sx, sy) = scaled ? (screen.width / own.width, screen.height / own.height) : (1, 1)
        let onScreen = { (f: CGRect) in
            scaled ? CGRect(x: screen.minX + (f.minX - own.minX) * sx, y: screen.minY + (f.minY - own.minY) * sy,
                            width: f.width * sx, height: f.height * sy) : f
        }
        var found: [Node] = []
        var pending: [(snapshot: any XCUIElementSnapshot, container: Int)] = [(snapshot, -1)]
        var count = 0
        while let item = pending.popLast() {
            let next = item.snapshot
            let number = count
            count += 1
            if !next.identifier.isEmpty {
                found.append(Node(id: next.identifier, label: next.label, value: next.value as? String, frame: onScreen(next.frame),
                                  isSelected: next.isSelected, container: item.container))
            }
            pending.append(contentsOf: next.children.map { ($0, number) })
        }
        return found
    }

    /// The Reader page under the middle of the window (the pager keeps the pages on either side too). Its frame is the page image's,
    /// following zoom and scrolling.
    func visiblePage(in nodes: [Node]? = nil) -> Node? {
        let midX = window.midX
        return (nodes ?? self.nodes()).first { $0.id == "page" && $0.frame.minX <= midX && $0.frame.maxX >= midX }
    }

    /// The visible page's marked words, in reading order: those in the page's own container (zoomed in, the page's frame also
    /// reaches over the next page's words) and inside its frame.
    func pageWords(in nodes: [Node]? = nil) -> [Node] {
        let all = nodes ?? self.nodes()
        guard let page = visiblePage(in: all) else { return [] }
        let words = all.filter { node in
            node.id.hasPrefix("word.") && node.container == page.container
                && node.frame.midX >= page.frame.minX && node.frame.midX <= page.frame.maxX
        }
        return words.sorted { Self.wordIndex($0) < Self.wordIndex($1) }
    }

    nonisolated private static func wordIndex(_ node: Node) -> Int {
        Int(node.id.dropFirst("word.".count)) ?? 0
    }

    /// A marked word on the visible page by its label, the printed word without punctuation, its first if it is marked more than
    /// once; nil if it is not marked.
    func word(_ label: String) -> Node? {
        pageWords().first { $0.label == label }
    }

    /// The visible page's VoiceOver value: `5 new words`, `No new words`, or its status line.
    func pageValue() -> String? {
        visiblePage()?.value
    }

    /// How many words the visible page marks, from its value; nil while it is not read.
    func newWordCount() -> Int? {
        guard let value = pageValue() else { return nil }
        if value == Strings.noNewWords { return 0 }
        return value.wholeMatch(of: #/(\d+) new words?/#).flatMap { Int($0.1) }
    }

    /// Waits until the visible page has been read: marked words, none, or no English text.
    @discardableResult
    func waitForRecognized(timeout: TimeInterval = 300) -> Bool {
        eventually(timeout, interval: 1) {
            guard let value = self.pageValue() else { return false }
            return value == Strings.noNewWords || value == Strings.noText || value.wholeMatch(of: #/\d+ new words?/#) != nil
        }
    }

    /// The Reader's navigation subtitle, `Page 3 of 30` or `Page 3 of 30 · No new words`; empty elsewhere and in a book with no pages.
    var subtitle: String {
        let text = app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Page '")).firstMatch
        return text.exists ? text.label : ""
    }

    func position() -> Position? {
        guard let match = subtitle.prefixMatch(of: #/Page (\d+) of (\d+)/#),
              let index = Int(match.1), let count = Int(match.2) else { return nil }
        return Position(index: index, count: count)
    }

    func showsPage(_ index: Int, of count: Int) -> Bool {
        position() == Position(index: index, count: count)
    }

    /// Waits for the Reader to show a page, and for the book to have `pages` pages when given (an import adds them one by one).
    @discardableResult
    func waitForReader(pages: Int? = nil, timeout: TimeInterval = 120) -> Bool {
        eventually(timeout) {
            guard let position = self.position() else { return false }
            return pages.map { position.count == $0 } ?? true
        }
    }

    /// Waits in the Reader until the import adding pages to its book has ended, and returns the page count; nil if it never held still.
    /// It must hold still for 3 s, or longer under load (`waitUntilStill`).
    func waitForImportToEnd(timeout: TimeInterval = 120) -> Int? {
        waitUntilStill(timeout: timeout, minimum: 3) { self.position()?.count }?.value
    }

    // MARK: Level test

    var skipButton: XCUIElement {
        app.buttons["skip"]
    }

    /// `Skip` on the first-launch level test: one tap, the default level (3,000 words).
    func skipLevelTest(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(eventually(30) { self.skipButton.exists }, "The level test did not appear", file: file, line: line)
        skipButton.tap()
        XCTAssertTrue(eventually(10) { !self.skipButton.exists }, "Skip did not close the level test", file: file, line: line)
        levelTestPending = false
    }

    /// After a launch on a store that has a level: Books comes up, and the level test does not, then or a few seconds later.
    func levelTestStaysAway() -> Bool {
        guard eventually(30, { self.app.buttons["addBook"].exists }) else { return false }
        settle(3)
        return !skipButton.exists && app.buttons["addBook"].exists
    }

    /// The level test's word at `index`, 0 to 39, top left to bottom right.
    func testWord(_ index: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "testWord.\(index)").firstMatch
    }

    /// Goes through the level test's 40 words in order, scrolling down as it goes, and checks those `taps` picks by their labels (one
    /// checked already is left so); each must then read as on. Returns the words picked; Continue is the caller's.
    @discardableResult
    func answerLevelTest(tapping taps: (String) -> Bool, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        var tapped: [String] = []
        for index in 0..<40 {
            let word = testWord(index)
            // Clear of the bar at the top and of Continue at the bottom, so a tap cannot land on them
            guard scrollIntoView(word) else {
                XCTFail("Test word \(index) never came into view", file: file, line: line)
                return tapped
            }
            guard taps(word.label) else { continue }
            // A toggle: its value is "1" when on
            if word.value as? String != "1" { word.tap() }
            XCTAssertTrue(eventually(5) { word.value as? String == "1" }, "Test word \(index) does not read as on", file: file, line: line)
            tapped.append(word.label)
        }
        return tapped
    }

    // MARK: Settings

    /// Books' gear: Settings at full height.
    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        let gear = app.buttons["settings"]
        XCTAssertTrue(eventually(30) { gear.exists }, "No Settings button", file: file, line: line)
        gear.tap()
        XCTAssertTrue(eventually(10) { self.app.buttons["close"].exists }, "Settings did not open", file: file, line: line)
    }

    /// The close button on Settings.
    func closeSettings(file: StaticString = #filePath, line: UInt = #line) {
        let close = app.buttons["close"]
        close.tap()
        XCTAssertTrue(eventually(10) { !close.exists }, "Settings did not close", file: file, line: line)
    }

    /// A level row, in Settings or on the level test's result, scrolled into view: rows start out of sight at the medium detent and
    /// at the larger text sizes. A row far off screen is not in the tree, so the rows that are tell which way to look.
    func levelRow(_ level: Int, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let row = app.buttons["level.\(level)"]
        let shown = row.exists ? [] : nodes().compactMap { $0.id.hasPrefix("level.") ? Int($0.id.dropFirst("level.".count)) : nil }
        let forward = shown.isEmpty || shown.contains { $0 < level }
        XCTAssertTrue(scrollIntoView(row, forward: forward), "No row for level \(level)", file: file, line: line)
        return row
    }

    /// The subtitle of Settings over the Reader, `This page: N of M words are new`: new words and all words; nil when it is not shown.
    func pageTally() -> (new: Int, words: Int)? {
        let line = app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This page: '")).firstMatch
        guard line.exists,
              let match = line.label.wholeMatch(of: #/This page: ([\d,]+) of ([\d,]+) words? (?:is|are) new/#),
              let new = Int(match.1.filter(\.isNumber)), let words = Int(match.2.filter(\.isNumber)) else { return nil }
        return (new, words)
    }

    // MARK: Books

    /// Books' bar, and no book page's `Read`: a book page pushed over Books could leave Books' bar in the tree.
    var isShowingBooks: Bool {
        app.navigationBars["Books"].exists && !app.buttons["read"].exists
    }

    /// A book page: its `Read`, and no Reader over it.
    var isShowingBook: Bool {
        app.buttons["read"].exists && position() == nil
    }

    /// The cells on Books in grid order, left to right, then top to bottom. A cell is one element labelled with the book's title; its
    /// value is `Page n of count` while its line shows.
    /// Only the cells in the tree: the grid is lazy, so a caller that needs every cell scrolls. The rows, at the largest text sizes, are
    /// all in the tree, off screen too, so a caller taps a cell only once it is scrolled into view.
    func rows() -> [Node] {
        var seen: Set<[Int]> = []
        return nodes().filter { $0.id == "book" && !$0.label.isEmpty }
            .sorted { ($0.frame.minY.rounded(), $0.frame.minX) < ($1.frame.minY.rounded(), $1.frame.minX) }
            .filter { seen.insert([Int($0.frame.midX.rounded()), Int($0.frame.midY.rounded())]).inserted }
    }

    /// `+` then `Choose from Photos`, which imports the seed photos into a new book.
    func addBookFromPhotos(file: StaticString = #filePath, line: UInt = #line) {
        addBook(with: "choosePhotos", file: file, line: line)
    }

    /// `+` then `Choose from Files`, which opens the seed file as a new book.
    func addBookFromFiles(file: StaticString = #filePath, line: UInt = #line) {
        addBook(with: "chooseFile", file: file, line: line)
    }

    private func addBook(with item: String, file: StaticString, line: UInt) {
        let add = app.buttons["addBook"]
        XCTAssertTrue(eventually(30) { add.exists }, "No Add Book button", file: file, line: line)
        add.tap()
        tapMenuItem(item, file: file, line: line)
    }

    /// Scrolls the `index`th cell on Books (newest first) into view, taps it and waits for its book page. At the largest text sizes
    /// on the SE only two cells fit on screen, and a cell further down is in the tree but off screen.
    func openBookPage(at index: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(eventually(30) { self.rows().count > index }, "No book cell \(index)", file: file, line: line)
        let shelf = rows()
        guard shelf.indices.contains(index) else { return }
        // Found by title; books can share a title (two added in the same minute): the nth of them, in the same order as rows()
        let title = shelf[index].label, same = shelf[..<index].filter { $0.label == title }.count
        let cell = app.buttons.matching(NSPredicate(format: "identifier == 'book' AND label == %@", title)).element(boundBy: same)
        XCTAssertTrue(scrollIntoView(cell, whole: true), "Book cell \(index) never came into view", file: file, line: line)
        cell.tap()
        XCTAssertTrue(eventually(30) { self.isShowingBook }, "The book page did not open", file: file, line: line)
    }

    /// A book from Books: its page, then `Read`, which opens the Reader where the book was left, or its `No Pages`.
    func openBook(at index: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        openBookPage(at: index, file: file, line: line)
        app.buttons["read"].firstMatch.tap()
        XCTAssertTrue(eventually(30) { self.position() != nil || self.app.staticTexts[Strings.noPages].exists },
                      "The Reader did not open", file: file, line: line)
    }

    /// A chapter row of the book page, `n` from 0 in the order shown.
    func chapterRow(_ n: Int) -> XCUIElement {
        app.buttons.matching(identifier: "chapter.\(n)").firstMatch
    }

    /// On a book page: scrolls chapter row `n` into view and taps it, and the Reader opens.
    func openChapter(_ n: Int, file: StaticString = #filePath, line: UInt = #line) {
        let row = chapterRow(n)
        XCTAssertTrue(scrollIntoView(row), "No chapter row \(n)", file: file, line: line)
        row.tap()
        XCTAssertTrue(eventually(30) { self.position() != nil }, "Chapter row \(n) did not open the Reader", file: file, line: line)
    }

    /// The book page's chapter rows, top to bottom, each scrolled into view (rows far off screen are not in the tree); the list ends
    /// up scrolled back to the top.
    func chapterTitles() -> [String] {
        var titles: [String] = []
        while scrollIntoView(chapterRow(titles.count)) {
            titles.append(chapterRow(titles.count).label)
        }
        return titles
    }

    /// From Books: the book's page, then `More`, `Delete Book`, and Books comes back.
    func deleteBook(at index: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        openBookPage(at: index, file: file, line: line)
        tapMore(file: file, line: line)
        tapMenuItem("deleteBook", file: file, line: line)
        XCTAssertTrue(eventually(20) { self.isShowingBooks }, "Books did not come back after Delete Book", file: file, line: line)
    }

    /// On a book page: `More`, `Rename…`, a new title, `Save`. The alert must open on the current title, which it returns, and Save
    /// must be off while the field is empty.
    @discardableResult
    func renameBook(to title: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        tapMore(file: file, line: line)
        let rename = menuItem("rename")
        XCTAssertTrue(eventually(10) { rename.exists }, "No Rename menu item with its identifier", file: file, line: line)
        XCTAssertEqual(rename.label, Strings.rename, file: file, line: line)
        rename.tap()
        let alert = app.alerts[Strings.renameBook]
        XCTAssertTrue(eventually(10) { alert.exists }, "No rename alert", file: file, line: line)
        let field = alert.textFields.firstMatch
        let save = alert.buttons["Save"]
        XCTAssertEqual(field.placeholderValue, "Title", file: file, line: line)
        let old = field.value as? String ?? ""
        XCTAssertFalse(old.isEmpty, "The alert shows no title", file: file, line: line)
        // On a loaded simulator at large text sizes some synthesized keystrokes are lost: delete, and type, again until they took
        for _ in 0..<3 {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            for _ in 0..<3 {
                let left = field.value as? String ?? ""
                if left.isEmpty || left == "Title" { break }
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: left.count + 2))
            }
            // Save turns off a moment after the last delete, and only if the deletes all took
            let empty = { (field.value as? String ?? "").isEmpty || field.value as? String == "Title" }
            XCTAssertTrue(eventually(5) { !empty() || !save.isEnabled }, "Save is on with an empty title", file: file, line: line)
            field.typeText(title)
            if field.value as? String == title { break }
            print("Rename: the field holds \(field.value as? String ?? "nothing"), not \(title); typing it again")
        }
        XCTAssertEqual(field.value as? String, title, file: file, line: line)
        save.tap()
        XCTAssertTrue(eventually(10) { !alert.exists }, "The rename alert stayed", file: file, line: line)
        return old
    }

    // MARK: Word List

    var isShowingWordList: Bool {
        app.navigationBars[Strings.wordList].exists
    }

    /// Books' `Word List` button.
    func openWordList(file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["wordList"]
        XCTAssertTrue(eventually(30) { button.exists }, "No Word List button", file: file, line: line)
        button.tap()
        XCTAssertTrue(eventually(20) { self.isShowingWordList }, "The Word List did not open", file: file, line: line)
    }

    /// Back from the Reader that Go to Page opened.
    func backToWordList(file: StaticString = #filePath, line: UInt = #line) {
        tapBack(file: file, line: line)
        XCTAssertTrue(eventually(20) { self.isShowingWordList && self.position() == nil }, "The Word List did not come back",
                      file: file, line: line)
    }

    /// The whole Word List by group, read while it scrolls down with slow drags, then scrolled back: at the larger text sizes it is
    /// taller than the screen, and rows far off screen are not in the tree. A plain list keeps a group's header pinned above its rows,
    /// so every row shows under its own header at some point; one above every header (under a pinned one) is left for then.
    func scrolledWordGroups(titles: [String]) -> [WordGroup] {
        var merged: [WordGroup] = []
        var seen: Set<String> = []
        var steps: [CGFloat] = []
        for _ in 0..<10 {
            let (groups, lowest) = readWordList(titles: titles)
            for group in groups where !group.title.isEmpty {
                let new = group.words.filter { seen.insert($0).inserted }
                if let index = merged.firstIndex(where: { $0.title == group.title }) {
                    merged[index] = WordGroup(merged[index].title, merged[index].words + new)
                } else {
                    merged.append(WordGroup(group.title, new))
                }
            }
            // More can follow only when the lowest row or header reaches down to within a row's height of the band's bottom
            let band = visibleBand()
            guard lowest > band.bottom - 44 else { break }
            steps.append((band.bottom - band.top) / 2)
            dragContent(by: steps.last ?? 0, in: band)
        }
        for step in steps.reversed() { dragContent(by: -step, in: visibleBand()) }
        return merged
    }

    /// One snapshot of the Word List: its groups, and the bottom of its lowest row or header, in the app's own points (the screen's
    /// only on an iPhone; the Word List is never scrolled on the iPad). The groups run top to bottom, each row under the nearest
    /// header above it. `titles` are the headers to look for (book titles, `Other`); rows above all of them, or every row when none
    /// is given, form a first group with an empty title.
    private func readWordList(titles: [String]) -> (groups: [WordGroup], lowest: CGFloat) {
        guard let snapshot = try? app.snapshot() else { return ([], 0) }
        let wanted = Set(titles.map { $0.lowercased() })
        // Keyed by position: SwiftUI can give a row's identifier to more than one element
        var headers: [Int: String] = [:]
        var rows: [Int: String] = [:]
        var lowest: CGFloat = 0
        var pending: [any XCUIElementSnapshot] = [snapshot]
        while let next = pending.popLast() {
            let y = Int(next.frame.midY.rounded())
            if next.identifier == "wordRow", !next.label.isEmpty {
                rows[y] = rowWord(next.label)
                lowest = max(lowest, next.frame.maxY)
            } else if next.elementType == .staticText, wanted.contains(next.label.lowercased()) {
                headers[y] = next.label
                lowest = max(lowest, next.frame.maxY)
            }
            pending.append(contentsOf: next.children)
        }
        let sortedHeaders = headers.sorted { $0.key < $1.key }
        var words = Array(repeating: [String](), count: sortedHeaders.count + 1)
        for (y, word) in rows.sorted(by: { $0.key < $1.key }) {
            words[(sortedHeaders.lastIndex { $0.key < y } ?? -1) + 1].append(word)
        }
        let groups = zip(sortedHeaders, words.dropFirst()).map { WordGroup($0.value, $1) }
        return (words[0].isEmpty ? groups : [WordGroup("", words[0])] + groups, lowest)
    }

    /// Every word the Word List shows, top to bottom.
    func listedWords() -> [String] {
        readWordList(titles: []).groups.flatMap(\.words)
    }

    /// Taps a word's row, scrolled into view, and waits for its card.
    func openListedWord(_ word: String, file: StaticString = #filePath, line: UInt = #line) {
        // The row's label is the word, then its sentence (see `rowWord`)
        let pattern = "(?s)" + NSRegularExpression.escapedPattern(for: word) + "([^\\p{L}\\p{N}'\u{2019}-].*)?"
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'wordRow' AND label MATCHES %@", pattern)).firstMatch
        guard scrollIntoView(row) else { return XCTFail("No row for \(word): \(listedWords())", file: file, line: line) }
        XCTAssertTrue(tapWord(at: row.frame, expecting: word), "No card for \(word)", file: file, line: line)
    }

    // MARK: Navigation and menus

    /// Back to Books: up to 3 taps, as the Reader sits over its book page, or over the Word List after Go to Page. Each tap after the
    /// first waits up to 3 s for Books first: under load the pop before can still be running once the screen has changed.
    func back(file: StaticString = #filePath, line: UInt = #line) {
        let atBooks = { self.isShowingBooks && self.position() == nil }
        for tap in 0..<3 {
            if tap == 0 ? atBooks() : eventually(3, atBooks) { break }
            guard tapBack(file: file, line: line) else { break }
        }
        XCTAssertTrue(eventually(20, atBooks), "Books did not come back", file: file, line: line)
    }

    /// One tap back from the Reader, onto its book page.
    func backToBook(file: StaticString = #filePath, line: UInt = #line) {
        tapBack(file: file, line: line)
        XCTAssertTrue(eventually(20) { self.isShowingBook }, "The book page did not come back", file: file, line: line)
    }

    /// Taps the bar's back button once and waits for the screen to change: its bar's title, the Reader's subtitle, or a book page's
    /// `Read` coming or going (the Reader and its book page share a title). False when there is no back button, or nothing changed.
    @discardableResult
    func tapBack(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        // By its identifier only: its label is the title below (a book's, over a book page), and on Books a label could match Word List
        let button = app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch
        guard eventually(10, { button.exists }) else {
            XCTFail("No back button", file: file, line: line)
            return false
        }
        let screen = { () -> [String] in
            let bar = self.app.navigationBars.firstMatch
            return [bar.exists ? bar.identifier : "", self.subtitle, "\(self.app.buttons["read"].exists)"]
        }
        let before = screen()
        button.tap()
        return eventually(20) { screen() != before }
    }

    /// `More` in the bar, of the Reader or a book page. Both reuse the one identifier, so exactly one must be in the tree.
    func tapMore(file: StaticString = #filePath, line: UInt = #line) {
        let more = app.buttons.matching(identifier: "more")
        XCTAssertTrue(eventually(10) { more.count > 0 }, "No More button", file: file, line: line)
        XCTAssertEqual(more.count, 1, "More is in the tree more than once: a book page's under the Reader?", file: file, line: line)
        more.firstMatch.tap()
    }

    func menuItem(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Taps a menu item where it is, as a finger would. While an import saves pages the app never idles, so XCUITest does not wait
    /// for the menu to finish opening (hence the short wait for it to be hittable), and an item it looks up can have no activation
    /// point when the menu updates; a tap at the item's frame reaches the menu all the same.
    func tapMenuItem(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = menuItem(id)
        XCTAssertTrue(eventually(10) { item.exists }, "No menu item \(id)", file: file, line: line)
        _ = eventually(3) { item.isHittable }
        let frame = item.frame
        tap(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Closes an open menu with a tap outside it: low in the window, since a menu drops from the top bar and at the largest text
    /// sizes reaches past the middle.
    func dismissMenu() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
        settle()
    }

    /// `More` then `Delete Page`.
    func deleteCurrentPage(file: StaticString = #filePath, line: UInt = #line) {
        tapMore(file: file, line: line)
        tapMenuItem("deletePage", file: file, line: line)
    }

    // MARK: Pages

    func nextPage(file: StaticString = #filePath, line: UInt = #line) {
        turnPage(by: 1, file: file, line: line)
    }

    func previousPage(file: StaticString = #filePath, line: UInt = #line) {
        turnPage(by: -1, file: file, line: line)
    }

    /// Swipes once (twice if a synthesized swipe was lost) and waits for the subtitle to follow.
    private func turnPage(by step: Int, file: StaticString, line: UInt) {
        guard let start = position() else { return XCTFail("Not in the Reader", file: file, line: line) }
        let target = start.index + step
        for _ in 0..<2 {
            let screen = app.windows.firstMatch
            if step > 0 { screen.swipeLeft(velocity: .fast) } else { screen.swipeRight(velocity: .fast) }
            if eventually(8, { self.position()?.index == target }) { break }
        }
        XCTAssertEqual(position()?.index, target, "The page did not turn", file: file, line: line)
        settle()
    }

    /// A point on screen, in the points XCUIElement.frame, `window` and nodes() use, as a fraction of the window: right wherever the
    /// window sits and however it is scaled (an iPhone app on an iPad).
    func windowPoint(_ point: CGPoint) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: (point.x - window.minX) / window.width,
                                                                         dy: (point.y - window.minY) / window.height))
    }

    /// Taps a point on screen (see windowPoint).
    func tap(_ point: CGPoint) {
        windowPoint(point).tap()
    }

    /// Double-taps a point on screen (see windowPoint).
    func doubleTap(_ point: CGPoint) {
        windowPoint(point).doubleTap()
    }

    /// Checks that a button's target is at least 44×44 pt and taps it 3 pt inside its top edge, well above its text: the whole target
    /// must answer, not just the word. The reported frame is snapped to whole pixels, so it may be up to half a point short.
    func tapTargetEdge(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let frame = button.frame
        XCTAssertGreaterThanOrEqual(frame.height, 43.5, "\(button.identifier) is \(frame.height) pt tall", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.width, 43.5, "\(button.identifier) is \(frame.width) pt wide", file: file, line: line)
        tap(CGPoint(x: frame.midX, y: frame.minY + 3))
    }

    /// Drags across the window between two points given as fractions of its size. By default the finger stops before it lifts, so
    /// nothing flings; `fling` lets go at speed.
    func drag(from start: CGVector, to end: CGVector, fling: Bool = false) {
        let screen = app.windows.firstMatch
        screen.coordinate(withNormalizedOffset: start)
            .press(forDuration: 0.05, thenDragTo: screen.coordinate(withNormalizedOffset: end),
                   withVelocity: fling ? .fast : .default, thenHoldForDuration: fling ? 0 : 0.3)
        settle(1.5)
    }

    /// Waits until the visible page is back where it rests; a closed card lets it settle back.
    func waitForRest(_ rest: CGRect) -> Bool {
        eventually(10) { self.visiblePage().map { abs($0.frame.minY - rest.minY) < 0.5 } ?? false }
    }

    // MARK: Scrolling

    /// Scrolls with slow drags, which never fling, until `element` is in view (`visibleBand()`), and says whether it got there: whole
    /// in the band, or with its middle in it and hittable, which is all a tap needs. One in the tree is dragged toward the band's
    /// middle, at most a third of the band at a time, so it cannot jump past it; when the content can go no further, its middle in
    /// the band will do. One not in the tree yet (a lazy list leaves out what is far off screen) is looked for `forward`, half the band
    /// at a time, toward the end of the content, then the other way. With `whole`, an element that fits in the band must be whole in
    /// it, unless the drags only swing it back and forth past that place: on the SE at AX5, with the Mac loaded, synthesized drags
    /// have carried the Books rows up to 3.7 times the drag. Then its middle in the band and hittable will do, and the caller's
    /// own checks of its frame still decide.
    @discardableResult
    func scrollIntoView(_ element: XCUIElement, forward: Bool = true, whole: Bool = false) -> Bool {
        var forward = forward
        var turned = false
        var places: [CGFloat] = []
        for _ in 0..<30 {
            let band = visibleBand()
            let frame = element.exists ? element.frame : .null
            let middleInBand = frame.midY > band.top && frame.midY < band.bottom
            let fits = frame.height <= band.bottom - band.top
            let inBand = frame.minY >= band.top && frame.maxY <= band.bottom
            if !frame.isEmpty, inBand || middleInBand && element.isHittable && !(whole && fits) { return true }
            // Back at a place it left: a swing, not a failed snapshot or a drag that moved nothing
            if whole, fits, !frame.isEmpty, frame.minY.rounded() != places.last {
                if places.contains(frame.minY.rounded()) {
                    let ok = middleInBand && element.isHittable
                    print("scrollIntoView: \(element.identifier) '\(element.label)' swings past whole; \(ok ? "accepted" : "given up") at \(frame)")
                    return ok
                }
                places.append(frame.minY.rounded())
            }
            // Long enough to start a scroll, short enough not to carry the element past the band
            let (third, half, middle) = ((band.bottom - band.top) / 3, (band.bottom - band.top) / 2, (band.top + band.bottom) / 2)
            let step = frame.isEmpty ? (forward ? half : -half)
                : (frame.midY < middle ? -1 : 1) * min(max(abs(frame.midY - middle), 30), third)
            // A snapshot that fails (on a loaded machine it can time out) says nothing about the drag: look again
            guard let before = frames() else { continue }
            dragContent(by: step, in: band)
            guard frames() == before else { continue }
            // Nothing moved. A sheet at the medium detent takes a short drag up and springs back, so once more, half the band.
            if step > 0, step < half {
                dragContent(by: half, in: band)
                guard frames() == before else { continue }
            }
            // The content is at its end
            if !frame.isEmpty { return middleInBand }
            guard !turned else { return false }
            forward.toggle()
            turned = true
        }
        return false
    }

    /// Every element's frame, from one snapshot: the same after a drag only if the drag moved nothing; nil when the snapshot fails.
    private func frames() -> [CGRect]? {
        guard let snapshot = try? app.snapshot() else { return nil }
        var found: [CGRect] = []
        var pending: [any XCUIElementSnapshot] = [snapshot]
        while let next = pending.popLast() {
            found.append(next.frame)
            pending.append(contentsOf: next.children)
        }
        return found
    }

    /// Where content shows whole: under the navigation bar and above the level test's bottom button and the soft edge over it, or else
    /// the home indicator (none on the SE). The bar is Settings' own while it is open, since the screen under a sheet keeps its bar;
    /// otherwise the shortest one, the level test's over the Books behind it.
    func visibleBand() -> (top: CGFloat, bottom: CGFloat) {
        let settings = app.navigationBars.containing(.button, identifier: "close").firstMatch
        let top = settings.exists ? settings.frame.maxY
            : app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).filter { $0 > 0 }.min() ?? window.minY
        let button = [app.buttons["continue"], app.buttons["startReading"]].first { $0.exists }
        // The bottom bar takes a tap on its soft edge, about 24 pt above the button: a word there tapped Continue instead
        return (top, button.map { $0.frame.minY - 24 } ?? window.maxY - bottomSafeArea)
    }

    /// Drags the content in the middle of `band` up by `distance` points (down when negative) and holds still before lifting, so it
    /// does not fling. The finger stays in the middle half of the band, clear of the bars, the bottom button and the home indicator.
    private func dragContent(by distance: CGFloat, in band: (top: CGFloat, bottom: CGFloat)) {
        let middle = (band.top + band.bottom) / 2
        windowPoint(CGPoint(x: window.midX, y: middle + distance / 2))
            .press(forDuration: 0.05, thenDragTo: windowPoint(CGPoint(x: window.midX, y: middle - distance / 2)),
                   withVelocity: .default, thenHoldForDuration: 0.3)
        settle()
    }

    // MARK: Zoom

    /// The visible page's zoom: its width over its width at rest, the window less 8 pt on each side.
    func zoom() -> CGFloat? {
        visiblePage().map { $0.frame.width / (window.width - 16) }
    }

    func zoomIn(_ scale: CGFloat) {
        app.windows.firstMatch.pinch(withScale: scale, velocity: scale)
        settle(1.5)
    }

    /// Pinches back to fit width. A pinch-out on the whole window never registers, so it pinches on a word in the middle of the page,
    /// or on the page itself.
    @discardableResult
    func zoomToFit() -> Bool {
        for _ in 0..<4 {
            guard let current = zoom(), current > 1.01 else { break }
            let middle = window.insetBy(dx: 20, dy: 200)
            let id = pageWords().filter { middle.contains($0.frame) }.max { $0.frame.width < $1.frame.width }?.id ?? "page"
            let target = app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex.first { $0.isHittable }
                ?? app.windows.firstMatch
            target.pinch(withScale: 0.5, velocity: -1)
            settle(1.5)
        }
        return (zoom() ?? 1) <= 1.01
    }

    // MARK: Word card

    /// From Books: the first book, the template book left on its page 1, and the card of `peeped`, a marked word with a sentence.
    func openPeeped(file: StaticString = #filePath, line: UInt = #line) throws {
        openBook(file: file, line: line)
        XCTAssertTrue(waitForRecognized(), "The page was never read", file: file, line: line)
        let peeped = try XCTUnwrap(word("peeped"), "peeped is not marked", file: file, line: line)
        XCTAssertTrue(tapWord(at: peeped.frame, expecting: "peep"), "No card for peep", file: file, line: line)
    }

    var headword: XCUIElement {
        app.staticTexts["headword"]
    }

    var primaryAction: XCUIElement {
        app.buttons["primaryAction"]
    }

    /// The card's `Open Settings`, in its hint to turn on Apple Intelligence: it opens the system's Settings, where `openSettings()`
    /// opens ReadStair's own. Found by its label, which no other button on the card has.
    var openSettingsButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", Strings.openSettings)).firstMatch
    }

    /// Taps a word and waits for its card: `expected` is its headword; without one, any card other than the one open before. A
    /// synthesized tap is now and then lost on a loaded Mac, so it taps once more before giving up.
    @discardableResult
    func tapWord(at rect: CGRect, expecting expected: String? = nil) -> Bool {
        // The label from one snapshot, nil if it is gone: a card that is closing can go between checking for it and reading it
        let label: () -> String? = { self.headword.exists ? (try? self.headword.snapshot())?.label : nil }
        let before = label()
        let opened: () -> Bool = {
            guard let shown = label() else { return false }
            return expected.map { shown == $0 } ?? (shown != before)
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        tap(center)
        if eventually(8, opened) { return true }
        tap(center)
        return eventually(8, opened)
    }

    /// Drags the card down until it closes; does nothing when no card is open.
    func closeCard(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<2 where headword.exists {
            headword.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.2)),
                       withVelocity: .fast, thenHoldForDuration: 0)
            if eventually(10, { !self.headword.exists }) { break }
        }
        XCTAssertFalse(headword.exists, "The word card did not close", file: file, line: line)
    }

    /// Drags the card up from the low detent to the medium one by the system's grabber. Dragging the content instead would also scroll
    /// it once the sheet stops at .medium: at AX5 on the SE the card's content is taller than the medium detent.
    func expandCard() {
        app.buttons["Sheet Grabber"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        settle(1.5)
    }

    /// The top of the card's content: the scroll view holding the headword, or the headword itself. XCUITest reports no frame for the
    /// sheet, and its content is never above the sheet's top edge.
    func cardContentTop() -> CGFloat? {
        let scroll = app.scrollViews.containing(.staticText, identifier: "headword").firstMatch
        if scroll.exists { return scroll.frame.minY }
        return headword.exists ? headword.frame.minY : nil
    }

    /// Where the app takes the low card's top edge to be: the window height less the low detent (240 pt scaled with the body text size,
    /// at most 45% of the window) and the bottom safe area. The real card sits a few points lower.
    func lowCardTop() -> CGFloat {
        let height = window.height
        let scaled = UIFontMetrics(forTextStyle: .body)
            .scaledValue(for: 240, compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSize ?? Config.contentSize))
        return height - min(scaled, 0.45 * height) - bottomSafeArea
    }

    /// 34 pt on an iPhone with a home indicator, 0 on the SE.
    var bottomSafeArea: CGFloat {
        window.height >= 800 ? 34 : 0
    }

    /// The lowest a word shown on the card may end: 12 pt above the card. Measured from where the app takes the card to be, and from
    /// the card's content in case the card is taller than that.
    func wordLimit() -> CGFloat {
        min(lowCardTop(), cardContentTop() ?? .infinity) - 12
    }

    // MARK: Toast and page status

    /// The undo toast.
    var toast: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toast").firstMatch
    }

    var undo: XCUIElement {
        app.buttons["undo"]
    }

    func toastText() -> String? {
        text(in: toast)
    }

    /// Waits out the toast: once it is gone, its change has been saved.
    @discardableResult
    func waitForToastToEnd() -> Bool {
        eventually(30) { !self.toast.exists }
    }

    /// The Reader's status capsule, shown while a page is read, when reading failed, and when it has no English text.
    var status: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "pageStatus").firstMatch
    }

    func statusText() -> String? {
        text(in: status)
    }

    private func text(in capsule: XCUIElement) -> String? {
        let first = capsule.staticTexts.firstMatch
        return first.exists ? first.label : nil
    }

    /// Page text under the status capsule must be able to scroll out from under it. Checks the page's lowest line of text; `state`
    /// names the page's state in the failure message.
    func assertTextClearsStatus(_ truth: Truth, state: String, file: StaticString = #filePath, line: UInt = #line) {
        guard status.exists, let page = visiblePage() else { return XCTFail("\(state): no status capsule", file: file, line: line) }
        let capsuleTop = status.frame.minY
        let lastLine = truth.textBottom
        let bottom = page.frame.minY + lastLine * page.frame.height
        guard bottom > capsuleTop else { return }
        drag(from: CGVector(dx: 0.5, dy: 0.6), to: CGVector(dx: 0.5, dy: 0.2))
        let scrolled = visiblePage().map { $0.frame.minY + lastLine * $0.frame.height } ?? bottom
        XCTAssertLessThanOrEqual(scrolled, status.frame.minY,
                                 "\(state): the status capsule (top \(capsuleTop)) covers the last line of text (bottom \(bottom)), and the page does not scroll it clear",
                                 file: file, line: line)
    }
}
