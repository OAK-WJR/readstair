#!/usr/bin/env swift
// Renders test book pages from chapter 1 of the Standard Ebooks edition of "Alice's Adventures in Wonderland" (CC0) and exports each word's ground-truth box.
// Usage (from the repository root): swift tools/make-fixtures.swift
// Output: Fixtures/alice-p1.png + .json (upright page) and Fixtures/alice-p1-tilt8.png + .json (whole page rotated 8°).
// Ground-truth box = the word's glyph advance width on its typeset line × the line's ascent + descent; normalized coordinates, top-left origin, corners in TL TR BR BL order.
// A word broken across lines gets two boxes (this page happens to have none).
// Font: Source Serif 4 Regular 4.005 (Adobe, SIL Open Font License 1.1), read from build/fonts/ (git-ignored: the font is not
// redistributed here) and checked against its sha256; the script stops rather than fall back to a system font. Get it from
// https://github.com/adobe-fonts/source-serif/releases/tag/4.005R (source-serif-4.005_Desktop.zip, OTF/SourceSerif4-Regular.otf).
import AppKit
import CoreText
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

let pageWidth = 1400, pageHeight = 2100
let margin: CGFloat = 130, fontSize: CGFloat = 37, lineSpacing: CGFloat = 8, indent: CGFloat = 48
let tiltDegrees: CGFloat = 8

struct TruthWord: Codable { var text: String; var quads: [[[Double]]] }
struct Truth: Codable {
    var source: String
    var license: String
    var font: String
    var imageWidth: Int
    var imageHeight: Int
    /// Tilted pages: which upright page they were rotated from, and by how many degrees counterclockwise about its center (nil for upright pages)
    var rotatedFrom: String? = nil
    var rotationDegrees: Double? = nil
    var words: [TruthWord]
}

// MARK: Read paragraphs (skipping the chapter-heading hgroup)

final class ParagraphCollector: NSObject, XMLParserDelegate {
    var paragraphs: [String] = []
    private var inHeading = false
    private var current: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "hgroup" { inHeading = true }
        if name == "p", !inHeading { current = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { current?.append(string) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "hgroup" { inHeading = false }
        if name == "p", let text = current {
            let cleaned = text.replacingOccurrences(of: "\u{2060}", with: "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !cleaned.isEmpty { paragraphs.append(cleaned) }
            current = nil
        }
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appending(path: "Fixtures/source/alice-chapter-1.xhtml")
guard let parser = XMLParser(contentsOf: sourceURL) else { fatalError("Not found: \(sourceURL.path)") }
let collector = ParagraphCollector()
parser.delegate = collector
guard parser.parse() else { fatalError("XHTML parsing failed: \(String(describing: parser.parserError))") }

// MARK: Typesetting

let fontURL = root.appending(path: "build/fonts/SourceSerif4-Regular.otf")
let fontSHA256 = "edf160d0d584deee8a3bb2c3371b2a7624ca63580fbe02c57c1f4c91e84d8787"
guard let fontData = try? Data(contentsOf: fontURL) else {
    fatalError("Missing \(fontURL.path): download source-serif-4.005_Desktop.zip from https://github.com/adobe-fonts/source-serif/releases/tag/4.005R and put OTF/SourceSerif4-Regular.otf there")
}
guard SHA256.hash(data: fontData).map({ String(format: "%02x", $0) }).joined() == fontSHA256 else {
    fatalError("\(fontURL.path) is not Source Serif 4 Regular 4.005 (sha256 \(fontSHA256))")
}
guard let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor])?.first else {
    fatalError("Cannot read the font at \(fontURL.path)")
}
let serif = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil) as NSFont
let style = NSMutableParagraphStyle()
style.alignment = .justified
style.firstLineHeadIndent = indent
style.lineSpacing = lineSpacing
let text = collector.paragraphs.joined(separator: "\n") as NSString
let attributed = NSAttributedString(string: text as String, attributes: [.font: serif, .paragraphStyle: style,
                                                                         .foregroundColor: NSColor.black])
let frameRect = CGRect(x: margin, y: margin, width: CGFloat(pageWidth) - 2 * margin,
                       height: CGFloat(pageHeight) - 2 * margin)
let framesetter = CTFramesetterCreateWithAttributedString(attributed)
let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil)
let lines = CTFrameGetLines(frame) as! [CTLine]
var origins = [CGPoint](repeating: .zero, count: lines.count)
CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
let visible = CTFrameGetVisibleStringRange(frame)
let visibleEnd = visible.location + visible.length

// MARK: Ground-truth boxes (split words on whitespace, intersect them with typeset lines)

