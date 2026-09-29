import UIKit
import XCTest

/// What the tests import: CC0 renderings with their ground truth and EPUBs in Fixtures/, and pages and files made at run time. An
/// e-book's page 1 is the cover the app sets from its title (and author), so its text starts on page 2.
@MainActor
enum Fixture {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures", directoryHint: .isDirectory)
    /// A page of Alice's Adventures in Wonderland.
    static let alice = directory.appending(path: "alice-p1.png")
    /// The same page rotated 8° counter-clockwise.
    static let aliceTilted = directory.appending(path: "alice-p1-tilt8.png")
    /// Where every word of alice-p1.png is, independent of the app: the oracle for tapping words the app does not mark.
    static let aliceTruth = Truth.load(directory.appending(path: "alice-p1.json"))
    /// Chapter I of the same book as an EPUB, whose title is the sample book's, with no table of contents (tools/make-epub.sh).
    /// The chapter starts on page 2, with `peeped`.
    static let aliceEPUB = directory.appending(path: "alice-chapter-1.epub")
    /// `Three Chapters` (tools/make-epub.sh): a title page its table of contents leaves out, chapter I, then two short entries of one
    /// file, the second at an anchor in its middle. Page 1 is the cover, page 2 the title page, and chapter I starts on page 3; the
    /// two short entries take the last two pages.
    static let chaptersEPUB = directory.appending(path: "chapters.epub")
    /// chapters.epub's table of contents as its book page lists it; the last label, of 80 characters, wraps.
    static let chaptersLabels = [
        "I: Down the Rabbit-Hole", "Two", "Three: A Chapter Whose Title Is Long Enough to Wrap onto Two Lines on All Phones",
    ]
    /// Chapters I–XII of Alice's Adventures in Wonderland, as the sample book was until it became chapter I alone (never in the app):
    /// opened from Files where a test needs an import that runs for a minute and more.
    static let wholeAlice = directory.appending(path: "alice-whole.epub")
    /// How many pages `wholeAlice` takes, measured on the iPhone 17 Pro simulator, iOS 26.5. The layout is fixed (1200 × 1800 px
    /// pages in the system serif), so only another iOS version can change it.
    static let wholeAlicePages = 193

    /// A white page: read, it has no words, so it shows the No text status.
    static var blankPage: URL {
        drawnPage("blank", lines: [])
    }

    /// Three short lines of the most common words and no names: read, nothing on it is marked at the default level.
    static var commonWordsPage: URL {
        drawnPage("common-words", lines: ["The dog ran home.", "It was a cold day", "and the sun was low."])
    }

    /// A file that is not an image: an import skips it as a photo it cannot read.
    static var notAnImage: URL {
        written("not-an-image.png", Data("This is not an image.".utf8))
    }

    /// The chapter's first paragraph as a plain text file, wrapped like a Project Gutenberg file: titled by its file name,
    /// `rabbit-hole`, it makes two pages, the cover and the paragraph.
    static var plainTextBook: URL {
        written("rabbit-hole.txt", Data("""
            Alice was beginning to get very tired of sitting by her sister on the
            bank, and of having nothing to do: once or twice she had peeped into the
            book her sister was reading, but it had no pictures or conversations in
            it, \u{201C}and what is the use of a book,\u{201D} thought Alice \u{201C}without pictures or
            conversations?\u{201D}

            """.utf8))
    }

    /// A file that starts like an EPUB, a ZIP archive, and is not one: it cannot be opened.
    static var notABook: URL {
        written("not-a-book.epub", Data([0x50, 0x4B, 0x03, 0x04]) + Data("This is not a book.".utf8))
    }

    private static func written(_ name: String, _ data: Data) -> URL {
        let url = Paths.work.appending(path: name)
        try? data.write(to: url)
        return url
    }

    /// A 1400 × 2100 px page, the shape of the Alice fixtures, with black system-font lines on white.
    private static func drawnPage(_ name: String, lines: [String]) -> URL {
        let url = Paths.work.appending(path: "\(name).png")
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return url }
        let size = CGSize(width: 1400, height: 2100)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 88), .foregroundColor: UIColor.black]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 140, y: 240 + CGFloat(index) * 140), withAttributes: attributes)
            }
        }
        try? data.write(to: url)
        return url
    }
}

