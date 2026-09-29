import XCTest

/// Delete Page, with undo.
final class DeletePageTests: UITestCase {
    /// UI-DEL-001: `Delete Page` hides the page at once and `Undo` brings it back, the toast taking the status capsule's place meanwhile.
    /// Once the toast ends the deletion is saved and the page count never flickers back. Deleting the last page leaves an empty book
    /// with no `Delete Page`, which is kept, also after a relaunch. The Reader's More never offers Rename: that is the book page's,
    /// whose menu an empty book keeps.
    @MainActor
    func testUI_DEL_001_deleteUndoAndEmptyBook() throws {
        let session = try Session.fresh()
        session.launch(seeds: [Fixture.alice, Fixture.alice], recognizer: .fail)
        session.addBookFromPhotos()
        XCTAssertTrue(session.waitForReader(pages: 2))
        XCTAssertTrue(session.eventually(60) { session.statusText() == Strings.failed })

        session.tapMore()
        let delete = session.menuItem("deletePage")
        XCTAssertTrue(session.eventually(10) { delete.exists }, "No Delete Page menu item with its identifier")
        XCTAssertEqual(delete.label, "Delete Page")
        delete.tap()
        XCTAssertTrue(session.eventually(20) { session.showsPage(1, of: 1) }, "After Delete Page: \(session.subtitle)")
        XCTAssertTrue(session.eventually(10) { session.toastText() == Strings.pageDeleted })
        XCTAssertFalse(session.status.exists, "The status capsule shows with the toast")
        session.undo.tap()
        XCTAssertTrue(session.eventually(20) { session.showsPage(1, of: 2) }, "After Undo: \(session.subtitle)")
        XCTAssertFalse(session.toast.exists)
        XCTAssertTrue(session.eventually(10) { session.statusText() == Strings.failed }, "The status capsule did not come back")

        // Saved when the toast ends: the count stays at one page before, during and after the save
        session.deleteCurrentPage()
        XCTAssertTrue(session.eventually(20) { session.showsPage(1, of: 1) })
        var seen: Set<String> = []
        let saved = session.eventually(30, interval: 0) {
            let subtitle = session.subtitle
            if !subtitle.isEmpty { seen.insert(subtitle) }
            return !session.toast.exists
        }
        XCTAssertTrue(saved, "The toast did not end")
        let after = Date.now.addingTimeInterval(3)
        while Date.now < after {
            let subtitle = session.subtitle
            if !subtitle.isEmpty { seen.insert(subtitle) }
        }
        XCTAssertEqual(seen, [Strings.page(1, of: 1)], "The page count changed while the deletion was saved")

        // The last page: an empty book
        session.deleteCurrentPage()
        XCTAssertTrue(session.eventually(20) { session.app.staticTexts[Strings.noPages].exists })
        XCTAssertTrue(session.app.staticTexts[Strings.noPagesMessage].exists)
        XCTAssertEqual(session.subtitle, "", "A book with no pages shows no page count")
        XCTAssertTrue(session.waitForToastToEnd())
        session.tapMore()
        XCTAssertTrue(session.eventually(10) { session.menuItem("howManyToMark").exists }, "No How Many to Mark\u{2026} in the menu")
        XCTAssertFalse(session.menuItem("deletePage").exists, "Delete Page offered in a book with no pages")
        XCTAssertFalse(session.menuItem("rename").exists, "Rename is in the Reader's menu")
        session.dismissMenu()

        session.backToBook()
        session.tapMore()
        XCTAssertTrue(session.eventually(10) { session.menuItem("rename").exists }, "No Rename on the empty book's page")
        XCTAssertTrue(session.menuItem("deleteBook").exists, "No Delete Book on the empty book's page")
        session.dismissMenu()
        session.back()
        let listed = { session.rows().count == 1 }
        XCTAssertTrue(session.eventually(20, listed), "Cells: \(session.rows().map(\.label))")
        session.relaunch(recognizer: .fail)
        XCTAssertTrue(session.eventually(30, listed), "The emptied book was not kept")
        session.openBook()
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noPages].exists })
    }
}
