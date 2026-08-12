import AVFoundation
import Speech

/// Engine abstraction so Parakeet (FluidAudio) and WhisperKit can slot in
/// later (PLAN.md §4.3) without touching the dictation flow.
protocol SpeechEngine {
    func prepare() async throws
    func transcribe(_ audio: [AVAudioPCMBuffer]) async throws -> String
}

/// Apple SpeechAnalyzer/SpeechTranscriber (macOS 26) — the zero-setup,
/// on-device day-one engine. Language assets are AssetInventory-managed
/// downloads; `prepare()` requests them up front.
final class SpeechAnalyzerEngine: SpeechEngine {
    private var preparedLocale: Locale?

    var locale: Locale {
        if let id = UserDefaults.standard.string(forKey: "whispr.locale"),
           !id.isEmpty, id != "auto" {
            return Locale(identifier: id)
        }
        return Locale.current
    }

    /// Resolves the desired locale to the closest SpeechTranscriber-supported
    /// one. System locales often carry extensions (e.g. `en_US@rg=bdzzzz`,
    /// a region-format override) that fail exact matching against `en-US`.
    static func resolve(_ desired: Locale, against supported: [Locale]) -> Locale? {
        let wantLang = desired.language.languageCode?.identifier ?? desired.identifier
        let wantRegion = desired.language.region?.identifier ?? desired.region?.identifier

        if let exact = supported.first(where: { $0.identifier(.bcp47) == desired.identifier(.bcp47) }) {
            return exact
        }
        if let langAndRegion = supported.first(where: {
            $0.language.languageCode?.identifier == wantLang && $0.region?.identifier == wantRegion
        }) {
            return langAndRegion
        }
        if let langOnly = supported.first(where: { $0.language.languageCode?.identifier == wantLang }) {
            return langOnly
        }
        return nil
    }

    private func resolvedLocale() async throws -> Locale {
        let desired = self.locale
        let supported = await SpeechTranscriber.supportedLocales
        guard let match = Self.resolve(desired, against: supported) else {
            throw NSError(domain: "whispr.asr", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Locale \(desired.identifier) not supported by SpeechTranscriber",
            ])
        }
        return match
    }

    func prepare() async throws {
        let locale = try await resolvedLocale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        preparedLocale = locale
    }

    func transcribe(_ audio: [AVAudioPCMBuffer]) async throws -> String {
        guard !audio.isEmpty else { return "" }
        let locale = try await resolvedLocale()
        if preparedLocale?.identifier != locale.identifier {
            try await prepare()
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // The analyzer has a preferred input format; convert our 16 kHz mono
        // capture to it if they differ.
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        let collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        try await analyzer.start(inputSequence: inputSequence)

        var converter: AVAudioConverter?
        for buffer in audio {
            let payload: AVAudioPCMBuffer
            if let analyzerFormat, analyzerFormat != buffer.format {
                if converter == nil {
                    converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
                }
                guard let converter,
                      let converted = Self.convert(buffer, with: converter, to: analyzerFormat)
                else { continue }
                payload = converted
            } else {
                payload = buffer
            }
            inputBuilder.yield(AnalyzerInput(buffer: payload))
        }
        inputBuilder.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collector.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
