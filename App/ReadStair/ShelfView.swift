import os
import ReadStairCore
import SwiftUI

/// Books, the root screen: every book's cover, with a line under it for how far the reader is, and its title, newest first, two to
/// a row; from the largest standard text size (xxxLarge) on, one to a row with a small cover. A book opens its book page, which also
/// renames and deletes it. `Add Book` is the only way to add one. `Word List` is always there: its empty state says how words get in.
struct ShelfView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var showsSettings = false

    var body: some View {
        let books = app.visibleBooks
        let isRows = dynamicTypeSize >= .xxxLarge
        ScrollView {
            // Rows are not lazy: at the largest text sizes a row runs from the cover's 60 pt to most of a screen for a long title, and
            // a lazy stack, estimating the rows it had not measured, kept correcting its scroll offset after a drag and hung the main
            // thread (UI-GRID-001 at AX5, on the SE and the 17 Pro). A row shows the page's small thumbnail, so a long shelf loads
            // little. The grid's cells differ far less in height, and it stays lazy.
            Group {
                if isRows {
                    VStack(spacing: 24) { cells(books, isRow: true) }
                } else {
                    LazyVGrid(columns: Self.columns, spacing: 24) { cells(books, isRow: false) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .overlay {
            // No action button: `Add Book` is the one way in. The text names no control, so it also reads right to VoiceOver.
            if books.isEmpty {
                ContentUnavailableView("No Books Yet", systemImage: "books.vertical", description: Text(
                    "Scan pages from a printed English book. ReadStair underlines only the words you may not know."))
            }
        }
        .navigationTitle("Books")
        .toolbar {
            // Before there is any book, the one way to the translation language and to what ReadStair does with data
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
                    .accessibilityIdentifier("settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Word List") {
                    // P-DB-001: WordListView ends the interval once the list is on screen
                    os_signpost(.begin, log: .performance, name: "Open Word List")
                    open(.wordList)
                }
                .accessibilityIdentifier("wordList")
            }
            // Apart, so the two do not read as one control, "add to Word List"
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Without the document camera (the simulator) only this item goes; nothing else on the screen changes
                    if AppModel.canScan {
                        Button("Scan Pages", systemImage: "doc.viewfinder") { app.scanPages(into: .newBook) }
                            .accessibilityIdentifier("scanPages")
                    }
                    Button("Choose from Photos", systemImage: "photo.on.rectangle") { app.choosePhotos(into: .newBook) }
                        .accessibilityIdentifier("choosePhotos")
                    // An EPUB or plain text file; always a new book, so not in the Reader's Add Pages
                    Button("Choose from Files", systemImage: "folder") { app.chooseFile() }
                        .accessibilityIdentifier("chooseFile")
                    Divider()
                    // Public-domain books on the web, opened in the browser: an EPUB saved there comes in through Choose from Files. ReadStair
                    // itself goes online for none of it.
                    Button("Find Free Books", systemImage: "safari") { openURL(Self.freeBooks) }
                        .accessibilityIdentifier("findFreeBooks")
                } label: {
                    Label("Add Book", systemImage: "plus")
                }
                .accessibilityIdentifier("addBook")
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsSheet() }
    }

    /// Standard Ebooks' catalogue: carefully produced public-domain books, each with the table of contents that Books' chapters use.
    private static let freeBooks = URL(string: "https://standardebooks.org/ebooks")!

    /// Two equal columns, each cell's top on the row's top: about four books to a screen on a 6.3-inch phone.
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 2)

    private func cells(_ books: [BookSummary], isRow: Bool) -> some View {
        ForEach(books, id: \.book.id) { summary in
            Button { open(.book(summary.book.id)) } label: { BookCell(summary: summary, isRow: isRow) }
                .buttonStyle(.plain)
                .accessibilityValue(summary.progress > 0
                    ? Text("Page \(summary.openingPageNumber) of \(summary.pageCount)") : Text(verbatim: ""))
                .accessibilityIdentifier("book")
        }
    }

    /// Books is the root, so it is on top only while the path is empty; a second tap during the push does not open a screen twice.
    private func open(_ route: Route) {
        guard app.path.isEmpty else { return }
        app.path.append(route)
    }
}

/// One book: its cover, with the line for how far the reader is, and its title. In the grid the cover fills the column in a 2:3 slot,
/// with the title under it; in rows it takes a 44×60 pt slot, the page's thumbnail, with the title beside it. A button's label, so
/// VoiceOver reads it as one element: the title, with `Page n of count` as its value while the line shows.
private struct BookCell: View {
    let summary: BookSummary
    let isRow: Bool

    var body: some View {
        let layout = isRow ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        layout {
            CoverView(page: summary.firstPage, progress: summary.progress, small: isRow)
                .frame(width: isRow ? 44 : nil, height: isRow ? 60 : nil)
                .aspectRatio(2 / 3, contentMode: .fit)
            // Whole, however long: the title is all that tells apart the books added on one day
            Text(summary.book.title)
                .font(.subheadline)
        }
        // The whole cell answers a tap, the gap between cover and text included
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}
