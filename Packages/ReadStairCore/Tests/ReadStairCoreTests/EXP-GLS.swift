import Foundation
import Testing
import Translation

private let english = Locale.Language(identifier: "en")
private let simplifiedChinese = Locale.Language(identifier: "zh-Hans")

/// Device experiment: Apple Translation's glosses for the 200-item evaluation set, requested the way the word card requests them (the
/// headword the app derives, and the sentence, in one batch). It never downloads a language pack: without the installed en → zh-Hans pack
/// the run is skipped and EXP-GLS-001 records the pack's status. Output: one `[EXP-TSV] EXP-GLS` row per item, then an `[EXP]` summary.
/// Other suites would compete for the device and skew the times, so run the suite on its own: xcodebuild with
/// `TEST_RUNNER_READSTAIR_EXPERIMENT=1` and `-only-testing:ReadStairCoreTests/TranslationGlossExperiment`, or on a Mac
/// `READSTAIR_EXPERIMENT=1 swift test --filter TranslationGlossExperiment`.
@Suite("EXP-GLS Apple Translation glosses", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_EXPERIMENT"] == "1", "Set READSTAIR_EXPERIMENT=1 to run"))
struct TranslationGlossExperiment {
    /// `supported` means the pack can be downloaded but is not installed.
    @Test("EXP-GLS-001 Language pack status for en → zh-Hans (read only; never downloads)")
    func languagePack() async {
        ExperimentLog.recordEnvironment(test: "EXP-GLS-001")
        let availability = await LanguageAvailability().status(from: english, to: simplifiedChinese)
        let status = switch availability {
        case .installed: "installed"
        case .supported: "supported"
        case .unsupported: "unsupported"
        @unknown default: "unknown"
        }
        ExperimentLog.record(["test": "EXP-GLS-001", "status": status])
    }

    /// An item's time covers both requests; the summary's times are over successful items, the first one including model loading.
    /// Each row logs the reference headword and the app's (empty when unknown, and the reference one is sent instead).
    @Test("EXP-GLS-002 Translate each item's headword and sentence in one batch: output and time per item",
          .enabled("The en → zh-Hans language pack is not installed (EXP-GLS-001 records its status)") {
              await LanguageAvailability().status(from: english, to: simplifiedChinese) == .installed
          })
    func translateEvalSet() async throws {
        ExperimentLog.recordEnvironment(test: "EXP-GLS-002")
        let items = try GlossEvalItem.load()
        #expect(items.count == 200)
        // The installed-only initializer: a missing pack fails the request instead of offering a download
        let session = TranslationSession(installedSource: english, target: simplifiedChinese)
        var times: [Duration] = []
        ExperimentLog.row("EXP-GLS", "id", "headword", "app_headword", "word", "sentence", "ms", "error")
        for item in items {
            let appHeadword = item.appHeadword()
            let requests = [TranslationSession.Request(sourceText: appHeadword ?? item.headword, clientIdentifier: "word"),
                            TranslationSession.Request(sourceText: item.sentence, clientIdentifier: "sentence")]
            let start = ContinuousClock.now
            do {
                let responses = try await session.translations(from: requests)
                let elapsed = ContinuousClock.now - start
                times.append(elapsed)
                ExperimentLog.row("EXP-GLS", item.id, item.headword, appHeadword ?? "",
                                  responses.first { $0.clientIdentifier == "word" }?.targetText ?? "",
                                  responses.first { $0.clientIdentifier == "sentence" }?.targetText ?? "", ExperimentLog.ms(elapsed), "")
            } catch {
                ExperimentLog.row("EXP-GLS", item.id, item.headword, appHeadword ?? "", "", "",
                                  ExperimentLog.ms(ContinuousClock.now - start), "\(error)")
            }
        }
        ExperimentLog.record(["test": "EXP-GLS-002", "items": items.count, "errors": items.count - times.count,
                              "first_ms": times.first ?? .zero, "median_ms": percentile(0.5, times), "p90_ms": percentile(0.9, times),
                              "max_ms": times.max() ?? .zero, "thermal": thermalState()])
    }
}

/// The evaluation set is read only by the gated experiments, so it is checked on every run: a broken edit to it, or to its parser,
/// shows up here instead of in a device session.
@Suite("Supplementary: Gloss evaluation set")
struct GlossEvalSetTests {
    @Test("gloss-200.tsv parses into 200 items with unique ids; each word appears in its sentence and has a headword")
    func evalSet() throws {
        let items = try GlossEvalItem.load()
        #expect(items.count == 200)
        #expect(Set(items.map(\.id)).count == items.count)
        for item in items {
            #expect(item.sentence.contains(item.word) && !item.headword.isEmpty, "\(item.id)")
        }
    }
}
