import XCTest

/// Launch: Books without a flash of the empty state, and the screen shown when the store cannot be opened.
final class LaunchTests: UITestCase {
    /// UI-LAUNCH-001: with a book saved, the app opens on Books and goes straight to its cell, never through `No Books Yet`. XCUITest
    /// only sees the screen once `launch()` returns, so a flash before that is out of its reach.
    @MainActor
    func testUI_LAUNCH_001_booksWithoutEmptyFlash() throws {
        let session = try Session.fresh()
        session.launch(seeds: [Fixture.alice], recognizer: .fail)
        session.addBookFromPhotos()
        XCTAssertTrue(session.waitForReader(pages: 1))

        session.relaunch(recognizer: .fail)
        var sawEmpty = false
        let listed = session.eventually(30, interval: 0) {
            if session.app.staticTexts[Strings.noBooks].exists { sawEmpty = true }
            return session.rows().count == 1
        }
        XCTAssertTrue(listed, "The saved book never appeared")
        XCTAssertFalse(sawEmpty, "Books showed its empty state before the saved book")
        // A relaunch always starts on Books, whatever was open before
        XCTAssertTrue(session.isShowingBooks)
        XCTAssertNil(session.position())
    }

    /// UI-LAUNCH-002: a store that cannot be opened shows `Can’t Open Your Books` and `Try Again`; once the problem is gone, Try Again
    /// opens the store, and with it the first-launch level test.
    @MainActor
    func testUI_LAUNCH_002_failureThenTryAgain() throws {
        let session = try Session.fresh()
        let blocker = try session.blockDataRoot()
        // A store that cannot open has no level test to skip yet
        session.launch(stopsAtLevelTest: true)
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.cannotOpen].exists })
        XCTAssertTrue(session.app.staticTexts[Strings.cannotOpenMessage].exists)
        let retry = session.app.buttons["launchRetry"]
        XCTAssertTrue(retry.exists)
        XCTAssertEqual(retry.label, Strings.tryAgain)
        XCTAssertFalse(session.app.buttons["addBook"].exists, "The failure screen has no navigation")

        try FileManager.default.removeItem(at: blocker)
        session.tapTargetEdge(retry)
        session.skipLevelTest()
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noBooks].exists })
        XCTAssertTrue(session.isShowingBooks)
        XCTAssertFalse(retry.exists)
    }
}
