import XCTest

/// The Word List: its empty state, its groups and their order, a row's card with `I Know This` and Go to Page, and a row's translation.
/// Page 1 of the template book is alice-p1 read at the default level: `peeped` (peep, band 9) and `curiosity` (band 6) are marked,
/// `sister` (band 1) is not. Opening a marked word's card adds it to the list; `Mark as New` adds any word.
final class WordListTests: UITestCase {
    /// UI-LIST-001: with no words yet, the Word List shows no rows and says how words get in.
    @MainActor
    func testUI_LIST_001_emptyState() throws {
        let session = try Template.bookWithRecognizedPages()
        session.launch()
        XCTAssertTrue(session.eventually(30) { session.rows().count == 1 })
        XCTAssertEqual(session.app.buttons["wordList"].label, Strings.wordList)
        session.openWordList()
        XCTAssertTrue(session.eventually(10) { session.app.staticTexts[Strings.noWords].exists }, "No empty state")
        XCTAssertTrue(session.app.staticTexts[Strings.noWordsMessage].exists)
        XCTAssertEqual(session.listedWords(), [])
        session.back()
    }

    /// UI-LIST-001: one group per book, in shelf order (newest first), headed by the book's title; within a group the most
    /// common word first. Once its book is deleted, a word moves to Other, which comes last, and its card offers no Go to Page.
    @MainActor
    func testUI_LIST_001_groupsAndOrder() throws {
        let session = try Template.bookWithRecognizedPages()
        session.launch(seeds: [Fixture.alice])

        // The template book: opening curiosity adds it; sister is not marked and goes in with Mark as New
        session.openBook()
        XCTAssertTrue(session.eventually(30) { session.showsPage(1, of: 2) }, "Opened at \(session.subtitle)")
        XCTAssertTrue(session.waitForRecognized())
        let curiosity = try XCTUnwrap(session.word("curiosity"))
        XCTAssertTrue(session.tapWord(at: curiosity.frame, expecting: "curiosity"))
        session.closeCard()
        let page = try XCTUnwrap(session.visiblePage()).frame
        let sister = try XCTUnwrap(Fixture.aliceTruth.word("sister"))
        XCTAssertTrue(session.tapWord(at: Fixture.aliceTruth.rect(of: sister, on: page), expecting: "sister"))
        XCTAssertEqual(session.primaryAction.label, Strings.markAsNew)
        session.primaryAction.tap()
        // Closing the Reader saves Mark as New
        session.back()

        // A newer book of the same page: opening peeped there adds peep with that book
        session.addBookFromPhotos()
        XCTAssertTrue(session.waitForReader(pages: 1))
        XCTAssertTrue(session.waitForRecognized())
        let peeped = try XCTUnwrap(session.word("peeped"))
        XCTAssertTrue(session.tapWord(at: peeped.frame, expecting: "peep"))
        session.closeCard()
        session.back()
        XCTAssertTrue(session.eventually(30) { session.rows().count == 2 })
        let titles = session.rows().map(\.label)
        let (newer, older) = (titles[0], titles[1])

        session.openWordList()
        let expected = [WordGroup(newer, ["peep"]), WordGroup(older, ["sister", "curiosity"])]
        XCTAssertTrue(session.eventually(30) { session.scrolledWordGroups(titles: titles) == expected },
                      "Word List: \(session.scrolledWordGroups(titles: titles))")

        // The newer book deleted and saved: its word goes to Other, after the books
        session.back()
        session.deleteBook(at: 0)
        XCTAssertTrue(session.eventually(10) { session.rows().count == 1 })
        XCTAssertTrue(session.waitForToastToEnd())
        session.openWordList()
        let afterDelete = [WordGroup(older, ["sister", "curiosity"]), WordGroup(Strings.other, ["peep"])]
        XCTAssertTrue(session.eventually(30) { session.scrolledWordGroups(titles: [older, Strings.other]) == afterDelete },
                      "Word List: \(session.scrolledWordGroups(titles: [older, Strings.other]))")
        session.openListedWord("peep")
        session.settle(1.5)
        XCTAssertFalse(session.app.buttons["goToPage"].exists, "Go to Page for a word whose book is gone")
    }

