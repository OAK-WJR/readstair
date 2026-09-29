import Foundation
import Testing
@testable import ReadStairCore

/// Performance records for importing an electronic book: laying out a novel, then typesetting and encoding its pages as the import
/// does. They measure the whole process, so they only run on their own: `READSTAIR_PERF=1 swift test --filter TypesetPerformanceTests`.
/// The time to the first page is asserted on a device only; on a Mac the numbers are recorded and only gross regressions fail.
@Suite("P-ETEXT Typesetting performance", .tags(.performance), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["READSTAIR_PERF"] == "1"))
struct TypesetPerformanceTests {
    @Test("P-ETEXT-001 A 100,000-word book in one chapter: layout time and memory; 60 pages typeset, analyzed and HEIC-encoded: ms and KB per page")
    func novel() async throws {
        ExperimentLog.recordEnvironment(test: "P-ETEXT-001")
        // Alice's chapter repeated to novel length, as one chapter, like a plain text file
        let paragraphs = try TypesetterTests.aliceChapter().dropFirst()
        let wordsPerCopy = paragraphs.reduce(0) { total, block in
            guard case .paragraph(let text) = block else { return total }
            return total + text.split(separator: " ").count
        }
        let copies = 100_000 / wordsPerCopy + 1
        let text = EBook(title: nil, chapters: [EBook.Chapter(blocks: Array(Array(repeating: paragraphs, count: copies).joined()))])
        let (book, layout) = await measure { Typesetter.paginate(text, title: nil) }

        var typeset: [Duration] = [], encode: [Duration] = [], pageBytes = 0, thumbnailBytes = 0
        let (_, pages) = try await measure {
            for index in 0..<60 {
                var start = ContinuousClock.now
                let page = try #require(book.page(index))
                typeset.append(.now - start)
                start = .now
                let (image, thumbnail) = try await PageImageFile.run { () throws(StoreError) in
                    (try PageImageFile.heic(page.image),
                     try PageImageFile.heic(PageImageFile.fitting(page.image, maxPixelSize: PageImageFile.thumbnailPixelSize)))
                }
                encode.append(.now - start)
                pageBytes += image.count
                thumbnailBytes += thumbnail.count
            }
        }
        let perPage = percentile(0.5, typeset) + percentile(0.5, encode)
        let firstPage = layout.elapsed + typeset[0] + encode[0]
        ExperimentLog.record(["test": "P-ETEXT-001", "stage": "layout", "words": copies * wordsPerCopy, "pages": book.pageCount,
                              "per_page_ms": layout.elapsed / max(book.pageCount, 1)], layout.fields)
        ExperimentLog.record(["test": "P-ETEXT-001", "stage": "pages", "pages": typeset.count,
                              "typeset_median_ms": percentile(0.5, typeset), "typeset_p90_ms": percentile(0.9, typeset),
                              "encode_median_ms": percentile(0.5, encode), "encode_p90_ms": percentile(0.9, encode),
                              "page_kb": pageBytes / typeset.count / 1024, "thumb_kb": thumbnailBytes / typeset.count / 1024,
                              "first_page_ms": firstPage, "book_ms": perPage * book.pageCount,
                              "book_mb": book.pageCount * (pageBytes + thumbnailBytes) / typeset.count / 1_048_576], pages.fields)
        #expect(book.pageCount > 400, "a novel's length")
        #expect(layout.retainedMB < 150, "the laid-out book fits P-MEM's 150 MB app budget: +\(Int(layout.retainedMB)) MB")
        #expect(perPage < .seconds(2), "gross regression guard")
        #expect(pages.retainedMB < 50, "nothing accumulates across pages")
        if isDevice {
            #expect(firstPage < .seconds(3), "device threshold: page 1 soon after choosing the file; thermal state \(thermalState())")
        }
    }
}
