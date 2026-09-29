import XCTest

/// The device performance gates: cold launch to the shelf (P-LAUNCH-001), memory and hitches while turning 50 pages of a 600-page
/// book (P-MEM-001), and opening a Word List of 2,000 words (P-DB-001). All three run on the perf store, a heavy user's store
/// (`PerfStore`). XCTest records every metric wherever the tests run, into the result bundle. tools/report-tests.sh holds the
/// thresholds and judges them, on a device only: the simulator's numbers are the Mac's.
final class PerformanceGateTests: UITestCase {
    /// P-LAUNCH-001: cold launch to the shelf in less than 1 s (the median of 5 launches). XCTApplicationLaunchMetric, responsive: from
    /// the launch until the first frame is on screen and the main thread takes input. A launch counts only if it ends on the shelf
    /// with the book, and not on the level test or the failure screen. On a simulator nothing is judged, and XCTest there now and then
    /// records no launch and fails the run, so a simulator only checks that the five cold launches reach the shelf (XCTClockMetric keeps
    /// measure() running; the report does not read it).
    @MainActor
    func testP_LAUNCH_001_coldLaunchToShelf() throws {
        let session = try PerfStore.session()
        #if targetEnvironment(simulator)
        let metrics: [any XCTMetric] = [XCTClockMetric()]
        #else
        let metrics: [any XCTMetric] = [XCTApplicationLaunchMetric(waitUntilResponsive: true)]
        #endif
        measure(metrics: metrics, options: Self.options(iterations: 5)) {
            session.app.launch()
            PerfStore.assertShelf(session)
            session.app.terminate()
        }
    }

    /// P-MEM-001: the app's peak physical memory stays under 150 MB, and page turns hitch for less than 5 ms per second, while 50 pages
    /// of the 600-page book turn, one swipe at a time. Measured from the first swipe to the last, after the book has opened on a page
    /// that is read. It turns forward, or back when fewer than 50 pages are left ahead (a device keeps its copy of the store from run
    /// to run, and with it the reading position).
    @MainActor
    func testP_MEM_001_fiftyPageTurns() throws {
        let session = try PerfStore.session()
        let metrics: [any XCTMetric] = [XCTMemoryMetric(application: session.app), XCTOSSignpostMetric.scrollingAndDecelerationMetric]
        measure(metrics: metrics, options: Self.options(iterations: 1, manual: true)) {
            session.app.launch()
            PerfStore.assertShelf(session)
            session.openBook()
            // A page still to read means the store was built by an older analysis pipeline and the app is reading all 600 again
            XCTAssertTrue(session.waitForRecognized(timeout: 30), "The page is not read: \(session.pageValue() ?? "no value"). If pages "
                          + "are being read, the perf store predates the app's PageText: build it again.")
            let start = session.position() ?? Position(index: 1, count: PerfStore.pages)
            let forward = start.index + 50 <= start.count
            startMeasuring()
            for _ in 0..<50 {
                if forward { session.nextPage() } else { session.previousPage() }
            }
            stopMeasuring()
            XCTAssertEqual(session.position()?.index, start.index + (forward ? 50 : -50), "50 pages did not turn")
            session.app.terminate()
        }
    }

    /// P-DB-001: the Word List of 2,000 words opens in less than 200 ms (the median of 5 opens, each the first after a launch). The app
    /// marks the time from the tap on `Word List` to the list's first appearance with the signpost `Open Word List`.
    @MainActor
    func testP_DB_001_openWordListWith2000Words() throws {
        let session = try PerfStore.session()
        let signpost = XCTOSSignpostMetric(subsystem: "app.readstair", category: "performance", name: "Open Word List")
        measure(metrics: [signpost], options: Self.options(iterations: 5, manual: true)) {
            session.app.launch()
            PerfStore.assertShelf(session)
            let button = session.app.buttons["wordList"]
            startMeasuring()
            button.tap()
            let row = session.app.buttons.matching(identifier: "wordRow").firstMatch
            XCTAssertTrue(session.eventually(20) { row.exists }, "The Word List shows no rows")
            stopMeasuring()
            session.app.terminate()
        }
    }

    /// `iterations` measured runs (XCTest runs one more first and discards it). `manual` measures only between `startMeasuring()` and
    /// `stopMeasuring()`.
    private static func options(iterations: Int, manual: Bool = false) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        if manual { options.invocationOptions = [.manuallyStart, .manuallyStop] }
        return options
    }
}

/// The perf store: one book of 600 read pages, each alice-p1 with its recognized text, and 2,000 words being learned (1,500 first met in
/// the book, 500 under Other), at level 3. It is built once on the Mac by the core suite `PerfStoreFixture`
/// (Packages/ReadStairCore/Tests/ReadStairCoreTests/PerfStore.swift), through the store's own API:
///
///     cd Packages/ReadStairCore && READSTAIR_PERF_STORE="$PWD/../../build/perf-store" swift test --filter PerfStoreFixture
///
/// On the simulator each test gets its own copy. On a device the app reads the copy in its Documents folder, put there with
///
///     xcrun devicectl device copy to --device <device> --domain-type appDataContainer --domain-identifier <bundle id> \
///       --source build/perf-store --destination Documents/perf-store
@MainActor
enum PerfStore {
    static let pages = 600

    /// The folder's name in the app's Documents on a device.
    static let name = "perf-store"

    /// The store on the Mac: `READSTAIR_PERF_STORE` (`TEST_RUNNER_READSTAIR_PERF_STORE` for xcodebuild), or build/perf-store in the
    /// repository.
    static var source: URL {
        if let path = ProcessInfo.processInfo.environment["READSTAIR_PERF_STORE"], !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return Fixture.directory.deletingLastPathComponent().appending(path: "build/perf-store", directoryHint: .isDirectory)
    }

    /// A session on the perf store, configured and not launched.
    static func session() throws -> Session {
        #if targetEnvironment(simulator)
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw XCTSkip("No perf store at \(source.path(percentEncoded: false)). Build it: cd Packages/ReadStairCore && "
                          + "READSTAIR_PERF_STORE=\"$PWD/../../build/perf-store\" swift test --filter PerfStoreFixture")
        }
        let root = Paths.newDataRoot()
        try FileManager.default.copyItem(at: source, to: root)
        let session = Session(root: root)
        session.configure()
        #else
        // A relative data root is looked up in the app's Documents
        let session = Session(root: nil)
        session.configure()
        session.app.launchArguments += ["-ReadStairDataRoot", name]
        #endif
        return session
    }

    /// Right after a launch: the shelf shows the book, and no level test.
    static func assertShelf(_ session: Session, file: StaticString = #filePath, line: UInt = #line) {
        let shown = session.eventually(30) { session.rows().count == 1 || session.skipButton.exists }
        XCTAssertTrue(shown && !session.skipButton.exists,
                      "No book on the shelf. Is the perf store there (on a device: Documents/\(name), with a build whose "
                      + "-ReadStairDataRoot takes a relative path)?", file: file, line: line)
    }
}
