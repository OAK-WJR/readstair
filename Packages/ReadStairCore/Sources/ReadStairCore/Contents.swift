import Foundation

/// Where a titled entry of an electronic book's own table of contents starts: the index of its first page, in `Page.index`'s space,
/// and its label.
public struct ChapterStart: Sendable, Hashable {
    public let pageIndex: Int
    public let title: String

    public init(pageIndex: Int, title: String) {
        self.pageIndex = pageIndex
        self.title = title
    }

    /// A book's contents: each chapter with the first of `pages` from its start up to the next chapter's start (none for the last);
    /// a chapter with no page there is left out, and so are pages before the first chapter. Both lists may come in any order; the
    /// entries come in page order. Pages added after the last chapter's start fall into it.
    public static func contents(_ chapters: [ChapterStart], pages: [Page]) -> [ContentsEntry] {
        let chapters = chapters.sorted { $0.pageIndex < $1.pageIndex }
        let pages = pages.sorted { $0.index < $1.index }
        var entries: [ContentsEntry] = []
        var next = 0
        for (i, chapter) in chapters.enumerated() {
            let end = i + 1 < chapters.count ? chapters[i + 1].pageIndex : Int.max
            while next < pages.count, pages[next].index < chapter.pageIndex { next += 1 }
            if next < pages.count, pages[next].index < end { entries.append(ContentsEntry(title: chapter.title, page: pages[next])) }
        }
        return entries
    }
}

/// A row of a book's contents: a chapter's title and the page it opens at. Chapters' page ranges never overlap, so the page's id is
/// unique among the rows.
public struct ContentsEntry: Sendable, Hashable, Identifiable {
    public let title: String
    public let page: Page
    public var id: UUID { page.id }

    public init(title: String, page: Page) {
        self.title = title
        self.page = page
    }
}
