import CoreGraphics
import Darwin
import Foundation
import Synchronization
import Testing
@testable import ReadStairCore

// Measurement helpers for the performance suites and device experiments: memory footprint, timing, thermal state, and the log format.

#if targetEnvironment(simulator)
let runTarget = "simulator"
#elseif os(macOS)
let runTarget = "mac"
#else
let runTarget = "device"
#endif

/// Device thresholds are asserted only on a device: the simulator and a Mac run Vision on the Mac's CPU, with the Mac's memory.
let isDevice = runTarget == "device"

/// The fixture page the measurements use: Fixtures/alice-p1.png (1400×2100, a typeset CC0 page), decoded on the page-image queue.
func fixturePage() async throws -> CGImage {
    let url = fixtureURL("Fixtures/alice-p1.png")
    let image = await PageImageFile.run { PageImageFile.load(url) }
    return try #require(image, "Missing fixture \(url.path(percentEncoded: false))")
}

// MARK: - Memory

/// The process's physical footprint (what Xcode's memory gauge and jetsam use).
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Samples the footprint every 20 ms while `body` runs and keeps the maximum, plus one sample at each end. The timer fires on its
/// own high-priority queue, so recognition keeping every cooperative thread busy cannot delay or skip samples.
final class PeakSampler: Sendable {
    private static let queue = DispatchQueue(label: "app.readstair.tests.footprint", qos: .userInteractive)
    private let peak = Mutex<UInt64>(0)
    var maximum: UInt64 { peak.withLock { $0 } }

    func sampling<T>(_ body: () async throws -> T) async rethrows -> T {
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
        timer.setEventHandler { [self] in sample() }
        sample()
        timer.activate()
        defer {
            timer.cancel()
            sample()
        }
        return try await body()
    }

    private func sample() {
        let now = footprint()
        peak.withLock { $0 = max($0, now) }
    }
}

/// What one piece of work cost: its duration, and the footprint just before it, at its peak, and once it settled (1 s after it
/// ended, so memory released asynchronously counts as released).
struct Cost {
    var elapsed: Duration
    var baseline: UInt64
    var peak: UInt64
    var settled: UInt64

    var peakMB: Double { Self.mb(peak) }
    var increaseMB: Double { Self.mb(peak) - Self.mb(baseline) }
    var retainedMB: Double { Self.mb(settled) - Self.mb(baseline) }

    var fields: KeyValuePairs<String, Any> {
        ["ms": elapsed, "baseline_mb": Self.mb(baseline), "peak_mb": peakMB, "settled_mb": Self.mb(settled),
         "increase_mb": increaseMB, "retained_mb": retainedMB]
    }

