import Foundation
import Testing
@testable import ReadStairCore

/// U-LEM-001–003: lemmas from the bundled lexicon, with no context and no NLTagger.
@Suite("U-LEM Lemmas")
struct LemmaTests {
    /// One row of Data/ud-ewt/lemma-500.tsv (its ATTRIBUTION.md describes the sources, the sampling and the audit of `also`).
    struct Row {
        var form: String
        /// The gold reading: a lemma, or a contraction's parts separated by spaces (`can not`).
        var lemma: String
        /// Other lemmas a learner's dictionary lists the form under, audited by hand and never derived from the lexicon.
        var also: [String]
        /// `trap` for rows written for ReadStair; otherwise the UD stratum, where `homograph` rows are recorded but not gated.
        var kind: String
    }

    /// All rows in file order: tab-separated with one header row, no quoting, empty fields kept.
    static func rows() throws -> [Row] {
        let text = try String(contentsOf: fixtureURL("Data/ud-ewt/lemma-500.tsv"), encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let header = try #require(lines.first)
        try #require(header == ["form", "lemma", "also", "kind", "source"], "lemma-500.tsv header")
        return try lines.dropFirst().map { fields in
            try #require(fields.count == 5, "lemma-500.tsv row \(fields[0]) has \(fields.count) fields")
            return Row(form: fields[0], lemma: fields[1], also: fields[2].split(separator: "|").map(String.init), kind: fields[3])
        }
    }

    /// The app's reading of a word with no context: a compound's lemma (it keeps its hyphens), otherwise its parts joined by spaces.
    static func predicted(_ form: String) -> String {
        let key = PageWord.key(form)
        return key.contains("-") ? Lexicon.bundled.lemma(of: key) : Lexicon.bundled.parts(of: key).joined(separator: " ")
    }

    @Test("U-LEM-001 ReadStair's trap words read exactly as written: wed, hiss and sheer stay themselves; irregular forms, contractions, possessives and compounds")
    func traps() throws {
        let traps = try Self.rows().filter { $0.kind == "trap" }
        try #require(traps.count >= 70, "\(traps.count) trap rows")
        for row in traps {
            #expect(Self.predicted(row.form) == row.lemma, "\(row.form)")
        }
    }

    @Test("U-LEM-001 UD English-EWT word pairs: at least 97% read as the gold lemma or an audited alternative, at least 92% as the gold lemma; homographs recorded")
    func udAccuracy() throws {
        let rows = try Self.rows()
        let gated = rows.filter { $0.kind != "trap" && $0.kind != "homograph" }
        let homographs = rows.filter { $0.kind == "homograph" }
        try #require(gated.count >= 400, "\(gated.count) gated UD rows")
        var strict = 0
        var misses: [String] = []
        for row in gated {
            let got = Self.predicted(row.form)
            if got == row.lemma { strict += 1 } else if !row.also.contains(got) { misses.append("\(row.form) gold \(row.lemma) got \(got)") }
        }
        let accepted = gated.count - misses.count
        let majority = homographs.filter { Self.predicted($0.form) == $0.lemma }.count
        ExperimentLog.record(["test": "U-LEM-001", "gated": gated.count, "accepted": accepted, "strict": strict,
                              "homographs": homographs.count, "homograph_majority": majority])
        #expect(accepted * 100 >= gated.count * 97, "\(accepted)/\(gated.count) accepted; misses: \(misses.joined(separator: "; "))")
        #expect(strict * 100 >= gated.count * 92, "\(strict)/\(gated.count) strict")
    }

    @Test("U-LEM-002 Irregular and -ies plurals read as their lemma from the lexicon alone, also as a single word with no sentence around it",
          arguments: [("mice", "mouse"), ("geese", "goose"), ("flies", "fly")])
    func irregularForms(form: String, lemma: String) {
        #expect(Lexicon.bundled.lemma(of: form) == lemma)
        let page = PageAnalyzer.analyze([RecognizedWord(text: form, quads: [])], lexicon: .bundled)
        #expect(page.words.map(\.lemma) == [lemma])
    }

    @Test("U-LEM-003 Contractions: parts can + not, will + not, i + would|have (both readings kept) with any apostrophe OCR prints; the lemma is the contraction itself, band 1",
          arguments: [
              ("can't", "can't", ["can", "not"]), ("can\u{2019}t", "can't", ["can", "not"]), ("won't", "won't", ["will", "not"]),
              ("I'd", "i'd", ["i", "would|have"]), ("I\u{2019}d", "i'd", ["i", "would|have"]), ("I\u{2018}d", "i'd", ["i", "would|have"]),
              ("I\u{02BC}d", "i'd", ["i", "would|have"]),
          ])
    func contractions(text: String, lemma: String, parts: [String]) {
        let lexicon = Lexicon.bundled
        let key = PageWord.key(text)
        #expect(lexicon.parts(of: key) == parts)
        #expect(lexicon.lemma(of: key) == lemma)
        #expect(lexicon.band(ofLemma: lemma) == 1)
    }
}
