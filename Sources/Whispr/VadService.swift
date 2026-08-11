import AVFoundation
import FluidAudio

/// Silero VAD (CoreML via FluidAudio) for hands-free utterance endpointing.
///
/// Semantics per PLAN.md §4.2 (rev 2): silence endpoints an *utterance*
/// (transcribe + paste, keep listening) — it never ends the hands-free
/// *session*; only the user does. If the VAD model can't load, hands-free
/// still works: audio just accumulates until the user presses fn.
final class VadService {
    /// Fired on the main queue when an utterance ends (speech → sustained silence).
    var onUtteranceEnd: (() -> Void)?

    private var manager: VadManager?
    private var feedContinuation: AsyncStream<[Float]>.Continuation?
    private var pump: Task<Void, Never>?
    private var pending: [Float] = []
    private let chunkSize = VadManager.chunkSize // 4096 samples @ 16 kHz

    /// End an utterance after ~0.8 s of silence; pad edges slightly.
    private let segmentation = VadSegmentationConfig(
        minSpeechDuration: 0.25,
        minSilenceDuration: 0.8
    )

    var isAvailable: Bool { manager != nil }

    func prepare() async {
        guard manager == nil else { return }
        manager = try? await VadManager()
        if manager == nil {
            NSLog("whispr: VAD model unavailable — hands-free will endpoint only on fn press")
        }
    }

    /// Starts a hands-free session pipeline. Chunks fed via `feed` are
    /// processed strictly in order on a single consumer task.
    func beginSession() {
        endSession()
        guard let manager else { return }
        pending = []
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        feedContinuation = continuation
        pump = Task { [weak self] in
            var state = await manager.makeStreamState()
            for await samples in stream {
                guard let self, !Task.isCancelled else { return }
                do {
                    let result = try await manager.processStreamingChunk(
                        samples, state: state, config: self.segmentation)
                    state = result.state
                    if result.event?.isEnd == true {
                        DispatchQueue.main.async { self.onUtteranceEnd?() }
                    }
                } catch {
                    // VAD failure mid-session: stop endpointing, keep recording.
                    NSLog("whispr: VAD chunk failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    func endSession() {
        feedContinuation?.finish()
        feedContinuation = nil
        pump?.cancel()
        pump = nil
        pending = []
    }

    /// Called from the audio thread with converted 16 kHz mono buffers.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard feedContinuation != nil, let data = buffer.floatChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        while pending.count >= chunkSize {
            let chunk = Array(pending.prefix(chunkSize))
            pending.removeFirst(chunkSize)
            feedContinuation?.yield(chunk)
        }
    }
}
