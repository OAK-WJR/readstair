import XCTest

/// The word card: opening and swapping, keeping the word in view, its buttons, the toast and undo, and what opening a card may change.
/// Page 1 is alice-p1 read at the default level: `peeped` (peep) and `curiosity` are marked, `waistcoat-pocket` is marked because the
/// lexicon has no `waistcoat`, `sister` is common and not marked, and nothing on the last three lines is marked.
final class WordCardTests: UITestCase {
    /// The Reader on page 1 of the template book, read; `holdsUndo` keeps the undo toast until something commits it.
    @MainActor
    private func readerOnReadPage(holdsUndo: Bool = false) throws -> Session {
        let session = try Template.bookWithRecognizedPages()
        session.holdsUndo = holdsUndo
        session.launch()
        session.openBook()
        XCTAssertTrue(session.eventually(30) { session.showsPage(1, of: 2) }, "Opened at \(session.subtitle)")
        XCTAssertTrue(session.waitForRecognized())
        return session
    }

    /// UI-CARD-001: a word's card opens at the low detent and the word shows as selected; tapping another word with the card open swaps
    /// the card in place at the same detent.
    @MainActor
    func testUI_CARD_001_swapInPlace() throws {
        let session = try readerOnReadPage()
        let first = try XCTUnwrap(session.word("waistcoat-pocket"))
        XCTAssertTrue(session.tapWord(at: first.frame, expecting: "waistcoat-pocket"))
        session.settle(1.5)
        let top = try XCTUnwrap(session.cardContentTop())
        XCTAssertGreaterThanOrEqual(top, session.lowCardTop() - 1, "The card opened above the low detent")
        XCTAssertTrue(session.eventually(5) { session.word("waistcoat-pocket")?.isSelected == true })
        // The whole headword shows at the low detent, above the buttons (at accessibility sizes they scroll with the text)
        let headword = session.headword.frame
        XCTAssertLessThanOrEqual(headword.maxY, session.primaryAction.frame.minY, "The buttons cover the headword")
        XCTAssertLessThanOrEqual(headword.maxY, session.window.maxY, "The headword runs off the screen")

        let second = try XCTUnwrap(session.word("peeped"))
        XCTAssertTrue(session.tapWord(at: second.frame, expecting: "peep"), "The open card did not change to peep")
        session.settle(1.5)
        XCTAssertEqual(try XCTUnwrap(session.cardContentTop()), top, accuracy: 1, "The detent changed with the word")
        XCTAssertTrue(session.eventually(5) {
            session.word("peeped")?.isSelected == true && session.word("waistcoat-pocket")?.isSelected == false
        }, "The selection did not follow the card")
    }

    /// UI-CARD-007: the card's own buttons. Pronounce leaves the card as it is; Look Up shows the system dictionary over the card, and
    /// closing it returns to the card.
    @MainActor
    func testUI_CARD_007_pronounceAndLookUp() throws {
        let session = try readerOnReadPage()
        let word = try XCTUnwrap(session.word("peeped"))
        XCTAssertTrue(session.tapWord(at: word.frame, expecting: "peep"))
        let pronounce = session.app.buttons["pronounce"]
        XCTAssertEqual(pronounce.label, "Pronounce peep")
        pronounce.tap()
        session.settle()
        XCTAssertEqual(session.headword.label, "peep")

        let lookUp = session.app.buttons["lookUp"]
        XCTAssertEqual(lookUp.label, "Look Up")
        lookUp.tap()
        // The dictionary's close button is labelled `close` on iOS 26
        let close = session.app.buttons.matching(NSPredicate(format: "label ==[c] 'Done' OR label ==[c] 'Close'")).firstMatch
        // The dictionary is a remote view: on a loaded simulator it can take 15 s or more to load
        XCTAssertTrue(session.eventually(60) { close.exists }, "The dictionary did not appear")
        close.tap()
        XCTAssertTrue(session.eventually(20) { !close.exists && session.headword.isHittable }, "The card did not come back")
        XCTAssertEqual(session.headword.label, "peep")
    }

