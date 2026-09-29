import ReadStairCore
import SwiftUI

/// A book's cover: its first page, fitted into whatever slot the parent gives and standing on the slot's bottom edge, so covers of
/// different shapes line up along a row, as on a shelf, and, on Books, how far the reader is. Books' grid, its rows at the largest
/// text sizes and the book page show it. Decorative: hidden from VoiceOver, which reads the book's title instead.
struct CoverView: View {
    @Environment(AppModel.self) private var app
    /// The book's first page; nil for a book with no pages.
    let page: Page?
    /// How far into the book the reader is (`BookSummary.progress`): above 0, a line in system green under the cover's bottom edge,
    /// that share of its width and never shorter than twice its thickness, so page 2 of a long book reads as a line, not a dot. System
    /// green is #34C759 in light mode, 2.2:1 on white, and #30D158 in dark mode; with Increase Contrast on, iOS darkens it to #248A3D,
    /// 4.4:1. The line only repeats what VoiceOver reads and the Reader shows as `Page n of count`. Books passes it; the book page
    /// does not.
    var progress: Double = 0
    /// Whether the page's 240 px thumbnail will do, as it does in Books' 44×60 pt rows, which load every row at once.
    var small = false
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // A picture of a page: Smart Invert leaves it alone, like the Reader's pages
                    .accessibilityIgnoresInvertColors()
            } else {
                // Also what shows while the cover loads, or if its file is missing: in the page's shape, so nothing moves when the
                // image arrives
                Rectangle()
                    .fill(.fill)
                    .aspectRatio(page.map { CGFloat($0.width) / CGFloat($0.height) } ?? 2 / 3, contentMode: .fit)
                    .overlay {
                        if page == nil {
                            Image(systemName: "book.closed")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .clipShape(.rect(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5) }
        .overlay(alignment: .bottomLeading) {
            if progress > 0 {
                // Scaled as it is drawn, so the line takes no part in layout
                Capsule().fill(.green)
                    .frame(height: 3)
                    .visualEffect { line, cover in
                        line.scaleEffect(x: max(6 / max(cover.size.width, 6), progress), anchor: .leading)
                    }
                    .offset(y: 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
        .task(id: Source(pageID: page?.id, small: small)) {
            guard let page else {
                image = nil
                return
            }
            image = small ? await app.thumbnail(of: page) : await app.cover(of: page)
        }
    }

    private struct Source: Equatable {
        let pageID: UUID?
        let small: Bool
    }
}
