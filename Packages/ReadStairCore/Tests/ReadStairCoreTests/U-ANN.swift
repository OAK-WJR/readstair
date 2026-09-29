import CoreGraphics
import Testing
@testable import ReadStairCore

/// U-ANN-001–005: Annotator decides marking from the band and the explicit state, and never marks a word without a box.
@Suite("U-ANN Annotator")
struct AnnotatorTests {
    private func word(_ lemma: String, band: Int?, kind: PageWord.Kind = .word) -> PageWord {
        PageWord(surface: lemma, lemma: lemma, kind: kind, band: band,
                 quads: [Quad(CGRect(x: 0, y: 0, width: 0.05, height: 0.02))], sentence: 0)
    }

    @Test("U-ANN-001 Level 3k with no user state: only plain words with band > 3 are marked; names, numbers, punctuation are not")
    func levelOnly() {
        let page = PageText(words: [
            word("the", band: 1),
            word("rabbit", band: 5),
            word("alice", band: 6, kind: .name),
            word("1865", band: nil, kind: .number),
            word("waistcoat", band: 14),
            word("\u{201C}", band: nil, kind: .punct),
            word("consider", band: 3),
            word("hedge", band: 9),
            word("xyzzy", band: nil),
            word("go", band: 1),
        ], sentences: [""])
        // A plain word with band nil (not in the word list) counts as unfamiliar and is marked
        #expect(Annotator.markedWords(in: page, level: 3, states: [:]) == [1, 4, 7, 8])
    }

    @Test("U-ANN-002 Same lemma 5 times on a page: all marked; one state change updates the whole page")
    func sameLemmaEverywhere() {
        var words = (0..<5).map { _ in word("rabbit", band: 5) }
        words.insert(word("the", band: 1), at: 2)
        let page = PageText(words: words, sentences: [""])
        #expect(Annotator.markedWords(in: page, level: 3, states: [:]) == [0, 1, 3, 4, 5])
        #expect(Annotator.markedWords(in: page, level: 3, states: ["rabbit": .known]).isEmpty)
    }

    @Test("U-ANN-003 A band=2 word the user set to learning is marked (explicit state overrides band)")
    func learningOverridesBand() {
        let page = PageText(words: [word("well", band: 2), word("the", band: 1)], sentences: [""])
        #expect(Annotator.markedWords(in: page, level: 3, states: ["well": .learning]) == [0])
    }

    @Test("U-ANN-004 A band=9 word the user set to known is not marked")
    func knownOverridesBand() {
        let page = PageText(words: [word("hedge", band: 9), word("daisy", band: 8)], sentences: [""])
        #expect(Annotator.markedWords(in: page, level: 3, states: ["hedge": .known]) == [1])
    }

    @Test("U-ANN-005 A word without a box (the title on a book's own cover) is never marked, even set to learning or above the level")
    func boxlessNeverMarked() {
        var alice = word("alice", band: 9)
        alice.quads = []
        let page = PageText(words: [alice, word("rabbit", band: 5)], sentences: [""])
        #expect(Annotator.markedWords(in: page, level: 3, states: ["alice": .learning]) == [1])
        #expect(Annotator.markedWords(in: page, level: 3, states: [:]) == [1])
    }
}

extension Annotator {
    /// The tests' way to give saved states: keyed by `PageWord.stateKey`, as the store keeps them.
    static func markedWords(in page: PageText, level: Int, states: [String: WordState]) -> [Int] {
        markedWords(in: page, level: level) { states[page.words[$0].stateKey] }
    }
}
