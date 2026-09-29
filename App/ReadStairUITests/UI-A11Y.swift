import UIKit
import XCTest

/// The accessibility gate, its automatic part: Xcode's accessibility audit of every screen and sheet the app draws, in each of its
/// states, at the default text size and at AX5 in the same run (the run's appearance applies). One test per screen or sheet. Each
/// collects the issues of all its states and sizes and fails once, listing them all. What may be let through, and why, is
/// `AccessibilityAudit`'s policy, the one policy of every audit in the suite. Every state audited is also saved as a screenshot, for
/// review by eye: run the suite in light and in dark to have them all.
///
/// Not audited: what the system draws (menus, alerts, Look Up, the Photos picker and the document camera). Only their labels are
/// ours, and other tests check those.
final class AccessibilityTests: UITestCase {
    /// The default text size (Large) and the largest accessibility size.
    private static let sizes: [UIContentSizeCategory] = [.large, .accessibilityExtraExtraExtraLarge]

    /// UI-A11Y-001 Books: the launch failure screen, the empty shelf, and a shelf of two books, an e-book with chapters
    /// (chapters.epub, its cover laid out from its title) and a photographed book.
    @MainActor
    func testUI_A11Y_001_books() throws {
        let audit = AccessibilityAudit()
        defer { audit.assertNoIssues() }
        for size in Self.sizes {
            let broken = try Session.fresh()
            broken.contentSize = size
            _ = try broken.blockDataRoot()
            // A store that cannot open has no level test to skip
            broken.launch(stopsAtLevelTest: true)
            XCTAssertTrue(broken.eventually(30) { broken.app.buttons["launchRetry"].exists }, "No launch failure screen")
            try audit.run(broken, "Books-launchFailed")
            broken.app.terminate()

            let session = try Session.fresh()
            session.contentSize = size
            session.launch(seeds: [Fixture.alice], seedFile: Fixture.chaptersEPUB, recognizer: .fail)
            XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noBooks].exists }, "No empty shelf")
            try audit.run(session, "Books-empty")
            session.addBookFromFiles()
            XCTAssertTrue(session.waitForReader(), "The e-book did not open")
            XCTAssertNotNil(session.waitForImportToEnd(), "The e-book's import never ended: \(session.subtitle)")
            session.back()
            session.addBookFromPhotos()
            XCTAssertTrue(session.waitForReader(pages: 1))
            session.back()
            XCTAssertTrue(session.eventually(30) { session.rows().count == 2 }, "Not two book cells")
            try audit.run(session, "Books-populated")
            session.app.terminate()
        }
    }

    /// UI-A11Y-002 Reader: a marked page, the same page zoomed all the way in, No text, No marks, Failed, and a book with no pages; then,
    /// on a store of their own, a page being read and the toast after it is deleted, both held (a stalled recognizer, a held toast) so
    /// the audit can take its time, and an e-book's first page, typeset on the device. The blank page and the page of common words are
    /// read once, in the first round, and the second round reopens the same store.
    @MainActor
    func testUI_A11Y_002_reader() throws {
        let audit = AccessibilityAudit()
        defer { audit.assertNoIssues() }
        let session = try Template.bookWithRecognizedPages()
        for (round, size) in Self.sizes.enumerated() {
            session.contentSize = size
            if round == 0 {
                session.launch(seeds: [Fixture.blankPage, Fixture.commonWordsPage])
            } else {
                session.relaunch()
            }
            // The template book is the oldest: the last cell
            XCTAssertTrue(session.eventually(30) { !session.rows().isEmpty }, "No book cell")
            session.openBook(at: session.rows().count - 1)
            if round == 0 {
                // Add Pages goes to Photos on the simulator, here the seed pages: page 3 is blank, page 4 has common words only
                XCTAssertTrue(session.eventually(30) { session.showsPage(1, of: 2) }, "Opened at \(session.subtitle)")
                session.app.buttons["addPages"].tap()
                XCTAssertTrue(session.waitForReader(pages: 4), "After Add Pages: \(session.subtitle)")
            }

            session.turn(to: 1)
            XCTAssertTrue(session.waitForRecognized())
            try audit.run(session, "Reader-marked")
            session.zoomIn(2)
            session.zoomIn(3)
            XCTAssertGreaterThan(session.zoom() ?? 0, 3.5, "Not zoomed all the way in")
            try audit.run(session, "Reader-zoomed")
            XCTAssertTrue(session.zoomToFit())

            session.turn(to: 3)
            XCTAssertTrue(session.eventually(300) { session.statusText() == Strings.noText },
                          "Page 3: \(session.statusText() ?? "no status")")
            try audit.run(session, "Reader-noText")
            session.turn(to: 4)
            XCTAssertTrue(session.eventually(300) { session.subtitle == Strings.pageWithoutMarks(4, of: 4) }, "Page 4: \(session.subtitle)")
            try audit.run(session, "Reader-noMarks")
            session.back()

            // A new book whose one page fails to read, then the same book once that page is deleted
            session.relaunch(seeds: [Fixture.alice], recognizer: .fail)
            session.addBookFromPhotos()
            XCTAssertTrue(session.waitForReader(pages: 1))
            XCTAssertTrue(session.eventually(60) { session.statusText() == Strings.failed }, "The page did not fail")
            try audit.run(session, "Reader-failed")
            session.deleteCurrentPage()
            XCTAssertTrue(session.eventually(20) { session.app.staticTexts[Strings.noPages].exists }, "No empty book")
            XCTAssertTrue(session.waitForToastToEnd())
            try audit.run(session, "Reader-emptyBook")
            session.back()

            let held = try Session.fresh()
            held.contentSize = size
            held.holdsUndo = true
            held.launch(seeds: [Fixture.alice], seedFile: Fixture.aliceEPUB, recognizer: .stall)
            held.addBookFromPhotos()
            XCTAssertTrue(held.waitForReader(pages: 1))
            XCTAssertTrue(held.eventually(20) { held.statusText() == Strings.reading }, "The page is not being read")
            try audit.run(held, "Reader-reading")
            held.deleteCurrentPage()
            XCTAssertTrue(held.eventually(20) { held.toastText() == Strings.pageDeleted }, "No toast")
            try audit.run(held, "Reader-toast")

            // An e-book's first page of text, after its cover: saved already read, so its words are marked although nothing reads
            // pages here
            held.back()
            held.addBookFromFiles()
            XCTAssertTrue(held.waitForReader(), "The e-book did not open")
            XCTAssertNotNil(held.waitForImportToEnd(), "The e-book's import never ended: \(held.subtitle)")
            held.turn(to: 2)
            XCTAssertTrue(held.eventually(20) { !held.pageWords().isEmpty }, "The e-book's first page of text marks no word")
            try audit.run(held, "Reader-ebook")
            held.app.terminate()
        }
    }

    /// UI-A11Y-003 Word card over the Reader, at the low detent and at the medium one, with the one-time hint to turn on Apple
    /// Intelligence where In This Sentence would be (forgotten at each launch); at AX5, where the hint runs on below the medium detent,
    /// Open Settings is in reach by scrolling, and that state is saved as a screenshot but not audited: there the audit judged the
    /// headword and I Know This, scrolled out of view above the hint, at frames over it, on both iPhones and after any wait
    /// (2026-09-27). `waistcoat-pocket` has no band, so opening its card changes nothing. The Word List's card, with Go to Page, is
    /// in UI-A11Y-004.
    @MainActor
    func testUI_A11Y_003_card() throws {
        let audit = AccessibilityAudit()
        defer { audit.assertNoIssues() }
        let session = try Template.bookWithRecognizedPages()
        session.appleIntelligence = .notEnabled
        session.resetsHint = true
        for (round, size) in Self.sizes.enumerated() {
            session.contentSize = size
            if round == 0 { session.launch() } else { session.relaunch() }
            session.openBook()
            session.turn(to: 1)
            XCTAssertTrue(session.waitForRecognized())
            let word = try XCTUnwrap(session.word("waistcoat-pocket"), "waistcoat-pocket is not marked")
            XCTAssertTrue(session.tapWord(at: word.frame, expecting: "waistcoat-pocket"))
            XCTAssertTrue(session.eventually(10) { session.openSettingsButton.exists }, "No hint to turn on Apple Intelligence")
            try audit.run(session, "Card-low")
            let lowTop = try XCTUnwrap(session.cardContentTop())
            session.expandCard()
            XCTAssertTrue(session.eventually(10) { (session.cardContentTop() ?? .infinity) < lowTop - 10 },
                          "The card did not reach the medium detent")
            try audit.run(session, "Card-medium")
            if size.isAccessibilityCategory {
                XCTAssertTrue(session.scrollIntoView(session.openSettingsButton), "Open Settings is out of reach")
                saveScreenshot("Card-hint", size: size)
            }
            // Left open: the next launch starts from Books
        }
    }

    /// UI-A11Y-004 Word List: empty, with a word, and that word's card with Go to Page. A fresh copy of the template for each size, so
    /// the list starts empty both times.
    @MainActor
    func testUI_A11Y_004_wordList() throws {
        let audit = AccessibilityAudit()
        defer { audit.assertNoIssues() }
        for size in Self.sizes {
            let session = try Template.bookWithRecognizedPages()
            session.contentSize = size
            session.launch()
            session.openWordList()
            XCTAssertTrue(session.eventually(10) { session.app.staticTexts[Strings.noWords].exists }, "No empty state")
            try audit.run(session, "WordList-empty")
            session.back()

            // Opening a marked word's card puts it on the list
            session.openBook()
            XCTAssertTrue(session.waitForRecognized())
            let peeped = try XCTUnwrap(session.word("peeped"), "peeped is not marked")
            XCTAssertTrue(session.tapWord(at: peeped.frame, expecting: "peep"))
            session.closeCard()
            session.back()
            session.openWordList()
            XCTAssertTrue(session.eventually(10) { session.listedWords() == ["peep"] }, "Word List: \(session.listedWords())")
            try audit.run(session, "WordList-populated")
            session.openListedWord("peep")
            XCTAssertTrue(session.eventually(10) { session.app.buttons["goToPage"].exists }, "No Go to Page")
            try audit.run(session, "Card-list")
            session.closeCard()
            session.app.terminate()
        }
    }

    /// UI-A11Y-005 Settings: from Books at full height, then scrolled to its footer; from the Reader at the medium detent, with the
    /// page's count.
    @MainActor
    func testUI_A11Y_005_settings() throws {
        let audit = AccessibilityAudit()
        defer { audit.assertNoIssues() }
        let session = try Template.bookWithRecognizedPages()
        for (round, size) in Self.sizes.enumerated() {
            session.contentSize = size
            if round == 0 { session.launch() } else { session.relaunch() }
            session.openSettings()
            try audit.run(session, "Settings-books")
            // At AX5 the footer is several screens down
            XCTAssertTrue(session.scrollIntoView(session.app.staticTexts[Strings.wordData]), "The footer never came into view")
            try audit.run(session, "Settings-footer", scrolled: true)
            session.closeSettings()

            session.openBook()
            XCTAssertTrue(session.waitForRecognized())
            session.tapMore()
            session.tapMenuItem("howManyToMark")
            XCTAssertTrue(session.eventually(10) { session.pageTally() != nil }, "No This page subtitle")
            try audit.run(session, "Settings-reader")
            session.closeSettings()
            session.back()
        }
    }

    /// UI-A11Y-006 First-launch level test: its words, then with the made-up words in view checked (before any scrolling: scrolled to
    /// its end, the grid's audit timed out), then a result. The result audited is the one for made-up words, whose note makes it the
    /// longest; every result has the same rows.
    @MainActor
    func testUI_A11Y_006_levelTest() throws {
        let audit = AccessibilityAudit()
        defer { audit.assertNoIssues() }
        for size in Self.sizes {
            let session = try Session.fresh()
            session.contentSize = size
            session.launch(stopsAtLevelTest: true)
            XCTAssertTrue(session.eventually(30) { session.skipButton.exists }, "The level test did not appear")
            try audit.run(session, "LevelTest-words")
            let bottom = session.visibleBand().bottom
            let madeUp = session.nodes().filter {
                $0.id.hasPrefix("testWord.") && $0.frame.maxY <= bottom && Vocab.band(of: $0.label) == 0
            }
            for word in madeUp { session.tap(CGPoint(x: word.frame.midX, y: word.frame.midY)) }
            try audit.run(session, "LevelTest-checked")
            session.answerLevelTest { Vocab.band(of: $0) == 0 }
            session.app.buttons["continue"].tap()
            XCTAssertTrue(session.eventually(10) { session.app.staticTexts[Strings.unreliableNote].exists }, "No result")
            try audit.run(session, "LevelTest-result")
            session.app.terminate()
        }
    }

    /// UI-A11Y-007 Book: the page of an e-book with chapters (chapters.epub) and of a photographed book, which lists none. One store,
    /// built in the first round and reopened in the second.
    @MainActor
    func testUI_A11Y_007_bookPage() throws {
        let audit = AccessibilityAudit()
        defer { audit.assertNoIssues() }
        let session = try Session.fresh()
        for (round, size) in Self.sizes.enumerated() {
            session.contentSize = size
            if round == 0 {
                session.launch(seeds: [Fixture.alice], seedFile: Fixture.chaptersEPUB, recognizer: .fail)
                session.addBookFromFiles()
                XCTAssertTrue(session.waitForReader(), "The e-book did not open")
                XCTAssertNotNil(session.waitForImportToEnd(), "The e-book's import never ended: \(session.subtitle)")
                session.back()
                session.addBookFromPhotos()
                XCTAssertTrue(session.waitForReader(pages: 1))
                session.back()
            } else {
                session.relaunch(recognizer: .fail)
            }
            // Newest first: the photographed book, then chapters.epub
            session.openBookPage(at: 1)
            XCTAssertTrue(session.eventually(10) { session.chapterRow(0).exists }, "chapters.epub lists no chapters")
            try audit.run(session, "Book-chapters")
            session.back()
            session.openBookPage(at: 0)
            try audit.run(session, "Book-plain")
            session.back()
        }
    }
}

