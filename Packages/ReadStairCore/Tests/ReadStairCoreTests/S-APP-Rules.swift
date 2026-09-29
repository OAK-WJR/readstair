import CoreGraphics
import Foundation
import Testing
@testable import ReadStairCore

// The pure rules the app builds on: the key a word's state is looked up by, what opening a word card writes (U-STA-001, whose undo
// cases are in S-APP-Loop.swift), whether a page counts as English, and the Word List's groups. All but U-STA-001 are supplementary.

private func ruleWord(_ lemma: String, band: Int?, kind: PageWord.Kind = .word) -> PageWord {
    PageWord(surface: lemma, lemma: lemma, kind: kind, band: band, quads: [Quad(CGRect(x: 0, y: 0, width: 0.05, height: 0.02))],
             sentence: 0)
}

private func shelfBook(_ title: String) -> Book {
    Book(id: UUID(), title: title, createdAt: .now, lastPageIndex: 0)
}

private func listEntry(_ lemma: String, band: Int?, book: UUID?, state: WordState = .learning) -> WordEntry {
    WordEntry(lemma: lemma, state: state, source: .lookup, band: band, firstBookID: book)
}

/// Exactly 20 French words.
private let frenchTwentyWords = "Le petit prince habitait une planète à peine plus grande que lui et il avait besoin d'un ami pour partager"

@Suite("Supplementary: State key")
struct StateKeyTests {
    @Test("A word whose accent OCR returned decomposed (NFD) finds the state stored under the precomposed (NFC) key, and its key matches the stored key byte for byte")
    func decomposedAccentFindsStoredState() async throws {
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            try await store.upsertWord(WordEntry(lemma: "caf\u{E9}", state: .known, source: .card, band: 9))
            try await store.upsertWord(WordEntry(lemma: "nai\u{308}ve", state: .learning, source: .card, band: 1))
            let stored = try await store.wordEntries()
            let states = Dictionary(uniqueKeysWithValues: stored.map { ($0.lemma, $0.state) })
            // NFD café with band 9 would be marked at level 3 without its known state; NFC naïve with band 1 only with its learning state
            let page = PageText(words: [ruleWord("cafe\u{301}", band: 9), ruleWord("na\u{EF}ve", band: 1), ruleWord("hedge", band: 9)],
                                sentences: [""])
            #expect(Annotator.markedWords(in: page, level: 3, states: states) == [1, 2])
            // Swift's String == treats NFC and NFD as equal, so compare the bytes the store and CloudKit record names see
            #expect(Set(stored.map { Array($0.lemma.utf8) }) == Set(page.words.prefix(2).map { Array($0.stateKey.utf8) }))
            #expect(Array(page.words[0].stateKey.utf8) == Array("caf\u{E9}".utf8))
        }
    }

    @Test("The lookup folds case like the store key: a lemma with a capital finds the lowercase stored state")
    func caseIsFolded() {
        let page = PageText(words: [ruleWord("Hedge", band: 9), ruleWord("Well", band: 2)], sentences: [""])
        #expect(Annotator.markedWords(in: page, level: 3, states: ["hedge": .known, "well": .learning]) == [1])
        #expect(page.words.map(\.stateKey) == ["hedge", "well"])
    }
}

@Suite("U-STA Word card entry on open")
struct EntryOnOpenTests {
    private let bookID = UUID(), pageID = UUID()

    /// For each level, the bands (of nil, 1, 3, 4, 25) that write when the state is nil and the word is plain: those above the level.
    private static let writingBands: [Int: [Int?]] = [1: [3, 4, 25], 3: [4, 25], 25: []]

    @Test("U-STA-001 Truth table over state × kind × band × level: writes only with no state, a plain word and a band above the level; when it writes, the word was already marked and stays marked",
          arguments: [WordState?.none, .learning, .known], [PageWord.Kind.word, .name, .number, .punct])
    func truthTable(state: WordState?, kind: PageWord.Kind) {
        for (level, writing) in Self.writingBands {
            let expected = state == nil && kind == .word ? writing : []
            var written: [Int?] = []
            for band in [nil, 1, 3, 4, 25] as [Int?] {
                let word = ruleWord("peep", band: band, kind: kind)
                guard WordEntry.entryOnOpen(word: word, state: state, level: level, bookID: bookID, pageID: pageID,
                                            sentence: nil) != nil else { continue }
                written.append(band)
                #expect(Annotator.isMarked(word, level: level, state: state) && Annotator.isMarked(word, level: level, state: .learning))
            }
            #expect(written == expected, "level \(level)")
        }
    }

    @Test("U-STA-001 The entry: learning, looked up, the word's band, the store key (NFC) and the card's first-seen context")
    func entryContents() throws {
        let word = PageWord(surface: "Caf\u{E9}s,", lemma: "cafe\u{301}", kind: .word, band: 9, quads: [], sentence: 0)
        let entry = try #require(WordEntry.entryOnOpen(word: word, state: nil, level: 3, bookID: bookID, pageID: pageID,
                                                       sentence: "They met in cafés."))
        #expect(Array(entry.lemma.utf8) == Array("caf\u{E9}".utf8))
        #expect(entry.state == .learning && entry.source == .lookup && entry.band == 9)
        #expect(entry.firstBookID == bookID && entry.firstPageID == pageID && entry.firstSentence == "They met in cafés.")
    }

    @Test("U-STA-001 Bundled lexicon at the default level 3: peeped (peep, band 9) writes; the (1), garden (2) and waistcoat-pocket (no band, marked all the same) do not")
    func bundledLexiconExamples() throws {
        let page = analyzeText("She peeped into the garden through a waistcoat-pocket.")
        let written = page.words.compactMap {
            WordEntry.entryOnOpen(word: $0, state: nil, level: 3, bookID: bookID, pageID: pageID, sentence: page.sentences.first)
        }
        #expect(written.map(\.lemma) == ["peep"])
        let pocket = try #require(page.words.first { $0.lemma == "waistcoat-pocket" })
        #expect(pocket.band == nil && Annotator.isMarked(pocket, level: 3, state: nil))
    }
}

