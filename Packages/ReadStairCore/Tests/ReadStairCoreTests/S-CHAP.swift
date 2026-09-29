import Foundation
import Testing
@testable import ReadStairCore

/// S-CHAP-001…005: an electronic book's chapters in the store: saved with their pages, cut and resumed imports, deleted pages,
/// reused indices and concurrent imports. The pages are built by hand the way `TypesetBook.page(_:)` gives them.
@Suite("S-CHAP Store chapters", .timeLimit(.minutes(2)))
struct StoreChapterTests {
    @Test("S-CHAP-001 Chapters are saved with their pages: chapters(of:) gives exactly the (page index, title) pairs in index order, for that book only; saving them publishes only .pages(bookID)")
    func savedWithPages() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            let book = try await store.createBook(title: "Alice")
            let other = try await store.createBook(title: "Hare")
            let titles = [(0, "I: Down the Rabbit-Hole"), (2, "II"), (5, "XII: Alice’s Evidence")]
            try await importEBook(importer, into: book.id, pages: 0..<6, chapters: Dictionary(uniqueKeysWithValues: titles))
            try await importEBook(importer, into: other.id, pages: 0..<1, chapters: [0: "Only"])
            #expect(try await store.chapters(of: book.id) == starts(titles))
            #expect(try await store.chapters(of: other.id) == starts([(0, "Only")]))
            #expect(try await store.chapters(of: UUID()).isEmpty)
            let expected: [StoreChange] = [.books, .books] + Array(repeating: .pages(book.id), count: 6) + [.pages(other.id)]
            #expect(await published(store) == expected)
        }
    }

    @Test("S-CHAP-002 A cut import leaves only the chapters whose page was saved: cancelled while page 3 is in hand (which is still saved), or failing at page 3")
    func cutImports() async throws {
        let chapters = [0: "I", 2: "II", 3: "III", 4: "IV"]
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let gate = AsyncGate()
            let importing = Task {
                try await importEBook(Importer(store: store, recognizer: { _ in fakeText(0) }), into: book.id, pages: 0..<6,
                                      chapters: chapters, waitingAt: (3, gate))
            }
            try await waitUntil { await gate.waiting == 1 }
            importing.cancel()
            await gate.open()
            #expect(try await importing.value == 4)
            #expect(try await store.chapters(of: book.id) == starts([(0, "I"), (2, "II"), (3, "III")]))
        }
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            try await store.execute("""
                CREATE TRIGGER failPage BEFORE INSERT ON page WHEN NEW."index" = 3 BEGIN SELECT RAISE(ABORT, 'injected'); END
                """)
            await #expect(throws: StoreError.self) { try await importEBook(importer, into: book.id, pages: 0..<6, chapters: chapters) }
            #expect(try await store.pages(of: book.id).map(\.index) == [0, 1, 2])
            #expect(try await store.chapters(of: book.id) == starts([(0, "I"), (2, "II")]))
        }
    }

    @Test("S-CHAP-003 Deleting a chapter's first page moves the chapter to its next page; deleting all its pages hides it; deleting the book removes its chapters and no other book's")
    func deletions() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            let book = try await store.createBook(title: "Alice")
            let other = try await store.createBook(title: "Hare")
            try await importEBook(importer, into: book.id, pages: 0..<6, chapters: [0: "I", 2: "II", 4: "III"])
            try await importEBook(importer, into: other.id, pages: 0..<1, chapters: [0: "Only"])
            let pages = try await store.pages(of: book.id)
            #expect(try await contents(store, book.id) == ["I@0", "II@2", "III@4"])
            try await store.deletePage(pages[2].id)
            #expect(try await contents(store, book.id) == ["I@0", "II@3", "III@4"])
            try await store.deletePage(pages[3].id)
            #expect(try await contents(store, book.id) == ["I@0", "III@4"])

            try await store.deleteBook(book.id)
            #expect(try await store.chapters(of: book.id).isEmpty)
            #expect(try inspect(root, "SELECT COUNT(*) AS n FROM chapter").first?["n"].int == 1)
            #expect(try await store.chapters(of: other.id) == starts([(0, "Only")]))
        }
    }

    @Test("S-CHAP-004 Index edges: a chapter starting in a gap still resolves, also after pages are added; pages added to an e-book fall into its last chapter; once its one-page last chapter is deleted, added pages do not bring that title back; a concurrent second import keeps the first one's chapters; a photographed book has none")
    func indexEdges() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })

            // Page 4 skipped at import and page 3, II's first, deleted: II starts in the gap and opens at page 5
            let gapped = try await store.createBook(title: "Gaps")
            try await importEBook(importer, into: gapped.id, pages: 0..<8, chapters: [0: "I", 3: "II", 6: "III"], skipping: [4])
            try await store.deletePage(try #require(try await store.pages(of: gapped.id).first(where: { $0.index == 3 })).id)
            #expect(try await contents(store, gapped.id) == ["I@0", "II@5", "III@6"])
            // Add Pages keeps II's row: it sits below the next free index, though the page it names is gone
            try await importer.importPages(count: 1, into: gapped.id) { pageImage($0 + 101) }
            #expect(try await store.chapters(of: gapped.id) == starts([(0, "I"), (3, "II"), (6, "III")]))
            #expect(try await contents(store, gapped.id) == ["I@0", "II@5", "III@6"])

            // Add Pages: photographed pages go after the last page, into the last chapter, and no chapter is lost
            let added = try await store.createBook(title: "Added")
            try await importEBook(importer, into: added.id, pages: 0..<5, chapters: [0: "I", 2: "II", 4: "III"])
            try await importer.importPages(count: 2, into: added.id) { pageImage($0 + 101) }
            #expect(try await store.pages(of: added.id).map(\.index) == Array(0..<7))
            #expect(try await store.chapters(of: added.id) == starts([(0, "I"), (2, "II"), (4, "III")]))
            #expect(try await contents(store, added.id) == ["I@0", "II@2", "III@4"])

            // The last page, III's only one, deleted in the same run, then Add Pages: the new pages must not open as III
            let trimmed = try await store.createBook(title: "Trimmed")
            try await importEBook(importer, into: trimmed.id, pages: 0..<5, chapters: [0: "I", 2: "II", 4: "III"])
            try await store.deletePage(try await store.pages(of: trimmed.id)[4].id)
            #expect(try await contents(store, trimmed.id) == ["I@0", "II@2"])
            try await importer.importPages(count: 2, into: trimmed.id) { pageImage($0 + 101) }
            #expect(try await store.chapters(of: trimmed.id) == starts([(0, "I"), (2, "II")]))
            #expect(try await contents(store, trimmed.id) == ["I@0", "II@2"])

            // A second import into the same book starts while the first waits at page 3, with I and II saved
            let shared = try await store.createBook(title: "Shared")
            let gate = AsyncGate()
            let first = Task {
                try await importEBook(importer, into: shared.id, pages: 0..<6, chapters: [0: "I", 2: "II", 4: "III"],
                                      waitingAt: (3, gate))
            }
            try await waitUntil { await gate.waiting == 1 }
            #expect(try await importer.importPages(count: 2, into: shared.id) { pageImage($0 + 101) } == 2)
            await gate.open()
            #expect(try await first.value == 6)
            #expect(try await store.chapters(of: shared.id) == starts([(0, "I"), (2, "II"), (4, "III")]))
            #expect(try await store.pages(of: shared.id).map(\.index) == Array(0..<8))

            let photographed = try await makeBook(store, pages: 2, title: "Notes")
            #expect(try await store.chapters(of: photographed.id).isEmpty)
            #expect(try await contents(store, photographed.id).isEmpty)
        }
    }

    @Test("S-CHAP-005 Resume: an import cut after 5 pages, continued in a relaunched store from the page after the last saved one, ends with the same pages, texts and chapters as an import that was never cut")
    func resume() async throws {
        try await withTemporaryRoot { root in
            let (count, chapters) = (9, [0: "I", 3: "II", 5: "III", 7: "IV"])
            let store = try BookStore(root: root)
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            let whole = try await store.createBook(title: "Whole")
            try await importEBook(importer, into: whole.id, pages: 0..<count, chapters: chapters)

            // Cut while page 4 is in hand, as a kill would leave it (a kill between the image and its row leaves only a file, which
            // the relaunch reclaims)
            let cut = try await store.createBook(title: "Cut")
            let gate = AsyncGate()
            let importing = Task {
                try await importEBook(importer, into: cut.id, pages: 0..<count, chapters: chapters, waitingAt: (4, gate))
            }
            try await waitUntil { await gate.waiting == 1 }
            importing.cancel()
            await gate.open()
            #expect(try await importing.value == 5)

            // As the sample import resumes: a fresh store holds no reservations
            let relaunched = try BookStore(root: root)
            let next = (try await relaunched.pages(of: cut.id).last?.index ?? -1) + 1
            #expect(next == 5)
            try await importEBook(Importer(store: relaunched, recognizer: { _ in fakeText(0) }), into: cut.id, pages: next..<count,
                                  chapters: chapters)

            let wholePages = try await relaunched.pages(of: whole.id)
            let cutPages = try await relaunched.pages(of: cut.id)
            #expect(cutPages.map(\.index) == wholePages.map(\.index))
            #expect(cutPages.map(\.width) == wholePages.map(\.width))
            for (expected, resumed) in zip(wholePages, cutPages) {
                let (want, got) = (try await relaunched.pageText(of: expected.id), try await relaunched.pageText(of: resumed.id))
                #expect(got != nil && got == want, "page \(resumed.index)")
            }
            #expect(try await relaunched.chapters(of: cut.id) == relaunched.chapters(of: whole.id))
        }
    }
}

