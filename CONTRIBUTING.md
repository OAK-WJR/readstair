# Contributing to ReadStair

This page covers what you need to build and test ReadStair, the rules the hooks and CI enforce, and how to propose a change.

## Propose first

- **Open an issue before starting a feature or changing the UI.** Bug fixes, tests and documentation fixes can go straight to a pull request.
- ReadStair aims for the fewest screens and interactions that do the job. A new screen, setting, button or option has to justify itself: who needs it, why the existing flow can't serve them, and what it costs everyone else. Proposals that remove or merge something are just as welcome.
- ReadStair works offline, has no account and collects no data. Changes must keep [`PRIVACY.md`](PRIVACY.md) true.

## Prerequisites

- macOS 26 and Xcode 26.6 or later (iOS 26 SDK). The core package's tests run on the Mac itself, which needs macOS 26.
- An iOS 26 simulator; CI uses an iPhone 17 Pro.
- Only to regenerate the word list: Python 3 with `wordfreq==3.1.1`, installed in a virtual environment outside the repository.

## Setup

```sh
git config core.hooksPath .githooks
```

The pre-commit, pre-merge-commit and commit-msg hooks run `tools/check-secrets.sh`, the same check CI runs on every tracked file. To also block your own names, host names and device IDs, list them one per line in `.git/info/private-terms`, which is never committed; list each spelling you use (with a space, a hyphen, an underscore, run together). Other addresses your commit messages may carry can be listed one per line in `.git/info/allowed-emails`, which is never committed. The pre-push hook only stops pushes straight to OAK-WJR/readstair; push to your fork. `tools/export-release.sh`, `tools/release-gate.sh` and `tools/check-package.sh` serve the maintainers' releases; contributors don't need them.

Simulator builds need no signing. To run on a device, copy `Config/Local.xcconfig.template` to `Config/Local.xcconfig` (git-ignored) and set your own `DEVELOPMENT_TEAM` and `READSTAIR_BUNDLE_ID` there.

iCloud sync is compiled in only with `READSTAIR_ICLOUD = YES` in `Config/Local.xcconfig` (or `READSTAIR_ICLOUD=YES` on the xcodebuild command line), which needs the team that owns the `iCloud.app.readstair` container, or your own container (see the README). Leave it unset otherwise; see `Config/Shared.xcconfig`.

## Build and test

Core package (recognition, word bands, storage, sync, import queue), on the Mac:

```sh
cd Packages/ReadStairCore && swift test
```

This includes the recognition integration tests, which run real Vision recognition on the pages in `Fixtures/` and take a while.

