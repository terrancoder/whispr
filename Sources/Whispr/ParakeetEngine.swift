import AVFoundation
import FluidAudio

/// Parakeet TDT 0.6B via FluidAudio (CoreML/ANE). Primary engine per PLAN.md
/// §4.3 — v2 for English (tighter vocab, best English WER), v3 for its other
/// languages. Models are downloaded from HuggingFace on first use.
final class ParakeetEngine: SpeechEngine {
    enum Status: Equatable {
        case notReady
        case downloading
        case ready
        case failed(String)
    }

    private(set) var status: Status = .notReady
    var onStatusChange: ((Status) -> Void)?

    private var manager: AsrManager?
    private let prepareLock = AsyncLock()

    /// v2 for English system/override locale, v3 otherwise.
    private var version: AsrModelVersion {
        let id = UserDefaults.standard.string(forKey: "whispr.locale") ?? Locale.current.identifier
        return id.hasPrefix("en") ? .v2 : .v3
    }

    func prepare() async throws {
        try await prepareLock.withLock {
            guard self.manager == nil else { return }
            self.setStatus(.downloading)
            do {
                let models = try await AsrModels.downloadAndLoad(version: self.version)
                self.manager = AsrManager(config: .default, models: models)
                self.setStatus(.ready)
            } catch {
                self.setStatus(.failed(error.localizedDescription))
                throw error
            }
        }
    }

    func transcribe(_ audio: [AVAudioPCMBuffer]) async throws -> String {
        try await prepare()
        guard let manager else {
            throw NSError(domain: "whispr.asr", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Parakeet models not loaded",
            ])
        }
        let samples = Self.concatenate(audio)
        guard !samples.isEmpty else { return "" }
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Flattens our 16 kHz mono Float32 buffers into one sample array.
    static func concatenate(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(buffers.reduce(0) { $0 + Int($1.frameLength) })
        for buffer in buffers {
            guard let data = buffer.floatChannelData?[0] else { continue }
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        return samples
    }

    private func setStatus(_ new: Status) {
        status = new
        onStatusChange?(new)
    }
}

/// Minimal async mutex so concurrent transcribe() calls don't double-download.
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
