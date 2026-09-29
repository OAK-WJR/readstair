import Foundation

/// Plain text files: the whole file is one chapter of paragraphs, with no heading detection. A Project Gutenberg file loses its
/// license header and footer, and its `Title:` and `Author:` lines name the book and its author.
enum PlainText {
    static func read(_ data: Data) throws(EBookError) -> EBook {
        // English text takes 1 or 2 bytes a character in these encodings, so a file over 4 bytes for each character allowed is far over
        // the limit: refused before it is decoded
        guard data.count <= EBookReader.maxCharacters * 4 else { throw .tooLarge }
        // A NUL means binary data, or UTF-16 without a byte order mark: refused rather than typeset as garbage
        guard let text = decode(data), !text.utf8.contains(0) else { throw .unreadable }

        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...]
        var title: String?, author: String?
        // The oldest files have no START marker: their text starts after the license header, the "small print"
        if let start = lines.firstIndex(where: { isGutenbergMarker($0, "START") }) ?? lines.firstIndex(where: isSmallPrintEnd) {
            // A header line such as `Title: …`, trimmed; nil if there is none or it is blank
            let header = lines[..<start]
            func field(_ name: String) -> String? {
                let value = header.first { $0.hasPrefix(name) }?.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
                return value?.isEmpty == false ? value : nil
            }
            title = field("Title:")
            author = field("Author:")
            lines = lines[(start + 1)...]
        }
        if let end = lines.firstIndex(where: { isGutenbergMarker($0, "END") }) {
            lines = lines[..<end]
        }

        // Blank lines end paragraphs, and the lines in between are joined: text hard-wrapped at about 70 characters, as Project
        // Gutenberg's. Lines that are paragraphs themselves (as word processors save text, a play, dialogue) often have no blank line
        // in between: when a quarter of the lines are over 100 characters, or there is under one blank-line break for 50 lines of
        // text (100 Project Gutenberg classics have one for every 3 to 26), each line is a paragraph, rather than a book being one.
        let filled = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        let breaks = zip(lines, lines.dropFirst()).count { $0.allSatisfy(\.isWhitespace) && !$1.allSatisfy(\.isWhitespace) }
        let paragraphPerLine = breaks * 50 < filled.count || filled.count(where: { $0.count > 100 }) * 4 >= filled.count
        var blocks: [TextBlock] = []
        var words: [Substring] = []
        for line in lines + [""] {   // the added blank line ends the last paragraph
            var lineWords = line.split(whereSeparator: \.isWhitespace)
            let endsParagraph = lineWords.isEmpty || paragraphPerLine
            // A word with letters ending a line in a dash or a soft hyphen goes on without a space (rabbit-|hole, went--|and,
            // fell—|down, some|thing, the soft hyphen dropped); a dash standing alone keeps its spaces. EBookReader removes the other
            // invisible characters later.
            if let last = words.last, let dash = last.last, "-—\u{AD}".contains(dash), last.contains(where: \.isLetter),
               !lineWords.isEmpty {
                words[words.count - 1] = (dash == "\u{AD}" ? last.dropLast() : last) + lineWords.removeFirst()
            }
            words += lineWords
            if endsParagraph, !words.isEmpty {
                blocks.append(.paragraph(words.joined(separator: " ")))
                words = []
            }
        }
        guard !blocks.isEmpty else { throw .empty }
        return EBook(title: title, chapters: [EBook.Chapter(blocks: blocks)], author: author)
    }

    /// UTF-16 only with a byte order mark. Otherwise UTF-8 (without its byte order mark) if the bytes are valid UTF-8, or mostly
    /// are, else Windows-1252; nil if they are not that either (Windows-1252 leaves five byte values undefined).
    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)   // takes the byte order from the mark and drops it
        }
        let data = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        if let text = String(data: data, encoding: .utf8) { return text }
        // UTF-8 with a few bytes that are not (a truncated download, text pasted together) stays UTF-8, a � for each, when they are
        // fewer than the characters beyond ASCII that decode, which Windows-1252 would garble. Windows-1252 text has almost none.
        let lossy = String(decoding: data, as: UTF8.self)
        let replaced = lossy.unicodeScalars.count { $0 == "\u{FFFD}" }
        let decoded = lossy.unicodeScalars.count { !$0.isASCII } - replaced
        return replaced < decoded ? lossy : String(data: data, encoding: .windowsCP1252)
    }

    /// A Project Gutenberg marker, a line in any case, with or without stars: `*** START OF THE PROJECT GUTENBERG EBOOK ALICE’S
    /// ADVENTURES IN WONDERLAND ***`, `***START OF THIS PROJECT GUTENBERG EBOOK …`, the same with END, and the older footer's
    /// first line (`End of the Project Gutenberg EBook of …`, `End of Project Gutenberg's …`). Prose such as `end of Gutenberg's
    /// life` or `*** END OF PART ONE ***` is not one. A marker wrapped onto two lines leaves its second line in the text.
    private static func isGutenbergMarker(_ line: Substring, _ word: String) -> Bool {
        let text = line.drop { $0 == "*" || $0.isWhitespace }
        // Most lines fail on their first letter, before the line is uppercased
        guard let first = text.first, first.uppercased() == word.prefix(1) else { return false }
        let start = text.prefix(31).uppercased()   // as long as the longest form, START OF THIS PROJECT GUTENBERG
        return ["", "THE ", "THIS "].contains { start.hasPrefix("\(word) OF \($0)PROJECT GUTENBERG") }
    }

    /// The last line of the oldest license header: `*END*THE SMALL PRINT! FOR PUBLIC DOMAIN ETEXTS*Ver.04.29.93*END*`. Files from
    /// about 2002 have it at the end, after an END marker, and a START marker at the top.
    private static func isSmallPrintEnd(_ line: Substring) -> Bool {
        line.hasPrefix("*END") && line.dropFirst(4).drop { $0 == "*" || $0 == " " }.hasPrefix("THE SMALL PRINT!")
    }
}
