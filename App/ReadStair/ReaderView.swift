import ReadStairCore
import SwiftUI

/// The Reader: one book's pages side by side, each zoomable, with the new words underlined. A tap on a word opens its card.
struct ReaderView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    @State private var model: ReaderModel
    @State private var windowHeight: CGFloat = 0
    /// The status capsule's top edge in window coordinates while it shows.
    @State private var statusTop: CGFloat?
    @ScaledMetric(relativeTo: .body) private var scaledLow: CGFloat = 240

    /// `pageID` is a page to open at; nil opens the book where the reader left it.
    init(bookID: UUID, pageID: UUID?) {
        _model = State(initialValue: ReaderModel(bookID: bookID, pageID: pageID))
    }

    /// The word card's low detent: 240 pt scaled with the text size, at most 45% of the window. It is also the height the card is
    /// taken to cover when keeping the tapped word in view; the card's actual detent is never tracked.
    private var low: CGFloat {
        windowHeight > 0 ? min(scaledLow, 0.45 * windowHeight) : scaledLow
    }

    var body: some View {
        content
            .navigationTitle(app.book(model.bookID)?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .onGeometryChange(for: CGFloat.self) { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom } action: {
                windowHeight = $0
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.pixelWidth = $0 * displayScale }
            // One sheet whose content swaps when another word is tapped, so the card keeps its detent
            .sheet(isPresented: cardPresented, onDismiss: { model.cardDismissed() }) { cardSheet }
            // At the medium detent the page stays in view above it, and its underlines follow the rows. Opaque: on glass, the page
            // showing through lowered the rows' contrast.
            .sheet(isPresented: $model.showsSettings) {
                SettingsSheet(pageTally: { model.pageTally })
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Color(uiColor: .systemGroupedBackground))
            }
            // An alert never goes over a live card: the card closes, and the root shows the alert once the card is gone
            .onChange(of: app.alert != nil) { _, alerting in
                if alerting { model.card = nil }
            }
            .task(id: app.pageRevision[model.bookID]) { await model.reload(from: app) }
            // Loads Apple Intelligence before the first card asks it about a word
            .task(id: app.meaningAvailable) {
                if app.meaningAvailable { SentenceMeaning.prewarm() }
            }
            .onChange(of: app.hiddenPageID) { old, _ in model.pageMayHaveReturned(old) }
            .onChange(of: app.firstAddedPage) { model.revealFirstAddedPage() }
    }

    @ViewBuilder private var content: some View {
        if model.storedPages == nil {
            // Nothing until the pages are read, so a book with pages never flashes the empty state
            Color.clear
        } else if model.visiblePages.isEmpty {
            ContentUnavailableView {
                Label("No Pages", systemImage: "doc.viewfinder")
            } description: {
                Text("Scan pages to add them to this book.")
            }
        } else {
            let look = model.currentPage.map { model.look(of: $0) }
            pager
                .navigationSubtitle(subtitle(look))
                .overlay(alignment: .bottom) { statusCapsule(look?.status) }
        }
    }

    // MARK: Pages

    /// Pages rest between the bars: the pager keeps to the safe area, and each page clips its zoomed content to its own bounds.
    private var pager: some View {
        let visible = model.visiblePages
        let positions = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($0.element.id, $0.offset + 1) })
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.pagerPages) { page in
                    pageView(page, position: positions[page.id], count: visible.count)
                        .containerRelativeFrame(.horizontal)
                }
            }
            // Without it the scroll position does not follow the pages
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $model.currentPageID)
        // A zoomed page pans instead of paging; pinch back to page again
        .scrollDisabled(model.isZoomed)
        .scrollIndicators(.hidden)
    }

    private func pageView(_ page: Page, position: Int?, count: Int) -> some View {
        let look = model.look(of: page)
        let selected = model.selectedWord(on: page.id)
        // The status capsule shows the current page's status
        let isCurrent = page.id == model.currentPageID
        return PageView(
            imageID: model.image(of: page).map(ObjectIdentifier.init),
            image: { model.image(of: page) },
            pixelSize: CGSize(width: page.width, height: page.height),
            text: look.text,
            marked: look.marked,
            selected: selected,
            isCurrent: isCurrent,
            cardLow: selected == nil ? nil : low,
            statusTop: isCurrent ? statusTop : nil,
            // A page being deleted no longer counts
            summaryLabel: position.map { String(localized: "Page \($0) of \(count)") } ?? "",
            summaryValue: look.summaryValue,
            retry: isCurrent && look.status == .failed ? { model.retryCurrentPage() } : nil,
            onTap: { model.select($0, onPage: page.id) },
            onZoomedChange: { model.zoomChanged($0, onPage: page.id) })
    }

    /// `Page 3 of 30`, or `Page 3 of 30 · No new words`, counting the pages that show.
    private func subtitle(_ look: PageLook?) -> Text {
        let visible = model.visiblePages
        guard let index = visible.firstIndex(where: { $0.id == model.currentPageID }) else { return Text(verbatim: "") }
        let (number, count) = (index + 1, visible.count)
        return look?.hasNoNewWords == true ? Text("Page \(number) of \(count) · No new words") : Text("Page \(number) of \(count)")
    }

    /// Reading, Failed or No text, where the undo toast shows; it gives way while the toast is up and comes back after. Its top edge is
    /// passed to the current page, whose text under it can then scroll clear.
    private func statusCapsule(_ status: PageStatus?) -> some View {
        let shown = app.pendingChange == nil ? status : nil
        return ZStack {
            if let shown {
                BottomCapsule(Text(shown.text), showsProgress: shown == .reading) {
                    if shown == .failed {
                        Button("Try Again") { model.retryCurrentPage() }
                            .buttonStyle(.bordered)
                            // Bold, like the toast's Undo in the same capsule: the accent on glass meets the bold-text bar
                            // (3:1), not 4.5:1
                            .bold()
                            // At least 44 pt tall, the whole of it the target
                            .controlSize(.large)
                            .accessibilityIdentifier("tryAgain")
                    }
                }
                .accessibilityIdentifier("pageStatus")
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { statusTop = $0 }
                .onDisappear { statusTop = nil }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shown)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Add Pages", systemImage: "camera") { model.perform(.addPages) }
                .accessibilityIdentifier("addPages")
        }
        ToolbarItem(placement: .topBarTrailing) { ReaderMenu(model: model, hasPages: !model.visiblePages.isEmpty) }
    }

    // MARK: Word card

    private var cardPresented: Binding<Bool> {
        Binding { model.card != nil } set: { if !$0 { model.card = nil } }
    }

    /// Up to the low detent the page behind stays tappable, so the next word is one tap; which detent is showing is not tracked, since
    /// above the low one the page cannot be tapped.
    @ViewBuilder private var cardSheet: some View {
        if let card = model.card ?? model.shownCard {
            WordCard(card: card)
                .id(card.id)
                .presentationDetents([.height(low), .medium])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(low)))
        }
    }
}

/// The Reader's `More`, in a view of its own whose inputs change only when the book gains its first page or loses its last: an
/// open menu is not rebuilt on every page an import saves (VoiceOver would lose its place in it).
private struct ReaderMenu: View {
    let model: ReaderModel
    let hasPages: Bool

    var body: some View {
        Menu("More", systemImage: "ellipsis") {
            Button("How Many to Mark…", systemImage: "underline") { model.perform(.howManyToMark) }
                .accessibilityIdentifier("howManyToMark")
            if hasPages {
                Divider()
                Button("Delete Page", systemImage: "trash", role: .destructive) { model.deleteCurrentPage() }
                    .accessibilityIdentifier("deletePage")
            }
        }
        .accessibilityIdentifier("more")
    }
}
