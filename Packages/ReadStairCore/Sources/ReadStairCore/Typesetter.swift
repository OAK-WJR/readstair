import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
private typealias SystemFont = UIFont
private typealias SystemColor = UIColor
#else
import AppKit
private typealias SystemFont = NSFont
private typealias SystemColor = NSColor
#endif

/// How an electronic book's pages are typeset, for reading at fit width with no zoom. 1200×1800 px has the shape of a photographed
/// page; at a 393 pt phone's fit width it is about 3.2 px per point, so 54 px body text reads at about 17 pt. The cover's title is
/// 150 px, large enough to read as a cover in Books' grid, its first line 30% of the way down, and the author 72 px, 64 px below it;
/// a cover that does not fit is set in smaller type. The cover is one of `coverColors`, its text white or black (`coverTextColor`).
struct PageStyle {
    let width = 1200, height = 1800
    let margin: CGFloat = 72, fontSize: CGFloat = 54, lineSpacing: CGFloat = 16, indent: CGFloat = 54, headingSize: CGFloat = 70
    let authorSpace: CGFloat = 64, coverTop: CGFloat = 0.3
    /// The cover's title and author sizes, largest first: the first that fits the whole cover on its page is used.
    let coverSizes: [(title: CGFloat, author: CGFloat)] = [(150, 72), (104, 50), (72, 36)]
    /// The cover's backgrounds, sRGB: Apple's standard system colors as this system draws them in light mode, in the order of Apple's
    /// palette, orange, yellow, mint, teal, cyan, blue, indigo, purple and brown; no red or pink, the accent's, and no green, the
    /// color of Books' progress line, which is drawn just under the cover.
    let coverColors: [UInt32] = PageStyle.systemColors()
    static let phone = PageStyle()

    /// The cover's background for a title: the title's 64-bit FNV-1a hash over UTF-8, modulo the palette, so a title has the same
    /// color on every launch and device (Swift's `hashValue` is seeded per launch).
    func coverColor(title: String) -> UInt32 {
        let hash = title.utf8.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
        return coverColors[Int(hash % UInt64(coverColors.count))]
    }

    /// The cover's text on `background`: white where it reaches 3:1, the WCAG 2 contrast for large text, as on the deeper colors
    /// (Apple's white-on-color buttons); else black, which is then over 7:1.
    static func coverTextColor(on background: UInt32) -> CGColor {
        let linear = [16, 8, 0].map { shift in
            let value = CGFloat(background >> UInt32(shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        return CGColor(gray: (1 + 0.05) / (luminance + 0.05) >= 3 ? 1 : 0, alpha: 1)
    }

    /// The system colors of `coverColors`, resolved for light mode and converted to sRGB.
    private static func systemColors() -> [UInt32] {
        let colors: [SystemColor] = [.systemOrange, .systemYellow, .systemMint, .systemTeal, .systemCyan, .systemBlue, .systemIndigo,
                                     .systemPurple, .systemBrown]
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return colors.map { color in
            #if canImport(UIKit)
            let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
            #else
            var resolved = color.cgColor
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { resolved = color.cgColor }
            #endif
            let components = resolved.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0]
            return [0, 1, 2].reduce(0) { $0 << 8 | UInt32((min(max(components[$1], 0), 1) * 255).rounded()) }
        }
    }

    /// Where the text goes, in Core Graphics' bottom-up coordinates.
    var textRect: CGRect { CGRect(x: margin, y: margin, width: CGFloat(width) - 2 * margin, height: CGFloat(height) - 2 * margin) }

    /// Where the cover's text goes: the text's rect from `coverTop` down.
    var coverRect: CGRect {
        CGRect(x: margin, y: margin, width: CGFloat(width) - 2 * margin, height: CGFloat(height) * (1 - coverTop) - margin)
    }

    /// One page of a framesetter's text set in `rect`: `length` characters from `start`, or as many as fit when `length` is 0.
    func frame(_ framesetter: CTFramesetter, in rect: CGRect, from start: Int, length: Int = 0) -> CTFrame {
        CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: length), CGPath(rect: rect, transform: nil), nil)
    }

