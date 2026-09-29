import XCTest

/// How Many to Mark: the level rows in Settings, from the Reader and from Books.
final class LevelTests: UITestCase {
    /// UI-LEVEL-001: from the Reader, `⋯` → `How Many to Mark…` opens Settings, whose subtitle counts the page's new words; a row
    /// applies at once and the count follows live (more at 1,000, fewer at 12,000, the same again back at 3,000), and so does the page
    /// once Settings is closed. From Books the same sheet has no page count. The level holds after a relaunch.
    @MainActor
    func testUI_LEVEL_001_rowsChangeTheMarksLive() throws {
        let session = try Template.bookWithRecognizedPages()
        session.launch()
        session.openBook()
        XCTAssertTrue(session.waitForRecognized())
        let atThree = try XCTUnwrap(session.newWordCount())

        session.tapMore()
        session.tapMenuItem("howManyToMark")
        XCTAssertTrue(session.eventually(10) { session.pageTally() != nil }, "No This page subtitle")
        XCTAssertEqual(session.pageTally()?.new, atThree, "The sheet and the page count different new words")
        XCTAssertTrue(session.levelRow(3).isSelected)
        XCTAssertTrue(session.levelRow(3).label.hasPrefix("3,000 words. Examples: "), session.levelRow(3).label)

        session.levelRow(1).tap()
        XCTAssertTrue(session.eventually(10) { (session.pageTally()?.new ?? 0) > atThree }, "1,000 words did not mark more")
        XCTAssertTrue(session.levelRow(1).isSelected)
        XCTAssertFalse(session.levelRow(3).isSelected)
        let atOne = try XCTUnwrap(session.pageTally()?.new)
        session.levelRow(12).tap()
        XCTAssertTrue(session.eventually(10) { (session.pageTally()?.new ?? .max) < atThree }, "12,000 words did not mark fewer")
        // Tapping the row checked before takes the change back
        session.levelRow(3).tap()
        XCTAssertTrue(session.eventually(10) { session.pageTally()?.new == atThree })

        session.levelRow(1).tap()
        XCTAssertTrue(session.eventually(10) { session.pageTally()?.new == atOne })
        session.closeSettings()
        XCTAssertTrue(session.eventually(10) { session.newWordCount() == atOne }, "The page did not follow the level")

        // From Books
        session.back()
        session.openSettings()
        XCTAssertNil(session.pageTally(), "Settings from Books shows a page count")
        XCTAssertTrue(session.levelRow(1).isSelected)
        session.levelRow(5).tap()
        XCTAssertTrue(session.eventually(5) { session.levelRow(5).isSelected && !session.levelRow(1).isSelected })
        session.closeSettings()

        session.relaunch()
        session.openSettings()
        XCTAssertTrue(session.levelRow(5).isSelected, "The level was not saved")
    }
}
