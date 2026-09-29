import XCTest

/// The runner of the iCloud sync device checks I-SYNC-001 to I-SYNC-006, which the app runs itself (`-ReadStairSyncSelfTest YES`)
/// because only the app has the iCloud entitlement; each check reports an `[I-SYNC-00n]` line. Opt-in, on a device (or a simulator)
/// signed in to iCloud, with a DEBUG app built with the iCloud switch:
/// `TEST_RUNNER_READSTAIR_SYNC_SELFTEST=1 xcodebuild test … READSTAIR_ICLOUD=YES -only-testing:ReadStairUITests/SyncSelfTestTests`.
/// It writes to that account's iCloud development environment. The report's lines go to the test output and into the result bundle.
final class SyncSelfTestTests: UITestCase {
    @MainActor
    func testI_SYNC_deviceChecks() throws {
        guard ProcessInfo.processInfo.environment["READSTAIR_SYNC_SELFTEST"] == "1" else {
            throw XCTSkip("Opt-in: set TEST_RUNNER_READSTAIR_SYNC_SELFTEST=1 and build the app with READSTAIR_ICLOUD=YES.")
        }
        let session = Session(root: nil)
        session.app.launchArguments = ["-ReadStairSyncSelfTest", "YES"]
        session.app.launch()
        let report = session.app.staticTexts["syncSelfTest"]
        XCTAssertTrue(session.eventually(30) { report.exists }, "No self-test screen: build a DEBUG app with READSTAIR_ICLOUD=YES")

        let finished = session.eventually(1200, interval: 5) { !report.exists || report.label != "Running" }
        XCTAssertTrue(report.exists, "The app quit during the self-test")
        let text = report.value as? String ?? ""
        for line in text.split(separator: "\n") { print(line) }
        let attachment = XCTAttachment(string: text)
        attachment.name = "I-SYNC report"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(finished, "The self-test did not finish within 20 minutes")
        XCTAssertEqual(report.label, "Passed", "The report is attached to this test")
    }
}
