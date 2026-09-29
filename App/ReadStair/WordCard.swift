import ReadStairCore
import SwiftUI
import Translation
import UIKit

/// What a word card shows and acts on.
nonisolated struct CardWord: Identifiable, Hashable {
    nonisolated enum Origin: Hashable {
        /// A word tapped on a page: `index` is its position in the page's words.
        case page(bookID: UUID, pageID: UUID, index: Int)
        /// A row of the Word List: the book and page the word was first met on, where known.
        case list(bookID: UUID?, pageID: UUID?)
    }

    let word: PageWord
    /// The sentence the word was met in, translated below the word; nil if none.
    let sentence: String?
    let origin: Origin

    /// The sheet's identity: a new word swaps the card's content in place and keeps the detent.
    var id: String {
        switch origin {
        case .page(_, let pageID, let index): "\(pageID)-\(index)"
        case .list: stateKey
        }
    }

    var headword: String { word.headword }
    var stateKey: String { word.stateKey }
}

/// The word card: the headword and its pronunciation, Apple Translation of the word and of its sentence, Go to Page when opened from
/// the Word List, Apple Intelligence's reading of the word in its sentence (once ever, while it is off, the hint to turn it on), and a
/// bar fixed at the bottom with the one primary action and Look Up.
///
/// The Reader keeps one sheet for every card and gives each card its own identity with `.id(card.id)`: a new word swaps the content
/// in place and keeps the detent, and the old card's translation, explanation and speech stop with it. The Word List gives each card
/// a sheet of its own. The primary action closes the card itself, through the sheet's dismiss action.
struct WordCard: View {
    let card: CardWord
    /// Go to Page: given only by the Word List, and only while the word's book is on the shelf. The card closes; the Word List pushes
    /// the page once it has closed.
    var goToPage: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @AccessibilityFocusState private var headwordFocused: Bool
    @State private var translated = Translated.loading
    @State private var meaning: SentenceMeaning.Explained?
    @State private var meaningFailed = false
    /// Whether the user has seen this card's hint to turn on Apple Intelligence: the card then keeps it while it is open.
    @State private var hintSeen = false
    /// Whether the word was marked when the primary button was pressed. The button keeps that label while the card closes, and a second
    /// press does nothing: it would propose the opposite change and undo the first.
    @State private var pressedWhileMarked: Bool?

    /// The language the headword and the English parts of the explanation are spoken in.
    private static let english = "en-US"

