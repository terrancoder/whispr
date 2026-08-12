import AVFoundation
import Foundation
import WhisperKit

/// Multilingual fallback engine (PLAN.md §4.3): WhisperKit compressed
/// large-v3 (~626 MB, 99 languages, MIT). Loaded lazily — the model only
/// downloads the first time a language outside Parakeet/SpeechAnalyzer
/// coverage (or auto-detect) is actually used.
final class WhisperKitEngine {
    enum Status: Equatable { case notLoaded, loading, ready, failed(String) }

    private(set) var status: Status = .notLoaded
    private var pipe: WhisperKit?
    private let modelName = "large-v3-v20240930_626MB"

    func prepare() async throws {
        if pipe != nil { return }
        status = .loading
        do {
            let config = WhisperKitConfig(model: modelName)
            pipe = try await WhisperKit(config)
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// language: ISO 639-1 code, or nil for auto-detect.
    func transcribe(_ audio: [AVAudioPCMBuffer], language: String?) async throws -> String {
        try await prepare()
        guard let pipe else { throw NSError(domain: "whispr.whisper", code: 1) }

        var samples: [Float] = []
        samples.reserveCapacity(audio.reduce(0) { $0 + Int($1.frameLength) })
        for buffer in audio {
            guard let data = buffer.floatChannelData?[0] else { continue }
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        guard !samples.isEmpty else { return "" }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: language != nil,
            detectLanguage: language == nil,
            skipSpecialTokens: true
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The user's dictation-language setting (Settings picker; stored in
/// "whispr.locale"): "" = system locale, "auto" = Whisper auto-detect,
/// anything else = a language/locale code.
enum LanguageSetting: Equatable {
    case system
    case autoDetect
    case code(String)

    static var current: LanguageSetting {
        switch UserDefaults.standard.string(forKey: "whispr.locale") ?? "" {
        case "": return .system
        case "auto": return .autoDetect
        case let value: return .code(value)
        }
    }

    /// ISO 639-1 language for routing decisions.
    var languageCode: String? {
        switch self {
        case .system: return Locale.current.language.languageCode?.identifier
        case .autoDetect: return nil
        case .code(let value): return Locale(identifier: value).language.languageCode?.identifier ?? value
        }
    }
}