    /// Body text is ragged right with an indented first line; a paragraph with line breaks (verse) has none, so its lines align, and
    /// half a body size of space after it, so its stanzas stand apart. A heading is semibold and centred, with a body size of space
    /// after it.
    func attributes(heading: Bool, lineBreaks: Bool = false) -> [NSAttributedString.Key: Any] {
        heading ? attributes(size: headingSize, weight: .semibold, centred: true, spaceAfter: fontSize)
            : attributes(size: fontSize, weight: .regular, indent: lineBreaks ? 0 : indent, spaceAfter: lineBreaks ? fontSize / 2 : 0)
    }

    /// The cover's title, semibold, or its author, regular, at one of `coverSizes`, in the text color for `background`: centred,
    /// with `authorSpace` from the title's last line to the author's first (the line spacing and the title's space after it).
    func coverAttributes(author: Bool, sizes: (title: CGFloat, author: CGFloat), background: UInt32) -> [NSAttributedString.Key: Any] {
        var cover = author ? attributes(size: sizes.author, weight: .regular, centred: true)
            : attributes(size: sizes.title, weight: .semibold, centred: true, spaceAfter: authorSpace - lineSpacing)
        cover[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = Self.coverTextColor(on: background)
        return cover
    }

    /// The system serif (New York), never hyphenated.
    private func attributes(size: CGFloat, weight: SystemFont.Weight, centred: Bool = false, indent: CGFloat = 0,
                            spaceAfter: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let system = SystemFont.systemFont(ofSize: size, weight: weight)
        let font = system.fontDescriptor.withDesign(.serif).flatMap { SystemFont(descriptor: $0, size: size) } ?? system
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centred ? .center : .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing
        paragraph.firstLineHeadIndent = indent
        paragraph.paragraphSpacing = spaceAfter
        return [.font: font as CTFont, .paragraphStyle: paragraph]
    }
}

enum Typesetter {
    /// Lays a book out into pages. With a title, a cover comes first: an untitled chapter of one page with the title and the book's
    /// author, trimmed and capped as a title is. Then each chapter of the text is one attributed string (blocks joined by line
    /// breaks) with its own framesetter, so it starts on a new page; a chapter with no text is dropped, and its title with it, and a
    /// book with no text has no pages, not even the cover. Only each page's range is kept; pages are drawn when asked for. A page
    /// never ends inside a word: when its last line breaks within one (after a hyphen, at a dash or slash, or inside an over-long
    /// word), the page ends before the line the word starts on, unless that is the page's first line. A line break inside a block
    /// (U+2028) breaks the line and draws nothing.
    static func paginate(_ book: EBook, title: String?) -> TypesetBook {
        let style = PageStyle.phone
        let body = style.attributes(heading: false), heading = style.attributes(heading: true)
        let verse = style.attributes(heading: false, lineBreaks: true)
        var chapters: [TypesetBook.Chapter] = [], chapterTitles: [String?] = [], pages: [TypesetBook.Page] = []
        if let title, !title.isEmpty, let cover = typesetCover(title: title, author: TypesetBook.capped(book.author), style: style) {
            chapters.append(cover.chapter)
            chapterTitles.append(nil)
            pages.append(TypesetBook.Page(chapter: 0, start: 0, length: cover.length))
        }
        let coverPages = pages.count
        for chapter in book.chapters {
            let text = NSMutableAttributedString()
            for block in chapter.blocks {
                let (string, attributes) = switch block {
                case .heading(let string): (string, heading)
                case .paragraph(let string): (string, string.contains("\u{2028}") ? verse : body)
                }
                // Each piece carries the paragraph break (\n) that ends it: a paragraph's attributes must cover its break too
                for piece in pieces(of: string) where !piece.allSatisfy(\.isWhitespace) {
                    text.append(NSAttributedString(string: piece + "\n", attributes: attributes))
                }
            }
            guard text.length > 0 else { continue }
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let units = text.string as NSString
            func inWord(_ index: Int) -> Bool { !(Unicode.Scalar(units.character(at: index))?.properties.isWhitespace ?? false) }
            var start = 0
            while start < text.length {
                let frame = style.frame(framesetter, in: style.textRect, from: start)
                var length = CTFrameGetVisibleStringRange(frame).length
                guard length > 0 else { break }  // Nothing fits: end the chapter rather than loop forever
                if start + length < text.length, inWord(start + length - 1), inWord(start + length) {
                    var first = start + length - 1  // The first character of the word the page would cut
                    while first > start, inWord(first - 1) { first -= 1 }
                    let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
                    if let line = lines.dropFirst().last(where: { CTLineGetStringRange($0).location <= first }) {
                        length = CTLineGetStringRange(line).location - start
                    }
                }
                pages.append(TypesetBook.Page(chapter: chapters.count, start: start, length: length))
                start += length
            }
            chapters.append(TypesetBook.Chapter(text: text.string, framesetter: framesetter, rect: style.textRect))
            chapterTitles.append(chapter.title)
        }
        guard pages.count > coverPages else {
            return TypesetBook(title: title, style: style, chapters: [], chapterTitles: [], pages: [], cover: nil)
        }
        return TypesetBook(title: title, style: style, chapters: chapters, chapterTitles: chapterTitles, pages: pages,
                           cover: coverPages > 0 ? book.cover.flatMap(TypesetBook.usableCover) : nil)
    }