    /// UI-CARD-002: `I Know This` closes the card, drops the underline and names the word in the toast; Undo puts it back. Left to time
    /// out, the change is saved and holds after a relaunch.
    @MainActor
    func testUI_CARD_002_iKnowThisUndoAndSave() throws {
        let session = try readerOnReadPage()
        let count = try XCTUnwrap(session.newWordCount())
        let peeped = try XCTUnwrap(session.word("peeped"))
        XCTAssertTrue(session.tapWord(at: peeped.frame, expecting: "peep"))
        XCTAssertEqual(session.primaryAction.label, Strings.iKnowThis)
        session.primaryAction.tap()
        XCTAssertTrue(session.eventually(10) { !session.headword.exists }, "I Know This did not close the card")
        XCTAssertTrue(session.eventually(10) { session.toastText() == Strings.markedKnown("peep") }, "Toast: \(session.toastText() ?? "none")")
        XCTAssertTrue(session.eventually(20) { session.newWordCount() == count - 1 && session.word("peeped") == nil })
        session.undo.tap()
        XCTAssertTrue(session.eventually(20) { session.newWordCount() == count && session.word("peeped") != nil }, "Undo did not bring the underline back")
        XCTAssertFalse(session.toast.exists)

        XCTAssertTrue(session.tapWord(at: peeped.frame, expecting: "peep"))
        session.primaryAction.tap()
        XCTAssertTrue(session.eventually(20) { session.newWordCount() == count - 1 })
        XCTAssertTrue(session.waitForToastToEnd())
        session.relaunch()
        session.openBook()
        XCTAssertTrue(session.eventually(30) { session.showsPage(1, of: 2) })
        XCTAssertTrue(session.waitForRecognized())
        XCTAssertEqual(session.newWordCount(), count - 1, "The change was not saved")
        XCTAssertNil(session.word("peeped"))
    }

    /// UI-CARD-002: opening and closing another card while the toast waits leaves the toast alone, and Undo still works. The toast is
    /// held (`holdsUndo`), so nothing here races its 5 seconds; the timeout itself is S-APP-Loop's.
    @MainActor
    func testUI_CARD_002_undoAfterAnotherCard() throws {
        let session = try readerOnReadPage(holdsUndo: true)
        let count = try XCTUnwrap(session.newWordCount())
        let peeped = try XCTUnwrap(session.word("peeped"))
        let other = try XCTUnwrap(session.word("waistcoat-pocket"))
        XCTAssertTrue(session.tapWord(at: peeped.frame, expecting: "peep"))
        session.primaryAction.tap()
        XCTAssertTrue(session.tapWord(at: other.frame, expecting: "waistcoat-pocket"))
        session.closeCard()
        XCTAssertTrue(session.undo.exists, "Opening and closing another card let the toast go")
        session.undo.tap()
        XCTAssertTrue(session.eventually(20) { session.newWordCount() == count && session.word("peeped") != nil },
                      "Undo did not bring the underline back")
    }

