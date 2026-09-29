import XCTest

/// Importing through `Choose from Photos` (the seed photos stand in for the picker) and the Reader's `Add Pages`.
final class ImportTests: UITestCase {
    /// UI-IMPORT-001: three photos make a new book, and the Reader opens on its first page as soon as that page is saved. Back on
    /// Books, it has its cell, and reopened it has its three pages. Pages added from the Reader land on the first new page.
    @MainActor
    func testUI_IMPORT_001_newBookThenAddPages() throws {
        let session = try Session.fresh()
        session.launch(seeds: [Fixture.alice, Fixture.aliceTilted, Fixture.alice])
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noBooks].exists })
        session.addBookFromPhotos()
        XCTAssertTrue(session.eventually(90) { session.position()?.index == 1 }, "The Reader did not open on the new book")
        XCTAssertTrue(session.eventually(90) { session.showsPage(1, of: 3) }, "Reader: \(session.subtitle)")

        session.back()
        XCTAssertTrue(session.eventually(20) { session.rows().count == 1 })

        session.openBook()
        XCTAssertTrue(session.eventually(30) { session.showsPage(1, of: 3) })
        let addPages = session.app.buttons["addPages"]
        XCTAssertEqual(addPages.label, "Add Pages")
        // No document camera on the simulator: Add Pages goes to Photos, here the seed photos
        addPages.tap()
        XCTAssertTrue(session.eventually(120) { session.showsPage(4, of: 6) }, "After adding pages: \(session.subtitle)")
    }

    /// UI-IMPORT-001: photos with no readable page leave no book behind, and the alert says why.
    @MainActor
    func testUI_IMPORT_001_unreadablePhotos() throws {
        let session = try Session.fresh()
        session.launch(seeds: [Fixture.notAnImage])
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noBooks].exists })
        session.addBookFromPhotos()
        let alert = session.app.alerts[Strings.photosUnreadable]
        XCTAssertTrue(session.eventually(30) { alert.exists })
        XCTAssertTrue(alert.staticTexts[Strings.photosUnreadableMessage].exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(session.eventually(10) { !alert.exists })
        XCTAssertTrue(session.isShowingBooks)
        XCTAssertNil(session.position(), "A Reader opened for a book with no pages")
        XCTAssertTrue(session.rows().isEmpty)
        XCTAssertTrue(session.app.staticTexts[Strings.noBooks].exists)
    }
}
