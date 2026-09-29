# ReadStair

ReadStair underlines the words you may not know in an English book: take a photo of a printed page, or open a DRM-free EPUB or plain text file. It estimates your vocabulary level, marks only the words above it, and explains any word you tap.

## What it does

- **Add a book.** Scan pages with the iOS document scanner, or choose photos of printed pages; Apple's on-device text recognition reads them. Or choose an EPUB without copy protection, or a plain text file, from Files: ReadStair lays it out into pages on the iPhone, and they open already marked. ReadStair reads English books only.
- **Books.** Your books appear as a grid of covers with their titles; an EPUB shows its own cover, if it has one. Once you're past a book's first page, a green line under its cover shows how far you've read. Tap one to open its page: Read opens the book where you left off, and an EPUB with a table of contents lists its chapters, so you can go straight to one. The book's More menu renames or deletes it. A sample book comes with the app: the first chapter of *Alice's Adventures in Wonderland*, which is in the public domain.
- **See only the new words.** Words above your level get a red underline. On first launch, a short word check estimates your level: you tap the words you know, and some of the words aren't real. Skip it and you start at 3,000 words. You can change the level anytime in How Many to Mark, which has six levels from 1,000 to 12,000 words.
- **Tap any word.** The word card shows:
  - the word and its sentence, translated by Apple Translation into the language set in Translate To;
  - In This Sentence, an explanation from Apple Intelligence, where it is available and turned on;
  - a speaker button that pronounces the word, and Look Up for the iOS dictionary.

  I Know This stops marking a word in every book. Mark as New adds a word that isn't underlined. You can undo both.
- **Word List.** Words above your level that you open, and words you mark as new, are kept with the sentence you first saw them in, grouped by book. While that book is still in Books, Go to Page takes you back to the page.

The interface is in English. Translations of words and sentences come in the language set in Translate To.

## Privacy

ReadStair has no server and no account. It has no analytics, ads, tracking or third-party code. Your books, their pages and their text stay on your iPhone and in its backups; a book file you open is read once and not kept. Text recognition, e-book layout, translation, explanations and speech run on the iPhone through iOS frameworks; iOS downloads a translation language once when needed. The only data ReadStair sends anywhere is your word list, with the sentence you first saw each word in, and your vocabulary level. They sync through your own private iCloud database when you're signed in to iCloud. See [PRIVACY.md](PRIVACY.md).

## Requirements

- An iPhone with iOS 26 or later.
- English books: printed pages, or EPUB (without copy protection) or plain text files.
- Translation: a language that Apple Translation supports.
- In This Sentence: Apple Intelligence, available and turned on.
- To build the app: a Mac with macOS 26 and Xcode 26.6 or later.

## Build from source

```sh
git clone https://github.com/OAK-WJR/readstair.git
cd readstair
git config core.hooksPath .githooks   # checks run before each commit
open App/ReadStair.xcodeproj
```

- **Simulator:** choose an iOS 26 simulator and run. You don't need to sign anything. The simulator has no camera, so add a book with Choose from Photos or Choose from Files.
- **Device:** copy `Config/Local.xcconfig.template` to `Config/Local.xcconfig`, which git ignores. Set your `DEVELOPMENT_TEAM` and your own `READSTAIR_BUNDLE_ID` there. Signing settings go only in that file, never in the project file.
- **iCloud sync** is off by default. Without it the app works the same, but nothing syncs. To build it in, set `READSTAIR_ICLOUD = YES` in `Config/Local.xcconfig`, or pass `READSTAIR_ICLOUD=YES` to `xcodebuild`. This adds the iCloud entitlements, the remote-notification background mode and the code that starts sync.
  - A signed build with the switch needs a paid developer team that owns the app's iCloud container, `iCloud.app.readstair`.
  - A fork that wants sync must use its own container: change it in `App/ReadStair/ReadStair.entitlements` and in `WordSync.containerIdentifier`.
  - Don't use Xcode's Signing & Capabilities editor on the app target: it replaces the entitlements setting that the switch controls.

## Tests

The core package tests run on the Mac (`cd Packages/ReadStairCore && swift test`), and the UI tests run on an iOS 26 simulator. [CONTRIBUTING.md](CONTRIBUTING.md) has the commands, the environment variables that turn on the performance records, on-device experiments and iCloud sync checks, and what CI (`.github/workflows/ci.yml`) checks on every pull request.

## License and third-party notices

The code is under the PolyForm Noncommercial License 1.0.0 ([LICENSE](LICENSE)): anyone may use, change and share it for any noncommercial purpose, such as personal study, research, teaching or a hobby project; commercial use is not licensed. The app ships two pieces of third-party material, each under its own license: its word list and its sample book. `tools/make-lexicon.py` generates the word list from wordfreq, the New General Service List and WordNet, and `python3 tools/make-lexicon.py --check` checks that the committed copy matches; the list is distributed under CC BY-SA 4.0 together with the WordNet 3.0 license. The sample book, `App/ReadStair/SampleBook/alice.epub`, holds Chapter I of *Alice's Adventures in Wonderland* by Lewis Carroll (1865), which is in the public domain; `tools/make-epub.sh` packages it, unchanged, from the Standard Ebooks edition, which is dedicated to the public domain under CC0 1.0. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) credits every source. The folders in `Data/` and `Fixtures/` hold the generator inputs and test data (`Fixtures/` also holds the sample book's chapter, and the whole book as `Fixtures/alice-whole.epub` for tests only), and each has its own `LICENSE` and `ATTRIBUTION.md`. The test pages are rendered from public-domain text.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Open an issue before you start a feature or change the UI: ReadStair keeps screens and options to a minimum. Bug fixes, tests and documentation fixes can go straight to a pull request. This repository holds one commit per tested release, so accepted pull requests are not merged here: the change ships in the next release, credited to you. Report problems in the repository's issues.
