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
        if let id = UserDefaults.standard.string(forKey: "whispr.locale") {
            return Locale(identifier: id)
        }
        return Locale.current
    }

    func prepare() async throws {
        let locale = self.locale
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw NSError(domain: "whispr.asr", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Locale \(locale.identifier) not supported by SpeechTranscriber",
            ])
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        preparedLocale = locale
    }

    func transcribe(_ audio: [AVAudioPCMBuffer]) async throws -> String {
        guard !audio.isEmpty else { return "" }
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
