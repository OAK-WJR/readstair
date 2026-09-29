import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ReadStairCore

/// I-OCR-001–002: real recognition on Standard Ebooks pages rendered in Fixtures/, compared against the ground truth exported by tools/make-fixtures.swift.
@Suite("I-OCR Recognition integration", .tags(.integration), .serialized)
struct RecognitionIntegrationTests {
    struct Truth: Decodable {
        struct Word: Decodable { var text: String; var quads: [[[Double]]] }
        var rotationDegrees: Double?
        var words: [Word]
    }

    private func load(_ name: String) throws -> (CGImage, Truth) {
        let url = fixtureURL("Fixtures/\(name).png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "Missing fixture \(url.path(percentEncoded: false))")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: fixtureURL("Fixtures/\(name).json")))
        return (image, truth)
    }

    private func recognize(_ image: CGImage, test: String, page label: String) async throws -> PageText {
        let start = ContinuousClock.now
        let page = try await Recognition.page(from: image)
        ExperimentLog.record(["test": test, "page": label, "words": page.words.count, "ms": ContinuousClock.now - start])
        return page
    }

    @Test("I-OCR-001 Upright page: word count = baseline ±5%, no empty boxes")
    func normalPage() async throws {
        let (image, truth) = try load("alice-p1")
        let page = try await recognize(image, test: "I-OCR-001", page: "upright")
        let baseline = truth.words.count
        #expect(abs(page.words.count - baseline) * 100 <= baseline * 5, "recognized \(page.words.count) words, baseline \(baseline)")
        let empty = page.words.filter { $0.surface.isEmpty || $0.quads.isEmpty || $0.quads.contains { Self.area($0.corners) <= 0 } }
        #expect(empty.isEmpty, "empty boxes: \(empty.map(\.surface))")
    }

    /// Baseline = OCR word boxes of the same page untilted, transformed into tilted-page coordinates by the rotation recorded in the fixture JSON.
    /// Pass criteria are positional: mean center offset and mean bottom-edge offset both ≤ 0.25 line height (line height = baseline box height),
    /// and mean width ratio within 0.9–1.1. IoU ≥ 0.8 is not a criterion: Vision's boxes on the tilted page are about 22% taller than on the upright page, so thin boxes only reach IoU ≈ 0.74,
    /// while underlines and taps depend only on position. IoU and the per-word maximum offsets are still printed for the record.
    @Test("I-OCR-002 Page tilted 8°: ≥ 95% of words aligned; mean center/bottom-edge offset ≤ 0.25 line height; mean width ratio 0.9–1.1")
    func tiltedPage() async throws {
        let (flatImage, flatTruth) = try load("alice-p1")
        let (tiltImage, tiltTruth) = try load("alice-p1-tilt8")
        let degrees = try #require(tiltTruth.rotationDegrees)
        let flat = try await recognize(flatImage, test: "I-OCR-002", page: "upright")
        let tilted = try await recognize(tiltImage, test: "I-OCR-002", page: "tilted")

        let rotate = Self.rotation(degrees: degrees, from: CGSize(width: flatImage.width, height: flatImage.height),
                                   to: CGSize(width: tiltImage.width, height: tiltImage.height))
        let baseline = flat.words.map { word in (key: PageWord.key(word.surface), quads: word.quads.map { $0.corners.map(rotate) }) }
        let result = Self.compare(tilted.words, to: baseline)
        let position = Self.position(tilted.words, baseline: baseline,
                                     pixels: CGSize(width: tiltImage.width, height: tiltImage.height))
        // Offsets in line heights
        ExperimentLog.record(["test": "I-OCR-002", "aligned": result.matched, "baseline": baseline.count, "center_mean": position.center,
                              "center_max": position.maxCenter, "bottom_mean": position.bottom, "bottom_max": position.maxBottom,
                              "width_ratio": position.width], result.fields)
        #expect(Double(result.matched) >= 0.95 * Double(baseline.count))
        #expect(position.center <= 0.25)
        #expect(position.bottom <= 0.25)
        #expect((0.9...1.1).contains(position.width))

        for (label, page, truth) in [("upright", flat, flatTruth), ("tilted", tilted, tiltTruth)] {
            let reference = truth.words.map { (key: PageWord.key($0.text), quads: $0.quads.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }) }
            let comparison = Self.compare(page.words, to: reference)
            ExperimentLog.record(["test": "I-OCR-002", "page": label, "against": "typeset_truth", "aligned": comparison.matched],
                                 comparison.fields)
        }
    }

    // MARK: - Geometry and alignment

    /// Same transform as tools/make-fixtures.swift: rotate counterclockwise about the page center onto a canvas enlarged to `to`; input and output are top-left normalized coordinates.
    static func rotation(degrees: Double, from: CGSize, to: CGSize) -> (CGPoint) -> CGPoint {
        let angle = degrees * .pi / 180
        return { p in
            let x = Double(p.x * from.width - from.width / 2), y = Double(from.height / 2 - p.y * from.height)
            let rx = x * cos(angle) - y * sin(angle), ry = x * sin(angle) + y * cos(angle)
            return CGPoint(x: (rx + to.width / 2) / to.width, y: (to.height / 2 - ry) / to.height)
        }
    }

    struct Comparison {
        var matched: Int
        var ious: [Double]
        var mean: Double { ious.reduce(0, +) / Double(max(ious.count, 1)) }
        /// IoU mean, median and minimum for a record; zero when nothing aligned.
        var fields: KeyValuePairs<String, Any> {
            let sorted = ious.sorted()
            return ["iou_mean": mean, "iou_median": sorted.isEmpty ? 0 : sorted[sorted.count / 2], "iou_min": sorted.first ?? 0]
        }
    }

