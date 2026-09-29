import CoreGraphics
import Foundation

/// A book as the shelf shows it: its page count, how far into it the reader is, and the page whose thumbnail stands for it.
public struct BookSummary: Sendable, Hashable {
    public var book: Book
    /// Pages saved so far; grows while an import runs.
    public var pageCount: Int
    /// Pages with an index below `book.lastPageIndex`: the Reader opens on the next one.
    public var pagesBefore: Int
    /// The page with the lowest index; nil for a book with no pages.
    public var firstPage: Page?

    /// The page the book opens at, numbered as the Reader numbers it ("Page n of pageCount"): the first at or after the saved
    /// position, else the last; 0 for a book with no pages.
    public var openingPageNumber: Int { min(pagesBefore + 1, pageCount) }

    /// How far into the book it opens: 0 on page 1, 1 on the last page; 0 for a book of one page or none.
    public var progress: Double { pageCount > 1 ? Double(openingPageNumber - 1) / Double(pageCount - 1) : 0 }
}

// Reads for the app's screens. Nothing here writes, so nothing here publishes to `changes`.
extension BookStore {
    /// Every book with its page counts, saved positions and first page, newest first: one grouped query plus one for the first
    /// pages, about a millisecond at 600 pages, so the app simply reads them all again after any book or page change.
    public func bookSummaries() throws(StoreError) -> [BookSummary] {
        var firstPages: [UUID: Page] = [:]
        // (bookID, index) is unique, so this is one page per book
        for row in try database.query("""
            SELECT page.* FROM page
            JOIN (SELECT bookID, MIN("index") AS first FROM page GROUP BY bookID) AS earliest
                ON page.bookID = earliest.bookID AND page."index" = earliest.first
            """) {
            let page = Self.page(row)
            firstPages[page.bookID] = page
        }
        return try database.query("""
            SELECT book.*, COUNT(page.id) AS pageCount,
                COUNT(page.id) FILTER (WHERE page."index" < book.lastPageIndex) AS pagesBefore
            FROM book LEFT JOIN page ON page.bookID = book.id
            GROUP BY book.id
            ORDER BY book.createdAt DESC
            """).map { row in
            let book = Self.book(row)
            return BookSummary(book: book, pageCount: row["pageCount"].int ?? 0, pagesBefore: row["pagesBefore"].int ?? 0,
                               firstPage: firstPages[book.id])
        }
    }

    /// The page image, decoded on the page-image queue; nil if the file is missing or damaged. Nonisolated, so loading a page never
    /// waits behind database work on the store such as an iCloud merge.
    public nonisolated func loadImage(of page: Page) async -> CGImage? {
        let url = imageURL(of: page)
        return await PageImageFile.run { PageImageFile.load(url) }
    }

    /// The page image decoded with its long edge at most `maxPixelSize` (never enlarged), the same way as `loadImage(of:)`: a book's
    /// cover, which is its first page, and the Reader's pages at the screen's size, without the full-size bitmap.
    public nonisolated func loadImage(of page: Page, maxPixelSize: Int) async -> CGImage? {
        let url = imageURL(of: page)
        return await PageImageFile.run { PageImageFile.downsample(url, maxPixelSize: maxPixelSize) }
    }

    /// The page's thumbnail, loaded the same way as `loadImage(of:)`.
    public nonisolated func loadThumbnail(of page: Page) async -> CGImage? {
        let url = thumbnailURL(of: page)
        return await PageImageFile.run { PageImageFile.load(url) }
    }
}
