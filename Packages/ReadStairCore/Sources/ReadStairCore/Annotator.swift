import CoreGraphics
import Foundation

/// The user's explicit state for a word. Only these two are stored; everything else is derived from the band.
public enum WordState: String, Sendable, Hashable {
    case learning, known
}

/// Computes which words on a page to mark and which word a tap hits. Pure functions, no state.
public enum Annotator {
    /// `learning` is always marked, `known` never. With no explicit state, only plain words whose band is above the user's level (or that are not in the word list) are marked; names, numbers and punctuation are not.
    public static func isMarked(_ word: PageWord, level: Int, state: WordState?) -> Bool {
        switch state {
        case .learning: true
        case .known: false
        case nil: word.kind == .word && (word.band ?? .max) > level
        }
    }

    /// Indices into `page.words` of the words to mark, in reading order. `state` gives the saved state of the word at an index. A word
    /// without a box (the title on a book's own cover) is never marked: there is nothing to underline.
    public static func markedWords(in page: PageText, level: Int, state: (Int) -> WordState?) -> [Int] {
        page.words.indices.filter { !page.words[$0].quads.isEmpty && isMarked(page.words[$0], level: level, state: state($0)) }
    }

    /// Tap hit test: the word nearest the tap, within `maxDistance` points. Punctuation is not tappable; any word is, marked or not.
    /// `size` is the page image's current display size in points; `point` is in the same coordinate space.
    public static func hit(_ point: CGPoint, in page: PageText, size: CGSize, maxDistance: CGFloat = 24) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, word) in page.words.enumerated() where word.kind != .punct {
            for quad in word.quads {
                let distance = quad.scaled(to: size).distance(to: point)
                if distance <= maxDistance, distance < (best?.distance ?? .infinity) {
                    best = (index, distance)
                }
            }
        }
        return best?.index
    }
}

extension PageWord {
    /// The key the word's saved state is stored and looked up under: the lemma lowercased, then Unicode NFC, exactly as `upsertWord`
    /// keys it, so a lookup matches the stored key byte for byte (OCR can return an accented letter as a base letter plus a combining
    /// mark).
    public var stateKey: String { SyncRules.lemmaKey(lemma) }
}

extension WordEntry {
    /// What opening the word's card in the Reader writes: the word as learning, or nil to write nothing. It writes only when the level
    /// is what marks the word: no explicit state, a plain word, and a band above the level. So opening a card never changes an
    /// underline, and a stray tap never adds a name, a number, a word the level covers or a word outside the lexicon (band nil, which
    /// includes OCR errors). `state` must be the effective one, a change still waiting to be saved included. The entry is written with
    /// `upsertWord(_:onlyIfAbsent: true)`, so a state already stored on this device, one the app has not read back yet included, is
    /// never replaced. A change another device made that has not arrived yet is not protected: the later write wins.
    public static func entryOnOpen(word: PageWord, state: WordState?, level: Int, bookID: UUID, pageID: UUID,
                                   sentence: String?) -> WordEntry? {
        guard state == nil, word.kind == .word, let band = word.band, band > level else { return nil }
        return WordEntry(lemma: word.stateKey, state: .learning, source: .lookup, band: band,
                         firstBookID: bookID, firstPageID: pageID, firstSentence: sentence)
    }
}