extension AccessibilityAudit {
    /// Audits the screen as it is now, once animations have finished, naming the state with the session's text size:
    /// `Books-empty @ AX5`. `scrolled` marks a state scrolled on purpose, with content under a bar. Which issues are let through,
    /// and why, is `AccessibilityAudit`'s one policy.
    func run(_ session: Session, _ state: String, scrolled: Bool = false) throws {
        // A state shows in the accessibility tree before it is on screen
        session.settle()
        let size = session.contentSize ?? Config.contentSize
        saveScreenshot(state, size: size)
        try run(session.app, "\(state) @ \(Config.name(of: size))", scrolled: scrolled)
    }
}

extension Session {
    /// Turns the Reader's pages one at a time until it shows page `index`.
    func turn(to index: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let start = position() else { return XCTFail("Not in the Reader", file: file, line: line) }
        for _ in 0..<abs(index - start.index) {
            if index > start.index { nextPage(file: file, line: line) } else { previousPage(file: file, line: line) }
        }
        XCTAssertEqual(position()?.index, index, "The Reader is not on page \(index)", file: file, line: line)
    }
}

/// Xcode's accessibility audit of the screen as it is. Every issue is listed in the run's output. An issue fails the test unless
/// `knownReason` names it; those are collected, so the run goes on through every state and then fails once with all of them.
@MainActor
final class AccessibilityAudit {
    private(set) var issues: [String] = []
    /// The state's issues let through although the audit named no element: each is checked by hand against the state's screenshot.
    private var unattributed: [String] = []

