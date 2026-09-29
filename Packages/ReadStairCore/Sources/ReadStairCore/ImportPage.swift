import CoreGraphics

/// A page to import: its image and, when the words and their boxes are already known (a typeset electronic book), its text, so the
/// page is saved as recognized and never queued for recognition.
public struct ImportPage: Sendable {
    public var image: CGImage
    public var text: PageText?
    /// The label of the book's own table-of-contents entry that starts on this page, if any. Only a typeset electronic book has one.
    public var chapter: String?

    public init(image: CGImage, text: PageText? = nil, chapter: String? = nil) {
        self.image = image
        self.text = text
        self.chapter = chapter
    }
}
