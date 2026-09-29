import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ReadStairCore

/// Supplementary cases: photo decoding (Recognition.pageImage) rotates upright per EXIF and scales the long edge down to 2200 px;
/// S-IMG-005: stored page images decoded downsampled, for covers.
@Suite("Supplementary: page images")
struct PageImageTests {
    private func jpeg(width: Int, height: Int, orientation: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                                   [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("Landscape 4000×3000 with EXIF orientation 6 (needs a 90° clockwise turn) → portrait 1650×2200")
    func orientsAndDownsamples() async throws {
        let image = try #require(await Recognition.pageImage(from: try jpeg(width: 4000, height: 3000, orientation: 6)))
        #expect(image.width == 1650)
        #expect(image.height == 2200)
    }

    @Test("Images under 2200 px are not upscaled; non-image data returns nil")
    func keepsSmallImagesAndRejectsGarbage() async throws {
        let image = try #require(await Recognition.pageImage(from: try jpeg(width: 1400, height: 2100, orientation: 1)))
        #expect(image.width == 1400 && image.height == 2100)
        #expect(await Recognition.pageImage(from: Data("not an image".utf8)) == nil)
    }

    /// 3×2 pixels, each its own color, so any turn or flip shows.
    private func sixColors() throws -> CGImage {
        let rgb: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0, 0, 255, 255, 255, 0, 255]
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(rgb) as CFData))
        return try #require(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 9, space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// The image's pixels as RGB bytes, top row first.
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.width * image.height).flatMap { [bytes[$0 * 4], bytes[$0 * 4 + 1], bytes[$0 * 4 + 2]] }
    }

    @Test("A scanned page turned upright matches ImageIO's own reading of the same orientation, for all eight orientations")
    func uprightScanMatchesImageIO() async throws {
        let image = try sixColors()
        for raw in UInt32(1)...8 {
            let orientation = try #require(CGImagePropertyOrientation(rawValue: raw))
            // The same pixels in a lossless file with that orientation tag, read back upright by ImageIO
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: raw] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            let expected = try #require(await Recognition.pageImage(from: data as Data))
            let upright = try #require(await Recognition.pageImage(from: image, orientation: orientation))
            #expect(upright.width == expected.width && upright.height == expected.height, "orientation \(raw)")
            let (got, want) = (try pixels(upright), try pixels(expected))
            #expect(got.count == want.count && zip(got, want).allSatisfy { abs(Int($0) - Int($1)) <= 3 },
                    "orientation \(raw): \(got) is not \(want)")
        }
    }

    @Test("A scanned page larger than 2200 px is scaled down as it is turned upright")
    func uprightScanIsScaledDown() async throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let landscape = try #require(context.makeImage())
        let image = try #require(await Recognition.pageImage(from: landscape, orientation: .right))
        #expect(image.width == 1650 && image.height == 2200)
    }

    @Test("S-IMG-005 Covers: a 1200×1800 page file downsampled to 540 is 360×540, to 4000 still 1200×1800 (never enlarged), a landscape one 540×360; a missing or non-image file gives nil. loadImage(of:maxPixelSize:) gives a stored page at that size, and once the first page is deleted, the next page is the book's first")
    func downsampledCovers() async throws {
        try await withTemporaryRoot { root in
            func size(_ image: CGImage?) -> [Int]? { image.map { [$0.width, $0.height] } }
            let portrait = root.appending(path: "portrait.heic"), landscape = root.appending(path: "landscape.heic")
            try PageImageFile.write(PageImageFile.heic(testImage(width: 1200, height: 1800)), to: portrait)
            try PageImageFile.write(PageImageFile.heic(testImage(width: 1800, height: 1200)), to: landscape)
            #expect(size(PageImageFile.downsample(portrait, maxPixelSize: 540)) == [360, 540])
            #expect(size(PageImageFile.downsample(portrait, maxPixelSize: 4000)) == [1200, 1800])
            #expect(size(PageImageFile.downsample(landscape, maxPixelSize: 540)) == [540, 360])
            let garbage = root.appending(path: "garbage.heic")
            try Data("not an image".utf8).write(to: garbage)
            #expect(PageImageFile.downsample(garbage, maxPixelSize: 540) == nil)
            #expect(PageImageFile.downsample(root.appending(path: "missing.heic"), maxPixelSize: 540) == nil)

            // Stored pages 1200 and 1400 px wide, 1800 high
            let store = try BookStore(root: root)
            let book = try await store.createBook(title: "Alice")
            try await Importer(store: store, recognizer: { _ in fakeText(0) }).importPages(count: 2, into: book.id) {
                testImage(width: 1200 + 200 * $0, height: 1800)
            }
            let pages = try await store.pages(of: book.id)
            #expect(size(await store.loadImage(of: pages[0], maxPixelSize: 540)) == [360, 540])
            try await store.deletePage(pages[0].id)
            #expect(await store.loadImage(of: pages[0], maxPixelSize: 540) == nil)
            #expect(try await store.pages(of: book.id).first == pages[1])
            #expect(size(await store.loadImage(of: pages[1], maxPixelSize: 540)) == [420, 540])
        }
    }
}