    /// Audits one state. The issues it lets through with no element go into the result bundle as `a11y-unattributed.txt`, one line
    /// each, right after the state's audit, so a failure later in the test cannot lose them; there is no attachment when there are none.
    func run(_ app: XCUIApplication, _ state: String, scrolled: Bool = false) throws {
        let earlier = issues.count
        var unnamedFailures: [String] = []
        defer { attachUnattributed(state) }
        func audit() throws {
            issues.removeSubrange(earlier...)
            (unattributed, unnamedFailures) = ([], [])
            try app.performAccessibilityAudit { issue in
                let element = issue.element
                let (id, label, frame) = (element?.identifier ?? "", element?.label ?? "", element?.frame ?? .zero)
                let line = "\(state): \(issue.compactDescription) — \(element == nil ? "no element" : "\(id) \"\(label)\" \(frame)")"
                    + " — \(issue.detailedDescription)"
                if element == nil, issue.auditType == .contrast, issue.compactDescription == "Contrast failed" {
                    unnamedFailures.append(line)
                } else if let reason = Self.knownReason(issue, id: id, label: label, app: app, scrolled: scrolled) {
                    print("Audit let through (\(reason)) \(line)")
                    if element == nil { self.unattributed.append("\(state): \(issue.compactDescription) — \(issue.detailedDescription)") }
                } else {
                    print("Audit ISSUE \(line)")
                    self.issues.append(line)
                }
                return true
            }
        }
        // On a loaded Mac the audit can run out of time (-56): settle, then audit once more, counting only that attempt's issues
        do {
            try audit()
        } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 {
            print("Audit of \(state) timed out, auditing it once more: \(error.localizedDescription)")
            Thread.sleep(forTimeInterval: 5)
            try audit()
        }
        let allowed = Self.unnamedContrastFailures[String(state.prefix { $0 != " " })] ?? 0
        for line in unnamedFailures {
            if unnamedFailures.count <= allowed {
                print("Audit let through (no element: allowed in this state, checked against the screenshot) \(line)")
                unattributed.append(line)
            } else {
                print("Audit ISSUE \(line)")
                issues.append(line)
            }
        }
    }

    /// Fails once with every issue collected.
    func assertNoIssues(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(issues.isEmpty, "Accessibility audit:\n" + issues.joined(separator: "\n"), file: file, line: line)
    }

    private func attachUnattributed(_ state: String) {
        guard !unattributed.isEmpty else { return }
        let attachment = XCTAttachment(string: unattributed.joined(separator: "\n"))
        attachment.name = "a11y-unattributed.txt"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Audit issues with no element in \(state): check each against its screenshot") { $0.add(attachment) }
    }

    /// Text the system lays out itself: `ContentUnavailableView` (empty shelf, empty book, empty Word List, launch failure), the
    /// status capsule and the toast (one `BottomCapsule`), and Settings' Translate To menu and level rows' header and footer.
    private static let scaledText: Set<String> = [
        Strings.noBooks, Strings.noBooksMessage, Strings.cannotOpen, Strings.cannotOpenMessage, Strings.tryAgain, Strings.noPages,
        Strings.noPagesMessage, Strings.noWords, Strings.noWordsMessage, Strings.reading, Strings.failed, Strings.noText,
        Strings.pageDeleted, "Translate To", "How Many to Mark", "Pick the hardest row where you know every word.",
    ]

    /// States where the audit fails a contrast without naming the element, and how many times it may, each checked against the
    /// screenshots of the state: Settings scrolled to its footer, whose first rows then sit under the navigation bar (on the SE in
    /// dark mode, since the footer credits the sample book, the rows of 1,000 and 2,000 words); on the SE, the lowest row cut off
    /// by the bottom of Settings at the medium detent, and at AX5 the row under the result's bottom bar; in dark mode at AX5, the
    /// text of the Reading, No Text or Failed capsule (one view), white on its dark glass, judged against the white page behind,
    /// and behind the card at the medium detent the Reader's bar and page, which the system dims while the card is up (seen in some
    /// runs only); in dark mode at the card's low detent, Look Up (see `knownReason`, "Look Up on its own fill"); on Books, the
    /// photographed book's cover, which the SE's audit does not name (see `knownReason`, "book cover photo"). One more, or one in
    /// any other state, counts.
    private static let unnamedContrastFailures: [String: Int] = [
        "Card-low": 1, "Card-medium": 1, "Settings-footer": 3, "Settings-reader": 1, "LevelTest-result": 1,
        "Reader-reading": 1, "Reader-noText": 1, "Reader-failed": 1, "Books-populated": 1,
    ]

    /// The issues let through, each for its reason; nil for any other issue.
    private static func knownReason(_ issue: XCUIAccessibilityAuditIssue, id: String, label: String, app: XCUIApplication,
                                    scrolled: Bool) -> String? {
        guard let element = issue.element else {
            // The audit could not name the element (a SwiftUI node it cannot resolve), so no rule here can match it. Clipped text and a
            // contrast that nearly passed are checked by hand against the screenshot of the state. A failed contrast cannot be judged
            // by eye: `run` lets it through only as `unnamedContrastFailures` allows. Anything else counts.
            switch issue.auditType {
            case .textClipped: return "no element, clipped: checked against the screenshot"
            case .contrast where issue.compactDescription == "Contrast nearly passed": return "no element, nearly passed: checked too"
            // The only images of text the app shows are page photos. Behind the card at the medium detent (modal) their words are
            // out of reach on purpose; seen on the SE in dark mode at AX5.
            case _ where issue.compactDescription == "Potentially inaccessible text": return "no element, text in a page photo: checked too"
            default: return nil
            }
        }
        let onPage = id == "page" || id.hasPrefix("word.")
        switch issue.auditType {
        case .contrast where onPage:
            // The page is a photo of printed paper: its text's contrast is the print's. The ink's color is fixed and checked on real
            // photos by eye.
            return "page photo"
        case .contrast where id == "book" || isBookCell(element.frame, label, app):
            // A Books cell, its cover and its title, which the audit gives as a node of the cell's frame and title with no identifier.
            // A photographed book's cover is a photo of a printed page at about a sixth of its size, and the audit reads its print, as
            // on the Reader's page, as it does a book's own cover, a picture with its lettering. A generated cover's text is white where
            // it reaches 3:1 and black elsewhere (U-TYPE-015); the title is primary text on the system background.
            return "book cover photo"
        case .contrast where [Strings.reading, Strings.failed, Strings.noText].contains(label) || ["tryAgain", "undo"].contains(id):
            // The status capsule's text on its own glass: 6.7:1 and more measured in the very frames the audit failed (dark mode, the
            // capsule over the white page). Its Try Again and the toast's Undo are bold accent text, whose bar is 3:1: measured on their
            // own fill or glass, 5.3:1 in light mode, 3.3–4.4:1 in dark. The audit judges them against the page behind.
            return "capsule text on glass"
        case .contrast where underToast(element.frame, app):
            // Text the toast covers while it is up (at AX5 on the SE, the empty book's message under the toast after a delete): whole
            // once the toast is gone, as in the same state without it (Reader-emptyBook)
            return "under the toast"
        case .contrast where element.frame.maxY > app.windows.firstMatch.frame.maxY:
            // Cut off by the bottom of the window (a lower row of a sheet at the medium detent): the audit judges it against the edge
            return "off the bottom of the window"
        case .contrast where scrolled && underBar(element.frame, label, app):
            // A state scrolled on purpose: text under a navigation bar, or under the soft edge below it, which fades what scrolls
            // under the bar. In view, the same text passes in the state's unscrolled screenshot.
            return "scrolled under a navigation bar"
        case .contrast where (id.hasPrefix("testWord.") || inTestWord(label, app))
            && element.frame.maxY > app.buttons["continue"].frame.minY - element.frame.height:
            // A test word within a row of the bottom bar, whose soft edge fades what scrolls under it; the audit judges the word against
            // it. Clear of it, a word is black on gray, as the screenshots show.
            return "at the bottom bar"
        case .contrast where label == Strings.openSettings && atCardBar(element.frame, app):
            // The Apple Intelligence hint's Open Settings at the low detent, within a row of the card's action bar, whose soft edge fades
            // what scrolls under it; the audit judges it against that. The same button passes at the medium detent.
            return "at the card's action bar"
        case .contrast where id == "lookUp" || label == "Look Up":
            // Look Up, label-colored text on its own gray fill: 13.75:1 in light mode (black on #D1D1D1) and 7.45:1 in dark (white on
            // #555556), from exact pixels on both iPhones (2026-09-27). In dark mode, at the card's low detent, the audit failed it
            // in every run, sometimes naming no element (`unnamedContrastFailures`, Card-low).
            return "Look Up on its own fill"
        case .contrast where issue.compactDescription == "Contrast nearly passed"
            && ["primaryAction", "continue", "startReading", "read"].contains(id):
            // White on the accent fill: 5.38:1 in light mode and 4.55:1 in dark (#ED0017), from exact pixels. The audit samples the
            // antialiased edge of the label. A failed contrast is not let through.
            return "white on the accent fill, nearly passed"
        case .contrast where issue.compactDescription == "Contrast nearly passed" && element.elementType == .staticText:
            // Secondary text in the system's secondary label color. A failed contrast is not let through, nor a control.
            return "system secondary color, nearly passed"
        case .hitRegion where id.hasPrefix("word."):
            // A word's element is its printed box, but a tap takes the nearest word within 24 pt
            return "word, 24 pt hit radius"
        case .dynamicType where scaledText.contains(label) || ["tryAgain", "launchRetry", "headword", "undo"].contains(id)
            || id.hasPrefix("testWord.") || inTestWord(label, app):
            // The system's text above, the card's headword and the level test's words (the longest shrink to stay on one line): seen
            // at full AX5 size in the AX5 screenshots of these states
            return "scales in the AX5 screenshots"
        case .dynamicType where ["wordList", "skip"].contains(id):
            // Text buttons in the navigation bar: the system caps their size, as in Apple's own apps, and shows them in the Large
            // Content Viewer on a long press
            return "navigation-bar text, Large Content Viewer"
        case .textClipped where id == "wordRow" || inWordRow(label, app):
            // A Word List row cuts its sentence at two lines by design; Go to Page shows the sentence on its page
            return "row sentence, two lines by design"
        case .textClipped where app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch.exists:
            // The system navigation bar shortens a long title or subtitle; VoiceOver reads the whole of it, its label. Queried by a
            // predicate: a query by identifier or label takes at most 128 characters.
            return "navigation title"
        case .textClipped where id.hasPrefix("testWord.") || inTestWord(label, app):
            // A test word stays on one line by design: the longest shrink rather than wrap, whole in the AX5 screenshots
            return "test word, one line by design"
        case .textClipped where id == "headword" || id == "tryAgain" || scaledText.contains(label)
            || ["Go to Page", Strings.appleIntelligenceHint, Strings.openSettings].contains(label):
            // Whole in the screenshot of the same state: the audit misjudges these, and the card's Go to Page and Apple Intelligence
            // hint at either detent
            return "whole in the screenshot"
        default:
            return nil
        }
    }

    /// Whether a node is a Books cell: a cell of that title and that frame. Queried by a predicate: a query by label takes at most 128
    /// characters.
    private static func isBookCell(_ frame: CGRect, _ label: String, _ app: XCUIApplication) -> Bool {
        let cell = app.buttons.matching(NSPredicate(format: "identifier == 'book' AND label == %@", label)).firstMatch
        return cell.exists && cell.frame == frame
    }

    /// Whether text outside the toast is partly under it.
    private static func underToast(_ frame: CGRect, _ app: XCUIApplication) -> Bool {
        let toast = app.descendants(matching: .any).matching(identifier: "toast").firstMatch
        guard toast.exists else { return false }
        let capsule = toast.frame
        return capsule.intersects(frame) && !capsule.contains(frame)
    }

    /// Whether content (not an item of the bar itself) starts under a navigation bar or under the soft edge, about 24 pt, below it.
    private static func underBar(_ frame: CGRect, _ label: String, _ app: XCUIApplication) -> Bool {
        guard !label.isEmpty,
              !app.navigationBars.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.exists
        else { return false }
        // Also text scrolled past the bar's top: out of view (on the SE, Settings scrolled to its footer puts its first header there)
        return app.navigationBars.allElementsBoundByIndex.contains { frame.minY < $0.frame.maxY + 24 }
    }

    /// Whether card content starts above the card's action bar and ends within a row of it. At accessibility sizes the actions
    /// scroll with the text, above the hint, so the hint never matches there.
    private static func atCardBar(_ frame: CGRect, _ app: XCUIApplication) -> Bool {
        let bar = app.buttons["primaryAction"]
        guard bar.exists else { return false }
        let top = bar.frame.minY
        return frame.minY < top && frame.maxY > top - frame.height
    }

    /// Whether the text is a level test word's: a checked word's element can be its text, which has no identifier.
    private static func inTestWord(_ label: String, _ app: XCUIApplication) -> Bool {
        !label.isEmpty && app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'testWord.' AND label == %@", label)).firstMatch.exists
    }

    /// Whether the text is part of a Word List row, whose label joins its word and its sentence.
    private static func inWordRow(_ label: String, _ app: XCUIApplication) -> Bool {
        !label.isEmpty && app.buttons.matching(NSPredicate(format: "identifier == 'wordRow' AND label CONTAINS %@", label)).firstMatch.exists
    }
}

/// Saves the whole screen as a PNG attachment the result bundle keeps, named `<state>_<device>_<appearance>_<text size>.png`, for
/// example `Reader-zoomed_iPhone-17-Pro_dark_AX5.png`. `xcrun xcresulttool export attachments` writes them out.
@MainActor
func saveScreenshot(_ state: String, size: UIContentSizeCategory) {
    // Let the 0.2 s capsule fade and other animations finish
    Thread.sleep(forTimeInterval: 1)
    let device = (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device").replacingOccurrences(of: " ", with: "-")
    let appearance = switch XCUIDevice.shared.appearance {
    case .dark: "dark"
    case .light: "light"
    default: "unspecified"
    }
    let attachment = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
    attachment.name = "\(state)_\(device)_\(appearance)_\(Config.name(of: size)).png"
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: "Screenshot \(attachment.name ?? state)") { $0.add(attachment) }
}
