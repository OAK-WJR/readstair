import XCTest

/// The first-launch level test: Skip, the estimate and its result, and a test that never comes back.
final class LevelTestTests: UITestCase {
    /// UI-TEST-001: Skip shows from the first moment, nothing swipes the test away, and Skip opens Books at the default level,
    /// 3,000 words. A relaunch does not show the test again.
    @MainActor
    func testUI_TEST_001_skip() throws {
        let session = try Session.fresh()
        session.launch(stopsAtLevelTest: true)
        let skip = session.skipButton
        XCTAssertTrue(session.eventually(30) { skip.exists }, "The level test did not appear")
        // In the top bar, before any answer, with nothing to scroll
        XCTAssertEqual(skip.label, "Skip")
        XCTAssertTrue(skip.isHittable)
        XCTAssertLessThan(skip.frame.maxY, session.window.height * 0.2)
        XCTAssertTrue(session.app.staticTexts[Strings.whichWords].exists)
        XCTAssertTrue(session.testWord(0).exists)

        // No gesture closes it
        session.drag(from: CGVector(dx: 0.5, dy: 0.08), to: CGVector(dx: 0.5, dy: 0.95), fling: true)
        XCTAssertTrue(skip.exists, "A swipe closed the level test")

        session.skipLevelTest()
        XCTAssertTrue(session.eventually(10) { session.app.staticTexts[Strings.noBooks].exists })
        session.openSettings()
        XCTAssertTrue(session.levelRow(3).isSelected, "Skip did not leave the default level")
        session.closeSettings()

        session.relaunch()
        XCTAssertTrue(session.levelTestStaysAway(), "The level test came back")
    }

    /// UI-TEST-001: the words tapped decide the estimate; Continue shows it in the same cover with the level rows, without Skip or
    /// a way back; a row changes the level and the heading with it; Start Reading opens Books. The level is saved, and the test never
    /// comes back.
    @MainActor
    func testUI_TEST_001_continueAdjustAndStartReading() throws {
        let session = try Session.fresh()
        session.launch(stopsAtLevelTest: true)
        XCTAssertTrue(session.eventually(30) { session.skipButton.exists })
        // Every real word of the 1,000 to 5,000 levels and no made-up word: 5,000 words
        let tapped = session.answerLevelTest { Vocab.band(of: $0).map { (1...5).contains($0) } ?? false }
        XCTAssertEqual(tapped.count, 20, "Tapped: \(tapped)")
        session.app.buttons["continue"].tap()

        XCTAssertTrue(session.eventually(10) { session.app.staticTexts[Strings.about("5,000")].exists }, "No estimate of 5,000 words")
        XCTAssertTrue(session.app.staticTexts[Strings.estimateNote].exists)
        XCTAssertFalse(session.skipButton.exists, "The result offers Skip")
        XCTAssertFalse(session.testWord(0).exists, "The words are still there")
        XCTAssertTrue(session.levelRow(5).isSelected)
        XCTAssertTrue(session.levelRow(5).label.hasPrefix("5,000 words. Examples: "), session.levelRow(5).label)

        // The heading names the checked row; at the larger text sizes it is scrolled away above the rows by now
        session.levelRow(8).tap()
        XCTAssertTrue(session.eventually(5) { session.levelRow(8).isSelected && !session.levelRow(5).isSelected })
        let heading = session.app.staticTexts[Strings.about("8,000")]
        session.scrollIntoView(heading, forward: false)
        XCTAssertTrue(heading.exists, "The heading did not follow the row")
        XCTAssertFalse(session.app.staticTexts[Strings.about("5,000")].exists)
        session.app.buttons["startReading"].tap()
        XCTAssertTrue(session.eventually(10) { session.app.staticTexts[Strings.noBooks].exists })
        session.levelTestPending = false

        session.relaunch()
        XCTAssertTrue(session.levelTestStaysAway(), "The level test came back")
        session.openSettings()
        XCTAssertTrue(session.levelRow(8).isSelected, "The level chosen on the result was not saved")
    }

    /// UI-TEST-001: answers that say too little give the lowest level. With made-up words tapped the result says why; with nothing
    /// tapped it is a plain estimate, since no tapped word was made up.
    @MainActor
    func testUI_TEST_001_unreliableAnswers() throws {
        let guessing = try Session.fresh()
        guessing.launch(stopsAtLevelTest: true)
        XCTAssertTrue(guessing.eventually(30) { guessing.skipButton.exists })
        let tapped = guessing.answerLevelTest { Vocab.band(of: $0) == 0 }
        XCTAssertEqual(tapped.count, 10, "Tapped: \(tapped)")
        guessing.app.buttons["continue"].tap()
        XCTAssertTrue(guessing.eventually(10) { guessing.app.staticTexts[Strings.startLow].exists })
        XCTAssertTrue(guessing.app.staticTexts[Strings.unreliableNote].exists)
        XCTAssertTrue(guessing.levelRow(1).isSelected)
        guessing.app.terminate()

        let silent = try Session.fresh()
        silent.launch(stopsAtLevelTest: true)
        XCTAssertTrue(silent.eventually(30) { silent.app.buttons["continue"].exists })
        silent.app.buttons["continue"].tap()
        XCTAssertTrue(silent.eventually(10) { silent.app.staticTexts[Strings.about("1,000")].exists })
        XCTAssertTrue(silent.app.staticTexts[Strings.estimateNote].exists)
        XCTAssertFalse(silent.app.staticTexts[Strings.unreliableNote].exists)
        XCTAssertTrue(silent.levelRow(1).isSelected)
    }
}
