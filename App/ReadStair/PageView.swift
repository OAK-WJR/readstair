import ReadStairCore
import SwiftUI
import UIKit

/// One page of the Reader: the page photo in a zooming UIKit scroll view, the ink as two shape layers inside the zoomed content (so it
/// moves with the page in every motion, including the ones Core Animation drives), UIKit accessibility elements for the page and its
/// marked words plus an `All Words` rotor over every word, a single-tap hit test, the scroll that keeps the selected word above the word
/// card, and the room that lets text under the status capsule scroll clear of it.
///
/// Keep `drawingGroup`, `compositingGroup`, blurs and other filters, and `shouldRasterize` off this view and its ancestors: without
/// them Core Animation rasterizes the shape layers in screen space, which is what keeps the ink sharp at 4× zoom.
struct PageView: UIViewRepresentable {
    /// Which image `image()` gives now, nil for none: the Reader reads it from its model, so the page updates when its image changes.
    /// The page's value carries this, never the image: while the pager scrolls, the lazy stack can hold on to the values of pages it
    /// has passed, and with them any image they carry, well after the model has let it go.
    let imageID: ObjectIdentifier?
    /// The screen-size image for the current page and its neighbours (the full one while the current page is zoomed in), the thumbnail
    /// for the others; nil shows a fill of the page's shape.
    let image: () -> CGImage?
    /// The stored page image's size in pixels: it sizes the page before any image arrives.
    let pixelSize: CGSize
    /// The recognized text; nil while the page is being read or when reading failed, and then no tap hits a word.
    let text: PageText?
    /// Indices into `text.words` to underline, in reading order.
    let marked: [Int]
    /// The word whose card is open.
    let selected: Int?
    let isCurrent: Bool
    /// The word card's low detent height while a card for this page is open; nil otherwise.
    let cardLow: CGFloat?
    /// The status capsule's top edge in window coordinates while it shows over this page; nil otherwise.
    let statusTop: CGFloat?
    /// The page's VoiceOver summary: the label (`Page 3 of 30`) and the value (the new-word count or the page status line).
    let summaryLabel: String
    let summaryValue: String
    /// `Try Again` while the page failed to read, also offered as an action on the page summary: VoiceOver and Switch Control keep it
    /// while the undo toast, which they never time out, holds the capsule's place.
    let retry: (() -> Void)?
    let onTap: (Int) -> Void
    let onZoomedChange: (Bool) -> Void

    func makeUIView(context: Context) -> PageScrollView {
        PageScrollView()
    }

    func updateUIView(_ view: PageScrollView, context: Context) {
        view.isUpdating = true
        defer { view.isUpdating = false }
        view.onTap = onTap
        view.onZoomedChange = onZoomedChange
        // Sized in image points (pixels ÷ screen scale), so the photo stays sharp up to its native resolution
        let scale = context.environment.displayScale
        view.show(image: image(), contentSize: CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale))
        view.annotate(text: text, marked: marked)
        view.summarize(label: summaryLabel, value: summaryValue, retry: retry)
        let reveal = selected != nil && selected != view.selected
        view.select(selected)
        if !isCurrent { view.resetZoom() }
        view.updateCovers(cardLow: cardLow, statusTop: statusTop, reveal: reveal,
                          animated: !context.environment.accessibilityReduceMotion)
    }
}

/// The zooming page. Minimum zoom fits the width with 8 pt margins, top aligned and centered; maximum is 4 × that. Pinch only, and
/// no double-tap recognizer anywhere, so a single tap has no delay.
final class PageScrollView: UIScrollView, UIScrollViewDelegate {
    private static let margin: CGFloat = 8
    private static let keepVisibleMargin: CGFloat = 16
    private static let hitRadius: CGFloat = 24
    private static let maxZoom: CGFloat = 4
    private static let inkWidth: CGFloat = 2.5
    /// 2 pt wider than the ink: a 1 pt white edge on each side keeps the ink readable on dark photos.
    private static let haloWidth: CGFloat = 4.5
    /// The AccentColor asset's light value, fixed in light and dark mode alike: the page is a photo of paper.
    private static let inkColor = UIColor(red: 0xD7 / 255, green: 0, blue: 0x15 / 255, alpha: 1)

    var onTap: ((Int) -> Void)?
    var onZoomedChange: ((Bool) -> Void)?
    /// True inside `updateUIView`: callbacks that change SwiftUI state wait for the next turn of the main loop then.
    var isUpdating = false
    private(set) var selected: Int?

