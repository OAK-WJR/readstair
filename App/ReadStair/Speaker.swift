import AVFoundation

/// Speaks a word with the best US English voice on the device. One for the whole app (the app model owns it). The user asked to hear
/// the word, so it plays even with the silent switch on; other audio ducks while it speaks. Speaking again starts over.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    /// Made on first use, so creating the app model does nothing.
    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()
    private lazy var voice = Self.bestVoice()
    /// The utterance being spoken; the audio session is released when this one ends, not one it replaced.
    private var utterance: AVSpeechUtterance?

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // VoiceOver users hear their own voice and rate
        utterance.prefersAssistiveTechnologySettings = true
        self.utterance = utterance
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? session.setActive(true)
        synthesizer.speak(utterance)
    }

    func stop() {
        guard utterance != nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    private func ended(_ id: ObjectIdentifier) {
        guard let utterance, ObjectIdentifier(utterance) == id else { return }
        self.utterance = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Premium, else enhanced, else the system's default US English voice; never a novelty or personal voice.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == "en-US" && $0.quality != .default
                && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}