    /// UI-LIST-001: the row opens the card at the medium detent. `I Know This` takes the row away at once and names the word in the
    /// toast; Undo brings it back. Go to Page, in view without scrolling, opens the Reader on the page the word was met on, not where
    /// the book was left, with no card; Back returns to the Word List.
    @MainActor
    func testUI_LIST_001_rowCardAndGoToPage() throws {
        let session = try Template.bookWithRecognizedPages()
        session.launch()
        session.openBook()
        XCTAssertTrue(session.eventually(30) { session.showsPage(1, of: 2) }, "Opened at \(session.subtitle)")
        XCTAssertTrue(session.waitForRecognized())
        let peeped = try XCTUnwrap(session.word("peeped"))
        XCTAssertTrue(session.tapWord(at: peeped.frame, expecting: "peep"))
        session.closeCard()
        // The book is left on page 2
        session.nextPage()
        session.back()

        session.openWordList()
        XCTAssertTrue(session.eventually(10) { session.listedWords() == ["peep"] }, "Word List: \(session.listedWords())")

        session.openListedWord("peep")
        session.settle(1.5)
        let top = try XCTUnwrap(session.cardContentTop()) / session.window.height
        XCTAssertTrue(top > 0.3 && top < 0.6, "The card's top is at \(top) of the window, not at the medium detent")
        XCTAssertEqual(session.primaryAction.label, Strings.iKnowThis)
        session.primaryAction.tap()
        XCTAssertTrue(session.eventually(10) { !session.headword.exists }, "I Know This did not close the card")
        XCTAssertTrue(session.eventually(10) { session.toastText() == Strings.markedKnown("peep") }, "Toast: \(session.toastText() ?? "none")")
        XCTAssertTrue(session.eventually(10) { session.listedWords().isEmpty }, "The row stayed")
        session.undo.tap()
        XCTAssertTrue(session.eventually(10) { session.listedWords() == ["peep"] }, "Undo did not bring the row back")

        session.openListedWord("peep")
        session.settle(1.5)
        let goToPage = session.app.buttons["goToPage"]
        XCTAssertTrue(session.eventually(10) { goToPage.exists }, "No Go to Page")
        XCTAssertEqual(goToPage.label, "Go to Page")
        // Three taps from Books to the word's page: at the medium detent Go to Page is in view with no scrolling (at accessibility
        // sizes the card scrolls)
        if !Config.contentSize.isAccessibilityCategory { XCTAssertTrue(goToPage.isHittable, "Go to Page starts out of view") }
        goToPage.tap()
        XCTAssertTrue(session.eventually(30) { session.showsPage(1, of: 2) }, "Go to Page opened \(session.subtitle)")
        XCTAssertFalse(session.headword.exists, "Go to Page opened a card")
        session.backToWordList()
        XCTAssertEqual(session.listedWords(), ["peep"])
    }

    /// UI-LIST-002: with a language to translate into whose pack is installed (`READSTAIR_TRANSLATE_INTO`), a row reads its word, the
    /// word's translation (the one its card shows), then its sentence; with Translate To Off, nothing between the word and its
    /// sentence. An English-only run is Off.
    @MainActor
    func testUI_LIST_002_translation() throws {
        let session = try Template.bookWithRecognizedPages()
        session.launch()
        try session.openPeeped()
        var translation: String?
        if Config.translationLanguage != nil {
            let shown = session.app.staticTexts["wordTranslation"]
            XCTAssertTrue(session.eventually(60) { shown.exists }, "The card does not translate")
            translation = shown.label
        }
        session.closeCard()
        session.back()
        session.openWordList()

        if let translation {
            XCTAssertTrue(session.eventually(60) { peepRow(session)?.between == ", \(translation), " },
                          "Row: \(peepRow(session)?.label ?? "none"); the card translates peep as \(translation)")
            saveScreenshot("WordList-translated", size: session.contentSize ?? Config.contentSize)
            session.back()
            session.openSettings()
            let picker = session.app.buttons["translateTo"]
            XCTAssertTrue(session.scrollIntoView(picker), "No Translate To")
            picker.tap()
            let off = session.app.buttons[Strings.off]
            XCTAssertTrue(session.eventually(10) { off.exists }, "No Off in the menu")
            off.tap()
            XCTAssertTrue(session.eventually(10) { shows(picker, Strings.off) }, "Translate To does not show Off")
            session.closeSettings()
            session.openWordList()
        }
        XCTAssertTrue(session.eventually(10) { peepRow(session) != nil }, "No row for peep: \(session.listedWords())")
        // Time for a translation to arrive, were one on its way
        session.settle(3)
        let row = try XCTUnwrap(peepRow(session), "No row for peep: \(session.listedWords())")
        XCTAssertFalse(row.between.contains { $0.isLetter || $0.isNumber }, "Something between the word and its sentence: \(row.label)")
    }

    /// peep's row, whose sentence is alice-p1's first (`Alice was beginning …`): its label, and what comes between the word and the
    /// sentence; nil while there is no such row.
    @MainActor
    private func peepRow(_ session: Session) -> (label: String, between: String)? {
        guard let label = session.nodes().first(where: { $0.id == "wordRow" && $0.label.hasPrefix("peep") })?.label,
              let sentence = label.range(of: "Alice was beginning") else { return nil }
        return (label, String(label.dropFirst("peep".count)[..<sentence.lowerBound]))
    }
}
