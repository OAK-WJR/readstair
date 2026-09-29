import Foundation

/// A block of an electronic book's text, in reading order. Its whitespace is collapsed as `EBookReader.collapsingWhitespace` does:
/// one space between words, or one U+2028 LINE SEPARATOR where a line breaks inside the block (verse), and none at either end.
public enum TextBlock: Sendable, Hashable {
    case heading(String)
    case paragraph(String)

    /// The block's text, whichever kind it is.
    var text: String {
        switch self {
        case .heading(let text), .paragraph(let text): text
        }
    }
}

/// An electronic book's text: its title and author, if the file names them, and its text in page-break units.
public struct EBook: Sendable, Hashable {
    /// A page-break unit of the text: it starts on a new page when typeset. `title` is the label of the book's own
    /// table-of-contents entry that starts it, if any.
    public struct Chapter: Sendable, Hashable {
        public var title: String?
        public var blocks: [TextBlock]

        public init(title: String? = nil, blocks: [TextBlock]) {
            self.title = title
            self.blocks = blocks
        }
    }

    public var title: String?
    public var author: String?
    /// The EPUB's own cover image as the file holds it (JPEG, PNG, GIF or WebP); nil if it names none, and for a text file.
    public var cover: Data?
    public var chapters: [Chapter]

    public init(title: String?, chapters: [Chapter], author: String? = nil, cover: Data? = nil) {
        self.title = title
        self.author = author
        self.cover = cover
        self.chapters = chapters
    }
}

/// Why a book file could not be opened. The app shows one alert for all of them.
public enum EBookError: Error, Equatable {
    /// Copy protection (encrypted content, a rights file, or an encrypted ZIP entry).
    case drm
    /// Not a readable EPUB or text file.
    case unreadable
    /// No text at all.
    case empty
    /// Over the size limits (`EBookReader.maxFileBytes`, `maxCharacters`, or a ZIP entry over its limit).
    case tooLarge
    /// The book says it is not in English (`dc:language`).
    case notEnglish
}

/// Reads an EPUB or a plain text file into an `EBook`. The format is chosen by content, not by file extension: data that starts
/// like a ZIP archive is read as EPUB, anything else as text.
public enum EBookReader {
    /// About ten long novels: a limit on what is read into memory at once.
    public static let maxFileBytes = 200 << 20
    /// About 2,500 typeset pages.
    static let maxCharacters = 4_000_000
    /// Soft hyphen, zero-width space, word joiner and byte order mark: invisible, and they would split or join words. They are not
    /// whitespace, so both formats keep them inside words, and they are removed here, once.
    private static let invisible: Set<Unicode.Scalar> = ["\u{AD}", "\u{200B}", "\u{2060}", "\u{FEFF}"]

    public static func read(_ data: Data) throws(EBookError) -> EBook {
        guard data.count <= maxFileBytes else { throw .tooLarge }
        var book = data.starts(with: [0x50, 0x4B, 0x03, 0x04]) ? try EPUB.read(data) : try PlainText.read(data)
        book.title = book.title.flatMap(visible)
        book.author = book.author.flatMap(visible)
        // A chapter left with no text is dropped, and its title with it
        book.chapters = book.chapters.compactMap { chapter in
            let blocks = chapter.blocks.compactMap { block in
                switch block {
                case .heading(let text): visible(text).map(TextBlock.heading)
                case .paragraph(let text): visible(text).map(TextBlock.paragraph)
                }
            }
            return blocks.isEmpty ? nil : EBook.Chapter(title: chapter.title.flatMap(visible), blocks: blocks)
        }
        let characters = book.chapters.lazy.flatMap(\.blocks).reduce(0) { $0 + $1.text.count }
        guard characters > 0 else { throw .empty }
        guard characters <= maxCharacters else { throw .tooLarge }
        return book
    }

    /// The text without invisible characters, whitespace collapsed again where one stood between spaces (a line break stays one);
    /// nil if nothing is left. Text without any, the usual case, is returned as it is.
    private static func visible(_ text: String) -> String? {
        guard text.unicodeScalars.contains(where: { !$0.isASCII && invisible.contains($0) }) else { return text.isEmpty ? nil : text }
        let collapsed = collapsingWhitespace(String(String.UnicodeScalarView(text.unicodeScalars.filter { !invisible.contains($0) })))
        return collapsed.isEmpty ? nil : collapsed
    }

    /// `text` with each run of whitespace made one U+2028 LINE SEPARATOR if the run holds one (a line break), else one space, and
    /// none left at either end: a block's text, as XHTMLText collects it and `visible` keeps it.
    static func collapsingWhitespace(_ text: String) -> String {
        var collapsed = "", separator: Character?
        for character in text {
            if !character.isWhitespace {
                if let pending = separator { collapsed.append(pending) }
                separator = nil
                collapsed.append(character)
            } else if !collapsed.isEmpty, separator != "\u{2028}" {
                separator = character == "\u{2028}" ? character : " "
            }
        }
        return collapsed
    }
}