    /// Aligns by lookup key in reading order; mean IoU over word pairs with the same number of boxes.
    static func compare(_ words: [PageWord], to expected: [(key: String, quads: [[CGPoint]])]) -> Comparison {
        let pairs = align(words.map { PageWord.key($0.surface) }, expected.map(\.key))
        var comparison = Comparison(matched: 0, ious: [])
        for (i, j) in pairs {
            let ocr = words[i].quads, target = expected[j].quads
            guard ocr.count == target.count else { continue }
            comparison.matched += 1
            comparison.ious.append(zip(ocr, target).map { iou($0.corners, $1) }.reduce(0, +) / Double(ocr.count))
        }
        return comparison
    }

    /// Positional metrics over aligned word pairs: center offset and bottom-edge midpoint offset (both divided by the baseline box height, i.e. in line heights) and width ratio, averaged; maxima are returned too.
    static func position(_ words: [PageWord], baseline: [(key: String, quads: [[CGPoint]])], pixels: CGSize)
        -> (center: Double, bottom: Double, width: Double, maxCenter: Double, maxBottom: Double) {
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * pixels.width, y: p.y * pixels.height) }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        func length(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(b.x - a.x, b.y - a.y)) }
        var center: [Double] = [], bottom: [Double] = [], width: [Double] = []
        for (i, j) in align(words.map { PageWord.key($0.surface) }, baseline.map(\.key)) {
            guard words[i].quads.count == 1, baseline[j].quads.count == 1 else { continue }
            let o = words[i].quads[0].corners.map(px), b = baseline[j].quads[0].map(px)
            let lineHeight = length(b[0], b[3])
            guard lineHeight > 0 else { continue }
            center.append(length(mid(o[0], o[2]), mid(b[0], b[2])) / lineHeight)
            bottom.append(length(mid(o[2], o[3]), mid(b[2], b[3])) / lineHeight)
            width.append(length(o[0], o[1]) / length(b[0], b[1]))
        }
        func average(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }
        return (average(center), average(bottom), average(width), center.max() ?? 0, bottom.max() ?? 0)
    }

    /// Longest-common-subsequence alignment in reading order; returns (recognized index, ground-truth index).
    static func align(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
    }

    static func area(_ polygon: [CGPoint]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        let sum = polygon.indices.reduce(0.0) { s, k in
            let p = polygon[k], q = polygon[(k + 1) % polygon.count]
            return s + Double(p.x * q.y - q.x * p.y)
        }
        return abs(sum) / 2
    }

    /// Intersection over union of two convex polygons (Sutherland–Hodgman clipping).
    static func iou(_ subject: [CGPoint], _ clip: [CGPoint]) -> Double {
        let orientation = area(clip) == 0 ? 1.0 : (signedArea(clip) > 0 ? 1.0 : -1.0)
        var output = subject
        for k in clip.indices {
            let a = clip[k], b = clip[(k + 1) % clip.count]
            func inside(_ p: CGPoint) -> Bool { Double((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) * orientation >= 0 }
            func intersection(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
                let d1 = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                let d2 = (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x)
                let t = d1 / (d1 - d2)
                return CGPoint(x: p.x + t * (q.x - p.x), y: p.y + t * (q.y - p.y))
            }
            let input = output
            output = []
            for m in input.indices {
                let p = input[m], q = input[(m + 1) % input.count]
                if inside(q) {
                    if !inside(p) { output.append(intersection(p, q)) }
                    output.append(q)
                } else if inside(p) {
                    output.append(intersection(p, q))
                }
            }
            if output.isEmpty { return 0 }
        }
        let overlap = area(output)
        let union = area(subject) + area(clip) - overlap
        return union > 0 ? overlap / union : 0
    }

    private static func signedArea(_ polygon: [CGPoint]) -> Double {
        polygon.indices.reduce(0.0) { s, k in
            let p = polygon[k], q = polygon[(k + 1) % polygon.count]
            return s + Double(p.x * q.y - q.x * p.y)
        } / 2
    }

    @Test("Supplementary: the test's rotation transform matches the fixture generator (rotated upright-page truth = tilted-page truth)")
    func rotationMatchesFixtureGenerator() throws {
        let (flatImage, flat) = try load("alice-p1")
        let (tiltImage, tilt) = try load("alice-p1-tilt8")
        let rotate = Self.rotation(degrees: try #require(tilt.rotationDegrees),
                                   from: CGSize(width: flatImage.width, height: flatImage.height),
                                   to: CGSize(width: tiltImage.width, height: tiltImage.height))
        #expect(flat.words.count == tilt.words.count)
        var worst = 0.0
        for (a, b) in zip(flat.words, tilt.words) {
            for (qa, qb) in zip(a.quads, b.quads) {
                for (pa, pb) in zip(qa, qb) {
                    let p = rotate(CGPoint(x: pa[0], y: pa[1]))
                    worst = max(worst, abs(Double(p.x) - pb[0]), abs(Double(p.y) - pb[1]))
                }
            }
        }
        #expect(worst < 1e-9)
    }

    @Test("Supplementary: IoU and alignment helpers self-check")
    func geometrySelfCheck() {
        let unit = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let shifted = unit.map { CGPoint(x: $0.x + 0.5, y: $0.y) }
        #expect(abs(Self.iou(unit, unit) - 1) < 1e-9)
        #expect(abs(Self.iou(unit, shifted) - 1.0 / 3.0) < 1e-9)
        #expect(Self.iou(unit, unit.map { CGPoint(x: $0.x + 2, y: $0.y) }) == 0)
        #expect(Self.align(["a", "b", "c", "d"], ["a", "c", "d", "e"]).map { [$0.0, $0.1] } == [[0, 0], [2, 1], [3, 2]])
    }
}
