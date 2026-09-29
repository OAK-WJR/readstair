import CoreGraphics
import Testing
@testable import ReadStairCore

/// U-HIT-001: tap hit threshold ≤ 24 pt.
@Suite("U-HIT Annotator.hit")
struct HitTests {
    /// Page image displayed at 400×600 points; two word boxes (points): A = x 100…140, y 100…120; B = x 200…260, y 100…120; plus one punctuation box.
    private let size = CGSize(width: 400, height: 600)
    private var page: PageText {
        func word(_ text: String, _ rect: CGRect, kind: PageWord.Kind = .word) -> PageWord {
            let normalized = CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                                    width: rect.width / size.width, height: rect.height / size.height)
            return PageWord(surface: text, lemma: text, kind: kind, band: 5, quads: [Quad(normalized)], sentence: 0)
        }
        return PageText(words: [
            word("alpha", CGRect(x: 100, y: 100, width: 40, height: 20)),
            word("beta", CGRect(x: 200, y: 100, width: 60, height: 20)),
            word(",", CGRect(x: 100, y: 300, width: 6, height: 20), kind: .punct),
        ], sentences: [""])
    }

    @Test("U-HIT-001 A tap 20 pt from the nearest word box hits; 30 pt misses")
    func threshold() {
        #expect(Annotator.hit(CGPoint(x: 120, y: 140), in: page, size: size) == 0)   // 20 pt below A's bottom edge
        #expect(Annotator.hit(CGPoint(x: 120, y: 150), in: page, size: size) == nil) // 30 pt below A's bottom edge
        #expect(Annotator.hit(CGPoint(x: 120, y: 70), in: page, size: size) == nil)  // 30 pt above A's top edge
    }

    @Test("U-HIT-001 supplementary: hits inside a box, nearest word wins, punctuation is not tappable")
    func nearestAndPunctuation() {
        #expect(Annotator.hit(CGPoint(x: 110, y: 110), in: page, size: size) == 0)
        #expect(Annotator.hit(CGPoint(x: 185, y: 110), in: page, size: size) == 1)   // 45 pt from A, 15 pt from B
        #expect(Annotator.hit(CGPoint(x: 103, y: 310), in: page, size: size) == nil) // inside the punctuation box
    }

    @Test("U-HIT-001 supplementary: a degenerate zero-area box does not catch taps across the whole page")
    func degenerateQuad() {
        let point = CGPoint(x: 0.25, y: 0.2)
        let dot = Quad(topLeft: point, topRight: point, bottomRight: point, bottomLeft: point)
        let page = PageText(words: [PageWord(surface: "x", lemma: "x", kind: .word, band: 5, quads: [dot], sentence: 0)],
                            sentences: [""])
        #expect(Annotator.hit(CGPoint(x: 300, y: 500), in: page, size: size) == nil)
        #expect(Annotator.hit(CGPoint(x: 110, y: 120), in: page, size: size) == 0)  // 10 pt from the point
    }
}
