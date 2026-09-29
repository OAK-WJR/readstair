import XCTest

/// The book page, between Books and the Reader: its cover, `Read`, the chapters of an e-book whose table of contents has two or more,
/// and its More menu with Rename and Delete Book. Every push is guarded, so a double tap opens one screen.
final class BookPageTests: UITestCase {
    /// UI-BOOK-001: an e-book from its import to its chapters and back (chapters.epub, laid out on the device, so the recognizer
    /// never has to finish). The import leaves the Reader on page 1 of N, the cover, over the book page: one Back reaches the book
    /// page, the next Books. The book page lists the three entries of the book's table of contents, and no row for its cover or title
    /// page. I opens page 3, Two page N−1 and the last entry page N, and Back from each returns to the book page. A double tap on a
    /// cell, on Read or on a row pushes one screen. Read opens where the book was left, also after a relaunch, and Go to Page from the
    /// Word List still returns to the list.
    @MainActor
    func testUI_BOOK_001_chaptersAndBack() throws {
        let session = try Session.fresh()
        session.launch(seedFile: Fixture.chaptersEPUB, recognizer: .stall)
        session.addBookFromFiles()
        XCTAssertTrue(session.waitForReader(), "The Reader did not open on the new book")
        XCTAssertEqual(session.position()?.index, 1, "Reader: \(session.subtitle)")
        let pages = try XCTUnwrap(session.waitForImportToEnd(), "The import never ended: \(session.subtitle)")
        XCTAssertEqual(session.position(), Position(index: 1, count: pages))
        session.backToBook()
        session.tapBack()
        XCTAssertTrue(session.eventually(20) { session.isShowingBooks }, "The second Back did not reach Books")
        session.openBookPage()

        XCTAssertEqual(session.chapterTitles(), Fixture.chaptersLabels)

        // Each entry's page; peeped, on chapter I's first page, goes on the Word List
        for (row, page) in [(0, 3), (1, pages - 1), (2, pages)] {
            session.openChapter(row)
            XCTAssertEqual(session.position(), Position(index: page, count: pages), "Chapter row \(row)")
            if row == 0 {
                XCTAssertTrue(session.eventually(10) { session.word("peeped") != nil }, "peeped is not underlined on page 3")
                let peeped = try XCTUnwrap(session.word("peeped"))
                XCTAssertTrue(session.tapWord(at: peeped.frame, expecting: "peep"))
                session.closeCard()
            }
            session.backToBook()
        }

        // A double tap pushes one screen: one Back undoes it. Read opens where Back was pressed, the last page.
        let read = session.app.buttons["read"]
        read.doubleTap()
        XCTAssertTrue(session.eventually(30) { session.showsPage(pages, of: pages) }, "Read opened \(session.subtitle)")
        session.backToBook()
        let second = session.chapterRow(1)
        XCTAssertTrue(session.scrollIntoView(second))
        second.doubleTap()
        XCTAssertTrue(session.eventually(30) { session.showsPage(pages - 1, of: pages) }, "Row Two opened \(session.subtitle)")
        session.backToBook()
        session.tapBack()
        XCTAssertTrue(session.eventually(20) { session.isShowingBooks }, "Back from the book page did not reach Books")
        XCTAssertTrue(session.eventually(20) { session.rows().count == 1 }, "No book cell")
        let cell = try XCTUnwrap(session.rows().first)
        session.doubleTap(CGPoint(x: cell.frame.midX, y: cell.frame.midY))
        XCTAssertTrue(session.eventually(30) { session.isShowingBook }, "The double tap did not open the book page")
        session.tapBack()
        XCTAssertTrue(session.eventually(20) { session.isShowingBooks }, "One Back after a double tap did not reach Books")

        session.relaunch(recognizer: .stall)
        session.openBook()
        XCTAssertTrue(session.eventually(30) { session.showsPage(pages - 1, of: pages) },
                      "After a relaunch Read opened \(session.subtitle)")

        session.back()
        session.openWordList()
        session.openListedWord("peep")
        let goToPage = session.app.buttons["goToPage"]
        XCTAssertTrue(session.eventually(10) { goToPage.exists }, "No Go to Page")
        goToPage.tap()
        XCTAssertTrue(session.eventually(30) { session.showsPage(3, of: pages) }, "Go to Page opened \(session.subtitle)")
        session.backToWordList()
    }