    /// UI-CARD-003: the card never covers the word it shows. A word on the last three lines scrolls up to at least 12 pt above the
    /// card; another word on the same line, or one already clear of the card, moves nothing; with the card open the page pans far
    /// enough to show its last line; at 2× the same holds and the zoom stays. None of these words is marked: any word opens a card.
    @MainActor
    func testUI_CARD_003_wordStaysInView() throws {
        let session = try readerOnReadPage()
        let truth = Fixture.aliceTruth
        let rest = try XCTUnwrap(session.visiblePage()).frame
        let lastLines = Array(truth.lines.suffix(3))
        XCTAssertEqual(lastLines.count, 3)

        // From rest, the first and the last word of each of the last three lines
        for line in lastLines {
            for word in [line.first, line.last].compactMap({ $0 }) {
                session.closeCard()
                XCTAssertTrue(session.waitForRest(rest), "The page did not settle back after the card closed")
                XCTAssertTrue(session.tapWord(at: truth.rect(of: word, on: rest)), "No card for \(word.text)")
                session.settle(1.2)
                assertClearOfCard(word, session)
            }
        }

        // The card is on the last line's last word; the first word on that line moves nothing
        let lastLine = try XCTUnwrap(lastLines.last)
        let lineStart = try XCTUnwrap(lastLine.first)
        let before = try XCTUnwrap(session.visiblePage()).frame
        XCTAssertTrue(session.tapWord(at: truth.rect(of: lineStart, on: before)), "No card for \(lineStart.text)")
        session.settle(1.2)
        XCTAssertEqual(try XCTUnwrap(session.visiblePage()).frame.minY, before.minY, accuracy: 0.5, "A word on the same line moved the page")

        // A word already clear of the card moves nothing
        let shown = try XCTUnwrap(session.visiblePage()).frame
        let limit = session.wordLimit()
        let clear = try XCTUnwrap(truth.words.first { word in
            let rect = truth.rect(of: word, on: shown)
            return word.core.count >= 6 && rect.minY > rest.minY && rect.maxY < limit - 40
        }, "No word clear of the card")
        XCTAssertTrue(session.tapWord(at: truth.rect(of: clear, on: shown)), "No card for \(clear.text)")
        session.settle(1.2)
        XCTAssertEqual(try XCTUnwrap(session.visiblePage()).frame.minY, shown.minY, accuracy: 0.5, "A word clear of the card moved the page")

        // With the card open, the page pans far enough to show its last line
        for _ in 0..<2 {
            session.drag(from: CGVector(dx: 0.5, dy: 0.45), to: CGVector(dx: 0.5, dy: 0.1))
        }
        let panned = try XCTUnwrap(session.visiblePage()).frame
        XCTAssertLessThanOrEqual(truth.rect(of: lineStart, on: panned).maxY, session.wordLimit(), "The last line cannot be panned clear of the card")

        // At 2×: a word the card would cover scrolls clear, and the zoom stays
        session.closeCard()
        XCTAssertTrue(session.waitForRest(rest))
        session.zoomIn(2.2)
        let zoom = try XCTUnwrap(session.zoom())
        XCTAssertGreaterThan(zoom, 1.5)
        let zoomed = try XCTUnwrap(session.visiblePage()).frame
        // On screen: inside the window's sides, below the bars, above the home indicator
        let screen = CGRect(x: session.window.minX + 8, y: rest.minY, width: session.window.width - 16,
                            height: session.window.maxY - 50 - rest.minY)
        let visible = truth.words.filter { word in
            word.core.count >= 4 && screen.contains(truth.rect(of: word, on: zoomed))
        }
        // Preferably one the card will cover; else the lowest on screen
        let cardTop = session.lowCardTop()
        let covered = visible.first { word in truth.rect(of: word, on: zoomed).minY > cardTop }
        let lowest = visible.max { first, second in truth.rect(of: first, on: zoomed).maxY < truth.rect(of: second, on: zoomed).maxY }
        let target = try XCTUnwrap(covered ?? lowest, "No word on screen at 2×")
        XCTAssertTrue(session.tapWord(at: truth.rect(of: target, on: zoomed)), "No card for \(target.text)")
        session.settle(1.2)
        XCTAssertEqual(try XCTUnwrap(session.zoom()), zoom, accuracy: 0.01, "Showing the word changed the zoom")
        assertClearOfCard(target, session)
    }

    /// The word ends at least 12 pt above the card.
    @MainActor
    private func assertClearOfCard(_ word: Truth.Word, _ session: Session, file: StaticString = #filePath, line: UInt = #line) {
        guard let page = session.visiblePage() else { return XCTFail("No page", file: file, line: line) }
        let bottom = Fixture.aliceTruth.rect(of: word, on: page.frame).maxY
        let limit = session.wordLimit()
        XCTAssertLessThanOrEqual(bottom, limit, "\(word.text) ends at \(bottom), below the limit \(limit) the card sets", file: file, line: line)
    }

    /// UI-CARD-004: a tap that hits no word opens nothing, and tapping the word already shown changes nothing.
    @MainActor
    func testUI_CARD_004_tapsThatDoNothing() throws {
        let session = try readerOnReadPage()
        let page = try XCTUnwrap(session.visiblePage()).frame
        // The page's bottom left corner, far from any word
        session.tap(CGPoint(x: page.minX + 0.02 * page.width, y: page.minY + 0.99 * page.height))
        session.settle(3)
        XCTAssertFalse(session.headword.exists, "A tap on the margin opened a card")

        let word = try XCTUnwrap(session.word("waistcoat-pocket"))
        XCTAssertTrue(session.tapWord(at: word.frame, expecting: "waistcoat-pocket"))
        session.settle(1.5)
        let before = try XCTUnwrap(session.visiblePage()).frame
        let shown = try XCTUnwrap(session.word("waistcoat-pocket"))
        session.tap(CGPoint(x: shown.frame.midX, y: shown.frame.midY))
        session.settle(2)
        XCTAssertEqual(session.headword.label, "waistcoat-pocket")
        XCTAssertEqual(try XCTUnwrap(session.visiblePage()).frame.minY, before.minY, accuracy: 0.5, "Tapping the shown word moved the page")
    }

