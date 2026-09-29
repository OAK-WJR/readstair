import ReadStairCore
import SwiftUI

/// A book's page, where every book opens from Books: its cover, `Read`, which opens the Reader where the book was left, and the book's
/// own table of contents when it has at least two chapters, each row opening the Reader at its chapter. `More` renames or deletes the
/// book, and nothing else does. The title is only in the bar, inline, where a long one is cut short; Books shows it whole, and
/// VoiceOver reads it whole. Photographed books, text files and e-books without contents show the cover and `Read` only.
struct BookView: View {
    @Environment(AppModel.self) private var app
    let bookID: UUID
    /// Read again whenever the book's pages change: while an import runs, rows arrive with their pages.
    @State private var contents: [ContentsEntry] = []

    var body: some View {
        let summary = app.books.first { $0.book.id == bookID }
        // A scroll view, not a List: a list row with one button becomes that button, cover and all
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 16) {
                    CoverView(page: summary?.firstPage)
                        .frame(width: 120, height: 180)
                    Button { open(.reader(bookID: bookID, pageID: nil)) } label: {
                        Text("Read")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("read")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // The app's one such check: a single chapter is nothing to choose from
                if contents.count >= 2 {
                    ForEach(Array(contents.enumerated()), id: \.element.id) { index, entry in
                        Button { open(.reader(bookID: bookID, pageID: entry.page.id)) } label: {
                            // The book's own label, as written: data, never translated. Plain text, so `Read` stays the one accent,
                            // in VoiceOver's English voice: only e-books have chapters, and one in another language is turned down
                            spoken(entry.title, in: "en-US")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.vertical, 6)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("chapter.\(index)")
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .navigationTitle(summary?.book.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { BookMenu(bookID: bookID) }
        }
        .task(id: app.pageRevision[bookID]) { contents = await app.contents(of: bookID) }
    }

    /// This page is on top only while the path ends with it; a second tap during the push does not open the Reader twice.
    private func open(_ route: Route) {
        guard app.path.last == .book(bookID) else { return }
        app.path.append(route)
    }
}

/// The book page's `More`, in a view of its own: it reads nothing that changes while pages arrive, so an open menu is not rebuilt
/// on every page an import saves (VoiceOver would lose its place in it).
private struct BookMenu: View {
    @Environment(AppModel.self) private var app
    let bookID: UUID

    var body: some View {
        Menu("More", systemImage: "ellipsis") {
            Button("Rename…", systemImage: "pencil") { app.alert = .rename(bookID: bookID) }
                .accessibilityIdentifier("rename")
            Divider()
            // Back to Books at once, where the book is gone and the undo toast can bring it back
            Button("Delete Book", systemImage: "trash", role: .destructive) {
                app.deleteBook(bookID)
                app.path = []
            }
            .accessibilityIdentifier("deleteBook")
        }
        .accessibilityIdentifier("more")
    }
}
