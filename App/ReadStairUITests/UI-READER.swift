import XCTest

/// The Reader: page states, paging and zoom, reading position, and its menu.
final class ReaderTests: UITestCase {
    /// UI-READER-001: a page that failed to read says so and offers Try Again, and its words do nothing when tapped. The first launch
    /// fails every page; a failed page stays failed across launches, and after a relaunch that reads for real, Try Again reads it.
    @MainActor
    func testUI_READER_001_failedThenTryAgain() throws {
        let session = try Session.fresh()
        session.launch(seeds: [Fixture.alice], recognizer: .fail)
        session.addBookFromPhotos()
        XCTAssertTrue(session.waitForReader(pages: 1))
        XCTAssertTrue(session.eventually(60) { session.statusText() == Strings.failed }, "Status: \(session.statusText() ?? "none")")
        XCTAssertEqual(session.pageValue(), Strings.failed)
        XCTAssertEqual(session.subtitle, Strings.page(1, of: 1))
        XCTAssertEqual(session.app.buttons["tryAgain"].label, Strings.tryAgain)
        let page = try XCTUnwrap(session.visiblePage()).frame
        let peeped = try XCTUnwrap(Fixture.aliceTruth.word("peeped"))
        session.tap(Self.center(Fixture.aliceTruth.rect(of: peeped, on: page)))
        session.settle(3)
        XCTAssertFalse(session.headword.exists, "A word on a failed page opened a card")

        session.relaunch()
        session.openBook()
        XCTAssertTrue(session.eventually(30) { session.statusText() == Strings.failed })
        session.settle()
        session.tapTargetEdge(session.app.buttons["tryAgain"])
        XCTAssertTrue(session.eventually(30) { session.statusText() == Strings.reading }, "Status: \(session.statusText() ?? "none")")
        XCTAssertFalse(session.app.buttons["tryAgain"].exists)
        XCTAssertTrue(session.waitForRecognized(), "Page value: \(session.pageValue() ?? "none")")
        XCTAssertFalse(session.status.exists)
        XCTAssertGreaterThan(session.newWordCount() ?? 0, 0)
    }

    /// UI-READER-001: a page with no text says so in the status capsule; a page where nothing is marked says so in the subtitle and
    /// has no capsule over its words.
    @MainActor
    func testUI_READER_001_noTextAndNoMarks() throws {
        let session = try Session.fresh()
        session.launch(seeds: [Fixture.blankPage, Fixture.commonWordsPage])
        session.addBookFromPhotos()
        XCTAssertTrue(session.waitForReader(pages: 2))
        XCTAssertTrue(session.eventually(300) { session.statusText() == Strings.noText }, "Status: \(session.statusText() ?? "none")")
        XCTAssertEqual(session.pageValue(), Strings.noText)
        XCTAssertFalse(session.app.buttons["tryAgain"].exists)
        XCTAssertEqual(session.subtitle, Strings.page(1, of: 2))

        session.nextPage()
        XCTAssertTrue(session.eventually(300) { session.subtitle == Strings.pageWithoutMarks(2, of: 2) }, "Subtitle: \(session.subtitle)")
        XCTAssertEqual(session.pageValue(), Strings.noNewWords)
        XCTAssertFalse(session.status.exists)
    }

    /// UI-READER-001: no state leaves page text stuck under the status capsule: text it covers can be scrolled clear. Checked while the
    /// page is Failed and while it is Reading (the only states with a capsule over text; No text has none).
    @MainActor
    func testUI_READER_001_statusNeverTrapsText() throws {
        let failed = try Session.fresh()
        failed.launch(seeds: [Fixture.alice], recognizer: .fail)
        failed.addBookFromPhotos()
        XCTAssertTrue(failed.waitForReader(pages: 1))
        XCTAssertTrue(failed.eventually(60) { failed.statusText() == Strings.failed })
        failed.assertTextClearsStatus(Fixture.aliceTruth, state: "Failed")

        let reading = try Session.fresh()
        reading.launch(seeds: [Fixture.alice], recognizer: .stall)
        reading.addBookFromPhotos()
        XCTAssertTrue(reading.waitForReader(pages: 1))
        XCTAssertTrue(reading.eventually(20) { reading.statusText() == Strings.reading })
        reading.assertTextClearsStatus(Fixture.aliceTruth, state: "Reading")
    }

