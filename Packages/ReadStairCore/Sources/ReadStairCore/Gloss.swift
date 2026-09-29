import Foundation

/// Picks the gloss target language; the translation itself happens in the app's word card via Apple's Translation framework.
public enum Gloss {
    /// Gloss target language: the first non-English language among the device's preferred languages; nil if all are English, in which case no translation layer is shown.
    public static func defaultTargetLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> Locale.Language? {
        preferredLanguages.lazy.map(Locale.Language.init(identifier:)).first { $0.languageCode != .english }
    }

    /// The menu item, among the languages Apple Translation supports (`all`), that a language shows as: its tag, the item's minimal
    /// identifier. That is the supported language it is, or else the one with its language and script, so a regional variant from
    /// the device settings (fr-CA) shows as the language offered (French). A language with no such item keeps its own tag.
    public static func menuOption(for language: Locale.Language, among all: [Locale.Language]) -> String {
        let wanted = Locale.Language(identifier: language.maximalIdentifier)
        let match = all.first { $0.maximalIdentifier == wanted.maximalIdentifier }
            ?? all.first { candidate in
                let full = Locale.Language(identifier: candidate.maximalIdentifier)
                return full.languageCode == wanted.languageCode && full.script == wanted.script
            }
        return (match ?? language).minimalIdentifier
    }

    /// A menu item's name in `locale`: the language alone (`Arabic`, not `Arabic (United Arab Emirates)`), with its script only when
    /// two items of `all` share the language (`Chinese, Simplified` and `Chinese, Traditional`), since that is the difference readers
    /// look for. The system names languages, so the String Catalog has none.
    public static func displayName(of language: Locale.Language, among all: [Locale.Language], locale: Locale = .current) -> String {
        guard let code = language.languageCode?.identifier else { return language.minimalIdentifier }
        if all.filter({ $0.languageCode == language.languageCode }).count > 1,
           let script = Locale.Language(identifier: language.maximalIdentifier).script?.identifier {
            return locale.localizedString(forIdentifier: "\(code)-\(script)") ?? language.minimalIdentifier
        }
        return locale.localizedString(forLanguageCode: code) ?? language.minimalIdentifier
    }
}