    /// UI-BOOK-002: the book page's More menu. Rename: the alert opens on the title, Save needs one, and the new title shows on the page
    /// and in its cell on Books. Delete Book goes back to Books, where the book is gone at once and `Book deleted` offers Undo, which
    /// brings it back. Left alone, the deletion is saved when the toast ends and holds after a relaunch.
    @MainActor
    func testUI_BOOK_002_renameAndDelete() throws {
        let session = try Session.fresh()
        session.launch(seedFile: Fixture.plainTextBook, recognizer: .stall)
        session.addBookFromFiles()
        XCTAssertTrue(session.waitForReader(pages: 2), "Reader: \(session.subtitle)")
        session.backToBook()

        XCTAssertEqual(session.renameBook(to: "Rabbit Test"), "rabbit-hole")
        XCTAssertTrue(session.eventually(10) { session.app.navigationBars.staticTexts["Rabbit Test"].exists }, "The page's title stayed")
        session.back()
        let cell = "Rabbit Test"
        XCTAssertTrue(session.eventually(20) { session.rows().map(\.label) == [cell] }, "Cells: \(session.rows().map(\.label))")

        session.openBookPage()
        session.tapMore()
        let delete = session.menuItem("deleteBook")
        XCTAssertTrue(session.eventually(10) { delete.exists }, "No Delete Book menu item with its identifier")
        XCTAssertEqual(delete.label, Strings.deleteBook)
        delete.tap()
        XCTAssertTrue(session.eventually(20) { session.isShowingBooks }, "Delete Book did not go back to Books")
        XCTAssertTrue(session.eventually(10) { session.rows().isEmpty }, "The cell stayed")
        XCTAssertTrue(session.eventually(10) { session.toastText() == Strings.bookDeleted })
        session.tapTargetEdge(session.undo)
        XCTAssertTrue(session.eventually(10) { session.rows().map(\.label) == [cell] }, "Undo did not bring the book back")
        XCTAssertFalse(session.toast.exists)

        session.deleteBook()
        XCTAssertTrue(session.eventually(10) { session.rows().isEmpty })
        XCTAssertTrue(session.waitForToastToEnd())
        session.relaunch(recognizer: .stall)
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noBooks].exists }, "The deleted book came back")
        XCTAssertTrue(session.rows().isEmpty)
    }

    /// UI-BOOK-003: a book without two chapters shows its cover and Read only: a photographed book, a plain text file and an EPUB with
    /// no table of contents. A book emptied of its pages keeps its page, and Read shows `No Pages`. Whether VoiceOver skips the covers
    /// is not checked here: XCUITest lists a SwiftUI image hidden from accessibility all the same. The audits (UI-A11Y-001, 007) and
    /// UI-GRID-001's exact labels cover it on the simulator, and a VoiceOver check by hand on a device.
    @MainActor
    func testUI_BOOK_003_booksWithoutChapters() throws {
        let session = try Session.fresh()
        session.launch(seeds: [Fixture.alice], seedFile: Fixture.plainTextBook, recognizer: .fail)
        session.addBookFromPhotos()
        XCTAssertTrue(session.waitForReader(pages: 1))
        session.back()
        session.addBookFromFiles()
        XCTAssertTrue(session.waitForReader(pages: 2), "Reader: \(session.subtitle)")
        session.back()
        session.relaunch(seedFile: Fixture.aliceEPUB, recognizer: .fail)
        session.addBookFromFiles()
        XCTAssertTrue(session.waitForReader(), "The EPUB did not open")
        XCTAssertNotNil(session.waitForImportToEnd(), "The import never ended: \(session.subtitle)")
        session.back()
        XCTAssertTrue(session.eventually(30) { session.rows().count == 3 }, "Cells: \(session.rows().map(\.label))")

        // Newest first: the EPUB, the text file, the photographed book
        for (index, book) in ["the EPUB", "the text file", "the photographed book"].enumerated() {
            session.openBookPage(at: index)
            XCTAssertEqual(session.app.buttons["read"].label, Strings.read)
            // The chapters load after the page shows
            session.settle()
            XCTAssertFalse(session.chapterRow(0).exists, "\(book) lists chapters")
            session.back()
        }

        session.openBook(at: 2)
        session.deleteCurrentPage()
        XCTAssertTrue(session.eventually(20) { session.app.staticTexts[Strings.noPages].exists }, "The book did not empty")
        XCTAssertTrue(session.waitForToastToEnd())
        session.backToBook()
        session.app.buttons["read"].tap()
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noPages].exists }, "Read did not show No Pages")
    }
}
