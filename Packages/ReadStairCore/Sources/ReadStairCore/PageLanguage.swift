import NaturalLanguage

/// Whether a recognized page is English, and so worth marking.
public enum PageLanguage {
    /// False only when the page has at least 20 words other than punctuation and NLLanguageRecognizer is confident (≥ 0.8) that its
    /// dominant language is not English. A shorter page, such as the end of a chapter, is too little text for a reliable guess and
    /// counts as English, and so does a page the recognizer is unsure about (a badly recognized English page). Not stored, so a
    /// change here needs no new analysis version. A full page takes about 15 ms on a Mac, several times that on the first call, so
    /// run it off the main actor; it creates its recognizer per call (one is not thread-safe), so any thread will do.
    public static func isEnglish(_ text: PageText) -> Bool {
        guard text.words.count(where: { $0.kind != .punct }) >= 20 else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text.sentences.joined(separator: " "))
        guard let language = recognizer.dominantLanguage, language != .english else { return true }
        return recognizer.languageHypotheses(withMaximum: 1)[language, default: 0] < 0.8
    }
}
