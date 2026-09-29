import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import ReadStairCore

// Shared fixtures: bundled test data, the gloss evaluation set, and helpers for the store and importer tests.

/// A bundled test data file or directory; `path` is relative to Tests/ReadStairCoreTests/Resources, e.g. "Fixtures/alice-p1.png" or
/// "Data/eval/gloss-200.tsv". Prefers the test bundle's copy, the only one a device can read. Falls back to the source tree, whose
/// symlinks lead to the repository's Fixtures/ and Data/, for builds that copy a symlink itself (it then dangles inside the bundle); a
/// macOS host and the simulator can read the source tree. The fallback is resolved, because listing a directory does not follow a
/// symlink to it.
func fixtureURL(_ path: String) -> URL {
    if let bundled = Bundle.module.resourceURL?.appending(path: path),
       FileManager.default.fileExists(atPath: bundled.path(percentEncoded: false)) {
        return bundled
    }
    return URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Resources").appending(path: path).resolvingSymlinksInPath()
}

/// One row of the gloss evaluation set, Data/eval/gloss-200.tsv (its ATTRIBUTION.md describes the columns). Only the columns sent to a framework
/// are kept: grading against the reference senses happens offline, on the logged output.
struct GlossEvalItem: Sendable {
    var id: String
    var sentence: String
    /// The tapped word as it appears in the sentence.
    var word: String
    /// The reference headword: the dictionary form a learner would look up, or the whole name. Graders use it; the word card shows
    /// `appHeadword()`, which can differ (`I've` → `i've`).
    var headword: String

    /// All rows in file order. Tab-separated with one header row and no quoting; columns are found by name.
    static func load() throws -> [GlossEvalItem] {
        let text = try String(contentsOf: fixtureURL("Data/eval/gloss-200.tsv"), encoding: .utf8)
        // Keep empty fields: other_senses may be empty, and the columns are positional
        let rows = text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let header = try #require(rows.first)
        func column(_ name: String) throws -> Int { try #require(header.firstIndex(of: name), "gloss-200.tsv has no \(name) column") }
        let (id, sentence, word, headword) = try (column("id"), column("sentence"), column("word"), column("headword"))
        return try rows.dropFirst().map { row in
            try #require(row.count == header.count, "gloss-200.tsv row \(row[0]) has \(row.count) fields")
            return GlossEvalItem(id: row[id], sentence: row[sentence], word: row[word], headword: row[headword])
        }
    }

    /// The headword the word card would show and translate for this item: `analyzeText` on the sentence, then `PageWord.headword`.
    /// Nil when the word is not one of its pieces (a dash joins it to the next word), since whether OCR splits there is unknown.
    func appHeadword() -> String? {
        analyzeText(sentence).words.first { PageWord.core($0.surface) == word }?.headword
    }
}

/// PageAnalyzer with the bundled lexicon over text split at spaces, the way OCR words arrive, each word in its own small box.
func analyzeText(_ text: String) -> PageText {
    let words = text.split(separator: " ").enumerated().map { i, word in
        RecognizedWord(text: String(word), quads: [Quad(CGRect(x: 0.02 * Double(i), y: 0, width: 0.02, height: 0.02))])
    }
    return PageAnalyzer.analyze(words, lexicon: .bundled)
}

/// Runs `body` with a fresh temporary directory (standing in for the app's Application Support) and deletes it afterwards. Runs on
/// the caller's actor, so a main-actor test can use it too.
func withTemporaryRoot<T>(isolation: isolated (any Actor)? = #isolation, _ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appending(path: "ReadStairTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

/// A test page image: black bars on white. The width identifies the page (sizes survive the HEIC round trip).
func testImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    for y in stride(from: 8, to: height - 8, by: 24) {
        context.fill(CGRect(x: 8, y: y, width: width - 16, height: 8))
    }
    return context.makeImage()!
}

/// Test image for page `number` (from 1): 200 + 2·number wide.
func pageImage(_ number: Int) -> CGImage { testImage(width: 200 + 2 * number, height: 300) }

/// Recovers the page number from an image handed to the recognizer.
func pageNumber(of image: CGImage) -> Int { (image.width - 200) / 2 }

/// A fake recognition result: one sentence naming the page, so it can be checked when read back.
func fakeText(_ number: Int) -> PageText { PageText(words: [], sentences: ["page \(number)"]) }

struct FakeRecognitionError: Error {}

/// Lets a test decide when the recognizer returns. `wait()` ignores cancellation, standing in for Vision recognition that cannot
/// stop midway (without blocking a thread).
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { waiters.count }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Thread-safe call log: which pages were recognized and the peak number running at once.
final class CallLog: Sendable {
    private struct State {
        var calls: [Int] = []
        var running = 0
        var maxRunning = 0
    }

    private let state = Mutex(State())

    var calls: [Int] { state.withLock { $0.calls } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }
    func count(of number: Int) -> Int { calls.filter { $0 == number }.count }

    /// Records a start; returns how many times this page has been recognized so far (from 1).
    @discardableResult
    func begin(_ number: Int) -> Int {
        state.withLock { state in
            state.calls.append(number)
            state.running += 1
            state.maxRunning = max(state.maxRunning, state.running)
            return state.calls.filter { $0 == number }.count
        }
    }

    func end() { state.withLock { $0.running -= 1 } }
}

extension Importer {
    /// `importPages(count:into:page:)` for pages that are images alone, each saved as pending.
    @discardableResult
    nonisolated func importPages(count: Int, into bookID: UUID,
                                 image: @Sendable (Int) async -> CGImage?) async throws(StoreError) -> Int {
        try await importPages(count: count, into: bookID) { index in await image(index).map { ImportPage(image: $0) } }
    }
}

/// Creates a book and imports `count` test pages (pages 1…count).
@discardableResult
func makeBook(_ store: BookStore, pages count: Int, title: String = "Alice") async throws -> Book {
    let book = try await store.createBook(title: title)
    let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
    let imported = try await importer.importPages(count: count, into: book.id) { pageImage($0 + 1) }
    #expect(imported == count)
    return book
}

/// Polls until `condition` holds (at most `seconds`), to wait for background work to reach a state. Runs on the caller's actor, so a
/// main-actor test can poll main-actor state.
func waitUntil(seconds: Double = 60, isolation: isolated (any Actor)? = #isolation, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Opens a separate connection to inspect the database (it sees committed state only).
func inspect(_ root: URL, _ sql: String) throws -> [SQLRow] {
    try SQLiteConnection(path: root.appending(path: "ReadStair.sqlite").path(percentEncoded: false)).query(sql)
}

/// Captures a page's state from inside the (concurrent) recognizer closure.
final class SnapshotBox: Sendable {
    private let value = Mutex<Page?>(nil)
    var page: Page? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
