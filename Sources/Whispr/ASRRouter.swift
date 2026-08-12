import AVFoundation

/// Routes each utterance to the best available engine (PLAN.md §4.3):
/// - Parakeet (ANE, near-instant) for its 25 languages, once downloaded
/// - Apple SpeechAnalyzer as the day-one engine and error fallback
/// - WhisperKit large-v3 for everything else and for auto-detect
final class ASRRouter: SpeechEngine {
    let parakeet = ParakeetEngine()
    let apple = SpeechAnalyzerEngine()
    let whisper = WhisperKitEngine()

    private var lastUsed = "Apple Speech"

    /// Parakeet TDT v3's 25 (European) languages.
    private static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu",
        "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    /// Kick off background downloads so the first dictation is fast.
    /// (WhisperKit stays lazy — it only downloads when actually needed.)
    func prepare() async throws {
        async let apple: Void = { [self] in try? await self.apple.prepare() }()
        async let parakeet: Void = { [self] in try? await self.parakeet.prepare() }()
        _ = await (apple, parakeet)
    }

    func transcribe(_ audio: [AVAudioPCMBuffer]) async throws -> String {
        let setting = LanguageSetting.current

        // Auto-detect = Whisper with language identification.
        if setting == .autoDetect {
            lastUsed = "Whisper (auto)"
            return try await whisper.transcribe(audio, language: nil)
        }

        let language = setting.languageCode ?? "en"

        if Self.parakeetLanguages.contains(language), parakeet.status == .ready {
            do {
                lastUsed = "Parakeet"
                return try await parakeet.transcribe(audio)
            } catch {
                NSLog("whispr: Parakeet failed (\(error.localizedDescription)); falling back")
            }
        }

        do {
            lastUsed = "Apple Speech"
            return try await apple.transcribe(audio)
        } catch {
            // Locale unsupported by SpeechAnalyzer (or transient failure) —
            // Whisper covers 99 languages.
            NSLog("whispr: SpeechAnalyzer failed (\(error.localizedDescription)); trying Whisper")
            lastUsed = "Whisper"
            return try await whisper.transcribe(audio, language: language)
        }
    }

    var activeEngineName: String { lastUsed }
}
