import CoreGraphics
import Foundation

/// A quadrilateral on the page image. Normalized coordinates (0…1), origin at the top left.
public struct Quad: Sendable, Hashable, Codable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// A quad from an axis-aligned rectangle (normalized coordinates).
    init(_ rect: CGRect) {
        self.init(topLeft: CGPoint(x: rect.minX, y: rect.minY), topRight: CGPoint(x: rect.maxX, y: rect.minY),
                  bottomRight: CGPoint(x: rect.maxX, y: rect.maxY), bottomLeft: CGPoint(x: rect.minX, y: rect.maxY))
    }

    public var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    var center: CGPoint {
        CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
    }

    /// Scales normalized coordinates to the given size (e.g. the page image's on-screen display size).
    public func scaled(to size: CGSize) -> Quad {
        func s(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        return Quad(topLeft: s(topLeft), topRight: s(topRight), bottomRight: s(bottomRight), bottomLeft: s(bottomLeft))
    }

    /// The part of the quad between two fractions of its width (0 = left edge, 1 = right edge), cut along its top and bottom edges.
    func slice(from start: CGFloat, to end: CGFloat) -> Quad {
        func point(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        return Quad(topLeft: point(topLeft, topRight, start), topRight: point(topLeft, topRight, end),
                    bottomRight: point(bottomLeft, bottomRight, end), bottomLeft: point(bottomLeft, bottomRight, start))
    }

    /// Distance from a point to the quad; 0 if the point is inside. The quad must be convex (OCR word boxes always are); a degenerate zero-area box is measured as segments and never "contains" a point.
    func distance(to point: CGPoint) -> CGFloat {
        let c = corners
        let edges = (0..<4).map { (c[$0], c[($0 + 1) % 4]) }
        let area = edges.reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y } / 2
        let crosses = edges.map { (a, b) in (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x) }
        if abs(area) > 1e-12, crosses.allSatisfy({ $0 >= 0 }) || crosses.allSatisfy({ $0 <= 0 }) { return 0 }
        return edges.map { Self.distance(from: point, toSegment: $0.0, $0.1) }.min() ?? .infinity
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// A recognized and analyzed word. A word broken across lines has two quads.
public struct PageWord: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case word, name, number, punct
    }

    /// The OCR text, including attached punctuation, e.g. `"conversations?"`.
    public var surface: String
    /// Dictionary form, lowercased, e.g. `consider`; a contraction is its own lemma (`won't`). Annotation and saved words are keyed by it.
    public var lemma: String
    public var kind: Kind
    /// Word-frequency band of the lemma (1 = the 1,000 most frequent lemmas); nil if the lexicon has none.
    public var band: Int?
    public var quads: [Quad]
    /// Index of the containing sentence in `PageText.sentences`.
    public var sentence: Int

    public init(surface: String, lemma: String, kind: Kind, band: Int?, quads: [Quad], sentence: Int) {
        self.surface = surface
        self.lemma = lemma
        self.kind = kind
        self.band = band
        self.quads = quads
        self.sentence = sentence
    }

    /// The word with leading and trailing punctuation removed: `"(conversations?"` → `conversations`; `don't` is unchanged.
    public static func core(_ text: some StringProtocol) -> String {
        String(text).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Lexicon lookup key: the core word lowercased, with the apostrophes books print (‘ ’ ʼ) normalized to a straight one first, so
    /// one at either end is trimmed like any other punctuation.
    static func key(_ text: some StringProtocol) -> String {
        core(String(text.map { "\u{2018}\u{2019}\u{02BC}".contains($0) ? "'" : $0 })).lowercased()
    }

    /// What the word card shows and translates: a name as printed, without punctuation (`Alice`); any other word as its lemma
    /// (a contraction as itself, `won't`).
    public var headword: String { kind == .name ? Self.core(surface) : lemma }
}

/// Recognition result for one page: words and sentences in reading order.
public struct PageText: Sendable, Hashable, Codable {
    /// Version of the recognition and analysis pipeline. Bump it when analysis rules or the lexicon change (lemmas, bands, sentence
    /// splitting): results stored by an older version then read as missing, and opening the store queues their pages again. That
    /// includes typeset e-book pages, which then go through recognition like photos (nothing re-analyzes stored words yet), so
    /// after release bump it only when the change is worth recognizing every page of every book again. A bump sends covers through
    /// recognition too, which reads their words as plain words where `TypesetBook.page` made them names, so the level marks them again,
    /// and on a book's own cover image finds whatever words it prints.
    static let schemaVersion = 4

    public var words: [PageWord]
    public var sentences: [String]

    public init(words: [PageWord], sentences: [String]) {
        self.words = words
        self.sentences = sentences
    }
}
