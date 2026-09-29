import Foundation
import NaturalLanguage
import Testing
@testable import ReadStairCore

/// NLTagger's English name-type model can be missing (a fresh iOS 26.5 Simulator lacked it); macOS has it. Only name detection needs it.
private let hasNameAssets = NLTagger.availableTagSchemes(for: .word, language: .english).contains(.nameType)

/// Supplementary cases: the bundled lexicon and PageAnalyzer. Lemmas and bands come from the lexicon alone, so every case except name
/// detection runs in every environment.
@Suite("Supplementary: Lexicon / PageAnalyzer")
struct LexiconTests {
    @Test("Bundled lexicon: common lemmas in band 1, non-ASCII lemmas included, a compound takes its hardest piece; words outside the table have no band")
    func bundledTable() throws {
        let lexicon = Lexicon.bundled
        #expect(lexicon.band(ofLemma: "the") == 1)
        #expect(lexicon.band(ofLemma: "café") != nil)
        let rabbit = try #require(lexicon.band(ofLemma: "rabbit")), hole = try #require(lexicon.band(ofLemma: "hole"))
        #expect(lexicon.band(ofLemma: "rabbit-hole") == max(rabbit, hole))
        for lemma in ["waistcoat", "loveliness", "xyzzyq", "rabbit-xyzzyq"] {
            #expect(lexicon.band(ofLemma: lemma) == nil, "\(lemma)")
        }
    }

    @Test("Lemmas, bands, sentences, numbers and punctuation, the same with or without NLTagger's assets (went → go)")
    func analyzesSentence() {
        let page = analyzeText("Alice was considering the daisies. She went down the rabbit-holes in 1865 \u{201C}")
        #expect(page.sentences.count == 2)
        #expect(page.words.map(\.lemma) == ["alice", "be", "consider", "the", "daisy", "she", "go", "down", "the",
                                            "rabbit-hole", "in", "1865", ""])
        #expect(page.words.map(\.sentence) == [0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1])
        #expect(page.words[2].headword == "consider")
        #expect(page.words[2].band == Lexicon.bundled.band(ofLemma: "consider"))
        #expect(page.words[6].band == Lexicon.bundled.band(ofLemma: "go"))
        #expect(page.words[11].kind == .number)
        #expect(page.words[12].kind == .punct)
    }

    @Test("Numbers: uppercase Roman numerals and tokens with digits are numbers, never marked or written on open; a lone I stays a word")
    func numbers() {
        let page = analyzeText("CHAPTER VII. On the 19th of May in the 1860s I left. CHAPTER XII.")
        let numbers = [1, 4, 9, 13]
        #expect(numbers.map { page.words[$0].surface } == ["VII.", "19th", "1860s", "XII."])
        #expect(numbers.allSatisfy { page.words[$0].kind == .number })
        #expect(page.words[10].surface == "I" && page.words[10].kind == .word)
        #expect(Set(Annotator.markedWords(in: page, level: 3, states: [:])).isDisjoint(with: numbers))
        for i in numbers {
            #expect(WordEntry.entryOnOpen(word: page.words[i], state: nil, level: 3, bookID: UUID(), pageID: UUID(), sentence: nil) == nil)
        }
    }

    @Test("Names: Alice is a name, shown as printed", .enabled(if: hasNameAssets, "No NLTagger English name-type assets in this environment"))
    func names() {
        let page = analyzeText("Alice was considering the daisies.")
        #expect(page.words[0].kind == .name && page.words[0].headword == "Alice")
    }

    @Test("A contraction is its own lemma, attached punctuation is dropped: \"I don't like the book,\" she said.")
    func contractionsAndPunctuation() {
        let page = analyzeText("\"I don't like the book,\" she said.")
        #expect(page.words.map(\.lemma) == ["i", "don't", "like", "the", "book", "she", "say"])
        #expect(page.words.allSatisfy { $0.kind == .word })
        #expect(page.words[1].band == 1)
    }

    @Test("Compounds: adjectival ones stay whole, a plural last piece is reduced, and a possessive is dropped first (rabbit-hole's)")
    func compounds() {
        let page = analyzeText("the well-known three-legged rabbit-holes and the rabbit-hole's edge")
        #expect(page.words.map(\.lemma) == ["the", "well-known", "three-legged", "rabbit-hole", "and", "the", "rabbit-hole", "edge"])
        #expect(page.words[6].band != nil)
    }

    @Test("Possessives are dropped: Alice's → alice")
    func possessive() {
        let page = analyzeText("Alice's sister")
        #expect(page.words[0].lemma == "alice")
        #expect(page.words[0].band == Lexicon.bundled.band(ofLemma: "alice"))
    }
}