@Suite("Supplementary: Page language")
struct PageLanguageTests {
    @Test("English: the recognized Alice page, and English prose full of accented loanwords")
    func english() throws {
        let truth = try JSONDecoder().decode(RecognitionIntegrationTests.Truth.self,
                                             from: Data(contentsOf: fixtureURL("Fixtures/alice-p1.json")))
        let alice = PageAnalyzer.analyze(truth.words.map { RecognizedWord(text: $0.text, quads: []) }, lexicon: .bundled)
        try #require(alice.words.count > 200)
        #expect(PageLanguage.isEnglish(alice))
        #expect(PageLanguage.isEnglish(analyzeText(
            "After a long walk she stopped at a little café where the naïve waiter handed her a menu, and her fiancé read his résumé aloud over the crème brûlée while it rained.")))
    }

    @Test("Other languages in Latin script, 20 words or more, are not English", arguments: [
        frenchTwentyWords + " ses journées.",
        "Der kleine Junge ging jeden Morgen mit seinem Hund durch den Wald und sah dort viele Vögel, die fröhlich in den Bäumen sangen.",
        "La niña caminaba todas las mañanas con su perro por el bosque y veía muchos pájaros que cantaban alegremente en los árboles.",
        "Il ragazzo camminava ogni mattina con il suo cane nel bosco e vedeva molti uccelli che cantavano allegramente sugli alberi del giardino.",
        "De kleine jongen liep elke ochtend met zijn hond door het bos en zag daar veel vogels die vrolijk in de bomen zongen.",
    ])
    func otherLanguages(text: String) {
        #expect(!PageLanguage.isEnglish(analyzeText(text)))
    }

    @Test("Short pages count as English: no words, and 19 French words with punctuation around them; the 20th word makes it French")
    func shortPages() throws {
        #expect(PageLanguage.isEnglish(PageText(words: [], sentences: [])))
        let nineteen = analyzeText("\u{AB} " + frenchTwentyWords.split(separator: " ").dropLast().joined(separator: " ") + " \u{2026} \u{BB} \u{2014}")
        try #require(nineteen.words.count(where: { $0.kind != .punct }) == 19 && nineteen.words.count > 19)
        #expect(PageLanguage.isEnglish(nineteen))
        let twenty = analyzeText(frenchTwentyWords)
        try #require(twenty.words.count(where: { $0.kind != .punct }) == 20)
        #expect(!PageLanguage.isEnglish(twenty))
    }

    /// Only a confident verdict hides a page. Measured on macOS 26: the garbled page reads as English at 0.47, the placeholder Latin as
    /// French at 0.62; both well under 0.8.
    @Test("Unsure recognizer: badly recognized English and placeholder Latin (lorem ipsum) count as English")
    func unsureCountsAsEnglish() {
        #expect(PageLanguage.isEnglish(analyzeText(
            "tbe qnick brovvn f0x jnmps ovcr tlie lazv dog aud tben rnns avvay into tbe vvoods wbere it bides nnder a big rock all day")))
        #expect(PageLanguage.isEnglish(analyzeText(
            "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam")))
    }
}

@Suite("Supplementary: Word List sections")
struct WordListSectionsTests {
    @Test("Learning words only, grouped by book in shelf order, Other last (first book deleted, pending deletion or unknown); band ascending with no band last, then lemma")
    func grouping() {
        let newest = shelfBook("Newest"), pending = shelfBook("Pending deletion"), empty = shelfBook("No words"), oldest = shelfBook("Oldest")
        let deleted = UUID()
        let entries = [
            listEntry("tarry", band: 5, book: oldest.id),
            listEntry("brook", band: 2, book: oldest.id),
            listEntry("zephyr", band: nil, book: oldest.id),
            listEntry("apple", band: 2, book: oldest.id),
            listEntry("peep", band: 9, book: newest.id),
            listEntry("hedge", band: 9, book: newest.id, state: .known),
            listEntry("quill", band: 12, book: pending.id),
            listEntry("shelter", band: 4, book: nil),
            listEntry("vellum", band: nil, book: deleted),
            listEntry("ardent", band: 12, book: deleted),
            listEntry("daisy", band: 3, book: nil, state: .known),
            listEntry("thimble", band: 8, book: empty.id, state: .known),
        ]
        let sections = WordListSections.make(entries: entries, books: [newest, pending, empty, oldest], hiddenBookID: pending.id)
        #expect(sections.map(\.id) == [newest.id, oldest.id, nil])
        #expect(sections.map { $0.entries.map(\.lemma) } == [["peep"], ["apple", "brook", "tarry", "zephyr"], ["shelter", "ardent", "quill", "vellum"]])
    }

    @Test("No learning words: no sections at all, not even an empty Other")
    func empty() {
        let book = shelfBook("Alice")
        #expect(WordListSections.make(entries: [], books: [book], hiddenBookID: nil).isEmpty)
        #expect(WordListSections.make(entries: [listEntry("hedge", band: 9, book: book.id, state: .known)], books: [book],
                                      hiddenBookID: nil).isEmpty)
    }
}
