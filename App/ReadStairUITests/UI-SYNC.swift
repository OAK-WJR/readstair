import XCTest

/// A level from iCloud arriving while the first-launch level test is open. `-ReadStairCloudLevel` has the app apply it three seconds into
/// the test through the store's merge of fetched records, the path a real one takes once the sync engine has read it.
final class SyncLevelTests: UITestCase {
    /// UI-SYNC-001: the level from iCloud neither closes the test nor moves anything on it; finishing the test makes the test's level
    /// the level, and it stays the level after a relaunch. That it is then sent to iCloud, and a level from iCloud never is, the core
    /// tests of the store's sync rules check.
    @MainActor
    func testUI_SYNC_001_cloudLevelDuringTestThenContinue() throws {
        let session = try Session.fresh()
        launchWithCloudLevel(12, session)

        // Every real word of the 1,000 to 5,000 levels and no made-up word: 5,000 words, whatever arrived from iCloud
        session.answerLevelTest { Vocab.band(of: $0).map { (1...5).contains($0) } ?? false }
        session.app.buttons["continue"].tap()
        XCTAssertTrue(session.eventually(10) { session.app.staticTexts[Strings.about("5,000")].exists })
        XCTAssertTrue(session.levelRow(5).isSelected)
        XCTAssertFalse(session.levelRow(12).isSelected)
        session.app.buttons["startReading"].tap()
        XCTAssertTrue(session.eventually(10) { session.app.staticTexts[Strings.noBooks].exists })
        session.levelTestPending = false

        session.relaunch()
        XCTAssertTrue(session.levelTestStaysAway())
        session.openSettings()
        XCTAssertTrue(session.levelRow(5).isSelected, "The test's level was not saved")
    }

    /// UI-SYNC-001, Skip: a level that arrived from iCloud during the test stays the level after Skip (Skip's placeholder never replaces
    /// a level), and after a relaunch.
    @MainActor
    func testUI_SYNC_001_cloudLevelDuringTestThenSkip() throws {
        let session = try Session.fresh()
        launchWithCloudLevel(12, session)

        session.skipLevelTest()
        session.openSettings()
        XCTAssertTrue(session.levelRow(12).isSelected, "Skip replaced the level from iCloud")
        session.closeSettings()

        session.relaunch()
        XCTAssertTrue(session.levelTestStaysAway())
        session.openSettings()
        XCTAssertTrue(session.levelRow(12).isSelected, "The level from iCloud was not kept")
    }

    /// Launches a new store on the level test with `-ReadStairCloudLevel`, then waits past the level's arrival: the test is still there,
    /// with every word where it was.
    @MainActor
    private func launchWithCloudLevel(_ level: Int, _ session: Session, file: StaticString = #filePath, line: UInt = #line) {
        session.configure()
        session.app.launchArguments += ["-ReadStairCloudLevel", "\(level)"]
        session.app.launch()
        XCTAssertTrue(session.eventually(30) { session.skipButton.exists }, "The level test did not appear", file: file, line: line)
        let before = layout(session)
        XCTAssertFalse(before.isEmpty, file: file, line: line)
        // The level arrives 3 s in, and the app reads it back within 0.25 s
        session.settle(6)
        XCTAssertTrue(session.skipButton.exists, "The level from iCloud closed the test", file: file, line: line)
        XCTAssertEqual(layout(session), before, "The level test's screen changed", file: file, line: line)
    }

    /// What the level test shows: each word, Skip and Continue, with where it is.
    @MainActor
    private func layout(_ session: Session) -> [String] {
        session.nodes().filter { $0.id.hasPrefix("testWord.") || $0.id == "skip" || $0.id == "continue" }
            .map { "\($0.id) \($0.label) \($0.isSelected) \($0.frame)" }
            .sorted()
    }
}
