import os
import ReadStairCore
import SwiftUI
import Translation

/// Word List: the words being learned, grouped by the book each was first met in (in shelf order), then Other (a book that is gone,
/// or a word from another device), easiest first within a group. Each word has its translation beside it while the Translate To
/// language is downloaded. A row opens the word's card, which says the word and offers Go to Page while the word's book is on the
/// shelf. No search, sorting, editing or swipe actions.
struct WordListView: View {
    @Environment(AppModel.self) private var app
    /// The open card. The list cannot be tapped behind it, so it never swaps to another word.
    @State private var card: CardWord?
    /// Where Go to Page leads: pushed once the card has closed, never while it slides away.
    @State private var destination: Route?
    /// The listed words in the Translate To language, by lemma, as they arrive; kept while the list is open.
    @State private var translations: [String: String] = [:]
    /// Set only while the Translate To language is downloaded: the list never brings up the download, Settings does.
    @State private var translating: TranslationSession.Configuration?

    var body: some View {
        let sections = app.wordListSections
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries, id: \.lemma) { entry in
                        WordRow(entry: entry, translation: translation(of: entry.lemma)) {
                            card = CardWord(listed: entry)
                            app.cardOnScreen = true
                        }
                    }
                } header: {
                    Text(section.book?.title ?? String(localized: "Other"))
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            // The empty state is the tutorial: it says how words get here
            if sections.isEmpty {
                ContentUnavailableView("No Words Yet", systemImage: "text.book.closed", description: Text(
                    "New words you tap while reading show up here."))
            }
        }
        .navigationTitle("Word List")
        // P-DB-001: ends the interval the Word List button began, once the list has appeared
        .task { os_signpost(.end, log: .performance, name: "Open Word List") }
        .sheet(item: $card, onDismiss: cardDismissed) { card in
            WordCard(card: card, goToPage: goToPage(card))
                .presentationDetents([.medium, .large])
        }
        // An alert never goes over a live card: the card closes, and the root shows the alert once the card is gone
        .onChange(of: app.alert != nil) { _, alerting in
            if alerting { card = nil }
        }
        // Checked when the language changes and each time the list appears, so a download finished in Settings meanwhile counts
        .task(id: app.translationTarget) {
            let target = await Self.installed(app.translationTarget)
            guard !Task.isCancelled, target != translating?.target else { return }
            translations = [:]
            translating = target.map { TranslationSession.Configuration(source: Locale.Language(identifier: "en"), target: $0) }
        }
        // Words added while the list is open, from the Reader after Go to Page or from iCloud: one more batch for them
        .onChange(of: sections) {
            if !untranslated.isEmpty { translating?.invalidate() }
        }
        // TranslationSession is not Sendable: the closure is @concurrent, so the session is used in one nonisolated context, off the
        // main actor. One batch for every listed word without a translation; they show 50 at a time as they arrive, so 2,000 words
        // redraw the list 40 times, not 2,000, and a word whose translation fails shows none.
        .translationTask(translating) { @concurrent [target = translating?.target] session in
            let words = await MainActor.run { untranslated }
            // The pack may have been deleted in Settings since the list checked: the batch would then bring up the download
            guard !words.isEmpty, await Self.installed(target) != nil else { return }
            let requests = words.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
            var arrived: [String: String] = [:]
            do {
                for try await response in session.translate(batch: requests) {
                    guard let lemma = response.clientIdentifier else { continue }
                    arrived[lemma] = response.targetText
                    guard arrived.count == 50 else { continue }
                    await show(arrived, in: target)
                    arrived = [:]
                }
            } catch {}
            await show(arrived, in: target)
        }
    }

    /// Adds translations that arrived, unless they are for a language no longer chosen.
    private func show(_ arrived: [String: String], in target: Locale.Language?) {
        guard !arrived.isEmpty, translating?.target == target else { return }
        translations.merge(arrived) { $1 }
    }

    /// A word's translation, which VoiceOver speaks in its language; nil until it arrives, and with no language to translate into.
    private func translation(of lemma: String) -> Text? {
        guard let text = translations[lemma], let language = translating?.target else { return nil }
        return spoken(text, in: language.minimalIdentifier)
    }

    /// The listed words without a translation yet.
    private var untranslated: [String] {
        app.wordListSections.flatMap(\.entries).map(\.lemma).filter { translations[$0] == nil }
    }

    /// The Translate To language if it is downloaded, else nil. LanguageAvailability is not Sendable, so it is made and asked off the
    /// main actor; asking never downloads anything.
    @concurrent
    private static func installed(_ target: Locale.Language?) async -> Locale.Language? {
        guard let target, await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: target) == .installed
        else { return nil }
        return target
    }

    /// Go to Page, offered while the word's first book is on the shelf: decided from the books already read, so the card never jumps.
    private func goToPage(_ card: CardWord) -> (() -> Void)? {
        guard case .list(let bookID?, let pageID) = card.origin,
              app.visibleBooks.contains(where: { $0.book.id == bookID }) else { return nil }
        return { destination = .reader(bookID: bookID, pageID: pageID) }
    }

    /// The card is gone, so an alert may show. After Go to Page: Books › Word List › Reader, so Back returns here. The Reader opens on
    /// the word's page, or where the book was left if that page is gone, and opens no card.
    private func cardDismissed() {
        app.cardOnScreen = false
        guard let destination else { return }
        self.destination = nil
        app.path.append(destination)
    }
}

/// One word: a button with the word, its translation beside it (one line, cut if long; under it at accessibility text sizes) and the
/// sentence it was first met in (two lines at most), which opens the card. VoiceOver reads it as one element: the word, the
/// translation, then the sentence.
private struct WordRow: View {
    let entry: WordEntry
    /// nil with Translate To Off or its language not downloaded: the row is the word and its sentence.
    let translation: Text?
    let open: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let english = "en-US"

    var body: some View {
        // At accessibility sizes the word fills most of the line and would cut its translation to "…": it goes under the word instead
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                layout {
                    spoken(entry.lemma, in: Self.english)
                        .font(.body.weight(.semibold))
                        // The word stays whole; its translation gives way
                        .layoutPriority(1)
                    if let translation {
                        translation
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let sentence = entry.firstSentence {
                    spoken(sentence, in: Self.english)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            // A button in a list takes the accent color; the row reads as text
            .foregroundStyle(Color.primary)
        }
        .accessibilityIdentifier("wordRow")
    }
}

private extension CardWord {
    /// A word from the list. Its headword is the stored lemma; its sentence and Go to Page come from where it was first met. The list
    /// keeps no kind: a learning word is marked whatever its kind, so the card offers `I Know This`.
    init(listed entry: WordEntry) {
        self.init(word: PageWord(surface: entry.lemma, lemma: entry.lemma, kind: .word, band: entry.band, quads: [], sentence: 0),
                  sentence: entry.firstSentence, origin: .list(bookID: entry.firstBookID, pageID: entry.firstPageID))
    }
}