    /// The cover's text at the largest of `coverSizes` that fits it whole from `coverTop` down within the margins, so every cover's
    /// title starts at the same height. The smallest fits a title and an author both at `TypesetBook.maxTitleLength` in wide letters.
    /// It is on the title's color, in black or white.
    private static func typesetCover(title: String, author: String?, style: PageStyle) -> (chapter: TypesetBook.Chapter, length: Int)? {
        var cover: (chapter: TypesetBook.Chapter, length: Int)?
        let background = style.coverColor(title: title)
        for sizes in style.coverSizes {
            let titled = style.coverAttributes(author: false, sizes: sizes, background: background)
            let text = NSMutableAttributedString(string: title, attributes: titled)
            if let author {
                // The line break ends the title's paragraph, so it carries the title's attributes
                text.append(NSAttributedString(string: "\n", attributes: titled))
                text.append(NSAttributedString(string: author, attributes: style.coverAttributes(author: true, sizes: sizes,
                                                                                                  background: background)))
            }
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let length = CTFrameGetVisibleStringRange(style.frame(framesetter, in: style.coverRect, from: 0)).length
            let chapter = TypesetBook.Chapter(text: text.string, framesetter: framesetter, rect: style.coverRect, background: background)
            cover = length > 0 ? (chapter, length) : cover
            if length == text.length { return cover }
        }
        return cover
    }

    /// Core Text lays a paragraph out more slowly the further into it a page starts, and a text file with no blank lines can be one
    /// paragraph as long as the book: a block over this many characters is set as several.
    static let maxBlockLength = 3_000

    /// `text` in pieces of at most `maxBlockLength` characters, each cut at the last sentence end that fits (a space after `.`, `?`
    /// or `!` and any closing quotes), else at the last space, else at the limit. The space cut at is dropped.
    static func pieces(of text: String) -> [Substring] {
        var pieces: [Substring] = [], rest = text[...]
        while let limit = rest.index(rest.startIndex, offsetBy: maxBlockLength, limitedBy: rest.endIndex), limit < rest.endIndex {
            let window = rest[...limit]
            func endsSentence(_ space: Substring.Index) -> Bool {
                window[..<space].reversed().drop { "\"”’')]".contains($0) }.first.map { ".?!".contains($0) } ?? false
            }
            let space = window.indices.last { window[$0].isWhitespace && endsSentence($0) } ?? window.lastIndex(where: \.isWhitespace)
            pieces.append(rest[..<(space ?? limit)])
            rest = rest[(space.map(rest.index(after:)) ?? limit)...]
        }
        return pieces + [rest]
    }
}

/// An electronic book laid out into pages; each page is rendered, with its words and their boxes, when asked for. Core Text is
/// used from one thread at a time: the framesetters sit behind a lock.
public final class TypesetBook: Sendable {
    struct Chapter {
        let text: String
        let framesetter: CTFramesetter
        /// Where its pages' text is set: `PageStyle.textRect`, or the cover's.
        let rect: CGRect
        /// The cover's background, sRGB; nil for a chapter of the text, black on white.
        var background: UInt32?
    }

