import XCTest

/// Books: the empty shelf, the Add Book menu, a book deleted during its import, and the sample book a new store gets. Deleting a book
/// with undo is UI-BOOK-002's, on the book page.
final class ShelfTests: UITestCase {
    /// UI-SHELF-001: the empty shelf explains itself and offers no button of its own; `+` is the way in. On the simulator, which has
    /// no document camera, its menu has `Choose from Photos`, `Choose from Files` and `Find Free Books`, which opens Safari.
    @MainActor
    func testUI_SHELF_001_emptyShelfAndAddMenu() throws {
        let session = try Session.fresh()
        session.launch()
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noBooks].exists })
        XCTAssertTrue(session.app.staticTexts[Strings.noBooksMessage].exists)
        let bar = session.app.navigationBars["Books"].frame
        let contentButtons = session.app.buttons.allElementsBoundByIndex.filter { $0.frame.minY >= bar.maxY }
        XCTAssertTrue(contentButtons.isEmpty, "The empty shelf shows buttons: \(contentButtons.map { $0.label })")
        // The gear and Word List are there with no book too: the gear is the one way to Settings before the first book, and Word List
        // is there even with no words
        XCTAssertEqual(session.app.buttons["settings"].label, "Settings")
        XCTAssertEqual(session.app.buttons["wordList"].label, Strings.wordList)

        let add = session.app.buttons["addBook"]
        XCTAssertEqual(add.label, "Add Book")
        add.tap()
        let choose = session.menuItem("choosePhotos")
        XCTAssertTrue(session.eventually(10) { choose.exists }, "No Choose from Photos item with its identifier")
        XCTAssertEqual(choose.label, "Choose from Photos")
        XCTAssertEqual(session.menuItem("chooseFile").label, "Choose from Files")
        #if targetEnvironment(simulator)
        XCTAssertFalse(session.menuItem("scanPages").exists)
        XCTAssertFalse(session.app.buttons["Scan Pages"].exists)
        #endif
        XCTAssertEqual(session.menuItem("findFreeBooks").label, "Find Free Books")
        // For the UX review: the system draws the menu, so no audit looks at it
        saveScreenshot("Books-addMenu", size: session.contentSize ?? Config.contentSize)
        session.dismissMenu()
        XCTAssertFalse(choose.exists)

        // Find Free Books opens the website in Safari; nothing else happens in ReadStair
        add.tap()
        session.tapMenuItem("findFreeBooks")
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 30), "Safari did not open")
        session.app.activate()
        XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noBooks].exists }, "Books did not come back as it was")
    }

    /// UI-SHELF-002: a book deleted while its import is still adding pages goes quietly: the import stops, and no alert appears. 100
    /// pages, so the import still runs after the taps back to Books and on to the book page's menu.
    @MainActor
    func testUI_SHELF_002_deleteDuringImport() throws {
        let session = try Session.fresh()
        let root = try XCTUnwrap(session.root)
        session.launch(seeds: Array(repeating: Fixture.alice, count: 100), recognizer: .fail)
        session.addBookFromPhotos()
        XCTAssertTrue(session.waitForReader())
        session.back()
        XCTAssertTrue(session.eventually(20) { session.rows().count == 1 })
        guard Self.savedPageCount(in: root) != 100 else {
            throw XCTSkip("All 100 pages were saved before the book could be deleted")
        }

        session.deleteBook()
        XCTAssertTrue(session.eventually(10) { session.toastText() == Strings.bookDeleted })
        XCTAssertTrue(session.waitForToastToEnd())
        // The import's next page finds the book gone and stops there
        session.settle(10)
        XCTAssertEqual(session.app.alerts.count, 0, "An alert appeared: \(session.app.alerts.firstMatch.label)")
        XCTAssertTrue(session.rows().isEmpty)
        XCTAssertTrue(session.app.staticTexts[Strings.noBooks].exists)
    }

    /// UI-SHELF-003: a new store gets the sample book, chapter I of Alice's Adventures in Wonderland, laid out behind the level test.
    /// Killed partway, the app shows the test again at the next launch and resumes the book where it stopped: after Skip, Books lists
    /// one book, never `No Books Yet` first, and does not open it, and in the end every page is saved once, `Sample.pageCount` in all,
    /// and `SampleBook.importing`, there since the import began, is gone. Its book page lists no chapters: it has one. Read opens the
    /// cover, page 1, and page 2 has `peeped` underlined. Deleted, it never comes back. The import takes seconds, so the kill comes as
    /// soon as the first page is saved, and the test skips if the whole chapter was saved by then. Prints `[PERF] sample-import
    /// seconds= bytes=`: from the first launch to the last page, the kill included, and all the store then holds.
    @MainActor
    func testUI_SHELF_003_sampleBook() throws {
        let session = try Session.fresh()
        session.sampleBook = true
        let root = try XCTUnwrap(session.root)
        let marker = root.appending(path: "SampleBook.importing").path(percentEncoded: false)
        let started = Date.now
        session.launch(stopsAtLevelTest: true)
        XCTAssertTrue(session.eventually(60, interval: 0.1) { (Self.savedPageCount(in: root) ?? 0) >= 1 }, "No sample page was saved")
        let beforeKill = Self.savedPageCount(in: root) ?? 0
        guard beforeKill < Sample.pageCount, FileManager.default.fileExists(atPath: marker) else {
            throw XCTSkip("The whole sample was saved before the kill (\(beforeKill) pages)")
        }

        // The kill, during the level test and the import: the relaunch shows the test again (`launch` skips it)
        session.relaunch()
        var sawEmpty = false
        let listed = session.eventually(30, interval: 0) {
            if session.app.staticTexts[Strings.noBooks].exists { sawEmpty = true }
            let shelf = session.rows()
            return shelf.count == 1 && shelf[0].label == Sample.title
        }
        XCTAssertTrue(listed, "Not one sample book: \(session.rows().map(\.label))")
        XCTAssertFalse(sawEmpty, "Books showed its empty state before the sample book")
        XCTAssertTrue(session.isShowingBooks, "The book opened by itself")

        let (pages, finished) = try XCTUnwrap(Self.waitForSample(session, root: root),
                                              "The sample import never ended: \(session.rows().map(\.label))")
        print("[PERF] sample-import seconds=\(String(format: "%.1f", finished.timeIntervalSince(started))) bytes=\(Self.bytes(in: root))")
        // Exact: a page laid out twice or skipped where the import resumed is one too many or too few
        XCTAssertEqual(pages, Sample.pageCount, "The sample's pages (\(beforeKill) before the kill)")
        XCTAssertTrue(session.eventually(10) { !FileManager.default.fileExists(atPath: marker) }, "SampleBook.importing stayed")
        XCTAssertEqual(session.rows().map(\.label), [Sample.title])

        session.openBookPage()
        saveScreenshot("Book-sample", size: session.contentSize ?? Config.contentSize)
        XCTAssertEqual(session.chapterTitles(), [], "A one-chapter book lists chapters")
        session.app.buttons["read"].tap()
        XCTAssertTrue(session.eventually(30) { session.showsPage(1, of: pages) }, "Read opened \(session.subtitle)")
        session.nextPage()
        XCTAssertTrue(session.eventually(10) { session.word("peeped") != nil },
                      "peeped is not underlined on page 2: \(session.pageWords().map(\.label))")

        session.back()
        session.deleteBook()
        XCTAssertTrue(session.eventually(10) { session.rows().isEmpty }, "The cell stayed")
        XCTAssertTrue(session.waitForToastToEnd())
        // Books is empty at first either way: a sample added again would come a moment later, so wait before looking
        session.relaunch()
        XCTAssertTrue(session.levelTestStaysAway(), "The level test came back")
        XCTAssertTrue(session.app.staticTexts[Strings.noBooks].exists, "The deleted sample book came back")
        XCTAssertTrue(session.rows().isEmpty)
    }

    /// The limit on the sample import after the relaunch: seconds for chapter I, with a wide margin for a Mac that runs a second
    /// simulator at the same time.
    private static let sampleLimit: TimeInterval = 300

    /// Waits until the sample's saved page images, N of them, hold still with N at least `Sample.pageCount`, and returns N and when
    /// it last changed; nil if that never happens. Still means for 5 s, or longer under load (`waitUntilStill`), not counting the first
    /// page after the relaunch, which waits for the whole book to be laid out again.
    @MainActor
    private static func waitForSample(_ session: Session, root: URL) -> (value: Int, at: Date)? {
        session.waitUntilStill(timeout: sampleLimit, minimum: 5, skipFirstGap: true) {
            savedPageCount(in: root)
        } accepting: { count in
            count >= Sample.pageCount
        }
    }

    /// How many page images the store's one book has, from its folder (`Books/<book>/<page>.heic`, thumbnails in `thumbs/`); nil
    /// while there is not exactly one book folder.
    private static func savedPageCount(in root: URL) -> Int? {
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let files = FileManager.default
        guard let folders = try? files.contentsOfDirectory(atPath: books.path(percentEncoded: false)), folders.count == 1,
              let names = try? files.contentsOfDirectory(atPath: books.appending(path: folders[0]).path(percentEncoded: false)) else {
            return nil
        }
        return names.filter { $0.hasSuffix(".heic") }.count
    }

    /// The size of every file in the folder and below it.
    private static func bytes(in folder: URL) -> Int {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let url = files?.nextObject() as? URL {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
