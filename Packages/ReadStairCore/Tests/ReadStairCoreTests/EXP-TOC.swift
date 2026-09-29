import Foundation
import Testing
@testable import ReadStairCore

/// EXP-TOC-001: real books' tables of contents, read and laid out as an import does, against an exact oracle. It prints each
/// book's units and pages, and each titled unit's label with the page it starts on (from 1, the cover being page 1), for the
/// review. The books are not in the repository (Project Gutenberg's pg11 as EPUB with and without images and as text, pg1342,
/// pg17989 and Standard Ebooks' Alice); run it on a Mac with the folder that holds them:
/// `READSTAIR_REAL_BOOKS=<dir> swift test --filter RealBookContentsExperiment`.
@Suite("EXP-TOC Real books' tables of contents", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_REAL_BOOKS"] != nil, "Set READSTAIR_REAL_BOOKS=<dir> to run"))
struct RealBookContentsExperiment {
    private static let directory = URL(filePath: ProcessInfo.processInfo.environment["READSTAIR_REAL_BOOKS"] ?? "")

    private static let aliceChapters = ["Down the Rabbit-Hole", "The Pool of Tears", "A Caucus-Race and a Long Tale",
                                        "The Rabbit Sends in a Little Bill", "Advice from a Caterpillar", "Pig and Pepper",
                                        "A Mad Tea-Party", "The Queen’s Croquet-Ground", "The Mock Turtle’s Story",
                                        "The Lobster Quadrille", "Who Stole the Tarts?", "Alice’s Evidence"]
    private static let numerals = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"]

    /// The book's titled units' labels, after printing its units, pages and each label's first page.
    private func labels(_ name: String) throws -> [String] {
        let book = try EBookReader.read(Data(contentsOf: Self.directory.appending(path: name)))
        let typeset = try TypesetBook.make(book, fileName: name)
        let starts = (0..<typeset.pageCount).compactMap { index in typeset.chapterTitle(onPage: index).map { (index + 1, $0) } }
        let lineBreaks = book.chapters.flatMap(\.blocks).reduce(0) { total, block in total + block.text.count { $0 == "\u{2028}" } }
        ExperimentLog.record(["test": "EXP-TOC-001", "book": name, "units": book.chapters.count, "titled": starts.count,
                              "pages": typeset.pageCount, "line_breaks": lineBreaks,
                              "cover": typeset.words(onPage: 0).map(\.text).joined(separator: " ")])
        for (page, label) in starts { ExperimentLog.row("EXP-TOC-001", name, "page \(page)", label) }
        // Every titled unit starts a page of its own
        #expect(starts.map(\.1) == book.chapters.compactMap(\.title), "\(name)")
        return starts.map(\.1)
    }

    @Test("EXP-TOC-001 Real books: pg11 (nav, and NCX only) gives its 15 entries and SE Alice its 13 (no title or half-title page), Pride its title and 61 chapters with no license entry, the French book is refused, and the text file is one untitled unit")
    func realBooks() throws {
        ExperimentLog.recordEnvironment(test: "EXP-TOC-001")
        let gutenberg = ["Alice’s Adventures in Wonderland", "THE MILLENNIUM FULCRUM EDITION 3.0", "Contents"]
            + zip(Self.numerals, Self.aliceChapters).map { "CHAPTER \($0). \($1)" }
        #expect(try labels("pg11-images.epub") == gutenberg)
        #expect(try labels("pg11-noimages.epub") == gutenberg)
        #expect(try labels("se-alice.epub") == ["All in the Golden Afternoon"]
                + zip(Self.numerals, Self.aliceChapters).map { "\($0): \($1)" })

        // Pride: its title, then chapters I to LXI in order, several behind an illustration's caption, two as "CHAPTERXXVII."
        let pride = try labels("pg1342-pride.epub")
        #expect(pride.count == 62 && pride.first == "PRIDE. and PREJUDICE")
        let chapters = pride.dropFirst().map { label in
            let numeral = label.uppercased().components(separatedBy: "CHAPTER").dropFirst().first?.split(separator: ".").first
            return numeral.map { $0.trimmingCharacters(in: .whitespaces) } ?? label
        }
        #expect(chapters.map(Self.number) == Array(1...61), "\(chapters)")
        #expect(!pride.contains { $0.localizedCaseInsensitiveContains("license") || $0.lowercased() == "back" })

        #expect(throws: EBookError.notEnglish) { try EBookReader.read(Data(contentsOf: Self.directory.appending(path: "pg17989-fr.epub"))) }
        let text = try EBookReader.read(Data(contentsOf: Self.directory.appending(path: "pg11.txt")))
        #expect(text.chapters.map(\.title) == [nil])
        #expect(try labels("pg11.txt").isEmpty)
    }

    /// A Roman numeral's value; 0 if it is not one.
    private static func number(_ numeral: String) -> Int {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100]
        let digits = numeral.map { values[$0] ?? 0 }
        guard !digits.isEmpty, !digits.contains(0) else { return 0 }
        return zip(digits, digits.dropFirst() + [0]).reduce(0) { total, pair in total + (pair.0 < pair.1 ? -pair.0 : pair.0) }
    }
}
