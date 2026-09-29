import Foundation
import Testing
@testable import ReadStairCore

/// I-ETEXT-001: real recognition on a typeset page, compared with the words and boxes the typesetter saved with it. This checks the
/// boxes against the pixels a second way (U-TYPE-004 is the first), and that Vision, the fallback for a typeset page whose text an
/// analysis version bump has outdated, reads such pages well. It is part of the serialized I-OCR suite, so it never recognizes at the
/// same time as I-OCR's tests.
extension RecognitionIntegrationTests {
    @Test("I-ETEXT-001 Typeset page 1 of Alice: ≥ 97% of its typeset words match a recognized word with IoU > 0.5")
    func typesetPageMatchesVision() async throws {
        let book = Typesetter.paginate(EBook(title: nil, chapters: [EBook.Chapter(blocks: try TypesetterTests.aliceChapter())]),
                                       title: nil)
        let page = try #require(book.page(0))
        let typeset = try #require(page.text).words.map { (key: PageWord.key($0.surface), quads: $0.quads.map(\.corners)) }
        let start = ContinuousClock.now
        let recognized = try await Recognition.page(from: page.image)
        let comparison = Self.compare(recognized.words, to: typeset)
        let matched = comparison.ious.filter { $0 > 0.5 }.count
        ExperimentLog.record(["test": "I-ETEXT-001", "typeset": typeset.count, "recognized": recognized.words.count,
                              "aligned": comparison.matched, "matched": matched, "ms": ContinuousClock.now - start], comparison.fields)
        #expect(Double(matched) >= 0.97 * Double(typeset.count), "\(matched) of \(typeset.count) typeset words matched")
    }
}
