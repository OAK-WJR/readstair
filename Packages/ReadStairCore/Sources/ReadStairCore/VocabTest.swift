import Foundation

/// The levels the app offers, in thousands of words: the rows of the level picker and the bands the vocabulary test samples.
public enum LevelLadder {
    /// Every anchor is a valid `Profile.levels` value, so a level chosen from the ladder can always be saved.
    public static let anchors = [1, 2, 3, 5, 8, 12]

    /// Example words for a level's row: the first three words of that band in vocab.tsv, which lists them by frequency.
    public static func samples(for level: Int) -> [String] {
        Array(VocabTest.pool[level, default: []].prefix(3))
    }
}

/// The first-launch yes/no vocabulary test: real words from each anchor band mixed with pseudowords; the user taps the words they
/// know. Tapping a pseudoword shows guessing, so each band's hit rate is corrected by the pseudoword false-alarm rate before the
/// level is read off. Pure functions over the bundled vocab.tsv.
public enum VocabTest {
    /// One word of the test.
    public struct Item: Sendable, Hashable {
        public let word: String
        /// The band the word was drawn from; 0 for a pseudoword.
        let band: Int
    }

    static let wordsPerBand = 5
    static let pseudowordCount = 10

    /// vocab.tsv by band, each list in file order: 20 real words for each band from 1 to 25, and 100 pseudowords under band 0.
    /// Parsed on first use.
    static let pool: [Int: [String]] = {
        guard let url = Lexicon.directory?.appending(path: "vocab.tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("ReadStairCore resource missing: lexicon/vocab.tsv")
        }
        var pool: [Int: [String]] = [:]
        Lexicon.rows(text) { word, band in
            if let band = Int(band) { pool[band, default: []].append(word) }
        }
        return pool
    }()

    /// The items of one test, in shuffled order: `wordsPerBand` real words drawn from each anchor band and `pseudowordCount`
    /// pseudowords (40 in all). The same seed always gives the same items, so a view that rebuilds keeps showing the same test.
    public static func items(seed: UInt64) -> [Item] {
        var random = SplitMix64(seed: seed)
        var items: [Item] = []
        for band in LevelLadder.anchors {
            items += pool[band, default: []].shuffled(using: &random).prefix(wordsPerBand).map { Item(word: $0, band: band) }
        }
        items += pool[0, default: []].shuffled(using: &random).prefix(pseudowordCount).map { Item(word: $0, band: 0) }
        return items.shuffled(using: &random)
    }

    /// The level for the words a user tapped among `items(seed:)`: the hardest anchor whose corrected score is at least one half.
    /// A band's corrected score is its hit rate minus the pseudoword false-alarm rate. The scores are fitted to a non-increasing
    /// sequence across the anchors (a harder band cannot be better known than an easier one), so one noisy band does not decide
    /// the level alone. Nothing reaching one half gives the lowest anchor.
    /// - Returns: `unreliable` is true when the corrected total is zero or less (the pseudowords tapped outweigh the real words, or
    ///   nothing was tapped): the answers say too little, the level is the lowest anchor, and the app suggests adjusting it later.
    public static func estimate(selected: Set<Item>) -> (level: Int, unreliable: Bool) {
        let anchors = LevelLadder.anchors
        let falseAlarms = selected.count(where: { $0.band == 0 })
        // In units of 1 / (wordsPerBand × pseudowordCount), so every comparison is exact: hits / 5 − falseAlarms / 10
        let scale = wordsPerBand * pseudowordCount
        let scores = anchors.map { band in selected.count(where: { $0.band == band }) * pseudowordCount - falseAlarms * wordsPerBand }
        if scores.reduce(0, +) <= 0 { return (anchors[0], true) }
        let known = nonIncreasingFit(scores).prefix(while: { 2 * $0.sum >= scale * $0.count }).reduce(0) { $0 + $1.count }
        return (anchors[max(known, 1) - 1], false)
    }

    /// Pool-adjacent-violators: the least-squares non-increasing fit of `values`, as runs of equal fitted value, each given by its
    /// sum and length (its fitted value is sum / count).
    static func nonIncreasingFit(_ values: [Int]) -> [(sum: Int, count: Int)] {
        var runs: [(sum: Int, count: Int)] = []
        for value in values {
            runs.append((value, 1))
            // Merge while the last run's mean is above the mean of the run before it (compared by cross-multiplying)
            while runs.count > 1, let last = runs.last,
                  last.sum * runs[runs.count - 2].count > runs[runs.count - 2].sum * last.count {
                runs.removeLast()
                runs[runs.count - 1].sum += last.sum
                runs[runs.count - 1].count += last.count
            }
        }
        return runs
    }
}

/// SplitMix64 (Steele, Lea and Flood, 2014): a small generator whose output depends only on its seed. Tests use it too, so a
/// failing random case can be reproduced.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
