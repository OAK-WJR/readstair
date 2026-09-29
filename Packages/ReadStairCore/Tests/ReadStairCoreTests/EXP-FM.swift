import Foundation
import FoundationModels
import Testing
@testable import ReadStairCore

/// Device experiment: Apple Intelligence (the on-device Foundation Models) explaining each evaluation item's word in its sentence, with
/// the word card's own prompt (`SentenceMeaning`), meanings in Simplified Chinese. Each item gets a new session, as each word card does. Without the model the run is skipped and EXP-FM-001 records
/// why. Output: one `[EXP-TSV] EXP-FM` row per item, then `[EXP]` summaries of time and of errors by kind. Other suites would compete for
/// the device and skew the times and rate limits, so run the suite on its own: xcodebuild with `TEST_RUNNER_READSTAIR_EXPERIMENT=1` and
/// `-only-testing:ReadStairCoreTests/FoundationModelsGlossExperiment`, or on a Mac `READSTAIR_EXPERIMENT=1 swift test --filter
/// FoundationModelsGlossExperiment`.
@Suite("EXP-FM Apple Intelligence glosses", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_EXPERIMENT"] == "1", "Set READSTAIR_EXPERIMENT=1 to run"))
struct FoundationModelsGlossExperiment {
    /// Error kinds counted on their own; every other error is `other`.
    private enum ErrorKind: String {
        case guardrailViolation, refusal, rateLimited, exceededContextWindowSize, unsupportedLanguageOrLocale, other

        init(_ error: any Error) {
            guard let error = error as? LanguageModelSession.GenerationError else {
                self = .other
                return
            }
            self = switch error {
            case .guardrailViolation: .guardrailViolation
            case .refusal: .refusal
            case .rateLimited: .rateLimited
            case .exceededContextWindowSize: .exceededContextWindowSize
            case .unsupportedLanguageOrLocale: .unsupportedLanguageOrLocale
            default: .other
            }
        }
    }

    @Test("EXP-FM-001 Model availability, and whether Simplified Chinese is a supported language")
    func availability() {
        ExperimentLog.recordEnvironment(test: "EXP-FM-001")
        let model = SystemLanguageModel.default
        let availability = switch model.availability {
        case .available: "available"
        case .unavailable(.deviceNotEligible): "deviceNotEligible"
        case .unavailable(.appleIntelligenceNotEnabled): "appleIntelligenceNotEnabled"
        case .unavailable(.modelNotReady): "modelNotReady"
        case .unavailable: "unavailableForAnotherReason"
        }
        // Maximal identifiers fill in the script, so "zh" and "zh-CN" both read as zh-Hans-CN
        let languages = model.supportedLanguages.map(\.maximalIdentifier).sorted()
        ExperimentLog.record(["test": "EXP-FM-001", "availability": availability,
                              "supports_zh_hans": languages.contains { $0.hasPrefix("zh-Hans") }, "languages": languages.joined(separator: ",")])
    }

    /// An item's time covers creating the session and the response; the summary's times are over successful items. The prompt's
    /// dictionary form is the headword the app derives, as the card would have it; each row logs it (empty when unknown, and the
    /// reference headword is used instead) next to the reference one.
    @Test("EXP-FM-002 Explain each item's word in its sentence, a new session per item: output, time and error kind",
          .enabled(if: SystemLanguageModel.default.isAvailable, "The Apple Intelligence model is unavailable (EXP-FM-001 records why)"))
    func explainEvalSet() async throws {
        ExperimentLog.recordEnvironment(test: "EXP-FM-002")
        let items = try GlossEvalItem.load()
        #expect(items.count == 200)
        let chinese = Locale.Language(identifier: "zh-Hans")
        var times: [Duration] = []
        var errors: [ErrorKind: Int] = [:]
        ExperimentLog.row("EXP-FM", "id", "headword", "app_headword", "meaning", "explanation", "example", "ms", "error")
        for item in items {
            let appHeadword = item.appHeadword()
            let start = ContinuousClock.now
            do {
                let answer = try await SentenceMeaning.explain(appHeadword ?? item.headword, printed: item.word, in: item.sentence,
                                                               language: chinese).answer
                let elapsed = ContinuousClock.now - start
                times.append(elapsed)
                ExperimentLog.row("EXP-FM", item.id, item.headword, appHeadword ?? "", answer.meaningHere, answer.explanation, answer.example,
                                  ExperimentLog.ms(elapsed), "")
            } catch {
                let kind = ErrorKind(error)
                errors[kind, default: 0] += 1
                ExperimentLog.row("EXP-FM", item.id, item.headword, appHeadword ?? "", "", "", "",
                                  ExperimentLog.ms(ContinuousClock.now - start), "\(kind.rawValue): \(error)")
            }
        }
        ExperimentLog.record(["test": "EXP-FM-002", "items": items.count, "first_ms": times.first ?? .zero,
                              "median_ms": percentile(0.5, times), "p90_ms": percentile(0.9, times), "max_ms": times.max() ?? .zero,
                              "thermal": thermalState()])
        let count = { (kind: ErrorKind) in errors[kind, default: 0] }
        ExperimentLog.record(["test": "EXP-FM-002", "errors": items.count - times.count, "guardrailViolation": count(.guardrailViolation),
                              "refusal": count(.refusal), "rateLimited": count(.rateLimited),
                              "exceededContextWindowSize": count(.exceededContextWindowSize),
                              "unsupportedLanguageOrLocale": count(.unsupportedLanguageOrLocale), "other": count(.other)])
    }
}
