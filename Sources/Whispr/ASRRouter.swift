import AVFoundation

/// Routes each utterance to the best available engine (PLAN.md §4.3):
/// Parakeet once its models are downloaded, Apple SpeechAnalyzer until then
/// (and as the error fallback so a Parakeet hiccup never loses an utterance).
final class ASRRouter: SpeechEngine {
    let parakeet = ParakeetEngine()
    let apple = SpeechAnalyzerEngine()

    /// Kick off background downloads so the first dictation is fast.
    func prepare() async throws {
        async let apple: Void = { [self] in try? await self.apple.prepare() }()
        async let parakeet: Void = { [self] in try? await self.parakeet.prepare() }()
        _ = await (apple, parakeet)
    }

    func transcribe(_ audio: [AVAudioPCMBuffer]) async throws -> String {
        if parakeet.status == .ready {
            do {
                return try await parakeet.transcribe(audio)
            } catch {
                NSLog("whispr: Parakeet failed (\(error.localizedDescription)); falling back to SpeechAnalyzer")
            }
        }
        return try await apple.transcribe(audio)
    }

    var activeEngineName: String {
        parakeet.status == .ready ? "Parakeet" : "Apple Speech"
    }
}
