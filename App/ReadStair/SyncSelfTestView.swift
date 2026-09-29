#if DEBUG && READSTAIR_ICLOUD
import OSLog
import ReadStairCore
import SwiftUI

extension DebugLaunch {
    /// `-ReadStairSyncSelfTest YES`: the app runs the iCloud sync self-test instead of opening the user's books.
    static var syncSelfTest: Bool {
        UserDefaults.standard.bool(forKey: "ReadStairSyncSelfTest")
    }
}

/// The only screen of a `-ReadStairSyncSelfTest` launch: runs `SyncSelfTest` on this device's iCloud account (development environment)
/// and shows its report as it grows. Every line also goes to the log. The element `syncSelfTest` has the outcome as its label
/// (`Running`, `Passed` or `Failed`) and the report as its value, which the UI test in I-SYNC.swift reads. The app model is never
/// launched, so the user's books and words are not opened and the app's own sync never starts.
struct SyncSelfTestView: View {
    @State private var outcome = "Running"
    @State private var lines: [String] = []
    private static let log = Logger(subsystem: "app.readstair", category: "sync-self-test")

    var body: some View {
        ScrollView {
            Text(verbatim: ([outcome] + lines).joined(separator: "\n"))
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("syncSelfTest")
                .accessibilityLabel(Text(verbatim: outcome))
                .accessibilityValue(Text(verbatim: lines.joined(separator: "\n")))
        }
        .task {
            // A run of up to 20 minutes that stops halfway leaves test words in iCloud: the screen must not lock
            UIApplication.shared.isIdleTimerDisabled = true
            let passed = await SyncSelfTest.run { line in
                Self.log.notice("\(line, privacy: .public)")
                lines.append(line)
            }
            outcome = passed ? "Passed" : "Failed"
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
#endif
