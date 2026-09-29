import Foundation
import FoundationModels

/// In This Sentence on the word card: Apple Intelligence (the on-device Foundation Models) explains the word's meaning in its
/// sentence. Here rather than in the app so that EXP-FM measures the prompt the card uses.
public enum SentenceMeaning {
    @Generable
    public struct Answer: Sendable {
        @Guide(description: "What the word means in this sentence, in a few words, in the language the prompt names")
        public var meaningHere: String
        @Guide(description: "One short sentence in simple English explaining that meaning")
        public var explanation: String
        @Guide(description: "One new example sentence in English using the word with the same meaning")
        public var example: String
    }

    /// An answer, and the language its first part is written in (for VoiceOver).
    public typealias Explained = (answer: Answer, language: String)

    /// Loads the model before the first card asks for it. The Reader calls this when it appears, if the model is available.
    public static func prewarm() {
        LanguageModelSession(model: model, instructions: instructions).prewarm()
    }

    /// `meaningHere` is in `language`, the translation language, when the model supports it, and in simple English otherwise.
    /// Throws the model's error, cancellation included.
    @concurrent
    public static func explain(_ headword: String, printed: String, in sentence: String,
                               language: Locale.Language?) async throws -> Explained {
        let model = Self.model
        var answerLanguage = (name: "simple English", tag: "en-US")
        if let language, model.supportsLocale(Locale(identifier: language.maximalIdentifier)),
           let name = Locale(identifier: "en").localizedString(forIdentifier: language.minimalIdentifier) {
            answerLanguage = (name, language.minimalIdentifier)
        }
        let prompt = """
            Sentence: \(sentence)
            Word: \(printed) (dictionary form: \(headword))
            Write meaningHere in \(answerLanguage.name).
            """
        let session = LanguageModelSession(model: model, instructions: instructions)
        return (try await session.respond(to: prompt, generating: Answer.self).content, answerLanguage.tag)
    }

    /// The prompt transforms the reader's own text; for a structured answer the system applies its default guardrails regardless.
    private static var model: SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    private static let instructions = """
        You help a reader who is learning English understand one word in a sentence from an English book. Explain only the meaning \
        the word has in that sentence, not its other senses. If the word is part of a phrasal verb or a name, explain the whole phrase.
        """
}