    /// Where a page's text is in its chapter, in UTF-16 units.
    struct Page {
        let chapter: Int, start: Int, length: Int
    }

    public let title: String?
    /// The book's own cover image, which its cover page shows as an import saves it (`importPage`); nil for none, or one that is not
    /// a JPEG, PNG, GIF or WebP, too small to read as a cover on Books (under 600 px on its long edge) or too large to decode
    /// safely (over 40 megapixels).
    let cover: Data?
    private let style: PageStyle
    private let chapters: Mutex<[Chapter]>
    /// Each chapter's title, by the chapter's index: plain values, so they need no lock.
    private let chapterTitles: [String?]
    private let pages: [Page]

    init(title: String?, style: PageStyle, chapters: sending [Chapter], chapterTitles: [String?], pages: [Page], cover: Data?) {
        self.title = title
        self.cover = cover
        self.style = style
        self.chapters = Mutex(chapters)
        self.chapterTitles = chapterTitles
        self.pages = pages
    }

    public var pageCount: Int { pages.count }

    /// Page `index` (from 0): its image, black text on white or the cover's black or white on its color, its text, analyzed like a
    /// recognized page, and the title of the chapter it starts. nil if out of range. The cover's plain words become names, keeping
    /// their bands: as with any name, no level marks them, opening a card saves nothing and the card shows the word as printed, yet
    /// a tap finds each by its box and Mark as New stores its true band. A word the user marked as new is still underlined there,
    /// by design, as on any page: hiding it would leave the card's button at odds with the word's state.
    func page(_ index: Int) -> ImportPage? {
        guard let (image, words, cover) = typeset(index, draw: true), let image else { return nil }
        var text = PageAnalyzer.analyze(words, lexicon: .bundled)
        if cover { for i in text.words.indices where text.words[i].kind == .word { text.words[i].kind = .name } }
        return ImportPage(image: image, text: text, chapter: chapterTitle(onPage: index))
    }

    /// Page `index` as an import saves it: `page(index)`, but with a cover of its own the cover page shows that image in place of the
    /// generated one (saved on white, like every page image: `PageImageFile.fitting`). It keeps the generated cover's words, the title
    /// and the author as names, without their boxes: the image prints them elsewhere, if at all, so no tap finds them and nothing marks
    /// them (`Annotator.markedWords`), and the page is saved already read like the others. If the image cannot be decoded after all,
    /// the generated cover.
    public func importPage(_ index: Int) async -> ImportPage? {
        guard var page = page(index) else { return nil }
        guard index == 0, let cover, let image = await Recognition.pageImage(from: cover) else { return page }
        page.image = image
        if var text = page.text {
            for i in text.words.indices { text.words[i].quads = [] }
            page.text = text
        }
        return page
    }

    /// `data` if it holds a JPEG, PNG, GIF or WebP image, the raster formats EPUB allows, 600 px or more on its long edge and at
    /// most 40 megapixels. The file is untrusted, so ImageIO's other formats (TIFF, HEIC, camera RAW and more) are never decoded.
    static func usableCover(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg, .png, .gif, .webP].contains(where: { $0.identifier == type }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) >= 600, width * height <= 40_000_000 else { return nil }
        return data
    }

    /// The title of the chapter that starts on page `index`: nil on every other page of it, for an untitled chapter, and out of range.
    func chapterTitle(onPage index: Int) -> String? {
        guard pages.indices.contains(index), pages[index].start == 0 else { return nil }
        return chapterTitles[pages[index].chapter]
    }

    /// The words on page `index` in reading order, before analysis; empty if out of range.
    func words(onPage index: Int) -> [RecognizedWord] {
        typeset(index, draw: false)?.words ?? []
    }

