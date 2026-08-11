import AppKit
import AVFoundation
import Combine

/// Dictation lifecycle state, observed by the HUD and menu bar.
enum DictationState: Equatable {
    case idle
    case recording
    case handsFree
    case processing
    case error(String)
}

@MainActor
final class AppController: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var micLevel: Float = 0
    @Published var enabled = true
    @Published var lastTranscript: String = ""
    @Published var engineName: String = "Apple Speech"

    private let hotkeys = HotkeyService()
    private let recorder = AudioRecorder()
    private let engine = ASRRouter()
    private let vad = VadService()
    private let inserter = Inserter()
    private var hud: HUDPanelController!

    // Push-to-talk / double-tap bookkeeping (PLAN.md §4.1 semantics:
    // hold ≥ minHold = PTT; shorter tap = pending double-tap; double-tap or
    // fn+Space = hands-free lock; fn press during hands-free = stop session).
    private var fnDownAt: Date?
    private var pendingTapTask: Task<Void, Never>?
    private var lastTapAt: Date?
    private let minHold: TimeInterval = 0.25
    private let doubleTapWindow: TimeInterval = 0.35

    // 20-minute session cap, like Wispr (warn at 19).
    private var capTask: Task<Void, Never>?
    private let sessionCap: TimeInterval = 20 * 60

    /// Frontmost app when the dictation started — the paste target, recorded
    /// into history.
    private var targetAppName: String?

    func start() {
        hud = HUDPanelController(controller: self)
        hud.show()

        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        recorder.onChunk = { [weak self] buffer in
            self?.vad.feed(buffer) // no-op outside a VAD session
        }
        vad.onUtteranceEnd = { [weak self] in self?.handsFreeEndpoint() }

        hotkeys.onFnDown = { [weak self] in self?.fnPressed() }
        hotkeys.onFnUp = { [weak self] in self?.fnReleased() }
        hotkeys.onFnSpace = { [weak self] in
            guard let self, self.enabled else { return false }
            self.toggleHandsFree()
            return true
        }
        hotkeys.onEscape = { [weak self] in
            guard let self, self.state == .recording || self.state == .handsFree else { return false }
            self.cancelDictation()
            return true
        }
        hotkeys.onPasteLast = { [weak self] in
            guard let self, !self.lastTranscript.isEmpty else { return false }
            self.inserter.paste(self.lastTranscript)
            return true
        }

        Permissions.promptForAccessibilityIfNeeded()
        hotkeys.startMonitoring()

        // Background: speech assets, Parakeet models, VAD model.
        engine.parakeet.onStatusChange = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.engineName = self.engine.activeEngineName
                if case .failed(let msg) = status {
                    NSLog("whispr: Parakeet unavailable: \(msg)")
                }
            }
        }
        Task {
            try? await engine.prepare()
            await vad.prepare()
        }
        Task.detached(priority: .background) {
            HistoryStore.shared.applyRetention()
        }

        recoverCrashedDictationIfAny()
    }

    func shutdown() {
        hotkeys.stopMonitoring()
        vad.endSession()
    }

    // MARK: - fn key semantics

    private func fnPressed() {
        guard enabled else { return }
        switch state {
        case .handsFree:
            // Press again to stop = process everything captured so far.
            finishHandsFree()
        case .idle:
            fnDownAt = Date()
            // Second tap of a double-tap? Lock straight into hands-free.
            if let last = lastTapAt, Date().timeIntervalSince(last) < doubleTapWindow {
                pendingTapTask?.cancel()
                pendingTapTask = nil
                lastTapAt = nil
                startHandsFree(reusingRecording: false)
                return
            }
            startRecording()
        case .recording:
            break // fn repeat while already held — ignore
        case .processing, .error:
            break
        }
    }

    private func fnReleased() {
        guard state == .recording, let downAt = fnDownAt else { return }
        fnDownAt = nil
        let heldFor = Date().timeIntervalSince(downAt)

        if heldFor >= minHold {
            endDictation()
            return
        }

        // Short tap: might be the first half of a double-tap. Keep recording
        // quietly; discard if no second tap arrives in time.
        lastTapAt = Date()
        pendingTapTask?.cancel()
        pendingTapTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.doubleTapWindow ?? 0.35))
            guard !Task.isCancelled, let self, self.state == .recording, self.fnDownAt == nil else { return }
            // Lone accidental tap — discard.
            _ = self.recorder.stop()
            self.state = .idle
            self.lastTapAt = nil
        }
    }

    /// Flow Bar click: start/stop hands-free (Wispr's click-the-pill behavior).
    func hudTapped() {
        guard enabled else { return }
        toggleHandsFree()
    }

    private func toggleHandsFree() {
        switch state {
        case .handsFree:
            finishHandsFree()
        case .idle:
            startHandsFree(reusingRecording: false)
        case .recording:
            // fn+Space while holding fn: convert the in-progress hold.
            startHandsFree(reusingRecording: true)
        default:
            break
        }
    }

    // MARK: - Push-to-talk flow

    private func startRecording() {
        guard state == .idle else { return }
        Task {
            guard await Permissions.ensureMicrophone() else {
                self.flashError("Microphone permission needed")
                return
            }
            guard self.state == .idle else { return }
            do {
                self.targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
                try self.recorder.start()
                self.state = .recording
                self.startCapTimer()
                Sounds.play(.start)
            } catch {
                self.flashError("Mic error: \(error.localizedDescription)")
            }
        }
    }

    private func endDictation() {
        guard state == .recording else { return }
        capTask?.cancel()
        let audio = recorder.stop()
        state = .processing
        Sounds.play(.stop)
        Task { await self.transcribeAndPaste(audio, returnTo: .idle) }
    }

    // MARK: - Hands-free flow

    private func startHandsFree(reusingRecording: Bool) {
        pendingTapTask?.cancel()
        pendingTapTask = nil
        lastTapAt = nil
        if reusingRecording {
            state = .handsFree
            vad.beginSession()
            return
        }
        guard state == .idle else { return }
        Task {
            guard await Permissions.ensureMicrophone() else {
                self.flashError("Microphone permission needed")
                return
            }
            guard self.state == .idle else { return }
            do {
                self.targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
                try self.recorder.start()
                self.state = .handsFree
                self.startCapTimer()
                self.vad.beginSession()
                Sounds.play(.start)
            } catch {
                self.flashError("Mic error: \(error.localizedDescription)")
            }
        }
    }

    /// VAD detected end-of-utterance: transcribe what we have, keep listening.
    private func handsFreeEndpoint() {
        guard state == .handsFree else { return }
        let audio = recorder.drain()
        guard !audio.isEmpty else { return }
        Task { await self.transcribeAndPaste(audio, returnTo: nil) }
    }

    private func finishHandsFree() {
        guard state == .handsFree else { return }
        capTask?.cancel()
        vad.endSession()
        let audio = recorder.stop()
        state = .processing
        Sounds.play(.stop)
        Task { await self.transcribeAndPaste(audio, returnTo: .idle) }
    }

    // MARK: - Shared pipeline

    /// Transcribe → rules → paste. `returnTo == nil` means a mid-session
    /// hands-free chunk: state stays `.handsFree` and recording continues.
    private func transcribeAndPaste(_ audio: [AVAudioPCMBuffer], returnTo: DictationState?) async {
        do {
            let raw = try await engine.transcribe(audio)
            let text = Rules.apply(to: raw)
            if !raw.isEmpty {
                HistoryStore.shared.save(
                    raw: raw, text: text, appName: targetAppName,
                    audio: audio, engine: engine.activeEngineName
                )
            }
            if !text.isEmpty {
                // Continuation spacing for follow-on hands-free chunks.
                let payload = (returnTo == nil && !lastTranscript.isEmpty) ? text + " " : text
                lastTranscript = text
                inserter.paste(payload)
                Sounds.play(.paste)
            }
            if let returnTo { state = returnTo }
        } catch {
            if returnTo != nil {
                flashError("Transcription failed: \(error.localizedDescription)")
            } else {
                NSLog("whispr: hands-free chunk failed: \(error.localizedDescription)")
            }
        }
    }

    private func cancelDictation() {
        capTask?.cancel()
        vad.endSession()
        _ = recorder.stop()
        state = .idle
    }

    func reloadHotkeys() {
        hotkeys.reload()
    }

    func pasteLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        inserter.paste(lastTranscript)
    }

    // MARK: - Session cap & crash recovery

    private func startCapTimer() {
        capTask?.cancel()
        capTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.sessionCap - 60))
            guard !Task.isCancelled else { return }
            self.flashError("1 minute left in this dictation")
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            switch self.state {
            case .recording: self.endDictation()
            case .handsFree: self.finishHandsFree()
            default: break
            }
        }
    }

    /// If a previous run crashed mid-dictation, its audio survives in the
    /// recovery WAV. Transcribe it and make it available via paste-last.
    private func recoverCrashedDictationIfAny() {
        let url = AudioRecorder.recoveryURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 64 * 1024 else { return }
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let file = try? AVAudioFile(forReading: url) else { return }
            let format = file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil else { return }
            if let text = try? await engine.transcribe([buffer]), !text.isEmpty {
                self.lastTranscript = Rules.apply(to: text)
                self.flashError("Recovered dictation — press ⌘⌃V to paste")
            }
        }
    }

    private func flashError(_ message: String) {
        let previous = state
        state = .error(message)
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if case .error = self.state {
                self.state = previous == .handsFree ? .handsFree : .idle
            }
        }
    }
}
