import ReadStairCore
import SwiftUI
import Translation

/// Settings: how many words to mark, the language cards translate into, and what ReadStair does with data. Books' gear and the Reader's
/// `How Many to Mark…` open this same sheet: from Books at full height; from the Reader at the medium detent, with the page in view
/// above it and the page's new words counted in its subtitle. Every choice applies at once, so it closes rather than confirms; there
/// is nothing to push.
struct SettingsSheet: View {
    /// The Reader's current page: its marked words and all its words, read live; nil from Books, and while the page is not read yet,
    /// failed or has no English text.
    var pageTally: () -> (new: Int, words: Int)? = { nil }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// The languages Apple Translation supports, English left out, by name; loaded when the sheet opens.
    @State private var languages: [Locale.Language] = []
    /// The language just chosen: the system offers its download right away if it is not installed yet.
    @State private var download: TranslationSession.Configuration?

    private static let english = Locale.Language(identifier: "en")

    var body: some View {
        NavigationStack {
            Form {
                LevelSection {
                    Text("How Many to Mark")
                }
                Section {
                    Picker("Translate To", selection: glossChoice) {
                        Text("Off").tag("en")
                        Divider()
                        ForEach(languages, id: \.self) { language in
                            Text(verbatim: Gloss.displayName(of: language, among: languages)).tag(language.minimalIdentifier)
                        }
                    }
                    .pickerStyle(.menu)
                    // The value in the label color: the accent on a dark sheet row is under 4.5:1
                    .tint(.primary)
                    .accessibilityIdentifier("translateTo")
                } footer: {
                    footer
                }
            }
            .navigationTitle("Settings")
            // In the bar rather than a row of its own, so every level row fits at the medium detent
            .navigationSubtitle(tallyLine)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("close")
                }
            }
        }
        .task { await loadLanguages() }
        // TranslationSession is not Sendable: the closure is @concurrent, so the session is used in one nonisolated context
        .translationTask(download) { @concurrent session in
            try? await session.prepareTranslation()
        }
    }

    /// `This page: 12 of 310 words are new`, read live; empty from Books.
    private var tallyLine: Text {
        guard let tally = pageTally() else { return Text(verbatim: "") }
        return Text("This page: \(tally.new) of \(tally.words) words are new")
    }

    /// The privacy policy the footer links to. It must be the Privacy Policy URL given in App Store Connect.
    private static let privacyPolicyURL = "https://oak-wjr.github.io/readstair/privacy/"

    /// What ReadStair does with data, with a link to the privacy policy, where the word data comes from and under which licenses, and
    /// whose the sample book is.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The link in the label color: the accent on a dark sheet is under 4.5:1
            Text(Self.privacyText)
                .tint(.primary)
            Text("Word data: wordfreq 3.1.1 (CC BY-SA 4.0), NGSL (CC BY-SA 4.0) and WordNet 3.0 (WordNet License).")
            Text("Sample book: Alice’s Adventures in Wonderland by Lewis Carroll (1865). Public domain.")
        }
    }

    /// The privacy sentence, ending in a Markdown link to the policy. The address is filled in after the String Catalog lookup, so
    /// the catalog never holds it, and the Markdown is read after that.
    private static var privacyText: AttributedString {
        let markdown = String(localized: "Your books and pages stay on this iPhone and in its backups. Your word list and vocabulary level sync through your iCloud account. ReadStair doesn’t collect any data. [Privacy Policy](\(privacyPolicyURL))")
        return (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    // MARK: Translate To

    /// The chosen language; before any choice, the one cards translate into by default (Off when there is none). Choosing saves it:
    /// from then on it no longer follows the device languages. A language not downloaded yet brings up the system's download at once;
    /// for one already installed, preparing it shows nothing.
    private var glossChoice: Binding<String> {
        Binding {
            switch app.glossSetting {
            case nil: app.translationTarget.map { Gloss.menuOption(for: $0, among: languages) } ?? "en"
            case "en"?: "en"
            case let identifier?: Gloss.menuOption(for: Locale.Language(identifier: identifier), among: languages)
            }
        } set: { identifier in
            app.setGloss(identifier)
            guard identifier != "en" else { return }
            download = TranslationSession.Configuration(source: Self.english, target: Locale.Language(identifier: identifier))
        }
    }

    private func loadLanguages() async {
        var seen: Set<String> = []
        let all = await Self.supportedLanguages()
            .filter { $0.languageCode != .english && seen.insert($0.minimalIdentifier).inserted }
        languages = all.sorted {
            Gloss.displayName(of: $0, among: all).localizedStandardCompare(Gloss.displayName(of: $1, among: all)) == .orderedAscending
        }
    }

    /// LanguageAvailability is not Sendable, so it is made and asked off the main actor.
    @concurrent
    private static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }
}

/// The level rows, shared by Settings and the level test's result: six levels from 1,000 to 12,000 words, each with three example
/// words, the current level checked. A tap saves the level at once, with no toast; tapping the row checked before takes it back. A
/// saved level that is not one of the six (none of the app's writers saves one) checks no row.
struct LevelSection<Header: View>: View {
    @ViewBuilder let header: Header

    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            ForEach(LevelLadder.anchors, id: \.self) { level in
                LevelRow(level: level, isCurrent: app.level == level) { app.setLevel(level) }
            }
        } header: {
            header
        } footer: {
            Text("Pick the hardest row where you know every word.")
        }
    }
}

/// `3,000 words` and its examples on one line, the examples under it when a large text size does not fit both. VoiceOver reads
/// `3,000 words. Examples: swear, motor, flood.`, and the checked row as selected.
private struct LevelRow: View {
    let level: Int
    let isCurrent: Bool
    let select: () -> Void

    var body: some View {
        let words = (level * 1000).formatted()
        let examples = spoken(LevelLadder.samples(for: level).joined(separator: " · "), in: "en-US")
        let title = Text("\(words) words")
        let samples = examples.font(.subheadline).foregroundStyle(.secondary)
        Button(action: select) {
            // Beside the title when the examples go under it
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .opacity(isCurrent ? 1 : 0)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        title
                        Spacer(minLength: 0)
                        samples
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        samples
                    }
                }
                // A button in a form takes the accent color; the row reads as text, and only its checkmark is tinted
                .foregroundStyle(Color.primary)
            }
            .contentShape(.rect)
        }
        .accessibilityLabel(Text("\(words) words. Examples: \(spoken(LevelLadder.samples(for: level).joined(separator: ", "), in: "en-US"))."))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("level.\(level)")
    }
}