/// U-CONT-001: `ChapterStart.contents(_:pages:)`, which turns a book's chapter starts and its pages into the rows of its contents.
@Suite("U-CONT Contents")
struct ContentsTests {
    @Test("U-CONT-001 The resolver: empty inputs give no rows; inputs in any order give rows in page order; a chapter whose range holds no page is left out, and the page goes to the chapter whose range holds it; pages before the first chapter belong to none; the last chapter takes the pages after its start")
    func resolver() {
        let bookID = UUID()
        let pages = [0, 1, 2, 3, 5, 8, 9].map {
            Page(id: UUID(), bookID: bookID, index: $0, width: 1, height: 1, status: .recognized, attempts: 0, error: nil)
        }
        func rows(_ chapters: [(Int, String)], _ pages: [Page]) -> [String] {
            ChapterStart.contents(starts(chapters), pages: pages).map { "\($0.title)@\($0.page.index)" }
        }
        #expect(rows([], pages).isEmpty)
        #expect(rows([(0, "I")], []).isEmpty)
        #expect(rows([(1, "I"), (3, "II"), (5, "III")], pages) == ["I@1", "II@3", "III@5"])
        #expect(rows([(5, "III"), (1, "I"), (3, "II")], pages.reversed()) == ["I@1", "II@3", "III@5"])
        // 6 and 7 have only page 8 ahead of them: it belongs to 7, whose range holds it, and 6 has no page
        #expect(rows([(1, "I"), (6, "A"), (7, "B")], pages) == ["I@1", "B@8"])
        #expect(rows([(4, "I"), (20, "II")], pages) == ["I@5"])

        let entries = ChapterStart.contents(starts([(0, "I"), (2, "II"), (6, "III")]), pages: pages)
        #expect(entries.map(\.page) == [pages[0], pages[2], pages[5]])
        #expect(Set(entries.map(\.id)).count == entries.count)
    }
}