var words: [TruthWord] = []
let whitespace = CharacterSet.whitespacesAndNewlines
var index = 0
while index < visibleEnd {
    while index < visibleEnd, let s = Unicode.Scalar(text.character(at: index)), whitespace.contains(s) { index += 1 }
    let start = index
    while index < visibleEnd, !(Unicode.Scalar(text.character(at: index)).map(whitespace.contains) ?? false) { index += 1 }
    guard index > start else { continue }
    var quads: [[[Double]]] = []
    for (line, origin) in zip(lines, origins) {
        let range = CTLineGetStringRange(line)
        let lo = max(start, range.location), hi = min(index, range.location + range.length)
        guard lo < hi else { continue }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let x0 = frameRect.minX + origin.x + CTLineGetOffsetForStringIndex(line, lo, nil)
        let x1 = frameRect.minX + origin.x + CTLineGetOffsetForStringIndex(line, hi, nil)
        let top = CGFloat(pageHeight) - (frameRect.minY + origin.y + ascent)
        let bottom = CGFloat(pageHeight) - (frameRect.minY + origin.y - descent)
        let w = Double(pageWidth), h = Double(pageHeight)
        quads.append([[x0 / w, top / h], [x1 / w, top / h], [x1 / w, bottom / h], [x0 / w, bottom / h]]
            .map { $0.map { Double($0) } })
    }
    words.append(TruthWord(text: text.substring(with: NSRange(location: start, length: index - start)), quads: quads))
}

// MARK: Rendering and output

func makeContext(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx
}

/// `path` is relative to the repository root, without the extension.
func writePNG(_ image: CGImage, _ path: String) {
    let url = root.appending(path: "\(path).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Failed to write PNG: \(url.path)") }
}

func writeJSON(_ truth: Truth, _ name: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try! encoder.encode(truth).write(to: root.appending(path: "Fixtures/\(name).json"))
}

let fontName = "\(serif.fontName) \(Int(fontSize))px"
let source = "Standard Ebooks, Alice's Adventures in Wonderland (John Tenniel), src/epub/text/chapter-1.xhtml"
let license = "CC0 1.0 (Standard Ebooks' edition; ReadStair authors' rendering and boxes); source text public domain"

let pageContext = makeContext(width: pageWidth, height: pageHeight)
CTFrameDraw(frame, pageContext)
let page = pageContext.makeImage()!
writePNG(page, "Fixtures/alice-p1")
writeJSON(Truth(source: source, license: license, font: fontName, imageWidth: pageWidth, imageHeight: pageHeight,
                words: words), "alice-p1")

// Tilted page: rotate the whole page counterclockwise about its center, grow the canvas to fit the rotated page, and transform the ground-truth boxes to match.
let angle = tiltDegrees * .pi / 180
let w = CGFloat(pageWidth), h = CGFloat(pageHeight)
let tiltWidth = Int((w * cos(angle) + h * sin(angle)).rounded(.up))
let tiltHeight = Int((w * sin(angle) + h * cos(angle)).rounded(.up))
let tiltContext = makeContext(width: tiltWidth, height: tiltHeight)
tiltContext.interpolationQuality = .high
tiltContext.translateBy(x: CGFloat(tiltWidth) / 2, y: CGFloat(tiltHeight) / 2)
tiltContext.rotate(by: angle)
tiltContext.draw(page, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
writePNG(tiltContext.makeImage()!, "Fixtures/alice-p1-tilt8")

func tilt(_ p: [Double]) -> [Double] {
    // Top-left normalized → page-centered, y-up coordinates → rotate → top-left normalized on the new canvas
    let x = CGFloat(p[0]) * w - w / 2, y = h / 2 - CGFloat(p[1]) * h
    let rx = x * cos(angle) - y * sin(angle), ry = x * sin(angle) + y * cos(angle)
    return [Double((rx + CGFloat(tiltWidth) / 2) / CGFloat(tiltWidth)),
            Double((CGFloat(tiltHeight) / 2 - ry) / CGFloat(tiltHeight))]
}
let tiltedWords = words.map { TruthWord(text: $0.text, quads: $0.quads.map { $0.map(tilt) }) }
writeJSON(Truth(source: source, license: license, font: fontName, imageWidth: tiltWidth, imageHeight: tiltHeight,
                rotatedFrom: "alice-p1", rotationDegrees: Double(tiltDegrees), words: tiltedWords), "alice-p1-tilt8")

print("✓ \(words.count) words, \(lines.count) lines, font \(fontName); tilted page \(tiltWidth)×\(tiltHeight)")
