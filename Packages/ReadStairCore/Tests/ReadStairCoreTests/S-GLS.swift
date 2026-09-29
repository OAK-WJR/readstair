import Foundation
import Testing
@testable import ReadStairCore

/// Supplementary cases: the gloss target language defaults to the first non-English language among the device's preferred languages.
@Suite("Supplementary: Gloss.defaultTargetLanguage")
struct GlossTests {
    @Test("Picks the first non-English language; nil when all are English or the list is empty", arguments: [
        (["en-US", "zh-Hans-US"], "zh"),
        (["es-US", "en-US"], "es"),
        (["zh-Hant-TW", "ja-JP"], "zh"),
        (["en-GB", "en-US"], nil),
        ([], nil),
    ] as [([String], String?)])
    func picksFirstNonEnglish(preferred: [String], expected: String?) {
        #expect(Gloss.defaultTargetLanguage(preferredLanguages: preferred)?.languageCode?.identifier == expected)
    }

    @Test("Keeps the script: Simplified and Traditional Chinese stay distinct")
    func keepsScript() {
        #expect(Gloss.defaultTargetLanguage(preferredLanguages: ["en-US", "zh-Hans-US"])?.script == .hanSimplified)
        #expect(Gloss.defaultTargetLanguage(preferredLanguages: ["zh-Hant-TW"])?.script == .hanTraditional)
    }
}

/// Supplementary cases: the Translate To menu of the Settings sheet, against the languages Apple Translation supported on macOS 26.
@Suite("Supplementary: Gloss.menuOption and Gloss.displayName")
struct GlossMenuTests {
    /// The supported languages as `LanguageAvailability().supportedLanguages` gave them (English left out), by minimal identifier.
    static let supported = ["ar-AE", "zh", "zh-TW", "nl", "fr", "de", "hi", "id", "it", "ja", "ko", "pl", "pt", "ru", "es", "th", "tr",
                            "uk", "vi"].map(Locale.Language.init(identifier:))

    @Test("A device language shows as the item of its language and script, and that item's tag shows as itself", arguments: [
        ("zh-Hans-CN", "zh"), ("zh-Hant-TW", "zh-TW"), ("zh-Hant-HK", "zh-TW"), ("fr-CA", "fr"), ("pt-PT", "pt"), ("es-MX", "es"),
        ("de-AT", "de"), ("ja-JP", "ja"), ("ko-KR", "ko"),
    ])
    func menuOption(device: String, item: String) {
        #expect(Gloss.menuOption(for: Locale.Language(identifier: device), among: Self.supported) == item)
        #expect(Gloss.menuOption(for: Locale.Language(identifier: item), among: Self.supported) == item)
    }

    @Test("Every supported language is its own item, with a tag no other item has")
    func itemsAreTheirOwn() {
        let tags = Self.supported.map { Gloss.menuOption(for: $0, among: Self.supported) }
        #expect(tags == Self.supported.map(\.minimalIdentifier))
        #expect(Set(tags).count == tags.count)
    }

    @Test("Names the language alone, and the script only where two items share the language")
    func displayNames() {
        let english = Locale(identifier: "en_US")
        let names = Self.supported.map { Gloss.displayName(of: $0, among: Self.supported, locale: english) }
        #expect(names.first == "Arabic")
        #expect(names[1] == "Chinese, Simplified" && names[2] == "Chinese, Traditional")
        #expect(Array(names.dropFirst(3)) == ["Dutch", "French", "German", "Hindi", "Indonesian", "Italian", "Japanese", "Korean",
                                               "Polish", "Portuguese", "Russian", "Spanish", "Thai", "Turkish", "Ukrainian",
                                               "Vietnamese"])
        // Alone in the list, Chinese needs no script
        #expect(Gloss.displayName(of: Locale.Language(identifier: "zh"), among: [Locale.Language(identifier: "zh")], locale: english)
                == "Chinese")
    }
}