/// Chapter starts from (page index, title) pairs.
private func starts(_ pairs: [(Int, String)]) -> [ChapterStart] {
    pairs.map { ChapterStart(pageIndex: $0, title: $1) }
}

/// Imports an electronic book's pages `range` as `TypesetBook.page(_:)` would give them: page i is `pageImage(i + 1)` with its text,
/// and a chapter's first page carries its title. Pages in `skipping` cannot be read; `waitingAt` holds the page with that index at
/// the gate until it opens.
@discardableResult
private func importEBook(_ importer: Importer, into bookID: UUID, pages range: Range<Int>, chapters: [Int: String],
                         skipping: Set<Int> = [], waitingAt pause: (index: Int, gate: AsyncGate)? = nil) async throws -> Int {
    try await importer.importPages(count: range.count, into: bookID) { offset in
        let i = range.lowerBound + offset
        if let pause, pause.index == i { await pause.gate.wait() }
        return skipping.contains(i) ? nil : ImportPage(image: pageImage(i + 1), text: fakeText(i + 1), chapter: chapters[i])
    }
}

/// A book's contents as the app builds them from the store, one "title@page index" per row.
private func contents(_ store: BookStore, _ bookID: UUID) async throws -> [String] {
    let (chapters, pages) = (try await store.chapters(of: bookID), try await store.pages(of: bookID))
    return ChapterStart.contents(chapters, pages: pages).map { "\($0.title)@\($0.page.index)" }
}

/// Everything the store has published so far, read up to a marker queued behind it, as S-APP-Store's ChangeReader does. It ends the
/// store's single-consumer stream, so call it once per store.
private func published(_ store: BookStore) async -> [StoreChange] {
    let marker = StoreChange.pages(UUID())
    await store.changeSink.yield(marker)
    var taken: [StoreChange] = []
    for await change in store.changes {
        if change == marker { break }
        taken.append(change)
    }
    return taken
}
