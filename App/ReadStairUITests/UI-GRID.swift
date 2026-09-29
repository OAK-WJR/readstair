import UIKit
import XCTest

/// Books as a grid of covers: two columns at the default size, and one column of rows from the largest standard text size
/// (xxxLarge) up.
final class GridTests: UITestCase {
    /// The longest title a book may have, 100 characters, whose longest word has 10 letters.
    private static let longTitle = "A Title of One Hundred Characters That Wraps Over Several Lines in a Narrow Column of the Books Grid"

    /// UI-GRID-001: four books, one of each kind of cell: a photographed book whose page stays Reading (`.stall`), chapters.epub
    /// left on page 2 (a partial line), rabbit-hole.txt renamed to the longest title and left on its last page (a full line), and a
    /// book emptied of its pages and renamed, since a photographed book's title is the minute it was added. At the default size and at
    /// AX5 the cells come newest first, left to right, then top to bottom, each labelled exactly with its title; at the default size
    /// each with `Page n of count` as its value where its line shows, the first row holds two and the four stand in two columns, at AX5
    /// in one. Scrolled into view, each cell lies within the window's width, is at least 44 pt each way, and overlaps no other cell.
    @MainActor
    func testUI_GRID_001_cells() throws {
        let session = try Session.fresh()
        session.contentSize = .large
        session.launch(seeds: [Fixture.alice], seedFile: Fixture.plainTextBook, recognizer: .stall)
        // The oldest: a photographed book, emptied of its one page
        let emptied = "Emptied"
        session.addBookFromPhotos()
        XCTAssertTrue(session.waitForReader(pages: 1))
        session.deleteCurrentPage()
        XCTAssertTrue(session.eventually(20) { session.app.staticTexts[Strings.noPages].exists }, "The book did not empty")
        XCTAssertTrue(session.waitForToastToEnd())
        session.backToBook()
        session.renameBook(to: emptied)
        session.back()
        XCTAssertTrue(session.eventually(20) { session.rows().count == 1 }, "Cells: \(session.rows().map(\.label))")
        session.addBookFromFiles()
        XCTAssertTrue(session.waitForReader(pages: 2), "Reader: \(session.subtitle)")
        session.nextPage()
        session.backToBook()
        session.renameBook(to: Self.longTitle)
        session.back()
        session.relaunch(seeds: [Fixture.alice], seedFile: Fixture.chaptersEPUB, recognizer: .stall)
        session.addBookFromFiles()
        XCTAssertTrue(session.waitForReader(), "The e-book did not open")
        let pages = try XCTUnwrap(session.waitForImportToEnd(), "The import never ended: \(session.subtitle)")
        session.nextPage()
        session.back()
        // The newest: a photographed book whose page is never read
        session.addBookFromPhotos()
        XCTAssertTrue(session.waitForReader(pages: 1))
        session.back()
        XCTAssertTrue(session.eventually(20) { session.rows().count == 4 }, "Cells: \(session.rows().map(\.label))")
        let photographed = try XCTUnwrap(session.rows().first).label
        let expected = [photographed, "Three Chapters", Self.longTitle, emptied]

        for size in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let name = Config.name(of: size)
            if size != session.contentSize {
                session.contentSize = size
                session.relaunch(recognizer: .stall)
            }
            XCTAssertTrue(session.eventually(30) { session.rows().first?.label == expected[0] },
                          "\(name): \(session.rows().map(\.label))")
            if !size.isAccessibilityCategory {
                let lines = ["", Strings.page(2, of: pages), Strings.page(2, of: 2), ""]
                XCTAssertTrue(session.eventually(30) { session.rows().map { $0.value ?? "" } == lines },
                              "\(name): \(session.rows().map { $0.value ?? "" })")
            }
            saveScreenshot(size.isAccessibilityCategory ? "Books-rows" : "Books-grid", size: size)
            if !size.isAccessibilityCategory {
                let row = session.rows().prefix(2)
                XCTAssertTrue(row.count == 2 && Set(row.map { $0.frame.minY.rounded() }).count == 1,
                              "\(name): not two cells in the first row: \(row.map(\.frame))")
            }
            let frames = checkCells(session, expected, name)
            let columns = size.isAccessibilityCategory ? 1 : 2
            XCTAssertEqual(Set(frames.map { $0.minX.rounded() }).count, columns, "\(name): not \(columns) columns: \(frames)")
        }
    }

    /// Scrolls each cell of `expected` into view in turn and checks it there: within the window's width (and its height, when it fits
    /// in the band), at least 44 pt each way, overlapping no other cell. The grid is lazy, so the order is checked on the way: every
    /// snapshot holds only expected cells, in the expected order, and each two neighbours are in one snapshot at least once. Returns
    /// each cell's frame in view.
    @MainActor
    private func checkCells(_ session: Session, _ expected: [String], _ name: String) -> [CGRect] {
        var frames: [CGRect] = []
        var neighbours: Set<Int> = []
        for label in expected {
            let element = session.app.buttons.matching(NSPredicate(format: "identifier == 'book' AND label == %@", label)).firstMatch
            XCTAssertTrue(session.scrollIntoView(element, whole: true), "\(name): \(label) never came into view")
            let shown = session.rows()
            let order = shown.map { expected.firstIndex(of: $0.label) ?? -1 }
            XCTAssertFalse(order.contains(-1), "\(name): cells other than the four: \(shown.map(\.label))")
            XCTAssertEqual(order, order.sorted(), "\(name): cells out of order: \(shown.map(\.label))")
            for (first, second) in zip(order, order.dropFirst()) where second == first + 1 { neighbours.insert(first) }

            guard let frame = shown.first(where: { $0.label == label })?.frame else {
                XCTFail("\(name): \(label) is not in the tree")
                continue
            }
            frames.append(frame)
            let (window, band) = (session.window, session.visibleBand())
            XCTAssertTrue(frame.minX >= window.minX - 0.5 && frame.maxX <= window.maxX + 0.5, "\(name): \(label) is cut off: \(frame)")
            if frame.height <= band.bottom - band.top {
                XCTAssertTrue(frame.minY >= window.minY - 0.5 && frame.maxY <= window.maxY + 0.5, "\(name): \(label) is cut off: \(frame)")
            }
            XCTAssertGreaterThanOrEqual(frame.width, 43.5, "\(name): \(label) is \(frame.width) pt wide")
            XCTAssertGreaterThanOrEqual(frame.height, 43.5, "\(name): \(label) is \(frame.height) pt tall")
            for other in shown where other.label != label {
                let overlap = frame.intersection(other.frame)
                XCTAssertTrue(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5,
                              "\(name): \(label) \(frame) overlaps \(other.label) \(other.frame)")
            }
        }
        XCTAssertEqual(neighbours, Set(0..<(expected.count - 1)), "\(name): neighbouring cells never seen together")
        return frames
    }
}
