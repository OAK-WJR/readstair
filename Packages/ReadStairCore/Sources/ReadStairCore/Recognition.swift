import Foundation
import ImageIO
import Vision

/// A word from OCR, before lemma and band analysis.
struct RecognizedWord: Sendable, Hashable {
    var text: String
    var quads: [Quad]
}

public enum Recognition {
    /// Page image → PageText: recognition, merging of words hyphenated across lines, analysis. Seconds per page, about 15 s on a Mac without a Neural Engine; callers must not wait on the main thread.
    /// The lexicon is fetched in the body, not as a default argument: default arguments are evaluated by the caller, and the first parse of the lexicon would block the main thread.
    @concurrent
    public static func page(from image: CGImage) async throws -> PageText {
        let lexicon = Lexicon.bundled
        let lines = try await lines(in: image)
        try Task.checkCancellation()  // After the image is replaced, the old task stops here (Vision itself cannot be stopped midway)
        let words = hyphenMerge(lines, isKnown: lexicon.knows)
        return PageAnalyzer.analyze(words, lexicon: lexicon)
    }

    /// Vision `RecognizeDocumentsRequest`: words grouped by line, in reading order, with words joined by a dash split (`splitAtDashes`).
    /// Empty for scripts without word-level results, such as Chinese, Japanese and Korean.
    @concurrent
    static func lines(in image: CGImage) async throws -> [[RecognizedWord]] {
        let observations = try await RecognizeDocumentsRequest().perform(on: image)
        guard let text = observations.first?.document.text, let words = text.words else { return [] }
        let lineQuads = text.lines.map(Quad.init)
        var lines = [[RecognizedWord]](repeating: [], count: lineQuads.count)
        for word in words {
            let quad = Quad(word)
            let center = quad.center
            // A word goes to the line containing its center (distance 0); when an OCR word box occasionally spills outside its line box, take the nearest line
            guard let line = lineQuads.indices.min(by: { lineQuads[$0].distance(to: center) < lineQuads[$1].distance(to: center) })
            else { continue }
            lines[line].append(contentsOf: splitAtDashes(RecognizedWord(text: word.transcript, quads: [quad])))
        }
        return lines
    }

    /// Decodes the chosen photo into a page image: rotated upright per EXIF orientation, long edge scaled down to at most `PageImageFile.maxPixelSize`.
    /// iPhone photos are HEIC; decoding shares one dedicated queue with saving page images (see `PageImageFile.run`).
    public static func pageImage(from data: Data) async -> CGImage? {
        await PageImageFile.run {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: PageImageFile.maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
    }

    /// A page from the document camera: turned upright per its orientation and scaled down like a chosen photo, on the same dedicated
    /// queue (a camera-size redraw belongs neither on the main actor nor on the cooperative pool). nil if it cannot be drawn.
    public static func pageImage(from image: CGImage, orientation: CGImagePropertyOrientation) async -> CGImage? {
        await PageImageFile.run { try? PageImageFile.fitting(image, orientation: orientation, maxPixelSize: PageImageFile.maxPixelSize) }
    }

    private static let hyphens: Set<Character> = ["-", "\u{2010}", "\u{00AD}"]
    private static let dashes: Set<Character> = ["\u{2014}", "\u{2013}"]

    /// Splits a word at each em or en dash printed between two words without spaces, as books do (`far—but` → `far` `—` `but`).
    /// Kept whole, such a pair is no word the lexicon knows, so it has no band and would be marked at every level. A dash splits
    /// only with a letter somewhere on each side, so `1850–60`, `“—yes` and `think—”` stay whole, and a hyphen never splits
    /// (`well-known` is one lemma). Each piece takes the part of the box its share of the characters covers, close enough for an
    /// underline and a tap. Runs before `hyphenMerge`, while every word still has one box.
    static func splitAtDashes(_ word: RecognizedWord) -> [RecognizedWord] {
        let characters = Array(word.text)
        guard word.quads.count <= 1, let first = characters.firstIndex(where: \.isLetter),
              let last = characters.lastIndex(where: \.isLetter) else { return [word] }
        // A piece starts wherever a run of dashes starts or ends between the first letter and the last
        let cuts = (first + 1..<last + 1).filter { dashes.contains(characters[$0]) != dashes.contains(characters[$0 - 1]) }
        guard !cuts.isEmpty else { return [word] }
        let bounds = [0] + cuts + [characters.count]
        let count = CGFloat(characters.count)
        return zip(bounds, bounds.dropFirst()).map { start, end in
            RecognizedWord(text: String(characters[start..<end]),
                           quads: word.quads.map { $0.slice(from: CGFloat(start) / count, to: CGFloat(end) / count) })
        }
    }

    /// Flattens words arranged by line into reading order, merging words hyphenated across lines.
    /// A line-final word ending in a hyphen is merged with the next line's first word, if any: if the joined form is known, join (`exam-` `ple` → `example`);
    /// otherwise, if both parts are known, it is a compound and keeps the hyphen (`well-` `known` → `well-known`); anything else is a hyphenated rare word, so join
    /// (`antipa-` `thies` → `antipathies`). A merged word carries two quads. If the next line is empty or there is none, the word is kept as is.
    static func hyphenMerge(_ lines: [[RecognizedWord]], isKnown: (String) -> Bool) -> [RecognizedWord] {
        var result: [RecognizedWord] = []
        var skipNextLineHead = false
        for (lineIndex, line) in lines.enumerated() {
            for (wordIndex, word) in line.enumerated() {
                if wordIndex == 0, skipNextLineHead {
                    skipNextLineHead = false
                    continue
                }
                if wordIndex == line.count - 1, lineIndex + 1 < lines.count,
                   let head = lines[lineIndex + 1].first, let merged = merge(word, head, isKnown: isKnown) {
                    result.append(merged)
                    skipNextLineHead = true
                } else {
                    result.append(word)
                }
            }
        }
        return result
    }

    private static func merge(_ tail: RecognizedWord, _ head: RecognizedWord, isKnown: (String) -> Bool) -> RecognizedWord? {
        guard let last = tail.text.last, hyphens.contains(last) else { return nil }
        let stem = tail.text.dropLast()
        guard stem.last?.isLetter == true, head.text.first?.isLetter == true else { return nil }
        let joined = stem + head.text
        let isCompound = !isKnown(PageWord.key(joined)) && isKnown(PageWord.key(stem)) && isKnown(PageWord.key(head.text))
        let text = isCompound ? stem + "-" + head.text : joined
        return RecognizedWord(text: String(text), quads: tail.quads + head.quads)
    }
}

extension Quad {
    /// Vision's normalized coordinates have their origin at the bottom left; flip to the top left.
    init(_ observation: RecognizedTextObservation) {
        func flip(_ p: NormalizedPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        self.init(topLeft: flip(observation.topLeft), topRight: flip(observation.topRight),
                  bottomRight: flip(observation.bottomRight), bottomLeft: flip(observation.bottomLeft))
    }
}
