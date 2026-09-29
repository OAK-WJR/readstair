import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ReadStairCore

/// An EPUB's own cover image: U-EPUB-014 reads it, U-TYPE-016 shows it on the cover page an import saves in place of the generated
/// image, and S-ETEXT-006 saves that page already read like every typeset page, on white.

/// `image` encoded as `type`.
private func encoded(_ image: CGImage, as type: UTType = .png) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

/// A PNG of `testImage` at the size given; with `clear`, a fully transparent one; with `gray`, a black 8-bit gray one, the least
/// memory for a size (6400×6400 is 41 MB).
private func png(width: Int, height: Int, clear: Bool = false, gray: Bool = false) throws -> Data {
    guard clear || gray else { return try encoded(testImage(width: width, height: height)) }
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: (gray ? CGImageAlphaInfo.none : .premultipliedLast).rawValue))
    return try encoded(try #require(context.makeImage()))
}

/// Two chapters, and a cover as the EPUB 3 manifest declares one, `images/cover`, holding `cover` when it is given.
private func bookWithCover(_ cover: Data?) -> Data {
    let manifest = #"""
        <item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/>
        <item id="cover" href="images/cover" media-type="image/png" properties="cover-image"/>
        """#
    return EPUBTests().epub(metadata: "<dc:title>Covered</dc:title><dc:creator>A. Author</dc:creator><dc:language>en</dc:language>",
                            manifest: manifest, spine: #"<itemref idref="c1"/><itemref idref="c2"/>"#,
                            files: [("OEBPS/text/c1.xhtml", EPUBTests.xhtml("<p>Alice was beginning.</p>")),
                                    ("OEBPS/text/c2.xhtml", EPUBTests.xhtml("<p>Down the rabbit hole.</p>"))],
                            images: cover.map { [("OEBPS/images/cover", $0)] } ?? [])
}

extension EPUBTests {
    @Test("U-EPUB-014 The cover image's bytes: the manifest item whose properties hold cover-image (EPUB 3), else the one <meta name=\"cover\"> names by id or by href (EPUB 2); the EPUB 3 one first; none, a meta naming nothing, or a missing file → nil")
    func coverImage() throws {
        let image = Data("the cover".utf8), other = Data("another".utf8)
        func cover(manifest: String, meta: String = "",
                   images: [(String, Data)] = [("OEBPS/images/c.png", Data("the cover".utf8))]) throws -> Data? {
            try EPUB.read(epub(metadata: "<dc:title>T</dc:title><dc:language>en</dc:language>" + meta,
                               manifest: #"<item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>"# + manifest,
                               images: images)).cover
        }
        let epub3 = #"<item id="x" href="images/c.png" media-type="image/png" properties="svg cover-image"/>"#
        let epub2 = #"<item id="cov" href="images/c.png" media-type="image/jpeg"/>"#
        #expect(try cover(manifest: epub3) == image)
        #expect(try cover(manifest: epub2, meta: #"<meta name="cover" content="cov"/>"#) == image, "by id")
        #expect(try cover(manifest: "", meta: #"<meta name="cover" content="images/c.png"/>"#) == image, "by href")
        #expect(try cover(manifest: epub3 + #"<item id="cov" href="images/o.png" media-type="image/png"/>"#,
                          meta: #"<meta name="cover" content="cov"/>"#,
                          images: [("OEBPS/images/c.png", image), ("OEBPS/images/o.png", other)]) == image, "EPUB 3 first")
        #expect(try cover(manifest: "") == nil, "none")
        #expect(try cover(manifest: epub2) == nil, "an image no meta names")
        #expect(try cover(manifest: epub2, meta: #"<meta name="cover" content="nothing"/>"#) == nil, "a meta naming nothing")
        #expect(try cover(manifest: epub3, images: []) == nil, "a missing file")
        #expect(try EBookReader.read(Data("Alice was beginning.".utf8)).cover == nil, "a text file")
    }
}

@Suite("U-TYPE-016 A book's own cover")
struct OwnCoverTests {
    @Test("U-TYPE-016 A usable cover image (a JPEG, PNG, GIF or WebP, 600 px or more on its long edge, at most 40 megapixels) shows on the cover page an import saves, with the generated cover's words as names and no boxes; the pages are as without it; anything else keeps the generated cover")
    func ownCoverOnTheCoverPage() async throws {
        let covered = try TypesetBook.make(EBookReader.read(bookWithCover(try png(width: 1400, height: 2100))), fileName: "c.epub")
        let plain = try TypesetBook.make(EBookReader.read(bookWithCover(nil)), fileName: "c.epub")
        #expect(covered.cover != nil && plain.cover == nil)
        #expect(covered.pageCount == plain.pageCount, "the same pages: the cover page stays first")

        let first = try #require(await covered.importPage(0)), generated = try #require(covered.page(0))
        #expect(first.image.width == 1400 && first.image.height == 2100, "the book's own cover")
        #expect(first.chapter == nil)
        let words = try #require(first.text).words
        #expect(words.map(\.surface) == ["Covered", "A.", "Author"] && words.allSatisfy { $0.kind == .name && $0.quads.isEmpty })
        #expect(words.map(\.surface) == generated.text?.words.map(\.surface))
        for index in 1..<covered.pageCount {
            #expect(await covered.importPage(index)?.text == covered.page(index)?.text)
        }
        #expect(await covered.importPage(covered.pageCount) == nil)
        #expect(await plain.importPage(0)?.text == plain.page(0)?.text, "without a cover, the generated one")

        // Not usable: the generated cover, as if there were none
        for (data, why) in [(Data("not an image".utf8), "not an image"), (Data("<svg/>".utf8), "SVG"),
                            (try encoded(testImage(width: 700, height: 1050), as: .tiff), "TIFF"),
                            (try png(width: 400, height: 599), "too small"), (try png(width: 6400, height: 6400, gray: true), "too large")] {
            let book = try TypesetBook.make(EBookReader.read(bookWithCover(data)), fileName: "c.epub")
            #expect(book.cover == nil, "\(why)")
            #expect(try #require(await book.importPage(0)).image.width == plain.page(0)?.image.width, "\(why)")
        }
    }
}

extension TypesetPageStoreTests {
    @Test("S-ETEXT-006 A book with its own cover: every page saved already read, the cover page with the generated cover's words and no boxes, a transparent cover saved on white (as any page image is)")
    func ownCoverSavedRead() async throws {
        let book = try TypesetBook.make(EBookReader.read(bookWithCover(try png(width: 700, height: 1050, clear: true))),
                                        fileName: "c.epub")
        try await withTemporaryRoot { root in
            let store = try BookStore(root: root)
            let stored = try await store.createBook(title: "Covered")
            let importer = Importer(store: store, recognizer: { _ in fakeText(0) })
            #expect(try await importer.importPages(count: book.pageCount, into: stored.id) { await book.importPage($0) } == book.pageCount)
            let pages = try await store.pages(of: stored.id)
            #expect(pages.map(\.status) == Array(repeating: .recognized, count: book.pageCount))
            #expect(pages.first?.width == 700)
            let saved = try #require(await store.loadImage(of: pages[0]))
            #expect([.none, .noneSkipFirst, .noneSkipLast].contains(saved.alphaInfo), "opaque")
            let corner = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            corner.draw(saved, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            #expect(try #require(corner.data?.load(as: UInt8.self)) > 250, "white, not black")
            #expect(try await store.pageText(of: pages[0].id)?.words.allSatisfy(\.quads.isEmpty) == true)
            #expect(try await store.pageText(of: pages[1].id) == book.page(1)?.text)
        }
    }
}
