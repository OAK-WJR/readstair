import ImageIO
import PhotosUI
import ReadStairCore
import SwiftUI
import VisionKit

/// The pages of one import, fetched one at a time while it runs so only one page is in memory. A nil page is one that could not be
/// read; the import skips it.
nonisolated struct ImportSource: Sendable {
    enum Kind: Sendable {
        case scanner, photos, ebook
    }

    let kind: Kind
    let count: Int
    /// A new book's title; nil gives it the date and time.
    var title: String?
    let page: @concurrent @Sendable (Int) async -> ImportPage?

    /// Photos chosen in the picker, loaded from the photo library (the picker runs out of process, so no permission prompt).
    static func photos(_ items: [PhotosPickerItem]) -> ImportSource {
        ImportSource(kind: .photos, count: items.count) { index in
            guard let data = try? await items[index].loadTransferable(type: Data.self) else { return nil }
            return await Recognition.pageImage(from: data).map { ImportPage(image: $0) }
        }
    }

    /// Pages from the document camera.
    @MainActor
    static func scan(_ scan: VNDocumentCameraScan) -> ImportSource {
        let source = ScanSource(scan)
        return ImportSource(kind: .scanner, count: scan.pageCount) { index in
            await source.image(at: index).map { ImportPage(image: $0) }
        }
    }

    #if DEBUG
    /// Image files: the seed pages standing in for chosen photos (`-ReadStairSeedPages`).
    static func files(_ urls: [URL]) -> ImportSource {
        ImportSource(kind: .photos, count: urls.count) { index in
            guard let data = try? Data(contentsOf: urls[index]) else { return nil }
            return await Recognition.pageImage(from: data).map { ImportPage(image: $0) }
        }
    }
    #endif

    /// An electronic book laid out on the device, titled as the book names itself. Each page comes with its words and their boxes, so
    /// it is saved already read and never waits for recognition; a cover of the book's own shows on its cover page (`importPage`).
    static func ebook(_ book: TypesetBook) -> ImportSource {
        ImportSource(kind: .ebook, count: book.pageCount, title: book.title) { await book.importPage($0) }
    }
}

/// How the document camera closed.
nonisolated enum ScanOutcome: Sendable {
    case cancelled
    case failed
    case scanned(ImportSource)
}

/// A finished scan. The scan object is not Sendable, so it stays on the main actor, where each page is taken from it; turning a page
/// upright and scaling it, the costly part, happens on the page-image queue. The import holds this until it returns.
@MainActor
private final class ScanSource {
    private let scan: VNDocumentCameraScan

    init(_ scan: VNDocumentCameraScan) {
        self.scan = scan
    }

    func image(at index: Int) async -> CGImage? {
        let page = scan.imageOfPage(at: index)
        guard let pixels = page.cgImage else { return nil }
        return await Recognition.pageImage(from: pixels, orientation: Self.orientation(page.imageOrientation))
    }

    /// UIKit's orientation as the image file orientation of the same name.
    private static func orientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

/// The system document camera, shown full screen. Everything on it is the system's.
struct DocumentScanner: UIViewControllerRepresentable {
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    let onFinish: (ScanOutcome) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        var onFinish: (ScanOutcome) -> Void

        init(onFinish: @escaping (ScanOutcome) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish(scan.pageCount > 0 ? .scanned(.scan(scan)) : .cancelled)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(.cancelled)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
            onFinish(.failed)
        }
    }
}