    /// UI-CARD-004: while a page is still being read, tapping its words opens nothing.
    @MainActor
    func testUI_CARD_004_noCardWhileReading() throws {
        let session = try Session.fresh()
        session.launch(seeds: [Fixture.alice], recognizer: .stall)
        session.addBookFromPhotos()
        XCTAssertTrue(session.waitForReader(pages: 1))
        XCTAssertTrue(session.eventually(20) { session.statusText() == Strings.reading })
        let page = try XCTUnwrap(session.visiblePage()).frame
        let peeped = try XCTUnwrap(Fixture.aliceTruth.word("peeped"))
        let rect = Fixture.aliceTruth.rect(of: peeped, on: page)
        session.tap(CGPoint(x: rect.midX, y: rect.midY))
        session.settle(3)
        XCTAssertEqual(session.statusText(), Strings.reading)
        XCTAssertFalse(session.headword.exists, "A word on a page being read opened a card")
    }

    /// UI-CARD-005: a word marked as known is still a word: tapping it offers `Mark as New`, which brings the underline back; Undo
    /// takes it away again.
    @MainActor
    func testUI_CARD_005_markAsNew() throws {
        let session = try readerOnReadPage()
        let count = try XCTUnwrap(session.newWordCount())
        let peeped = try XCTUnwrap(session.word("peeped"))
        XCTAssertTrue(session.tapWord(at: peeped.frame, expecting: "peep"))
        session.primaryAction.tap()
        XCTAssertTrue(session.waitForToastToEnd())
        XCTAssertTrue(session.eventually(20) { session.newWordCount() == count - 1 && session.word("peeped") == nil })

        XCTAssertTrue(session.tapWord(at: peeped.frame, expecting: "peep"), "The unmarked word opened no card")
        XCTAssertEqual(session.primaryAction.label, Strings.markAsNew)
        session.primaryAction.tap()
        XCTAssertTrue(session.eventually(10) { session.toastText() == Strings.markedNew("peep") }, "Toast: \(session.toastText() ?? "none")")
        XCTAssertTrue(session.eventually(20) { session.newWordCount() == count && session.word("peeped") != nil }, "The underline did not come back")
        session.undo.tap()
        XCTAssertTrue(session.eventually(20) { session.newWordCount() == count - 1 && session.word("peeped") == nil })
    }

    /// UI-CARD-006: opening a card never changes an underline, whatever the word: an unmarked common word (`sister`), a marked word
    /// (`peeped`), a marked word the lexicon does not know (`waistcoat-pocket`). A change still waiting in the toast counts at once:
    /// a word just marked as known and opened again offers `Mark as New`. Of these words only peep, marked with a band and still new,
    /// is in the Word List.
    @MainActor
    func testUI_CARD_006_openingChangesNoUnderline() throws {
        let session = try readerOnReadPage()
        let count = try XCTUnwrap(session.newWordCount())
        let page = try XCTUnwrap(session.visiblePage()).frame
        let sister = try XCTUnwrap(Fixture.aliceTruth.word("sister"))
        XCTAssertTrue(session.tapWord(at: Fixture.aliceTruth.rect(of: sister, on: page), expecting: "sister"))
        XCTAssertEqual(session.primaryAction.label, Strings.markAsNew)
        session.closeCard()
        for (label, headword) in [("peeped", "peep"), ("waistcoat-pocket", "waistcoat-pocket")] {
            let word = try XCTUnwrap(session.word(label))
            XCTAssertTrue(session.tapWord(at: word.frame, expecting: headword))
            XCTAssertEqual(session.primaryAction.label, Strings.iKnowThis, headword)
            session.closeCard()
        }
        session.settle(2)
        XCTAssertEqual(session.newWordCount(), count, "Opening cards changed the page's underlines")
        XCTAssertNil(session.word("sister"))

        let curiosity = try XCTUnwrap(session.word("curiosity"))
        XCTAssertTrue(session.tapWord(at: curiosity.frame, expecting: "curiosity"))
        session.primaryAction.tap()
        let marked = Date.now
        XCTAssertTrue(session.tapWord(at: curiosity.frame, expecting: "curiosity"))
        XCTAssertEqual(session.primaryAction.label, Strings.markAsNew,
                       "Reopened \(Date.now.timeIntervalSince(marked)) s after I Know This")
        session.closeCard()
        XCTAssertTrue(session.waitForToastToEnd())
        XCTAssertTrue(session.eventually(20) { session.newWordCount() == count - 1 && session.word("curiosity") == nil })

        session.back()
        session.openWordList()
        XCTAssertTrue(session.eventually(10) { session.listedWords() == ["peep"] }, "Word List: \(session.listedWords())")
    }

