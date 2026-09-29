import SwiftUI

/// The glass capsule at the bottom of the screen, 8 pt above the bottom safe area: the undo toast and the Reader's page status share
/// its place and its look. Text, then an optional button; stacked when a large text size does not fit on one line. Callers fade it in
/// and out (0.2 s opacity) and give it its identifier.
struct BottomCapsule<Action: View>: View {
    private let text: Text
    private let showsProgress: Bool
    private let action: Action

    init(_ text: Text, showsProgress: Bool = false, @ViewBuilder action: () -> Action) {
        self.text = text
        self.showsProgress = showsProgress
        self.action = action()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { content }
            VStack(spacing: 8) { content }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .frame(maxWidth: 400)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var content: some View {
        if showsProgress { ProgressView() }
        text
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        action
    }
}