/// The sample book a new store gets: App/ReadStair/SampleBook/alice.epub, chapter I of Alice's Adventures in Wonderland, typeset on
/// the device. Page 1 is its cover and the chapter starts on page 2. Its title is data, not in the String Catalog.
enum Sample {
    static let title = "Alice\u{2019}s Adventures in Wonderland"
    /// How many pages it takes, the cover and 14 of chapter I, measured as `Fixture.wholeAlicePages` is (2026-09-26).
    static let pageCount = 15
}

/// The level test's words and their levels, from the lexicon the app bundles (vocab.tsv: word, band in thousands, 0 for a made-up
/// word): the oracle for answering the test on purpose.
@MainActor
enum Vocab {
    private static let bands: [String: Int] = {
        let url = Fixture.directory.deletingLastPathComponent()
            .appending(path: "Packages/ReadStairCore/Sources/ReadStairCore/Resources/lexicon/vocab.tsv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var bands: [String: Int] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            if fields.count == 2, let band = Int(fields[1]), bands[String(fields[0])] == nil { bands[String(fields[0])] = band }
        }
        return bands
    }()

    /// The band of a test word: 1 to 25 for a real word, 0 for a made-up one; nil for a word not in the test's pool.
    static func band(of word: String) -> Int? {
        bands[word]
    }
}

/// A fixture page's ground truth: every word's text and boxes, normalized to the page with the origin at the top left.
struct Truth: Decodable {
    struct Word: Decodable {
        let text: String
        let quads: [[[Double]]]

        /// The word without surrounding punctuation, as the app labels it.
        var core: String {
            text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }

        /// The first box's bounds (a word broken across lines has two boxes).
        var box: CGRect {
            let points = quads.first ?? []
            let xs = points.map { $0[0] }, ys = points.map { $0[1] }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    let words: [Word]

    static func load(_ url: URL) -> Truth {
        guard let data = try? Data(contentsOf: url), let truth = try? JSONDecoder().decode(Truth.self, from: data) else {
            return Truth(words: [])
        }
        return truth
    }

    /// A word by its text without punctuation, e.g. `peeped`; the first if the page has it more than once.
    func word(_ core: String) -> Word? {
        words.first { $0.core == core }
    }

    /// The words line by line, top to bottom, each line left to right.
    var lines: [[Word]] {
        Dictionary(grouping: words) { Int(($0.box.maxY * 1000).rounded()) }.sorted { $0.key < $1.key }.map(\.value)
    }

    /// The bottom of the lowest line of text, normalized.
    var textBottom: CGFloat {
        words.map(\.box.maxY).max() ?? 0
    }

    /// Where a word is on screen, given the page image's frame.
    func rect(of word: Word, on page: CGRect) -> CGRect {
        CGRect(x: page.minX + word.box.minX * page.width, y: page.minY + word.box.minY * page.height,
               width: word.box.width * page.width, height: word.box.height * page.height)
    }
}

/// What the tests write: stores and drawn pages, in the runner's temporary folder, which the app on the same simulator can read and
/// write too. Emptied at the start of every test run.
@MainActor
enum Paths {
    private static var prepared = false

    static var work: URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ReadStairUITests", directoryHint: .isDirectory)
        if !prepared {
            prepared = true
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// A folder for a new store; the app creates it.
    static func newDataRoot() -> URL {
        work.appending(path: "store-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

/// A store with one book of two pages already read (alice-p1, then alice-p1-tilt8), made through the app once per test run; every test
/// that needs read pages gets a copy. Reading a page takes 15–40 s in a slow simulator.
@MainActor
enum Template {
    private static var store: URL?

    /// A session on a fresh copy of the store; the app is not launched yet.
    static func bookWithRecognizedPages() throws -> Session {
        let template = try store ?? build()
        store = template
        let root = Paths.newDataRoot()
        try FileManager.default.copyItem(at: template, to: root)
        return Session(root: root)
    }

    private static func build() throws -> URL {
        let session = try Session.fresh()
        session.launch(seeds: [Fixture.alice, Fixture.aliceTilted])
        session.addBookFromPhotos()
        guard session.waitForReader(pages: 2), session.waitForRecognized() else {
            throw HarnessError("The template book's first page was never read.")
        }
        session.nextPage()
        guard session.waitForRecognized() else { throw HarnessError("The template book's second page was never read.") }
        session.previousPage()
        session.app.terminate()
        guard let root = session.root else { throw HarnessError("The template has no data folder.") }
        return root
    }
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