    private let contentView = UIView()
    private let imageView = UIImageView()
    private let haloLayer = CAShapeLayer()
    private let inkLayer = CAShapeLayer()
    private var image: CGImage?
    private var contentPointSize = CGSize.zero
    private var fitScale: CGFloat = 0
    private var isZoomed = false
    /// The bottom inset that makes room above an open word card; nil while no card is open.
    private var cardInset: CGFloat?
    /// The bottom inset that lets text under the status capsule scroll clear of it; nil while no capsule shows over the page.
    private var statusInset: CGFloat?

    private var text: PageText?
    private var marked: [Int] = []
    private let summary: UIAccessibilityElement
    /// Every word element made so far, marked or not: the marked ones are listed in `accessibilityElements`, the others are only
    /// returned by the `All Words` rotor, named apart from VoiceOver's own `Words`. Kept while the text stays, so VoiceOver's focus
    /// survives a change of marks.
    private var elements: [Int: WordElement] = [:]
    private lazy var rotor = UIAccessibilityCustomRotor(name: String(localized: "All Words")) { [weak self] predicate in
        self?.rotorResult(predicate)
    }
    private var retry: (() -> Void)?
    private lazy var tryAgain = UIAccessibilityCustomAction(name: String(localized: "Try Again")) { [weak self] _ in
        guard let retry = self?.retry else { return false }
        retry()
        return true
    }