    private static func mb(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
}

/// Runs `body` and returns its result with what it cost.
func measure<T>(_ body: () async throws -> T) async rethrows -> (T, Cost) {
    let baseline = footprint()
    let sampler = PeakSampler()
    let start = ContinuousClock.now
    let result = try await sampler.sampling(body)
    let elapsed = ContinuousClock.now - start
    try? await Task.sleep(for: .seconds(1))
    return (result, Cost(elapsed: elapsed, baseline: baseline, peak: sampler.maximum, settled: footprint()))
}

/// A file's size in bytes; 0 if it is missing.
func fileSize(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

// MARK: - Time and heat

/// The sample at `fraction` by nearest rank: 0.5 is the median (the lower middle one for an even count), 0.9 the 9th of 10.
/// Zero when empty.
func percentile(_ fraction: Double, _ samples: [Duration]) -> Duration {
    let sorted = samples.sorted()
    guard !sorted.isEmpty else { return .zero }
    return sorted[max(Int((Double(sorted.count) * fraction).rounded(.up)), 1) - 1]
}

/// The thermal state's name. From `serious` on, a device throttles and its timings stop being comparable.
func thermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

/// Waits, at most two minutes, for the thermal state to return to nominal, so a timed run does not start on a warm device that
/// may throttle; returns how long it waited. A Mac is normally nominal and returns at once.
func coolDown() async throws -> Duration {
    let start = ContinuousClock.now
    while ProcessInfo.processInfo.thermalState != .nominal, ContinuousClock.now - start < .seconds(120) {
        try await Task.sleep(for: .seconds(5))
    }
    return ContinuousClock.now - start
}

// MARK: - Records

/// Output of the performance and device experiments, cut out of the test log afterwards; results are never written to files. Records are
/// `[EXP] key=value` lines; each evaluation item is one `[EXP-TSV]` row whose first field names the experiment, so rows from suites
/// running at the same time stay apart.
enum ExperimentLog {
    /// Prints one TSV row; tabs and line breaks inside a field (model output can contain them) become spaces.
    static func row(_ fields: String...) {
        print("[EXP-TSV] " + fields.map { String($0.map { $0 == "\t" || $0.isNewline ? " " : $0 }) }.joined(separator: "\t"))
    }

    /// Milliseconds with one decimal.
    static func ms(_ duration: Duration) -> String {
        String(format: "%.1f", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }

    /// Prints one `[EXP] key=value …` line made of the given groups of fields, starting with `test=<ID>` by convention.
    static func record(_ groups: KeyValuePairs<String, Any>...) {
        print(line(groups))
    }

    /// Durations in milliseconds (`ms`), doubles with two decimals, anything else as described; spaces inside a value become `_` so
    /// the line splits on spaces.
    static func line(_ groups: [KeyValuePairs<String, Any>]) -> String {
        func format(_ value: Any) -> String {
            let text = switch value {
            case let duration as Duration: Self.ms(duration)
            case let number as Double: String(format: "%.2f", number)
            default: String(describing: value)
            }
            return text.replacing(" ", with: "_")
        }
        return (["[EXP]"] + groups.joined().map { "\($0.key)=\(format($0.value))" }).joined(separator: " ")
    }

    /// What the numbers were measured on, once per test: device, simulator or mac; hardware model; system version; cores; memory;
    /// low power mode; build configuration (unoptimized code inflates the analysis time); thermal state.
    static func recordEnvironment(test: String) {
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let process = ProcessInfo.processInfo
        let os = process.operatingSystemVersion
        record(["test": test, "target": runTarget, "model": hardwareModel(),
                "os": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", "cores": process.activeProcessorCount,
                "memory_gb": Double(process.physicalMemory) / 1_073_741_824, "low_power": process.isLowPowerModeEnabled,
                "build": build, "thermal": thermalState()])
    }

    /// The model identifier (`iPhone18,1`); the simulator reports the model it simulates, a Mac its CPU architecture.
    private static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

@Suite("Supplementary: Probe")
struct ProbeTests {
    @Test("Nearest-rank percentiles: the median is the lower middle one for an even count, p90 the 9th of 10; zero when empty")
    func percentiles() {
        let tenths = (1...10).map { Duration.milliseconds($0 * 100) }.shuffled()
        #expect(percentile(0.5, tenths) == .milliseconds(500))
        #expect(percentile(0.9, tenths) == .milliseconds(900))
        let three: [Duration] = [.seconds(3), .seconds(1), .seconds(2)]
        #expect(percentile(0.5, three) == .seconds(2) && percentile(0.9, three) == .seconds(3))
        #expect(percentile(0.5, [.seconds(1)]) == .seconds(1) && percentile(0.9, [.seconds(1)]) == .seconds(1))
        #expect(percentile(0.5, []) == .zero)
    }

    @Test("A record is one line of key=value fields: durations in milliseconds, doubles with two decimals, no spaces inside a value")
    func recordFormat() {
        let line = ExperimentLog.line([["test": "P-X", "ms": Duration.milliseconds(1500), "mb": 12.5], ["words": 226, "note": "two words"]])
        #expect(line == "[EXP] test=P-X ms=1500.0 mb=12.50 words=226 note=two_words")
    }
}
