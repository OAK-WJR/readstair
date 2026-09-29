import XCTest

/// Opening a book file through `Choose from Files` (the seed file stands in for the file picker, which runs out of process). Its pages
/// are laid out on the device with their words already known, so these tests run with a recognizer that never finishes (`.stall`): a
/// page that waited for it would show Reading.
final class OpenFileTests: UITestCase {
    /// UI-FILE-001: an EPUB becomes a new book with the title the EPUB gives. The Reader opens on page 1, its cover, which marks no
    /// word, though its words still open their cards. The chapter's first page has its new words underlined at once and no status
    /// capsule, fits at rest, and a marked word opens its card. Once every page has arrived, back on its book page there is no chapter
    /// list (the EPUB has no table of contents), and Books has its one cell, titled as the EPUB is, its line at page 2, where the Reader
    /// closed: nothing but the saved position changes the book after that, so this is the check that the line follows it at once.
    @MainActor
    func testUI_FILE_001_epubOpensRead() throws {
        let session = try Session.fresh()
        session.launch(seedFile: Fixture.aliceEPUB, recognizer: .stall)
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noBooks].exists })
        session.addBookFromFiles()
        XCTAssertTrue(session.waitForReader(), "The Reader did not open on the new book")
        XCTAssertEqual(session.position()?.index, 1, "Reader: \(session.subtitle)")
        let title = session.app.navigationBars.staticTexts.matching(NSPredicate(format: "label == %@", Sample.title)).firstMatch
        XCTAssertTrue(session.eventually(10) { title.exists }, "The Reader's title is not the EPUB's")
        XCTAssertTrue(session.eventually(10) { session.newWordCount() == 0 }, "The cover: \(session.pageValue() ?? "not read")")
        // For the UX review: the cover's colour and text
        saveScreenshot("Reader-cover", size: session.contentSize ?? Config.contentSize)
        // The title's first line, `Alice’s` alone, centred with its top 30% of the way down the cover
        let cover = try XCTUnwrap(session.visiblePage()).frame
        XCTAssertTrue(session.tapWord(at: CGRect(x: cover.midX, y: cover.minY + 0.35 * cover.height, width: 0, height: 0)),
                      "The cover's title opened no card")
        session.closeCard()
        var sawStatus = session.status.exists
        XCTAssertTrue(session.eventually(30) { (session.position()?.count ?? 0) >= 2 }, "No page 2: \(session.subtitle)")
        session.nextPage()
        let marked = session.eventually(5, interval: 0.2) {
            if session.status.exists { sawStatus = true }
            return session.word("peeped") != nil
        }
        XCTAssertTrue(marked, "peeped is not underlined on page 2: \(session.pageWords().map(\.label))")

        let page = try XCTUnwrap(session.visiblePage()).frame
        XCTAssertLessThanOrEqual(page.maxY, session.window.maxY - session.bottomSafeArea, "The page does not fit at rest: \(page)")
        let peeped = try XCTUnwrap(session.word("peeped"))
        XCTAssertTrue(session.tapWord(at: peeped.frame, expecting: "peep"), "peeped did not open its card")
        session.closeCard()
        let count = try XCTUnwrap(session.waitForImportToEnd(), "The import never ended: \(session.subtitle)")
        XCTAssertGreaterThan(count, 2, "The chapter fits on one page after the cover")
        XCTAssertFalse(sawStatus || session.status.exists, "A page showed its status: \(session.statusText() ?? "gone")")

        session.backToBook()
        session.settle()
        XCTAssertFalse(session.chapterRow(0).exists, "A book with no table of contents lists chapters")
        session.back()
        let cells = { session.rows().map { [$0.label, $0.value ?? ""] } }
        XCTAssertTrue(session.eventually(20) { cells() == [[Sample.title, Strings.page(2, of: count)]] }, "Cells: \(cells())")
    }

    /// UI-FILE-002: a plain text file opens the same way, titled by its file name, with no chapter list.
    @MainActor
    func testUI_FILE_002_plainText() throws {
        let session = try Session.fresh()
        session.launch(seedFile: Fixture.plainTextBook, recognizer: .stall)
        session.addBookFromFiles()
        XCTAssertTrue(session.waitForReader(pages: 2), "Reader: \(session.subtitle)")
        session.nextPage()
        XCTAssertTrue(session.eventually(5) { session.word("peeped") != nil }, "peeped is not underlined on page 2")
        XCTAssertFalse(session.status.exists, "The page shows its status: \(session.statusText() ?? "gone")")
        session.backToBook()
        session.settle()
        XCTAssertFalse(session.chapterRow(0).exists, "A plain text file lists chapters")
        session.back()
        XCTAssertTrue(session.eventually(20) { session.rows().map(\.label) == ["rabbit-hole"] }, "Cells: \(session.rows().map(\.label))")
    }

    /// UI-FILE-002: a file that cannot be opened leaves no book behind, and the alert says what can be opened.
    @MainActor
    func testUI_FILE_002_unopenableFile() throws {
        let session = try Session.fresh()
        session.launch(seedFile: Fixture.notABook)
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noBooks].exists })
        session.addBookFromFiles()
        let alert = session.app.alerts[Strings.bookUnopenable]
        XCTAssertTrue(session.eventually(30) { alert.exists })
        XCTAssertTrue(alert.staticTexts[Strings.bookUnopenableMessage].exists)
        // For the UX review: the alert's copy
        saveScreenshot("Alert-bookUnopenable", size: session.contentSize ?? Config.contentSize)
        alert.buttons["OK"].tap()
        XCTAssertTrue(session.eventually(10) { !alert.exists })
        XCTAssertTrue(session.isShowingBooks)
        XCTAssertNil(session.position(), "A Reader opened for a book that could not be opened")
        XCTAssertTrue(session.rows().isEmpty)
        XCTAssertTrue(session.app.staticTexts[Strings.noBooks].exists)
    }

    /// UI-FILE-003: an e-book import carries on across the background. The whole of Alice (`Fixture.wholeAlice`), about 100 s of
    /// import, is still being imported when Home is pressed. 35 s later, past the point where the app cancels photo and scan imports
    /// (about 20 s) and the end of its background time (about 30 s), the app comes back, and in the end the book has every page,
    /// `Fixture.wholeAlicePages`, as an uninterrupted import of the same file does. Not tested: a kill meanwhile leaves the pages saved so far, a known limit.
    @MainActor
    func testUI_FILE_003_importCarriesOnInBackground() throws {
        let session = try Session.fresh()
        session.launch(seedFile: Fixture.wholeAlice, recognizer: .stall)
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noBooks].exists })
        session.addBookFromFiles()
        XCTAssertTrue(session.waitForReader(), "The Reader did not open on the new book")
        let before = try XCTUnwrap(session.position(), "Reader: \(session.subtitle)").count
        guard before < Fixture.wholeAlicePages else { throw XCTSkip("Every page was saved before Home: \(session.subtitle)") }

        XCUIDevice.shared.press(.home)
        // The home screen is up, its ReadStair icon tappable: the app's own state can read as foreground for a while after Home on
        // this simulator, and SpringBoard's reads as foreground either way
        let icon = XCUIApplication(bundleIdentifier: "com.apple.springboard").icons["ReadStair"]
        XCTAssertTrue(session.eventually(20) { icon.exists && icon.isHittable }, "The home screen did not come up")
        session.settle(35)
        session.app.activate()
        // The Reader on show: the app's state can go on reading it as not in the foreground after it is back (UI-CARD-008)
        XCTAssertTrue(session.eventually(30) { session.position() != nil }, "The app did not come back")
        XCTAssertTrue(session.eventually(600, interval: 1) { session.position()?.count == Fixture.wholeAlicePages },
                      "The import stopped at \(session.subtitle); \(before) pages were saved before Home")
    }
}