    /// UI-CARD-008: with Apple Intelligence turned off in Settings, the first card that would read its word In This Sentence shows,
    /// in that section's place, a hint to turn it on and `Open Settings`, which opens Settings; back from there the hint is still on
    /// its card. Relaunched with that card still open, no card shows it: the app saved it as shown when it showed it. Available, or
    /// unavailable for another reason, no card shows the hint or uses it up. The app keeps that flag in its UserDefaults, which
    /// outlive the store and the run, so the first launch forgets it (`resetsHint`) and every later one reads what the app saved.
    @MainActor
    func testUI_CARD_008_appleIntelligenceHintOnce() throws {
        let session = try Template.bookWithRecognizedPages()
        let hint = session.app.staticTexts.matching(NSPredicate(format: "label == %@", Strings.appleIntelligenceHint)).firstMatch
        let openSettings = session.openSettingsButton
        let section = session.app.staticTexts[Strings.inThisSentence]
        session.resetsHint = true
        // Available (the simulator's model may then fail, which takes the section away) or unavailable for another reason: no hint
        for state in [Session.AppleIntelligence.available, .unavailable] {
            session.appleIntelligence = state
            if state == .available { session.launch() } else { session.relaunch() }
            session.resetsHint = false
            try session.openPeeped()
            session.settle(2)
            XCTAssertFalse(hint.exists || openSettings.exists, "\(state): the card shows the hint")
            if state == .unavailable { XCTAssertFalse(section.exists, "Unavailable, yet the card shows In This Sentence") }
        }

        // Neither launch used the hint up
        session.appleIntelligence = .notEnabled
        session.relaunch()
        try session.openPeeped()
        XCTAssertTrue(session.eventually(10) { hint.exists }, "No hint with Apple Intelligence turned off")
        XCTAssertTrue(openSettings.exists, "No Open Settings")
        XCTAssertFalse(section.exists, "In This Sentence shows with Apple Intelligence turned off")
        // At AX5 the hint runs on below the medium detent
        session.expandCard()
        XCTAssertTrue(session.scrollIntoView(openSettings), "Open Settings is out of reach")
        XCTAssertTrue(hint.exists, "The hint went while its card was open")
        openSettings.tap()
        // Settings' own screen on show: XCUIApplication.state can go on reading another app as not in the foreground
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(session.eventually(60) { settings.navigationBars.firstMatch.exists }, "Open Settings did not open Settings")
        session.app.activate()
        // In the foreground by its state, or by the card's own button in the tree again, which a suspended app does not answer for:
        // the state can go on reading as not in the foreground after the app is back (the SE, 2026-09-27: the recording shows the
        // card), and at AX5 the button can be out of view, so not hittable
        XCTAssertTrue(session.eventually(30) { session.app.state == .runningForeground || openSettings.exists },
                      "The app did not come back")
        // Back in the foreground the app asks again whether Apple Intelligence is on, and the card draws again
        session.settle(2)
        XCTAssertTrue(hint.exists && openSettings.exists, "The hint went after a trip to Settings")

        // Relaunched with the hint's card still open, so no closing of it can have saved the flag
        session.relaunch()
        try session.openPeeped()
        session.settle(2)
        XCTAssertFalse(hint.exists || openSettings.exists || section.exists, "After a relaunch the card shows the hint or In This Sentence")
        session.closeCard()
        let other = try XCTUnwrap(session.word("waistcoat-pocket"), "waistcoat-pocket is not marked")
        XCTAssertTrue(session.tapWord(at: other.frame, expecting: "waistcoat-pocket"))
        session.settle(2)
        XCTAssertFalse(hint.exists || openSettings.exists || section.exists, "The next card shows the hint or In This Sentence")
    }
}
