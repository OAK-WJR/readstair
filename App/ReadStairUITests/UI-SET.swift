import XCTest

/// Settings: Translate To, and the footer on data and licenses.
final class SettingsTests: UITestCase {
    /// UI-SET-001: Translate To is a menu that starts with Off and has no Automatic; Off turns the card's translation off, and the
    /// choice holds after a relaunch. The footer says what ReadStair does with data, links to the privacy policy, and says where its
    /// word data comes from, under which licenses. The translation itself is checked when the run has a language pack installed
    /// (`READSTAIR_TRANSLATE_INTO`); without one, cards never translate and no test brings up the system's download.
    @MainActor
    func testUI_SET_001_translateToAndFooter() throws {
        let session = try Template.bookWithRecognizedPages()
        session.launch()
        let translates = Config.translationLanguage != nil
        let wordTranslation = session.app.staticTexts["wordTranslation"]
        if translates {
            // Following the device's languages, a card translates
            try session.openPeeped()
            XCTAssertTrue(session.eventually(60) { wordTranslation.exists }, "No translation before Off")
            session.closeCard()
            session.back()
        }

        session.openSettings()
        // Under the level rows, out of sight at the larger text sizes
        let picker = session.app.buttons["translateTo"]
        XCTAssertTrue(session.scrollIntoView(picker), "No Translate To")
        if !translates {
            XCTAssertTrue(shows(picker, Strings.off), "English only, yet Translate To shows \(picker.label) \(picker.value ?? "")")
        }
        picker.tap()
        let off = session.app.buttons[Strings.off]
        XCTAssertTrue(session.eventually(10) { off.exists }, "No Off in the menu")
        let automatic = session.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Automatic'")).firstMatch
        XCTAssertFalse(automatic.exists, "The menu offers Automatic")
        // Languages follow a divider, by name; any of these that the menu lists comes after Off
        for name in ["Chinese", "French", "German", "Japanese", "Spanish"] {
            let language = session.app.buttons[name]
            if language.exists { XCTAssertLessThan(off.frame.minY, language.frame.minY, "\(name) comes before Off") }
        }
        off.tap()
        XCTAssertTrue(session.eventually(10) { shows(picker, Strings.off) }, "Translate To does not show Off")

        // The footer, at the end; the privacy text is too long for a query by identifier or label, so it is matched by a predicate.
        // It ends in a link to the privacy policy, which is not followed: it would leave the app.
        XCTAssertTrue(session.scrollIntoView(session.app.staticTexts[Strings.wordData]), "No word data text")
        XCTAssertTrue(session.app.staticTexts.matching(NSPredicate(format: "label == %@", Strings.privacy)).firstMatch.exists,
                      "No privacy text")
        XCTAssertTrue(session.app.links[Strings.privacyPolicy].exists, "No link to the privacy policy")
        // The sample book's author, credited last (public domain, but the author's name is due wherever it is shown)
        let credit = session.app.staticTexts.matching(NSPredicate(format: "label == %@", Strings.sampleCredit)).firstMatch
        XCTAssertTrue(session.scrollIntoView(credit), "No credit for the sample book")
        session.closeSettings()

        if translates {
            try session.openPeeped()
            session.settle(3)
            XCTAssertFalse(wordTranslation.exists, "Off, yet the card translates")
            XCTAssertFalse(session.app.staticTexts[Strings.translationUnavailable].exists)
            session.closeCard()
            session.back()
        }

        session.relaunch()
        session.openSettings()
        XCTAssertTrue(session.scrollIntoView(picker), "No Translate To")
        XCTAssertTrue(session.eventually(10) { shows(picker, Strings.off) }, "Off was not saved")
    }
}
