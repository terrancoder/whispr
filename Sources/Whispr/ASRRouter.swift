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
            let text = try await whisper.transcribe(audio, language: nil)
            lastUsed = "Whisper (auto)"
            return text
        }

        let language = setting.languageCode ?? "en"

        if Self.parakeetLanguages.contains(language), parakeet.status == .ready {
            do {
                let text = try await parakeet.transcribe(audio)
                lastUsed = "Parakeet"
                return text
            } catch {
                NSLog("whispr: Parakeet failed (\(error.localizedDescription)); falling back")
            }
        }

        do {
            let text = try await apple.transcribe(audio)
            lastUsed = "Apple Speech"
            return text
        } catch {
            // Locale unsupported by SpeechAnalyzer (or transient failure) —
            // Whisper covers 99 languages.
            NSLog("whispr: SpeechAnalyzer failed (\(error.localizedDescription)); trying Whisper")
            let text = try await whisper.transcribe(audio, language: language)
            lastUsed = "Whisper"
            return text
        }
    }

    var activeEngineName: String { lastUsed }
}
