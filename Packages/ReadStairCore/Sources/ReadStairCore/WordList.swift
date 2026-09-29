import Foundation

/// The Word List's groups: the words being learned, by the book they were first met in.
public enum WordListSections {
    public struct Section: Sendable, Hashable, Identifiable {
        /// Nil for Other: words whose first book is gone, pending deletion, or unknown (the first book never syncs, so a word that
        /// came from another device has none).
        public var book: Book?
        public var entries: [WordEntry]

        public var id: UUID? { book?.id }
    }

    /// Builds the groups from the effective entries (stored ones with any change still waiting to be saved applied); only learning
    /// words are listed. One group per book in `books` order (the visible shelf) that has a learning word, then Other. The book
    /// `hiddenBookID` (pending deletion) gets no group even if `books` still has it; its words go to Other. Within a group: band
    /// ascending, words without a band last, then lemma. O(n log n).
    public static func make(entries: some Sequence<WordEntry>, books: [Book], hiddenBookID: UUID?) -> [Section] {
        var position: [UUID: Int] = [:]
        for (index, book) in books.enumerated() where book.id != hiddenBookID { position[book.id] = index }
        // Group key: the book's position in `books`; books.count stands for Other, so it sorts last
        var groups: [Int: [WordEntry]] = [:]
        for entry in entries where entry.state == .learning {
            groups[entry.firstBookID.flatMap { position[$0] } ?? books.count, default: []].append(entry)
        }
        return groups.sorted { $0.key < $1.key }.map { key, group in
            Section(book: key < books.count ? books[key] : nil, entries: group.sorted(by: inListOrder))
        }
    }

    private static func inListOrder(_ a: WordEntry, _ b: WordEntry) -> Bool {
        switch (a.band, b.band) {
        case let (x?, y?) where x != y: x < y
        case (_?, nil): true
        case (nil, _?): false
        default: a.lemma < b.lemma
        }
    }
}