App and UI tests, on the simulator (the UI tests read their fixtures from the Mac's disk):

```sh
xcodebuild test -project App/ReadStair.xcodeproj -scheme ReadStair \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

`tools/report-tests.sh` turns `.xcresult` bundles and `swift test` logs into a Markdown summary.

### Opt-in suites and run settings

Slow, noisy or device-oriented suites are skipped unless an environment variable enables them. Run each on its own, for example `READSTAIR_PERF=1 swift test --filter ImportPerformanceTests`. On a device, run the core package's suites from its own directory and scheme (the app's scheme holds only the UI tests). xcodebuild hands a variable to the test runner only with a `TEST_RUNNER_` prefix, which it strips, and `-xcconfig` applies the signing team in `Config/Local.xcconfig` to the package too:

```sh
cd Packages/ReadStairCore
TEST_RUNNER_READSTAIR_EXPERIMENT=1 xcodebuild test -scheme ReadStairCore -destination 'platform=iOS,name=<device name>' \
  -xcconfig ../../Config/Local.xcconfig -only-testing:ReadStairCoreTests/RecognitionSpeedTests
```

| Variable | Enables or sets |
|---|---|
| `READSTAIR_PERF=1` | Performance records: `ImportPerformanceTests`, `SyncPerformanceTests`, `TypesetPerformanceTests`, `WordListPerformanceTests` |
| `READSTAIR_EXPERIMENT=1` | Recognition speed and memory (`RecognitionSpeedTests`, `RecognitionMemoryTests`), the on-device experiments (`LemmaAssetExperiment`, `TranslationGlossExperiment`, `FoundationModelsGlossExperiment`) and the synthetic-reader replay (`SyntheticReaderReplay`, on a Mac) |
| `READSTAIR_ALLOW_ASSET_REQUEST=1` | With `READSTAIR_EXPERIMENT=1`: lets `LemmaAssetExperiment` request NLTagger assets, which may download them |
| `READSTAIR_REAL_BOOKS=<dir>` | `RealBookContentsExperiment`: the tables of contents of real e-books in that folder, which are not in the repository (the suite's comment lists them), on a Mac |
| `TEST_RUNNER_READSTAIR_APPEARANCE` | UI tests: `light` or `dark` (CI uses `light`); unset keeps the simulator's appearance |
| `TEST_RUNNER_READSTAIR_CONTENT_SIZE` | UI tests: `AX5` or any `UIContentSizeCategory` raw value; unset is the default text size |
| `TEST_RUNNER_READSTAIR_TRANSLATE_INTO` | UI tests: a language whose Apple Translation pack is already installed on the simulator, such as `zh-Hans`; unset, word cards translate nothing |
| `READSTAIR_PERF_STORE` | `PerfStoreFixture`: builds the store the app's performance gates (`PerformanceGateTests`) run on, in that folder; `TEST_RUNNER_READSTAIR_PERF_STORE` points the gates at it (default `build/perf-store`) |
| `TEST_RUNNER_READSTAIR_SYNC_SELFTEST=1` | `SyncSelfTestTests`: the iCloud sync checks I-SYNC-001 to 006, run by a DEBUG app built with `READSTAIR_ICLOUD=YES` on a device signed in to iCloud; writes to that account's development environment |

### What CI checks

Every pull request runs `.github/workflows/ci.yml`: `tools/check-secrets.sh`, a gitleaks scan of the full history, `make-lexicon.py --check`, `book-eval.py --self-test`, the core package and UI tests with Xcode 26.6, a build with the iCloud switch on, and an Xcode 27 build in which using a deprecated API is an error (skipped with a warning while the runner image has no Xcode 27).

## Repository rules

- **English only.** Code, comments, documentation and commit messages are in English. Translations belong in localization resources such as String Catalogs (`*.xcstrings`), which the check exempts.
- **No secrets or personal identifiers.** No keys, certificates, provisioning profiles, Team IDs, device identifiers (UDIDs) or email addresses (`example.com` and `noreply` addresses are fine), and no file over 5 MB.
- **Signing stays local.** Team IDs and other signing settings go only in the git-ignored `Config/Local.xcconfig`, never in the project file or `Config/Shared.xcconfig`.
- **Data carries its license.** Every data directory (each folder in `Data/`, `Fixtures/`, and the bundled word list) has a `LICENSE` and an `ATTRIBUTION.md` naming its source and license; a unit test fails when either is missing. The sample book, `App/ReadStair/SampleBook/alice.epub`, carries no `LICENSE` of its own, because files in that folder ship in the app bundle; `Fixtures/LICENSE` and `Fixtures/ATTRIBUTION.md` cover it. Add only data whose license allows redistribution.
- **The word list is generated.** Never edit `Packages/ReadStairCore/Sources/ReadStairCore/Resources/lexicon/` or `THIRD_PARTY_NOTICES.md` by hand. Change the inputs in `Data/` (reviewed lemma decisions go in `Data/lexicon/overrides.tsv`) or `tools/make-lexicon.py`, run `python3 tools/make-lexicon.py`, commit its output with the change, and confirm `python3 tools/make-lexicon.py --check` passes.

## Code style

- Swift 6 language mode. The app target is MainActor-isolated by default; `ReadStairCore` is nonisolated by default.
- Match the surrounding code in naming, structure and formatting. There is no formatter to satisfy, so leave unrelated lines alone.
- Comments explain why, not what: the constraint, measurement or trade-off behind the code.
- New unit tests use Swift Testing (`import Testing`) in `Packages/ReadStairCore/Tests/ReadStairCoreTests/`, next to the tests for the same area; UI tests use XCTest in `App/ReadStairUITests/`. Gate anything slow or device-only behind an environment variable, as the suites above do. A bug fix comes with a test that fails without it.
- No third-party dependencies (Swift packages, binaries, SDKs) without discussing them in an issue first. The project has none today.

## Pull requests

- One topic per pull request, with CI passing.
- Commit messages are English and imperative (`Add single-page deletion to the store`), with the reason in the body when it isn't obvious.
- Pull requests are not merged on GitHub. The public history holds one commit per tested release, so an accepted change is applied in the maintainer's development repository, tested with the next release, and credited in that release's commit with a `Co-authored-by` line using your GitHub noreply address.
- By opening a pull request you confirm that the change is your own work, and you grant the maintainer (OAK-WJR) a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to use, change, distribute, sublicense and relicense it on any terms, commercial ones included. The code is under the PolyForm Noncommercial License 1.0.0, and this lets the maintainer offer ReadStair on other terms later without asking every contributor.
- Say how you tested (simulator or device, iOS version), and attach screenshots for visible changes.
- Remove code, strings and assets your change leaves unused.
