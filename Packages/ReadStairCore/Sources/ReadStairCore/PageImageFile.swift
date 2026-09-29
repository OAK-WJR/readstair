import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Page image files: HEIC encoding, atomic writes, reading back whole or downsampled (long edge 2200 px; thumbnails 240 px).
enum PageImageFile {
    static let maxPixelSize = 2200
    static let thumbnailPixelSize = 240

    private static let queue = DispatchQueue(label: "app.readstair.page-image", qos: .userInitiated)

    /// Runs ImageIO encoding and decoding on a dedicated serial queue. It must not run concurrently on Swift's cooperative pool: the
    /// software HEVC encoder dispatches work internally and then blocks waiting for it, so once every cooperative thread (one per core)
    /// is blocked that way, the dispatched work never gets a thread and the whole process deadlocks (reproduced every time with 16
    /// concurrent software encodes; fine on a dedicated queue). Being serial also keeps at most one decoded bitmap in memory.
    static func run<T: Sendable, E: Error>(_ work: @escaping @Sendable () throws(E) -> T) async throws(E) -> T {
        let result: Result<T, E> = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Result { () throws(E) in try work() }) }
        }
        return try result.get()
    }

    /// The image turned upright per its EXIF-style orientation and scaled down so its long edge is at most `maxPixelSize`; an upright,
    /// opaque image that is small enough is returned as it is.
    /// Drawn into a bitmap of the target size rather than left to `kCGImageDestinationImageMaxPixelSize`, which enlarges small images
    /// and peaked about 50 MB higher while encoding a 12 MP photo. Transparent areas become white, like paper.
    static func fitting(_ image: CGImage, orientation: CGImagePropertyOrientation = .up, maxPixelSize: Int) throws(StoreError) -> CGImage {
        let longEdge = max(image.width, image.height)
        let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard longEdge > maxPixelSize || orientation != .up || !opaque else { return image }
        let scale = min(1, Double(maxPixelSize) / Double(longEdge))
        // The stored pixels at the new scale, and the upright bitmap (its sides swapped by a quarter turn)
        let drawnWidth = max(1, Int((Double(image.width) * scale).rounded()))
        let drawnHeight = max(1, Int((Double(image.height) * scale).rounded()))
        let turned = [CGImagePropertyOrientation.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let (width, height) = turned ? (drawnHeight, drawnWidth) : (drawnWidth, drawnHeight)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw .file("Cannot create a \(width)×\(height) bitmap")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.concatenate(upright(orientation, width: CGFloat(drawnWidth), height: CGFloat(drawnHeight)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: drawnWidth, height: drawnHeight))
        guard let scaled = context.makeImage() else { throw .file("Cannot scale the page image") }
        return scaled
    }

    /// Maps the stored pixels, drawn at `width`×`height` in Core Graphics' bottom-up coordinates, onto the upright bitmap. EXIF: 6
    /// (`.right`) turns them a quarter clockwise, 8 (`.left`) a quarter counterclockwise; the mirrored ones also flip.
    private static func upright(_ orientation: CGImagePropertyOrientation, width w: CGFloat, height h: CGFloat) -> CGAffineTransform {
        switch orientation {
        case .up: .identity
        case .upMirrored: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        @unknown default: .identity
        }
    }

    /// Encodes as HEIC at the image's own size.
    static func heic(_ image: CGImage) throws(StoreError) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw .file("HEIC encoder unavailable")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .file("HEIC encoding failed") }
        return data as Data
    }

    /// Atomic write: a temporary file in the same directory, then rename, so a crash never leaves half a file (stray temporary files are
    /// removed by the orphan sweep at launch).
    static func write(_ data: Data, to url: URL) throws(StoreError) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw isOutOfSpace(error) ? .diskFull : .file(error.localizedDescription)
        }
    }

    /// Reads a page image back; nil if the file is missing or damaged.
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Reads a page image back decoded straight to a smaller size: its long edge at most `maxPixelSize`, never enlarged, decoded now
    /// rather than when first drawn; nil if the file is missing or damaged. Only the app's own page files (long edge at most 2200 px)
    /// come here, so it needs no pixel limit.
    static func downsample(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func isOutOfSpace(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        return error.underlyingErrors.contains(where: isOutOfSpace)
    }
}
