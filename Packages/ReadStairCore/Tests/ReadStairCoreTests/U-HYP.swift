import CoreGraphics
import Testing
@testable import ReadStairCore

/// U-HYP-001–003: merging words hyphenated across lines, and splitting words printed joined by a dash.
@Suite("U-HYP Recognition.hyphenMerge and splitAtDashes")
struct HyphenMergeTests {
    private let lexicon: Set<String> = ["it", "is", "well", "known", "to", "all", "twenty", "one", "example", "an"]

    private func lines(_ texts: [[String]]) -> [[RecognizedWord]] {
        texts.enumerated().map { row, line in
            line.enumerated().map { column, text in
                RecognizedWord(text: text, quads: [Quad(CGRect(x: 0.1 * Double(column), y: 0.05 * Double(row),
                                                                width: 0.08, height: 0.02))])
            }
        }
    }

    @Test("U-HYP-001 well- + known → well-known; twenty- + one → twenty-one; merged words carry two boxes")
    func keepsHyphenWhenJoinedIsUnknown() {
        let merged = Recognition.hyphenMerge(lines([["It", "is", "well-"], ["known,", "twenty-"], ["one", "to", "all"]]),
                                             isKnown: lexicon.contains)
        #expect(merged.map(\.text) == ["It", "is", "well-known,", "twenty-one", "to", "all"])
        #expect(merged[2].quads.count == 2)
        #expect(merged[3].quads.count == 2)
    }

    @Test("U-HYP-001 supplementary: joined when the unhyphenated form is in the word list (exam- + ple → example)")
    func joinsWhenJoinedIsKnown() {
        let merged = Recognition.hyphenMerge(lines([["an", "exam-"], ["ple."]]), isKnown: lexicon.contains)
        #expect(merged.map(\.text) == ["an", "example."])
    }

    @Test("U-HYP-001 supplementary: if neither part is in the word list, it is a hyphenated rare word and is joined (antipa- + thies → antipathies)")
    func joinsRareWordBreaks() {
        let merged = Recognition.hyphenMerge(lines([["of", "antipa-"], ["thies,", "to"]]), isKnown: lexicon.contains)
        #expect(merged.map(\.text) == ["of", "antipathies,", "to"])
    }

    @Test("U-HYP-001 supplementary, bundled lexicon: a word, a compound, a compound whose first piece has forms but no band, a word whose second half is a suffix",
          arguments: [("rab-", "bits", "rabbits"), ("well-", "known", "well-known"), ("waistcoat-", "pocket", "waistcoat-pocket"),
                      ("earnest-", "ly", "earnestly")])
    func bundledLexicon(tail: String, head: String, expected: String) {
        #expect(Recognition.hyphenMerge(lines([[tail], [head]]), isKnown: Lexicon.bundled.knows).map(\.text) == [expected])
    }

    @Test("U-HYP-002 Line-final hyphen with an empty next line or no next line: no crash, word kept as is")
    func emptyNextLine() {
        #expect(Recognition.hyphenMerge(lines([["the", "well-"], [], ["known"]]), isKnown: lexicon.contains)
            .map(\.text) == ["the", "well-", "known"])
        #expect(Recognition.hyphenMerge(lines([["the", "well-"]]), isKnown: lexicon.contains).map(\.text) == ["the", "well-"])
        #expect(Recognition.hyphenMerge([], isKnown: lexicon.contains).isEmpty)
        #expect(Recognition.hyphenMerge(lines([["-"], ["known"]]), isKnown: lexicon.contains).map(\.text) == ["-", "known"])
    }

    @Test("U-HYP-003 Words joined by an em or en dash split, each with its share of the box and a band; a hyphen, or a dash between digits or at either end, does not")
    func splitsWordsJoinedByDash() throws {
        func split(_ text: String) -> [String] {
            Recognition.splitAtDashes(RecognizedWord(text: text, quads: [Quad(CGRect(x: 0.1, y: 0, width: 0.2, height: 0.02))])).map(\.text)
        }
        #expect(split("London\u{2013}Paris") == ["London", "\u{2013}", "Paris"])
        #expect(split("said,\u{2014}\u{201C}Oh") == ["said,", "\u{2014}", "\u{201C}Oh"])
        for text in ["well-known", "1850\u{2013}60", "\u{201C}\u{2014}yes,", "think\u{2014}\u{201D}"] {
            #expect(split(text) == [text])
        }

        // Eight characters: rain takes 4/8 of the box, the dash 1/8 and `and` 3/8 (binary fractions, so the corners compare exactly)
        let pieces = Recognition.splitAtDashes(RecognizedWord(text: "rain\u{2014}and",
                                                              quads: [Quad(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.0625))]))
        #expect(pieces.map(\.text) == ["rain", "\u{2014}", "and"])
        #expect(pieces.map(\.quads) == [[Quad(CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.0625))],
                                        [Quad(CGRect(x: 0.5, y: 0.5, width: 0.0625, height: 0.0625))],
                                        [Quad(CGRect(x: 0.5625, y: 0.5, width: 0.1875, height: 0.0625))]])
        let page = PageAnalyzer.analyze(pieces, lexicon: .bundled)
        try #require(page.words.map(\.lemma) == ["rain", "", "and"])
        #expect(page.words[1].kind == .punct && page.words[0].band != nil && page.words[2].band != nil)
    }
}
