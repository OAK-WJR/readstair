import Foundation
import NaturalLanguage
import Testing
@testable import ReadStairCore

/// Device experiment: does this device have NLTagger's English name-type assets offline, and which capitalized words does PageAnalyzer
/// take for names? Lemmas come from the lexicon alone (U-LEM-001 covers them in every environment); only a word's kind depends on the
/// device. Records only. Run the suite on its own, on the device (xcodebuild with `TEST_RUNNER_READSTAIR_EXPERIMENT=1` and
/// `-only-testing:ReadStairCoreTests/LemmaAssetExperiment`) and on a Mac for comparison (`READSTAIR_EXPERIMENT=1 swift test --filter
/// LemmaAssetExperiment`). Requesting assets may download, so it needs READSTAIR_ALLOW_ASSET_REQUEST=1 too.
@Suite("EXP-LEM NLTagger name assets", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_EXPERIMENT"] == "1", "Set READSTAIR_EXPERIMENT=1 to run"))
struct LemmaAssetExperiment {
    /// Capitalized words the name tagger decides on: a pronoun, a contraction and an ordinary word starting a sentence, and a name
    /// with a possessive. Books print curly apostrophes and OCR keeps them.
    private static let capitalized: [(sentence: String, word: String)] = [
        ("We shall see.", "We"),
        ("I\u{2019}d like some tea.", "I\u{2019}d"),
        ("Curiouser and curiouser!", "Curiouser"),
        ("Alice\u{2019}s sister was reading.", "Alice\u{2019}s"),
    ]

    @Test("EXP-LEM-001 Tag schemes available for English words (name type needs downloadable assets)")
    func schemes() {
        ExperimentLog.recordEnvironment(test: "EXP-LEM-001")
        ExperimentLog.record(["test": "EXP-LEM-001"], Self.schemes())
    }

    @Test("EXP-LEM-002 Capitalized words through PageAnalyzer: the kind (name or word) this device's tagger gives them")
    func capitalizedWords() throws {
        ExperimentLog.recordEnvironment(test: "EXP-LEM-002")
        for (sentence, word) in Self.capitalized {
            let analyzed = try #require(analyzeText(sentence).words.first { PageWord.core($0.surface) == word }, "\(word) not in \(sentence)")
            ExperimentLog.record(["test": "EXP-LEM-002", "word": word, "kind": analyzed.kind.rawValue, "sentence": sentence])
        }
    }

    @Test("EXP-LEM-003 Request the English name-type assets: result, time, and schemes before and after",
          .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_ALLOW_ASSET_REQUEST"] == "1",
                   "Requesting assets may download; set READSTAIR_ALLOW_ASSET_REQUEST=1 to allow it"))
    func requestAssets() async {
        ExperimentLog.recordEnvironment(test: "EXP-LEM-003")
        ExperimentLog.record(["test": "EXP-LEM-003", "when": "before"], Self.schemes())
        let start = ContinuousClock.now
        var result = "threw", failure = ""
        do {
            let assets = try await NLTagger.requestAssets(for: .english, tagScheme: .nameType)
            result = switch assets {
            case .available: "available"
            case .notAvailable: "notAvailable"
            case .error: "error"
            @unknown default: "unknown"
            }
        } catch {
            failure = "\(error)"
        }
        ExperimentLog.record(["test": "EXP-LEM-003", "scheme": NLTagScheme.nameType.rawValue, "result": result,
                              "ms": ContinuousClock.now - start, "error": failure])
        ExperimentLog.record(["test": "EXP-LEM-003", "when": "after"], Self.schemes())
    }

    private static func schemes() -> KeyValuePairs<String, Any> {
        let schemes = NLTagger.availableTagSchemes(for: .word, language: .english)
        return ["schemes": schemes.map(\.rawValue).sorted().joined(separator: ","), "name_type": schemes.contains(.nameType)]
    }
}
