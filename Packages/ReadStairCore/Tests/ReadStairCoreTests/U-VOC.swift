import Foundation
import Testing
@testable import ReadStairCore

/// A selection from a draw: the first `hits[i]` real words of anchor band `LevelLadder.anchors[i]` (1k, 2k, 3k, 5k, 8k, 12k),
/// and the first `falseAlarms` pseudowords.
private func tapped(_ items: [VocabTest.Item], hits: [Int], falseAlarms: Int = 0) -> Set<VocabTest.Item> {
    var selected = Set(items.filter { $0.band == 0 }.prefix(falseAlarms))
    for (band, count) in zip(LevelLadder.anchors, hits) {
        selected.formUnion(items.filter { $0.band == band }.prefix(count))
    }
    return selected
}

/// Data/wordnet/wordnet-extract.tsv as word → flags; flag `c` means WordNet also writes the word capitalized (a name, place or
/// brand sense). The extract lists every word of the frequency list that WordNet knows.
private func wordNetFlags() throws -> [String: String] {
    let text = try String(contentsOf: fixtureURL("Data/wordnet/wordnet-extract.tsv"), encoding: .utf8)
    var flags: [String: String] = [:]
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        if fields.count > 5 { flags[String(fields[0])] = String(fields[5]) }
    }
    return flags
}

/// U-VOC-001–004: the first-launch vocabulary test's estimate and draw.
@Suite("U-VOC Vocabulary test")
struct VocabTestTests {
    @Test("U-VOC-001 All 30 real words tapped and no pseudoword: the top level, 12k, reliable")
    func allRight() {
        for seed: UInt64 in [1, 2, 3] {
            let result = VocabTest.estimate(selected: tapped(VocabTest.items(seed: seed), hits: [5, 5, 5, 5, 5, 5]))
            #expect(result.level == 12)
            #expect(!result.unreliable)
        }
    }

    @Test("U-VOC-002 All 40 words tapped, the 10 pseudowords included: corrected score 0, so 1k and unreliable")
    func everythingTapped() {
        let result = VocabTest.estimate(selected: Set(VocabTest.items(seed: 1)))
        #expect(result.level == 1)
        #expect(result.unreliable)
    }

    @Test("U-VOC-003 Every word of the bands up to 3k tapped, none above and no pseudoword: exactly 3k")
    func rightUpTo3k() {
        let result = VocabTest.estimate(selected: tapped(VocabTest.items(seed: 1), hits: [5, 5, 5, 0, 0, 0]))
        #expect(result.level == 3)
        #expect(!result.unreliable)
    }

    @Test("U-VOC-004 20 draws: 5 words from each anchor band and 10 pseudowords, no repeats, the same for the same seed; real words are lemmas of their band with no name sense, pseudowords are no words at all, and the real words rotate")
    func draws() throws {
        let flags = try wordNetFlags()
        let lexicon = Lexicon.bundled
        var seen: [Int: Set<String>] = [:]
        for seed: UInt64 in 0..<20 {
            let items = VocabTest.items(seed: seed)
            #expect(items == VocabTest.items(seed: seed))
            #expect(items.count == 40)
            #expect(Set(items.map(\.word)).count == 40, "seed \(seed) repeats a word")
            for band in LevelLadder.anchors {
                #expect(items.count(where: { $0.band == band }) == 5, "seed \(seed), band \(band)")
            }
            #expect(items.count(where: { $0.band == 0 }) == 10, "seed \(seed)")
            for item in items {
                if item.band > 0 {
                    #expect(lexicon.band(ofLemma: item.word) == item.band, "\(item.word) is not a band-\(item.band) lemma")
                    #expect(flags[item.word].map { !$0.contains("c") } == true, "\(item.word) has a name sense or is not in WordNet")
                    seen[item.band, default: []].insert(item.word)
                } else {
                    #expect(!lexicon.knows(item.word) && flags[item.word] == nil, "pseudoword \(item.word) is a real word")
                }
            }
        }
        for band in LevelLadder.anchors {
            #expect(seen[band, default: []].count > 5, "band \(band) always shows the same words")
        }
    }
}

@Suite("Supplementary: VocabTest and LevelLadder")
struct VocabTestSupplementaryTests {
    @Test("Nothing tapped: corrected score 0, so 1k and unreliable")
    func nothingTapped() {
        let result = VocabTest.estimate(selected: [])
        #expect(result.level == 1)
        #expect(result.unreliable)
    }

    @Test("A band is known when at least half its words are after correction: 3 of 5 in each band up to 5k gives 5k with one pseudoword tapped and 1k with two")
    func correction() {
        let items = VocabTest.items(seed: 7)
        #expect(VocabTest.estimate(selected: tapped(items, hits: [3, 3, 3, 3, 0, 0], falseAlarms: 1)) == (5, false))
        #expect(VocabTest.estimate(selected: tapped(items, hits: [3, 3, 3, 3, 0, 0], falseAlarms: 2)) == (1, false))
    }

    @Test("Monotone fit: one band out of line does not decide the level alone (a dip at 3k still gives 8k; a lone known 12k gives 3k)")
    func monotoneFit() {
        let items = VocabTest.items(seed: 7)
        #expect(VocabTest.estimate(selected: tapped(items, hits: [5, 5, 1, 5, 5, 0])).level == 8)
        #expect(VocabTest.estimate(selected: tapped(items, hits: [5, 5, 5, 0, 0, 5])).level == 3)
    }

    @Test("LevelLadder: every anchor is a valid level, and a row's examples are the first three words of its band in vocab.tsv")
    func ladder() {
        #expect(LevelLadder.anchors.allSatisfy(Profile.levels.contains))
        #expect(LevelLadder.samples(for: 1) == ["thing", "country", "today"])
        #expect(LevelLadder.samples(for: 12) == ["entice", "solicit", "usable"])
        for level in LevelLadder.anchors {
            #expect(LevelLadder.samples(for: level).count == 3)
        }
    }
}
