import XCTest

/// E2E-001, end to end on a store of its own, in its nine steps. Each step runs as an activity named `E2E-001 step <n>`, so a failure
/// in the result bundle names the step it broke.
final class EndToEndTests: UITestCase {
    @MainActor
    func testE2E_001_readMarkAndRelaunch() throws {
        let session = try Session.fresh()

        try step(1, "Launch on a store of its own (-ReadStairDataRoot) with the recognizer timeout a slow simulator needs (180 s)") {
            session.launch(seeds: [Fixture.alice, Fixture.aliceTilted, Fixture.alice], stopsAtLevelTest: true)
        }

        try step(2, "The level test: tap 5 words, Continue, 3,000 words on the result, Start Reading") {
            XCTAssertTrue(session.eventually(30) { session.skipButton.exists }, "The level test did not appear")
            var remaining = 5
            let tapped = session.answerLevelTest { _ in
                remaining -= 1
                return remaining >= 0
            }
            XCTAssertEqual(tapped.count, 5, "Tapped \(tapped)")
            session.app.buttons["continue"].tap()
            // Whatever the estimate, the level is then 3
            session.levelRow(3).tap()
            XCTAssertTrue(session.eventually(10) { session.levelRow(3).isSelected }, "3,000 words is not checked")
            session.app.buttons["startReading"].tap()
            session.levelTestPending = false
            XCTAssertTrue(session.eventually(10) { !session.app.buttons["startReading"].exists }, "The level test did not close")
        }

        try step(3, "Empty Books, + then Choose from Photos (alice-p1, alice-p1-tilt8, alice-p1): the Reader opens on the new book") {
            XCTAssertTrue(session.eventually(30) { session.app.staticTexts[Strings.noBooks].exists }, "Books is not empty")
            session.addBookFromPhotos()
            XCTAssertTrue(session.eventually(90) { session.position()?.index == 1 }, "The Reader did not open on the new book")
        }

        try step(4, "Back to the book page (Read, no chapters), then Books: one cell, no line (only page 1 was seen); Read: page 1") {
            session.backToBook()
            session.settle()
            XCTAssertFalse(session.chapterRow(0).exists, "A photographed book lists chapters")
            session.back()
            XCTAssertTrue(session.eventually(20) { session.rows().count == 1 && (session.rows().first?.value ?? "") == "" },
                          "Cells: \(session.rows().map { [$0.label, $0.value ?? ""] })")
            session.openBook()
            XCTAssertTrue(session.eventually(30) { session.showsPage(1, of: 3) }, "Opened at \(session.subtitle)")
        }

        // peeped (lemma peep, band 9, above level 3) is marked. With a translation language installed (READSTAIR_TRANSLATE_INTO), the
        // card shows a translation or `Translation unavailable`; in English only it shows none.
        let count = try step(5, "At least one new word; tap peeped: the card shows peep, and a translation or Translation unavailable") {
            () throws -> Int in
            XCTAssertTrue(session.waitForRecognized())
            let count = try XCTUnwrap(session.newWordCount())
            XCTAssertGreaterThanOrEqual(count, 1)
            let peeped = try XCTUnwrap(session.word("peeped"), "peeped is not marked")
            XCTAssertTrue(session.tapWord(at: peeped.frame, expecting: "peep"))
            let translation = session.app.staticTexts["wordTranslation"]
            if Config.translationLanguage != nil {
                XCTAssertTrue(session.eventually(60) {
                    (translation.exists && !translation.label.isEmpty) || session.app.staticTexts[Strings.translationUnavailable].exists
                }, "The card shows neither a translation nor Translation unavailable")
            } else {
                session.settle(2)
                XCTAssertFalse(translation.exists, "English only, yet the card shows a translation")
            }
            return count
        }

        try step(6, "I Know This: the count drops and peeped loses its underline; Undo brings both back") {
            XCTAssertEqual(session.primaryAction.label, Strings.iKnowThis)
            session.primaryAction.tap()
            XCTAssertTrue(session.eventually(10) { !session.headword.exists }, "I Know This did not close the card")
            XCTAssertTrue(session.eventually(20) { session.newWordCount() == count - 1 && session.word("peeped") == nil },
                          "After I Know This: \(session.pageValue() ?? "no value")")
            XCTAssertEqual(session.toastText(), Strings.markedKnown("peep"))
            session.undo.tap()
            XCTAssertTrue(session.eventually(20) { session.newWordCount() == count && session.word("peeped") != nil },
                          "After Undo: \(session.pageValue() ?? "no value")")
        }

        // Opening the card of a marked word that has a band put it on the list; Undo took back only I Know This
        try step(7, "The Word List has one word: peep") {
            session.back()
            session.openWordList()
            XCTAssertTrue(session.eventually(10) { session.listedWords() == ["peep"] }, "Word List: \(session.listedWords())")
            session.back()
        }

        try step(8, "Toast over, terminate, relaunch: no level test; the book, its pages, their marks and the Word List are all there") {
            XCTAssertTrue(session.waitForToastToEnd())
            session.relaunch()
            XCTAssertTrue(session.levelTestStaysAway(), "The level test came back")
            XCTAssertTrue(session.eventually(30) { session.rows().count == 1 }, "Cells: \(session.rows().map(\.label))")
            session.openWordList()
            XCTAssertTrue(session.eventually(10) { session.listedWords() == ["peep"] },
                          "Word List after the relaunch: \(session.listedWords())")
            session.back()
            session.openBook()
            XCTAssertTrue(session.eventually(30) { session.showsPage(1, of: 3) }, "Opened at \(session.subtitle)")
            XCTAssertTrue(session.waitForRecognized())
            XCTAssertEqual(session.newWordCount(), count)
            XCTAssertNotNil(session.word("peeped"), "peeped lost its underline")
        }

        try step(9, "More, How Many to Mark\u{2026}, 1,000 words, Close: more words are new") {
            session.tapMore()
            session.tapMenuItem("howManyToMark")
            session.levelRow(1).tap()
            XCTAssertTrue(session.eventually(10) { session.levelRow(1).isSelected }, "1,000 words is not checked")
            session.closeSettings()
            XCTAssertTrue(session.eventually(20) { (session.newWordCount() ?? 0) > count }, "1,000 words did not mark more words")
        }
    }

    /// One step of E2E-001, run as an activity named `E2E-001 step <n>: <what it does>`.
    @MainActor
    @discardableResult
    private func step<T>(_ number: Int, _ name: String, _ body: () throws -> T) throws -> T {
        try XCTContext.runActivity(named: "E2E-001 step \(number): \(name)") { _ in try body() }
    }
}