    init() {
        summary = UIAccessibilityElement(accessibilityContainer: contentView)
        super.init(frame: .zero)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        isDirectionalLockEnabled = true
        bouncesZoom = true
        // Smart Invert leaves the photo and the ink alone
        accessibilityIgnoresInvertColors = true
        contentView.accessibilityIgnoresInvertColors = true
        addSubview(contentView)
        contentView.addSubview(imageView)
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.backgroundColor = .secondarySystemFill
        for (layer, color) in [(haloLayer, UIColor.white.withAlphaComponent(0.85)), (inkLayer, Self.inkColor)] {
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineCap = .round
            contentView.layer.addSublayer(layer)
        }
        summary.accessibilityIdentifier = "page"
        summary.accessibilityCustomRotors = [rotor]
        contentView.accessibilityCustomRotors = [rotor]
        contentView.accessibilityElements = [summary]
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    func show(image newImage: CGImage?, contentSize size: CGSize) {
        if newImage !== image {
            image = newImage
            imageView.image = newImage.map { UIImage(cgImage: $0) }
            imageView.backgroundColor = newImage == nil ? .secondarySystemFill : nil
        }
        guard size != contentPointSize, size.width > 0, size.height > 0 else { return }
        contentPointSize = size
        zoomScale = 1
        contentView.frame = CGRect(origin: .zero, size: size)
        imageView.frame = contentView.bounds
        contentSize = size
        fitScale = 0
        summary.accessibilityFrameInContainerSpace = contentView.bounds
        rebuildAnnotations()
        setNeedsLayout()
    }

    func annotate(text newText: PageText?, marked newMarked: [Int]) {
        guard newText != text || newMarked != marked else { return }
        // Another text (the page was read again) numbers other words; new marks keep the elements, so VoiceOver keeps its place
        if newText != text { elements = [:] }
        text = newText
        marked = newMarked
        rebuildAnnotations()
    }

    func summarize(label: String, value: String, retry newRetry: (() -> Void)?) {
        summary.accessibilityLabel = label
        summary.accessibilityValue = value
        retry = newRetry
        summary.accessibilityCustomActions = newRetry == nil ? nil : [tryAgain]
    }

    func select(_ index: Int?) {
        guard index != selected else { return }
        for old in [selected, index].compactMap({ $0 }) {
            elements[old]?.isSelected = old == index
        }
        selected = index
    }

    /// The ink path and the word elements, rebuilt only when the text, the marks or the page size change. The path is in content
    /// coordinates, so zooming and scrolling never touch it.
    private func rebuildAnnotations() {
        let path = CGMutablePath()
        let before = contentView.accessibilityElements as? [NSObject]
        if let text, contentPointSize.width > 0 {
            let marked = marked.filter(text.words.indices.contains)
            for index in marked {
                for quad in text.words[index].quads {
                    let edge = quad.scaled(to: contentPointSize)
                    path.move(to: edge.bottomLeft)
                    path.addLine(to: edge.bottomRight)
                }
            }
            // Every element made so far takes the new marks and frames, the rotor-only ones included
            for (index, element) in elements { configure(element, index: index, in: text) }
            contentView.accessibilityElements = [summary] + marked.map { element(for: $0, in: text) }
        } else {
            elements = [:]
            contentView.accessibilityElements = [summary]
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [haloLayer, inkLayer] {
            // Bounds and position rather than frame: the layers carry a transform
            layer.bounds = contentView.bounds
            layer.position = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
            layer.path = path
        }
        CATransaction.commit()
        updateInkWidth()
        // VoiceOver rereads the words, keeping its place on any element that is still there
        if window != nil, contentView.accessibilityElements as? [NSObject] != before {
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    /// The layers are scaled with the content, so dividing by the zoom keeps the ink the same width on screen at any zoom. The path runs
    /// along each word's bottom edge, the line its descenders reach; the layers move down by half the ink's width, so the ink's top edge
    /// sits on that line and the descenders stay readable.
    private func updateInkWidth() {
        guard zoomScale > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        haloLayer.lineWidth = Self.haloWidth / zoomScale
        inkLayer.lineWidth = Self.inkWidth / zoomScale
        let drop = CGAffineTransform(translationX: 0, y: Self.inkWidth / 2 / zoomScale)
        haloLayer.setAffineTransform(drop)
        inkLayer.setAffineTransform(drop)
        CATransaction.commit()
    }

    // MARK: Zoom and layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard contentPointSize.width > 0, bounds.width > 2 * Self.margin else { return }
        // The width is known only here (it is zero in makeUIView and the first updateUIView); portrait only, so it does not change after
        let fit = (bounds.width - 2 * Self.margin) / contentPointSize.width
        if abs(fit - fitScale) > 0.0001 {
            fitScale = fit
            minimumZoomScale = fit
            maximumZoomScale = Self.maxZoom * fit
            zoomScale = fit
            updateInsets()
            contentOffset = topLeft
        } else {
            updateInsets()
        }
        updateInkWidth()
    }

    /// Back to fit width at the top: a page that is no longer the current one opens at rest when the reader comes back to it.
    func resetZoom() {
        guard fitScale > 0, zoomScale != fitScale || contentOffset != topLeft else { return }
        setZoomScale(fitScale, animated: false)
        updateInsets()
        contentOffset = topLeft
    }

    private var topLeft: CGPoint { CGPoint(x: -contentInset.left, y: -contentInset.top) }

    /// 8 pt margins, horizontal centering while the page is narrower than the view, and room at the bottom above an open card or the
    /// status capsule.
    private var targetInsets: UIEdgeInsets {
        let side = max(Self.margin, (bounds.width - contentView.frame.width) / 2)
        return UIEdgeInsets(top: Self.margin, left: side, bottom: max(Self.margin, cardInset ?? 0, statusInset ?? 0), right: side)
    }

    private func updateInsets() {
        let insets = targetInsets
        if contentInset != insets { contentInset = insets }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateInsets()
        updateInkWidth()
        let zoomed = fitScale > 0 && zoomScale > fitScale * 1.01
        guard zoomed != isZoomed else { return }
        isZoomed = zoomed
        notify { [onZoomedChange] in onZoomedChange?(zoomed) }
    }

    private func notify(_ change: @escaping () -> Void) {
        if isUpdating { Task { @MainActor in change() } } else { change() }
    }

    // MARK: Word card and status capsule

    /// What covers the bottom of the page. While a card is open, the bottom inset lets every covered line scroll to 16 pt above the
    /// card, and selecting a word scrolls only when the card would cover it; never changes the zoom. The card's covered height is the
    /// low detent plus the bottom safe area: on iOS 26 the low card floats above the home indicator, so its top edge sits that much
    /// higher than the window height minus the detent. While the status capsule shows, the same rule lets the text under it scroll to
    /// 16 pt above it (at large text sizes it covers lines of a page that otherwise fits and cannot scroll).
    func updateCovers(cardLow: CGFloat?, statusTop: CGFloat?, reveal: Bool, animated: Bool) {
        var cardTop: CGFloat?
        var covers: (card: CGFloat?, status: CGFloat?) = (nil, nil)
        if cardLow != nil || statusTop != nil {
            guard let window else { return }
            let pageBottom = convert(bounds, to: nil).maxY
            if let cardLow {
                let top = window.bounds.height - cardLow - window.safeAreaInsets.bottom
                cardTop = top
                covers.card = max(0, pageBottom - top + Self.keepVisibleMargin)
            }
            if let statusTop {
                covers.status = max(0, pageBottom - statusTop + Self.keepVisibleMargin)
            }
        }
        setCovers(covers, animated: animated)
        guard reveal, let cardTop, let selected, let rect = wordRect(selected) else { return }
        let wordMaxY = contentView.convert(rect, to: nil).maxY
        let limit = cardTop - Self.keepVisibleMargin
        guard wordMaxY > limit else { return }
        let maxOffsetY = contentSize.height + contentInset.bottom - bounds.height
        setContentOffset(CGPoint(x: contentOffset.x, y: min(contentOffset.y + wordMaxY - limit, maxOffsetY)), animated: animated)
    }

    /// A growing inset only makes room. A shrinking one (the card closed, the capsule went) moves the page back into range explicitly,
    /// together with the inset: left to itself, the scroll view clamps with whatever animation the card's dismissal carries, even
    /// under Reduce Motion. 0.3 s, instant under Reduce Motion.
    private func setCovers(_ covers: (card: CGFloat?, status: CGFloat?), animated: Bool) {
        guard covers.card != cardInset || covers.status != statusInset else { return }
        let before = targetInsets.bottom
        cardInset = covers.card
        statusInset = covers.status
        let insets = targetInsets
        guard insets.bottom < before else { return updateInsets() }
        let maxOffsetY = max(-insets.top, contentSize.height + insets.bottom - bounds.height)
        let offset = CGPoint(x: contentOffset.x, y: min(contentOffset.y, maxOffsetY))
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { [self] in
                contentOffset = offset
                contentInset = insets
            }
        } else {
            UIView.performWithoutAnimation {
                contentOffset = offset
                contentInset = insets
            }
        }
    }

    // MARK: Tap

    /// The nearest word within 24 screen points; a miss or the word already selected does nothing.
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let text,
              let index = Annotator.hit(recognizer.location(in: contentView), in: text, size: contentPointSize,
                                        maxDistance: Self.hitRadius / zoomScale),
              index != selected else { return }
        onTap?(index)
    }

    // MARK: Accessibility

    /// A word's element, made on first use and kept while the text stays. Every element carries the `All Words` rotor, so the rotor
    /// stays available wherever it lands.
    private func element(for index: Int, in text: PageText) -> WordElement {
        if let existing = elements[index] { return existing }
        let element = WordElement(container: contentView, index: index)
        element.accessibilityCustomRotors = [rotor]
        element.isSelected = index == selected
        element.onActivate = { [weak self] in self?.onTap?(index) }
        configure(element, index: index, in: text)
        elements[index] = element
        return element
    }

    /// The printed word, `new word` while it is marked, and its first quad's frame; the whole page for a word without a box (the title
    /// on a book's own cover).
    private func configure(_ element: WordElement, index: Int, in text: PageText) {
        let word = text.words[index]
        element.accessibilityLabel = PageWord.core(word.surface)
        element.accessibilityValue = marked.contains(index) ? String(localized: "new word") : nil
        element.accessibilityFrameInContainerSpace = word.quads.first.map { Self.bounds(of: $0.scaled(to: contentPointSize).corners) }
            ?? CGRect(origin: .zero, size: contentPointSize)
    }

    /// The `All Words` rotor: every word other than punctuation, marked or not, in reading order. It is the only way VoiceOver reaches a
    /// word that is not marked.
    private func rotorResult(_ predicate: UIAccessibilityCustomRotorSearchPredicate) -> UIAccessibilityCustomRotorItemResult? {
        guard let text else { return nil }
        let words = text.words.indices.filter { text.words[$0].kind != .punct }
        let current = (predicate.currentItem.targetElement as? WordElement)?.index
        let next = switch predicate.searchDirection {
        case .next: current.map { current in words.first { $0 > current } } ?? words.first
        case .previous: current.map { current in words.last { $0 < current } } ?? words.last
        @unknown default: Int?.none
        }
        guard let next else { return nil }
        return UIAccessibilityCustomRotorItemResult(targetElement: element(for: next, in: text), targetRange: nil)
    }

    /// The union of a word's quads (a word broken across lines has two), in content-view points.
    private func wordRect(_ index: Int) -> CGRect? {
        guard let text, text.words.indices.contains(index) else { return nil }
        let corners = text.words[index].quads.flatMap { $0.scaled(to: contentPointSize).corners }
        return corners.isEmpty ? nil : Self.bounds(of: corners)
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }
}

/// A word on the page: label = the printed word without surrounding punctuation, value `new word` when marked.
private final class WordElement: UIAccessibilityElement {
    let index: Int
    var onActivate: (() -> Void)?
    var isSelected = false {
        didSet { accessibilityTraits = isSelected ? [.button, .selected] : .button }
    }

    init(container: UIView, index: Int) {
        self.index = index
        super.init(accessibilityContainer: container)
        accessibilityTraits = .button
        accessibilityLanguage = "en-US"
        accessibilityIdentifier = "word.\(index)"
    }

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}
