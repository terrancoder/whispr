import AVFoundation

/// Captures microphone audio at the hardware format and converts it with a
/// persistent AVAudioConverter to the format the ASR engine wants
/// (PLAN.md §4.2 — you cannot ask the input node for 16 kHz directly).
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?

    /// Target format for ASR. 16 kHz mono Float32 suits every engine we plan
    /// to use; SpeechAnalyzer converts internally if it prefers another rate.
    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var buffers: [AVAudioPCMBuffer] = []
    private let bufferLock = NSLock()
    private var running = false

    func start() throws {
        guard !running else { return }
        bufferLock.lock()
        buffers.removeAll()
        bufferLock.unlock()

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "whispr.audio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input device available",
            ])
        }
        converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    /// Stops capture and returns the full utterance as converted buffers.
    func stop() -> [AVAudioPCMBuffer] {
        guard running else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        bufferLock.lock()
        let result = buffers
        buffers.removeAll()
        bufferLock.unlock()
        return result
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        reportLevel(of: buffer)
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

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
        guard error == nil, out.frameLength > 0 else { return }
        bufferLock.lock()
        buffers.append(out)
        bufferLock.unlock()
    }

    private func reportLevel(of buffer: AVAudioPCMBuffer) {
        guard let onLevel, let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = (sum / Float(n)).squareRoot()
        // Map RMS to a 0...1 UI level with a gentle log curve.
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))
        onLevel(level)
    }
}
