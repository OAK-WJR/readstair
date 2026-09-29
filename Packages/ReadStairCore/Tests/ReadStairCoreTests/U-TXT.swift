import Foundation
import Testing
@testable import ReadStairCore

/// U-TXT-001…007: plain text files through EBookReader: encodings, Project Gutenberg markers, paragraphs, and telling text from EPUB.
@Suite("U-TXT PlainText")
struct PlainTextTests {
    /// A book of one untitled chapter of paragraphs, as plain text gives.
    private func book(_ title: String?, author: String? = nil, _ paragraphs: String...) -> EBook {
        EBook(title: title, chapters: [EBook.Chapter(blocks: paragraphs.map(TextBlock.paragraph))], author: author)
    }

    @Test("U-TXT-001 UTF-8 with a byte order mark: the mark is dropped; curly quotes and dashes are kept")
    func utf8WithByteOrderMark() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("“Curiouser and curiouser!” cried Alice—she was so surprised.".utf8)
        #expect(try EBookReader.read(data) == book(nil, "“Curiouser and curiouser!” cried Alice—she was so surprised."))
    }

    @Test("U-TXT-002 Bytes that are not UTF-8 are read as Windows-1252 (é, curly quotes, em dash, euro sign)")
    func windows1252() throws {
        // A byte per character: é, “, ”, — and € as Windows-1252 has them, none of them valid UTF-8 there
        let data = Data("The caf\u{E9} sign said \u{93}Tea\u{94} \u{97} two for 3\u{80}".unicodeScalars.map { UInt8($0.value) })
        #expect(try EBookReader.read(data) == book(nil, "The café sign said “Tea” — two for 3€"))
    }

    @Test("U-TXT-002 supplementary: bytes that are neither UTF-8 nor Windows-1252 (0x81 is undefined there) are unreadable")
    func neitherUTF8NorWindows1252() {
        #expect(throws: EBookError.unreadable) { try EBookReader.read(Data("Alice".utf8) + [0x81, 0x40]) }
    }

    @Test("U-TXT-002 supplementary: UTF-8 with one byte that is not (é in Windows-1252) stays UTF-8, that byte shown as �")
    func mostlyUTF8() throws {
        // As Windows-1252 the closing quote's last byte, 0x9D, would be undefined: the whole book unreadable
        let data = Data("“Curiouser and curiouser!” cried Alice".utf8) + [0xE9] + Data(" she was so surprised.".utf8)
        #expect(try EBookReader.read(data) == book(nil, "“Curiouser and curiouser!” cried Alice\u{FFFD} she was so surprised."))
    }

    @Test("U-TXT-003 UTF-16 with a byte order mark, either byte order", arguments: [true, false])
    func utf16WithByteOrderMark(littleEndian: Bool) throws {
        let text = "Alice’s 🐇 café\r\n\r\nDown the rabbit-hole"
        let data = Data(littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF])
            + text.data(using: littleEndian ? .utf16LittleEndian : .utf16BigEndian)!
        #expect(try EBookReader.read(data) == book(nil, "Alice’s 🐇 café", "Down the rabbit-hole"))
    }

    @Test("U-TXT-003 supplementary: UTF-16 without a byte order mark, like any data with a NUL, is unreadable rather than garbage")
    func utf16WithoutByteOrderMark() {
        #expect(throws: EBookError.unreadable) { try EBookReader.read("Alice was beginning".data(using: .utf16LittleEndian)!) }
        #expect(throws: EBookError.unreadable) { try EBookReader.read(Data("Alice\0was".utf8)) }
    }

    @Test("U-TXT-004 Project Gutenberg: only the text between the START and END markers is kept, and the Title: and Author: lines name the book and its author")
    func gutenbergMarkers() throws {
        let text = """
            The Project Gutenberg eBook of Alice’s Adventures in Wonderland

            This ebook is for the use of anyone anywhere in the United States and
            most other parts of the world at no cost and with almost no restrictions

            Title:  Alice’s Adven\u{AD}tures in Wonderland\t

            Author: Lewis Car\u{200B}roll\t

            *** START OF THE PROJECT GUTENBERG EBOOK ALICE’S ADVENTURES IN WONDERLAND ***


            CHAPTER I.
            Down the Rabbit-Hole


            Alice was beginning to get very tired of sitting by her sister on the
            bank, and of having nothing to do. By the
            end of Gutenberg's life, printing had spread.

            *** END OF PART ONE ***

            *** END OF THE PROJECT GUTENBERG EBOOK ALICE’S ADVENTURES IN WONDERLAND ***

            Updated editions will replace the previous one—the old editions will
            be renamed.
            """
        #expect(try EBookReader.read(Data(text.utf8)) == book("Alice’s Adventures in Wonderland", author: "Lewis Carroll",
            "CHAPTER I. Down the Rabbit-Hole",
            "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do. By the end of "
                + "Gutenberg's life, printing had spread.",
            "*** END OF PART ONE ***"))
    }

    @Test("U-TXT-004 supplementary: older markers, the older footer line and the oldest header's end; without a START marker a Title: line is text, and there is no title")
    func olderGutenbergMarkers() throws {
        let older = """
            Title: Alice's Adventures in Wonderland

            ***START OF THIS PROJECT GUTENBERG EBOOK ALICE'S ADVENTURES IN WONDERLAND***

            Alice was beginning to get very tired.

            End of Project Gutenberg's Alice's Adventures in Wonderland, by Lewis Carroll

            *** END OF THIS PROJECT GUTENBERG EBOOK ALICE'S ADVENTURES IN WONDERLAND ***

            *END THE SMALL PRINT! FOR PUBLIC DOMAIN EBOOKS*Ver.02/11/02*END*
            """
        #expect(try EBookReader.read(Data(older.utf8))
                == book("Alice's Adventures in Wonderland", "Alice was beginning to get very tired."))
        let oldest = """
            **The Project Gutenberg Etext of Alice in Wonderland**

            ***START**THE SMALL PRINT!**FOR PUBLIC DOMAIN ETEXTS**START***
            Why is this "Small Print!" statement here?  You know: lawyers.
            *END*THE SMALL PRINT! FOR PUBLIC DOMAIN ETEXTS*Ver.04.29.93*END*

            Alice was beginning to get very tired.

            End of The Project Gutenberg Etext of Alice in Wonderland
            """
        #expect(try EBookReader.read(Data(oldest.utf8)) == book(nil, "Alice was beginning to get very tired."))
        let notes = "Title: Notes\n\nAt the\nstart of Gutenberg's second decade, printing was new.\n"
        #expect(try EBookReader.read(Data(notes.utf8))
                == book(nil, "Title: Notes", "At the start of Gutenberg's second decade, printing was new."))
    }

    @Test("U-TXT-005 Hard-wrapped lines are joined with a space, blank lines split paragraphs; any line ending, spaces, tabs and invisible characters")
    func paragraphs() throws {
        let text = "  It was the White Rabbit,\r\ntrotting slowly back again,\r\n \t \r\n\r\nand looking anxiously about\r"
            + "as it went, \u{200B}\tas if it had\u{00A0}lost some\u{AD}thing;\n\n\n"
            + "\u{FEFF}and she heard it mut\u{200B}tering to it\u{2060}self\n"
        #expect(try EBookReader.read(Data(text.utf8)) == book(nil, "It was the White Rabbit, trotting slowly back again,",
                                                              "and looking anxiously about as it went, as if it had lost something;",
                                                              "and she heard it muttering to itself"))
    }

    @Test("U-TXT-005 supplementary: a word ending a line in a dash or soft hyphen goes on without a space; a dash standing alone keeps its spaces")
    func lineEndingInDash() throws {
        let text = "Down the rabbit-\nhole she went--\nand fell—\ndown, some\u{AD}\nthing like a well --\nor a deep one.\n\nShe fell."
        #expect(try EBookReader.read(Data(text.utf8))
                == book(nil, "Down the rabbit-hole she went--and fell—down, something like a well -- or a deep one.", "She fell."))
    }

    @Test("U-TXT-005 supplementary: when lines are paragraphs (a quarter or more over 100 characters, or under one blank-line break for 50 lines), each line is a paragraph, blank lines or not")
    func paragraphPerLine() throws {
        let long = "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice"
        let text = "Down the Rabbit-Hole\n\(long)\n“Oh dear!”\n\n\(long)\r\n\(long)\n"
        #expect(try EBookReader.read(Data(text.utf8)) == book(nil, "Down the Rabbit-Hole", long, "“Oh dear!”", long, long))
        // Dialogue with no blank lines: 40 paragraphs, not one
        let dialogue = (1...40).map { "“Line \($0), Alice?” said the Hatter." }
        #expect(try EBookReader.read(Data((dialogue.joined(separator: "\n") + "\n").utf8))
                == EBook(title: nil, chapters: [EBook.Chapter(blocks: dialogue.map(TextBlock.paragraph))]))
        // Hard-wrapped paragraphs of 25 lines, as long as the longest books' average (On Liberty's): each stays one paragraph
        let wrapped = Array(repeating: "Alice was beginning to get very tired of sitting by her sister on the", count: 25)
        let paragraph = wrapped.joined(separator: " ")
        let three = Array(repeating: wrapped.joined(separator: "\n"), count: 3).joined(separator: "\n\n")
        #expect(try EBookReader.read(Data(three.utf8)) == book(nil, paragraph, paragraph, paragraph))
    }

    @Test("U-TXT-006 No text (nothing, only whitespace or invisible characters, only a Gutenberg header and footer) → empty", arguments: [
        "",
        " \n\t\r\n  \u{00A0}\n",
        "\u{FEFF}\u{200B}\n",
        "Title: Alice\n*** START OF THE PROJECT GUTENBERG EBOOK ALICE ***\n\n*** END OF THE PROJECT GUTENBERG EBOOK ALICE ***\nLicense",
    ])
    func noText(text: String) {
        #expect(throws: EBookError.empty) { try EBookReader.read(Data(text.utf8)) }
    }

    @Test("U-TXT-006 supplementary: text over the character limit is too large; a file over 4 bytes for every character allowed is refused before it is decoded")
    func tooLarge() {
        #expect(throws: EBookError.tooLarge) { try EBookReader.read(Data(repeating: 0x61, count: EBookReader.maxCharacters + 1)) }
        let limit = EBookReader.maxCharacters * 4
        #expect(throws: EBookError.tooLarge) { try EBookReader.read(Data(repeating: 0x61, count: limit + 1)) }
    }

    @Test("U-TXT-007 EBookReader tells the format by content: data starting PK\\3\\4 goes to the EPUB reader, anything else is text")
    func formatByContent() throws {
        let text = Data("Once upon a time".utf8)
        #expect(throws: EBookError.unreadable) { try EBookReader.read(Data([0x50, 0x4B, 0x03, 0x04]) + text) }   // not a ZIP archive
        #expect(try EBookReader.read(text) == book(nil, "Once upon a time"))
        #expect(try EBookReader.read(Data("PK".utf8) + text) == book(nil, "PKOnce upon a time"))
    }
}
