import Foundation
import NaturalLanguage

/// ReadStair's lexicon, built offline by tools/make-lexicon.py (sources and method: Resources/lexicon/ATTRIBUTION.md): the band of
/// each lemma, and the forms that read as a lemma. Lookups only: no suffix rules and no NLTagger lemma. A word's lemma is the key of
/// its saved state and of its iCloud record, so it must be identical on every device, OS version and language-asset state.
struct Lexicon: Sendable {
    /// Lemma → band (1 = the 1,000 most frequent lemmas).
    private let bands: [String: Int]
    /// Form → its lemma parts, separated by spaces, with alternative readings joined by `|`: `mouse`, `can not`, `i would|have`.
    private let forms: [String: String]
    /// Every value of `forms`: lemmas beyond the band table (`waistcoat`, from `waistcoats`) are still words to `knows`.
    private let formValues: Set<String>

    /// Parses the two tables: one `key<TAB>value` per line, split once at the first tab; lines starting with `#` are comments.
    init(bandsTSV: String, formsTSV: String) {
        var bands: [String: Int] = [:], forms: [String: String] = [:]
        Self.rows(bandsTSV) { bands[$0] = Int($1) }
        Self.rows(formsTSV) { forms[$0] = String($1) }
        self.bands = bands
        self.forms = forms
        formValues = Set(forms.values)
    }

    static func rows(_ text: String, _ body: (String, Substring) -> Void) {
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            body(String(line[..<tab]), line[line.index(after: tab)...])
        }
    }

    /// The bundled `lexicon` directory: bands.tsv, forms.tsv, vocab.tsv, LICENSE and ATTRIBUTION.md.
    static let directory = Bundle.module.url(forResource: "lexicon", withExtension: nil)

    /// The lexicon shipped in the bundle. Parsed on first access, which takes tenths of a second (longer in a debug build), so
    /// never touch it first on the main thread.
    static let bundled: Lexicon = {
        guard let directory = Self.directory,
              let bands = try? String(contentsOf: directory.appending(path: "bands.tsv"), encoding: .utf8),
              let forms = try? String(contentsOf: directory.appending(path: "forms.tsv"), encoding: .utf8) else {
            fatalError("ReadStairCore resource missing: lexicon")
        }
        return Lexicon(bandsTSV: bands, formsTSV: forms)
    }()

    /// The dictionary-form parts of a lookup key (`PageWord.key`): `mice` → [mouse], `can't` → [can, not], `i'd` → [i, would|have].
    /// A possessive 's is dropped when the key itself has no row (`alice's` → [alice], `children's` → [child]).
    func parts(of key: String) -> [String] {
        if let row = forms[key] { return row.split(separator: " ").map(String.init) }
        if key.hasSuffix("'s"), key.count > 2 { return parts(of: String(key.dropLast(2))) }
        return [key]
    }

    /// The lemma a word is stored, marked and shown under. A contraction is its own lemma (`won't`), so a state set on it never
    /// marks every `will`. A hyphenated compound stays whole and only a plural last piece is reduced: `rabbit-holes` and
    /// `rabbit-hole's` → `rabbit-hole`, while `well-known` and `three-legged` stay as they are.
    func lemma(of key: String) -> String {
        let parts = parts(of: key)
        guard parts.count == 1 else { return key }
        let word = parts[0]
        guard word.contains("-") else { return word }
        var pieces = word.split(separator: "-").map(String.init)
        guard let last = pieces.popLast() else { return word }
        let base = lemma(of: last)
        pieces.append([base + "s", base + "es"].contains(last) ? base : last)
        return pieces.joined(separator: "-")
    }

    /// The band of a lemma (from `lemma(of:)`). A compound missing from the table takes its hardest piece, and a contraction its
    /// hardest part, each part at its easiest reading; nil if any piece or part has no band.
    func band(ofLemma lemma: String) -> Int? {
        if let band = bands[lemma] { return band }
        let pieces = lemma.contains("-") ? lemma.split(separator: "-").map { self.lemma(of: String($0)) } : parts(of: lemma)
        guard pieces.count > 1 else { return nil }
        var hardest = 0
        for piece in pieces {
            guard let band = piece.split(separator: "|").compactMap({ bands[String($0)] }).min() else { return nil }
            hardest = max(hardest, band)
        }
        return hardest
    }

    /// Whether a lookup key is a word, for merging words hyphenated across lines.
    func knows(_ key: String) -> Bool {
        forms[key] != nil || formValues.contains(key) || band(ofLemma: lemma(of: key)) != nil
    }
}