    /// UI-READER-002: zoomed in, swipes and pans move the page and never turn it; back at fit width a swipe turns it, and a page left
    /// behind is at fit width when it comes back. Zooming and paging change no underline.
    @MainActor
    func testUI_READER_002_zoomHoldsThePage() throws {
        let session = try Template.bookWithRecognizedPages()
        session.launch()
        session.openBook()
        XCTAssertTrue(session.eventually(30) { session.showsPage(1, of: 2) })
        XCTAssertTrue(session.waitForRecognized())
        let count = try XCTUnwrap(session.newWordCount())
        let marked = session.pageWords().count
        XCTAssertGreaterThan(marked, 0)

        session.zoomIn(2.2)
        XCTAssertGreaterThan(session.zoom() ?? 0, 1.5)
        XCTAssertEqual(session.newWordCount(), count)
        XCTAssertEqual(session.pageWords().count, marked)
        for gesture in 0..<6 {
            if gesture % 2 == 0 {
                let towardRight = gesture % 4 == 0
                session.drag(from: CGVector(dx: towardRight ? 0.15 : 0.85, dy: 0.5), to: CGVector(dx: towardRight ? 0.95 : 0.05, dy: 0.5),
                             fling: true)
            } else {
                session.app.windows.firstMatch.swipeLeft(velocity: .fast)
                session.settle()
            }
            XCTAssertTrue(session.showsPage(1, of: 2), "Zoomed in, gesture \(gesture + 1) turned the page to \(session.subtitle)")
        }

        XCTAssertTrue(session.zoomToFit(), "Could not pinch back to fit width: \(session.zoom() ?? 0)")
        session.nextPage()
        session.previousPage()
        XCTAssertEqual(try XCTUnwrap(session.zoom()), 1, accuracy: 0.01)
        XCTAssertEqual(session.newWordCount(), count)
        XCTAssertEqual(session.pageWords().count, marked)
    }

    /// UI-READER-003: the Reader opens where it was left, straight away after closing it and after a relaunch, also once a page before
    /// that place is deleted. Its More has no Rename: a book is renamed on its book page, and Save needs a title.
    @MainActor
    func testUI_READER_003_positionRenameAndRelaunch() throws {
        let session = try Session.fresh()
        session.launch(seeds: [Fixture.alice, Fixture.alice, Fixture.alice], recognizer: .fail)
        session.addBookFromPhotos()
        XCTAssertTrue(session.waitForReader(pages: 3))
        session.nextPage()
        XCTAssertTrue(session.showsPage(2, of: 3))

        // Reopened at once, without waiting for the shelf to read the saved position back: the Reader opens where it was from memory
        session.back()
        let row = try XCTUnwrap(session.rows().first).label
        session.openBook()
        XCTAssertTrue(session.eventually(30) { session.showsPage(2, of: 3) }, "Reopened at \(session.subtitle)")
        session.tapMore()
        XCTAssertTrue(session.eventually(10) { session.menuItem("howManyToMark").exists }, "The Reader's More did not open")
        XCTAssertFalse(session.menuItem("rename").exists, "Rename is in the Reader's menu")
        session.dismissMenu()

        // Rename on the book page: the alert holds the current title, and the page's title follows
        session.backToBook()
        let title = session.renameBook(to: "Alice Test")
        XCTAssertEqual(row, title, "The alert shows \(title) for the book \(row)")
        XCTAssertTrue(session.eventually(10) { session.app.navigationBars.staticTexts["Alice Test"].exists }, "The page's title stayed")

        // Deleting page 2 brings page 3 up as page 2 of 2
        session.app.buttons["read"].tap()
        XCTAssertTrue(session.eventually(30) { session.showsPage(2, of: 3) }, "Read opened \(session.subtitle)")
        session.deleteCurrentPage()
        XCTAssertTrue(session.eventually(20) { session.showsPage(2, of: 2) }, "After Delete Page: \(session.subtitle)")
        XCTAssertTrue(session.waitForToastToEnd())

        // Books' line: the last page, a full line, kept across the delete and a relaunch
        let cell = { session.rows().first.map { [$0.label, $0.value ?? ""] } ?? [] }, atEnd = ["Alice Test", Strings.page(2, of: 2)]
        session.back()
        XCTAssertTrue(session.eventually(20) { cell() == atEnd }, "Cell: \(cell())")
        session.relaunch(recognizer: .fail)
        XCTAssertTrue(session.eventually(30) { cell() == atEnd }, "Cell after a relaunch: \(cell())")
        session.openBook()
        XCTAssertTrue(session.eventually(30) { session.showsPage(2, of: 2) }, "After a relaunch the book opened at \(session.subtitle)")
    }

    private static func center(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}
