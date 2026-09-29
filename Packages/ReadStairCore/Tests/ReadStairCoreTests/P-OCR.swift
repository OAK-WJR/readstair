import CoreGraphics
import Foundation
import Testing
@testable import ReadStairCore

/// Recognition speed on the fixture page, split into Vision and analysis. The first run in the process is cold: it also parses the
/// lexicon and loads Vision's models, so run the suite on its own: `READSTAIR_EXPERIMENT=1 swift test --filter RecognitionSpeedTests`,
/// or xcodebuild with `TEST_RUNNER_READSTAIR_EXPERIMENT=1` and `-only-testing:ReadStairCoreTests/RecognitionSpeedTests` (a cold run that
/// finds the lexicon already parsed shows `lexicon_ms` near 0). The 3 s threshold is asserted on a device only; elsewhere it is recorded.
@Suite("P-OCR Recognition speed", .tags(.performance), .serialized, .timeLimit(.minutes(30)),
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_EXPERIMENT"] == "1"))
struct RecognitionSpeedTests {
    /// One recognition's time by stage.
    struct Stages {
        var lexicon: Duration
        var vision: Duration
        var analysis: Duration
        var words: Int
        var total: Duration { lexicon + vision + analysis }
    }

    @Test("P-OCR-001 Recognize the fixture page cold once, then warm 10 times: Vision and analysis timed apart; warm median ≤ 3 s on a device")
    func recognitionSpeed() async throws {
        let image = try await fixturePage()
        ExperimentLog.recordEnvironment(test: "P-OCR-001")
        let waited = try await coolDown()
        var runs: [Stages] = []
        for run in 0...10 {
            let stages = try await Self.recognize(image)
            ExperimentLog.record(["test": "P-OCR-001", "run": run == 0 ? "cold" : "warm", "n": run, "lexicon_ms": stages.lexicon,
                                  "vision_ms": stages.vision, "analysis_ms": stages.analysis, "total_ms": stages.total,
                                  "words": stages.words, "thermal": thermalState()])
            runs.append(stages)
        }
        let warm = runs.dropFirst()
        let total = warm.map(\.total), vision = warm.map(\.vision), analysis = warm.map(\.analysis)
        let median = percentile(0.5, total)
        ExperimentLog.record(["test": "P-OCR-001", "summary": "warm", "runs": warm.count, "total_median_ms": median,
                              "total_p90_ms": percentile(0.9, total), "vision_median_ms": percentile(0.5, vision),
                              "vision_p90_ms": percentile(0.9, vision), "analysis_median_ms": percentile(0.5, analysis),
                              "analysis_p90_ms": percentile(0.9, analysis), "cooldown_ms": waited])
        #expect(runs.allSatisfy { $0.words > 0 }, "a run that recognized nothing timed nothing")
        if isDevice {
            #expect(median <= .seconds(3), "warm median \(median), thermal state \(thermalState())")
        }
    }

    /// One recognition timed by stage: the steps of `Recognition.page(from:)` in the same order (keep the two in step).
    static func recognize(_ image: CGImage) async throws -> Stages {
        var start = ContinuousClock.now
        let lexicon = Lexicon.bundled
        let lexiconTime = ContinuousClock.now - start
        start = .now
        let lines = try await Recognition.lines(in: image)
        let visionTime = ContinuousClock.now - start
        start = .now
        let words = Recognition.hyphenMerge(lines, isKnown: lexicon.knows)
        let page = PageAnalyzer.analyze(words, lexicon: lexicon)
        return Stages(lexicon: lexiconTime, vision: visionTime, analysis: ContinuousClock.now - start, words: page.words.count)
    }
}