    /// The page's image (if `draw`), its words, and whether it is the cover.
    private func typeset(_ index: Int, draw: Bool) -> (image: CGImage?, words: [RecognizedWord], cover: Bool)? {
        guard pages.indices.contains(index) else { return nil }
        let page = pages[index]
        return chapters.withLock { chapters in
            let chapter = chapters[page.chapter]
            let frame = style.frame(chapter.framesetter, in: chapter.rect, from: page.start, length: page.length)
            return (draw ? render(frame, background: chapter.background) : nil, words(in: frame, rect: chapter.rect, text: chapter.text),
                    chapter.background != nil)
        }
    }

    private func render(_ frame: CTFrame, background: UInt32?) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: style.width, height: style.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rgb = background ?? 0xFFFFFF
        func channel(_ shift: UInt32) -> CGFloat { CGFloat(rgb >> shift & 0xFF) / 255 }
        context.setFillColor(CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: style.width, height: style.height))
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    /// The frame's words: its text split at whitespace, then at dashes by `Recognition.splitAtDashes`. A word's box spans its glyph
    /// advances on the line, from the line's ascent above the baseline to its descent below (as Vision and the fixture ground truth
    /// do, so an underline clears g, p and y). A word broken across lines (after a hyphen or slash, or inside an over-long word) gets
    /// one box per line; `Typesetter.paginate` never breaks one across pages. `rect` is the one the frame was set in.
    private func words(in frame: CTFrame, rect: CGRect, text: String) -> [RecognizedWord] {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let visible = CTFrameGetVisibleStringRange(frame)
        let page = (text as NSString).substring(with: NSRange(location: visible.location, length: visible.length))
        let width = CGFloat(style.width), height = CGFloat(style.height)

        func quads(from start: Int, to end: Int) -> [Quad] {
            zip(lines, origins).compactMap { line, origin in
                let range = CTLineGetStringRange(line)
                let lo = max(start, range.location), hi = min(end, range.location + range.length)
                guard lo < hi else { return nil }
                var ascent: CGFloat = 0, descent: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                let x = rect.minX + origin.x, baseline = height - rect.minY - origin.y
                let x0 = x + CTLineGetOffsetForStringIndex(line, lo, nil), x1 = x + CTLineGetOffsetForStringIndex(line, hi, nil)
                return Quad(CGRect(x: x0 / width, y: (baseline - ascent) / height, width: (x1 - x0) / width,
                                   height: (ascent + descent) / height))
            }
        }

        var words: [RecognizedWord] = []
        for token in page.split(whereSeparator: \.isWhitespace) {
            // splitAtDashes decides where a word splits; each piece's box comes from its own glyphs rather than a share of the word's
            var start = visible.location + NSRange(token.startIndex..<token.endIndex, in: page).location
            for piece in Recognition.splitAtDashes(RecognizedWord(text: String(token), quads: [])) {
                let end = start + piece.text.utf16.count
                words.append(RecognizedWord(text: piece.text, quads: quads(from: start, to: end)))
                start = end
            }
        }
        return words
    }

    /// Reads a book file and lays it out.
    @concurrent
    public static func make(from data: Data, fileName: String) async throws(EBookError) -> TypesetBook {
        try make(EBookReader.read(data), fileName: fileName)
    }

    /// Lays a book out, its cover first; `.empty` if no page has text. The title is the book's own, or else the file name without
    /// its extension; either is trimmed and capped at `maxTitleLength`, and a blank one counts as missing.
    static func make(_ book: EBook, fileName: String) throws(EBookError) -> TypesetBook {
        let typeset = Typesetter.paginate(book, title: capped(book.title) ?? title(fromFileName: fileName))
        guard typeset.pageCount > 0 else { throw .empty }
        return typeset
    }

    static func title(fromFileName name: String) -> String {
        capped((name as NSString).deletingPathExtension) ?? capped(name) ?? name
    }

    /// The most characters kept of a title, a book's or a chapter's, or of an author; the app caps a rename at it too.
    public static let maxTitleLength = 100

    /// `text` trimmed and capped at `maxTitleLength`; nil if it is blank.
    static func capped(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(maxTitleLength))
    }
}
