import ReadStairCore
import SwiftUI

/// The first-launch level test, full screen, in two steps with no way back: the user taps the words they know among 40 (five real
/// words from each of the six levels, and ten made-up words), then Continue shows the estimate with the level rows to adjust it.
/// Skip keeps the default level. No gesture closes it: a full-screen cover has none. Whether it shows was decided once, at launch, so a
/// level arriving from iCloud meanwhile neither closes it nor changes its words.
struct LevelTestView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// One draw per showing, in shuffled order.
    @State private var items = VocabTest.items(seed: UInt64.random(in: .min ... .max))
    @State private var known: Set<VocabTest.Item> = []
    /// nil while the words show; after Continue, whether the answers say too little to trust the estimate.
    @State private var unreliable: Bool?
    /// The narrowest a word may get before the grid drops a column: two columns on an iPhone at the default text size, where the
    /// longest words fit on one line, and one column at the larger sizes.
    @ScaledMetric private var columnWidth: CGFloat = 150
    /// The room kept for the checkmark on each side of a word, so the word neither moves nor narrows when the checkmark appears.
    @ScaledMetric private var checkRoom: CGFloat = 20

    var body: some View {
        NavigationStack {
            Group {
                if let unreliable {
                    result(unreliable: unreliable)
                } else {
                    words
                }
            }
            .toolbar {
                if unreliable == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Skip") { app.skipTest() }
                            .accessibilityIdentifier("skip")
                    }
                }
            }
        }
    }

    // MARK: Step 1: the words

    private var words: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Which Words Do You Know?")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Tap every word you know. Some aren’t real words — leave those.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: columnWidth), spacing: 8)], spacing: 8) {
                    ForEach(items.indices, id: \.self) { index in
                        wordToggle(items[index])
                            .accessibilityIdentifier("testWord.\(index)")
                    }
                }
                .padding(.top, 8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaBar(edge: .bottom) {
            // Always enabled: tapping nothing is an answer too
            bottomButton("Continue", id: "continue") {
                // The unreliable wording says some tapped words were made up, which is only true if something was tapped
                unreliable = app.finishTest(known) && !known.isEmpty
            }
        }
    }

    /// A word to toggle, in a capsule: tinted with a checkmark when on, so the state does not rest on color alone. The word itself
    /// is what is judged: it reads as text and stays whole on one line, since a word broken in two is harder to recognize.
    private func wordToggle(_ item: VocabTest.Item) -> some View {
        let isKnown = known.contains(item)
        return Toggle(isOn: Binding { known.contains(item) } set: { if $0 { known.insert(item) } else { known.remove(item) } }) {
            spoken(item.word, in: "en-US")
                .lineLimit(1)
                // Only the longest words shrink: a little at the default size, to about half at the largest
                .minimumScaleFactor(0.4)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, checkRoom)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if isKnown {
                        Image(systemName: "checkmark")
                            .accessibilityHidden(true)
                    }
                }
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }

    // MARK: Step 2: the result

    /// The heading names the checked row, so it follows a row tapped below and never disagrees with the checkmark.
    private func result(unreliable: Bool) -> some View {
        let words = (app.level * 1000).formatted()
        return Form {
            LevelSection {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        if unreliable {
                            Text("Let’s Start at \(words) Words")
                        } else {
                            Text("About \(words) Words")
                        }
                    }
                    .font(.title2.bold())
                    // Not the header's gray: the answer is the screen's message
                    .foregroundStyle(Color.primary)
                    .accessibilityAddTraits(.isHeader)
                    Group {
                        if unreliable {
                            Text("Some words you tapped aren’t real words, so this is only a starting point.")
                        } else {
                            Text("This is an estimate. You can change it anytime.")
                        }
                    }
                    .font(.subheadline)
                }
                .textCase(nil)
                .padding(.bottom, 8)
            }
        }
        .safeAreaBar(edge: .bottom) {
            bottomButton("Start Reading", id: "startReading") { dismiss() }
        }
    }

    /// The step's one action, fixed at the bottom and as wide as the screen.
    private func bottomButton(_ title: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityIdentifier(id)
    }
}