/// Analyzes a sequence of OCR words into a PageText: sentence splitting, lemma and band lookup, name detection. Lemmas come from the
/// lexicon alone; NLTagger only detects names. Creates a new NLTagger per call (it is not thread-safe), so this can be called from
/// any thread.
enum PageAnalyzer {
    static func analyze(_ words: [RecognizedWord], lexicon: Lexicon) -> PageText {
        guard !words.isEmpty else { return PageText(words: [], sentences: []) }

        // 1. Join the words with spaces into the page text, recording each word's range in it
        let text = words.map(\.text).joined(separator: " ")
        var ranges: [Range<String.Index>] = []
        var offset = 0
        for word in words {
            let length = word.text.utf16.count
            ranges.append(Range(NSRange(location: offset, length: length), in: text)!)
            offset += length + 1
        }
        let whole = text.startIndex..<text.endIndex

        // 2. Sentences
        var sentences: [String] = []
        var sentenceStarts: [String.Index] = []
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = text
        sentenceTokenizer.enumerateTokens(in: whole) { range, _ in
            sentences.append(text[range].trimmingCharacters(in: .whitespacesAndNewlines))
            sentenceStarts.append(range.lowerBound)
            return true
        }

        // 3. Names: NLTagger tokenizes finer than OCR words (Alice's → Alice + 's); a name token marks the OCR word containing its start
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.setLanguage(.english, range: whole)
        var names = Set<Int>()
        func owner(of index: String.Index) -> Int? {
            var low = 0, high = ranges.count - 1
            while low <= high {
                let mid = (low + high) / 2
                if ranges[mid].upperBound <= index { low = mid + 1 }
                else if ranges[mid].lowerBound > index { high = mid - 1 }
                else { return mid }
            }
            return nil
        }
        let nameTags: Set<NLTag> = [.personalName, .placeName, .organizationName]
        tagger.enumerateTags(in: whole, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if let tag, nameTags.contains(tag), let i = owner(of: range.lowerBound) { names.insert(i) }
            return true
        }

        // 4. Assemble
        var sentence = 0
        let analyzed = words.enumerated().map { i, word in
            while sentence + 1 < sentenceStarts.count, sentenceStarts[sentence + 1] <= ranges[i].lowerBound { sentence += 1 }
            let key = PageWord.key(word.text)
            let lemma = lexicon.lemma(of: key)
            let kind: PageWord.Kind = if key.isEmpty { .punct }
                else if !key.contains(where: \.isLetter) || key.contains(where: \.isNumber) || isRomanNumeral(word.text) { .number }
                else if names.contains(i) { .name }
                else { .word }
            return PageWord(surface: word.text, lemma: lemma, kind: kind, band: lexicon.band(ofLemma: lemma),
                            quads: word.quads, sentence: min(sentence, max(sentences.count - 1, 0)))
        }
        return PageText(words: analyzed, sentences: sentences)
    }

    /// A chapter or section number printed as an uppercase Roman numeral of two or more letters (II, VII, XIV). A lone I, V or X
    /// stays a word; an all-caps word that happens to be a numeral (MIX) goes unmarked, the safe direction.
    private static func isRomanNumeral(_ text: String) -> Bool {
        let core = PageWord.core(text)
        return core.count >= 2 && core.allSatisfy("MDCLXVI".contains)
            && core.wholeMatch(of: /M{0,3}(C[MD]|D?C{0,3})(X[CL]|L?X{0,3})(I[XV]|V?I{0,3})/) != nil
    }
}