    var body: some View {
        // At accessibility sizes the stacked buttons would take most of a low card and hide the headword: they scroll with the text,
        // right after the translations
        let buttonsScroll = dynamicTypeSize.isAccessibilitySize
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    headwordRow
                    translation
                }
                if buttonsScroll {
                    actions
                }
                // Secondary to the actions: in view at the medium detent, right under the translations while the bar holds the actions,
                // and it does not move when the explanation arrives
                if let goToPage {
                    Button {
                        goToPage()
                        dismiss()
                    } label: {
                        Label("Go to Page", systemImage: "arrow.forward")
                    }
                    .buttonStyle(.bordered)
                    // In the label color, like Look Up: the card has one red action
                    .tint(.primary)
                    .controlSize(.large)
                    .accessibilityIdentifier("goToPage")
                }
                if showsMeaning {
                    meaningSection
                } else if showsHint {
                    appleIntelligenceHint
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A bar rather than a plain inset: text scrolled under the buttons at the medium detent stays legible behind them
        .safeAreaBar(edge: .bottom) {
            if !buttonsScroll {
                actions
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .onAppear { headwordFocused = true }
        .onDisappear { app.speaker.stop() }
        // TranslationSession is not Sendable: the closure is @concurrent, so the session is used up in one nonisolated context, off the
        // main actor. The task ends with the card, which cancels the request.
        .translationTask(translationConfiguration) { @concurrent [word = card.headword, sentence = card.sentence] session in
            let result = await Self.translate(word, sentence, in: session)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if result == .declined { app.translationDeclined = true } else { translated = result }
            }
        }
        .task(id: app.meaningAvailable) { await explain() }
        // For the Reader's card and the Word List's alike: a drag on the card moves the card before it scrolls the card's text
        .presentationContentInteraction(.resizes)
        // Opaque: over a photo of paper, glass takes the page's tone and shows its text through the card. An explicit color:
        // `.background` resolves to the sheet's own glass here
        .presentationBackground(Color(uiColor: .systemBackground))
    }

    // MARK: Headword

    private var headwordRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            spoken(card.headword, in: Self.english)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headwordFocused)
                .accessibilityIdentifier("headword")
            Spacer(minLength: 0)
            // Speaks once per press, again from the start if pressed while speaking; never on its own
            Button { app.speaker.speak(card.headword) } label: {
                Image(systemName: "speaker.wave.2")
                    // At least 44 × 44, and larger with the symbol at large text sizes
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel(Text("Pronounce \(card.headword)"))
            .accessibilityIdentifier("pronounce")
        }
    }

    // MARK: Translation

    /// Hidden when there is no language to translate into.
    @ViewBuilder private var translation: some View {
        if let target = app.translationTarget {
            let language = target.minimalIdentifier
            switch app.translationDeclined ? Translated.unavailable : translated {
            case .loading:
                // Holds the word translation's line while it loads
                Text(verbatim: " ")
                    .font(.title3)
                    .hidden()
                    .overlay(alignment: .leading) { ProgressView().controlSize(.small) }
            case .done(let word, let sentence):
                spoken(word, in: language)
                    .font(.title3)
                    .accessibilityIdentifier("wordTranslation")
                if let sentence {
                    spoken(sentence, in: language)
                        .foregroundStyle(.secondary)
                }
            case .unavailable, .declined:
                Text("Translation unavailable")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// nil when there is nothing to translate into, or the language download was turned down this run: no request, so no prompt.
    private var translationConfiguration: TranslationSession.Configuration? {
        guard let target = app.translationTarget, !app.translationDeclined else { return nil }
        return TranslationSession.Configuration(source: Locale.Language(identifier: "en"), target: target)
    }

    /// The word and, if there is one, its sentence, in one batch. If the language pack is not installed the system offers the download
    /// itself. A pack still not installed after the attempt means the download was turned down, whatever the error, so the rest of the
    /// run asks no more.
    @concurrent
    private static func translate(_ word: String, _ sentence: String?, in session: TranslationSession) async -> Translated {
        var requests = [TranslationSession.Request(sourceText: word, clientIdentifier: "word")]
        if let sentence, !sentence.isEmpty {
            requests.append(TranslationSession.Request(sourceText: sentence, clientIdentifier: "sentence"))
        }
        do {
            let responses = try await session.translations(from: requests)
            guard let translatedWord = responses.first(where: { $0.clientIdentifier == "word" })?.targetText else { return .unavailable }
            return .done(word: translatedWord, sentence: responses.first { $0.clientIdentifier == "sentence" }?.targetText)
        } catch {
            if Task.isCancelled { return .unavailable }
            if TranslationError.notInstalled ~= error { return .declined }
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: session.targetLanguage)
            return status == .supported ? .declined : .unavailable
        }
    }

    // MARK: In This Sentence

    /// Only with Apple Intelligence available and a sentence to read the word in; any error removes the section.
    private var showsMeaning: Bool {
        app.meaningAvailable && card.sentence?.isEmpty == false && !meaningFailed
    }

    private var meaningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("In This Sentence")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if let meaning {
                spoken(meaning.answer.meaningHere, in: meaning.language)
                spoken(meaning.answer.explanation, in: Self.english)
                    .foregroundStyle(.secondary)
                // The quotation marks belong to the English example, not to the interface
                spoken("“\(meaning.answer.example)”", in: Self.english)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
        // Below the default priority: VoiceOver reads Go to Page, the primary action and Look Up before it
        .accessibilitySortPriority(-1)
    }

    /// In the section's place while Apple Intelligence is turned off, until a card has shown it: that card keeps it, no other shows it.
    private var showsHint: Bool {
        app.appleIntelligenceOff && card.sentence?.isEmpty == false && (!app.appleIntelligenceHintShown || hintSeen)
    }

    /// Only Settings can turn Apple Intelligence on.
    private var appleIntelligenceHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Turn on Apple Intelligence in Settings to see what this word means in this sentence.")
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.bordered)
            // In the label color, like Go to Page: the card has one red action
            .tint(.primary)
            .controlSize(.large)
        }
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(-1)
        // Seen once half of it is in view, not as the card opens: at the Reader's low detent it is under the bar or below the card
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            guard visible, !hintSeen else { return }
            hintSeen = true
            app.appleIntelligenceHintSeen()
        }
    }

    private func explain() async {
        guard showsMeaning, meaning == nil, let sentence = card.sentence else { return }
        let result = try? await SentenceMeaning.explain(card.headword, printed: PageWord.core(card.word.surface), in: sentence,
                                                        language: app.translationTarget)
        guard !Task.isCancelled else { return }
        if let result { meaning = result } else { meaningFailed = true }
    }

    // MARK: Actions

    /// One line when it fits, stacked at large text sizes.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                primaryButton
                lookUpButton(fillsWidth: false)
            }
            VStack(spacing: 8) {
                primaryButton
                lookUpButton(fillsWidth: true)
            }
        }
    }

    /// `I Know This` while the word is marked, `Mark as New` while it is not. Either one closes the card and shows the undo toast.
    private var primaryButton: some View {
        let marked = pressedWhileMarked ?? app.isMarked(card)
        return Button {
            guard pressedWhileMarked == nil else { return }
            pressedWhileMarked = marked
            app.primary(card)
            dismiss()
        } label: {
            (marked ? Text("I Know This") : Text("Mark as New"))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("primaryAction")
    }

    /// Always shown: with no definition on the device, the system dictionary says so and offers to download one.
    private func lookUpButton(fillsWidth: Bool) -> some View {
        Button(action: lookUp) {
            Label("Look Up", systemImage: "character.book.closed")
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        // In the label color: the accent is the primary action's, and on the gray fill it would be under 4.5:1
        .tint(.primary)
        .controlSize(.large)
        .accessibilityIdentifier("lookUp")
    }

    /// The system dictionary, presented by UIKit over the card: the one presentation stacked on another. Its own Done button closes it
    /// and leaves the card as it was.
    private func lookUp() {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(UIReferenceLibraryViewController(term: card.headword), animated: true)
    }
}

/// The card's translation of its word and sentence.
nonisolated private enum Translated: Equatable, Sendable {
    case loading
    case done(word: String, sentence: String?)
    case unavailable
    /// The language download was turned down: shown as unavailable, and no card asks again this run.
    case declined
}

/// Text that VoiceOver speaks in the given language's voice.
func spoken(_ string: String, in language: String) -> Text {
    var text = AttributedString(string)
    text.languageIdentifier = language
    return Text(text)
}
