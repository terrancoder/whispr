import AppKit
import AVFoundation
import Combine

/// Dictation lifecycle state, observed by the HUD and menu bar.
enum DictationState: Equatable {
    case idle
    case recording
    case command
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
    @Published var llmStatus: String = "Stopped"

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
    /// AX context snapshot taken at dictation start (PLAN.md §4.5).
    private var context = ContextSnapshot()

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
        hotkeys.onCommandDown = { [weak self] in self?.beginCommand() }
        hotkeys.onCommandUp = { [weak self] in self?.endCommand() }
        hotkeys.onEscape = { [weak self] in
            guard let self,
                  self.state == .recording || self.state == .handsFree || self.state == .command
            else { return false }
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
        LLMServer.shared.onStatusChange = { [weak self] status in
            Task { @MainActor in
                switch status {
                case .ready: self?.llmStatus = "Ready"
                case .starting: self?.llmStatus = "Starting…"
                case .notInstalled: self?.llmStatus = "Not installed (run scripts/setup-llm.sh)"
                case .failed(let msg): self?.llmStatus = "Failed: \(msg)"
                case .stopped: self?.llmStatus = "Stopped"
                }
            }
        }
        LLMServer.shared.start()

        recoverCrashedDictationIfAny()
    }

    func shutdown() {
        hotkeys.stopMonitoring()
        vad.endSession()
        LLMServer.shared.stop()
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
        case .command, .processing, .error:
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
                self.context = ContextService.capture()
                self.targetAppName = self.context.appName
                if self.context.isSecureField {
                    self.flashError("Secure field — dictation blocked")
                    return
                }
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

    // MARK: - Command mode (PLAN.md §4.8)

    private var commandSelection: String?

    private func beginCommand() {
        guard enabled, state == .idle else { return }
        guard LLMServer.shared.status == .ready else {
            flashError("Command mode needs the local AI (see Settings)")
            return
        }
        Task {
            guard await Permissions.ensureMicrophone() else {
                self.flashError("Microphone permission needed")
                return
            }
            guard self.state == .idle else { return }
            self.context = ContextService.capture()
            self.targetAppName = self.context.appName
            if self.context.isSecureField {
                self.flashError("Secure field — command mode blocked")
                return
            }
            // Selection: AX first, synthetic ⌘C fallback.
            var selection = self.context.selectedText
            if selection?.isEmpty ?? true {
                selection = await self.inserter.captureSelection()
            }
            if let words = selection?.split(separator: " ").count, words > CommandEngine.maxSelectionWords {
                self.flashError("Selection too long (max \(CommandEngine.maxSelectionWords) words)")
                return
            }
            self.commandSelection = selection
            do {
                try self.recorder.start()
                self.state = .command
                self.startCapTimer()
                Sounds.play(.start)
            } catch {
                self.flashError("Mic error: \(error.localizedDescription)")
            }
        }
    }

    private func endCommand() {
        guard state == .command else { return }
        capTask?.cancel()
        let audio = recorder.stop()
        state = .processing
        Sounds.play(.stop)
        Task {
            do {
                let instruction = try await engine.transcribe(audio)
                guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.state = .idle
                    return
                }
                let result = try await CommandEngine.run(
                    instruction: instruction, selection: self.commandSelection)
                guard !result.isEmpty else {
                    self.flashError("Command produced no output")
                    return
                }
                HistoryStore.shared.save(
                    raw: instruction, text: result, appName: self.targetAppName,
                    audio: audio, engine: "command"
                )
                self.lastTranscript = result
                self.inserter.paste(result) // replaces the selection in place
                Sounds.play(.paste)
                self.state = .idle
            } catch {
                self.flashError("Command failed: \(error.localizedDescription)")
            }
        }
    }

    /// Transforms: preset instructions applied to the current selection
    /// without speaking (menu-driven).
    func applyTransform(_ instruction: String) {
        guard state == .idle else { return }
        guard LLMServer.shared.status == .ready else {
            flashError("Transforms need the local AI (see Settings)")
            return
        }
        Task {
            self.context = ContextService.capture()
            self.targetAppName = self.context.appName
            var selection = self.context.selectedText
            if selection?.isEmpty ?? true {
                selection = await self.inserter.captureSelection()
            }
            guard let selection, !selection.isEmpty else {
                self.flashError("Select some text first")
                return
            }
            self.state = .processing
            do {
                let result = try await CommandEngine.run(instruction: instruction, selection: selection)
                guard !result.isEmpty else {
                    self.flashError("Transform produced no output")
                    return
                }
                self.lastTranscript = result
                self.inserter.paste(result)
                Sounds.play(.paste)
                self.state = .idle
            } catch {
                self.flashError("Transform failed: \(error.localizedDescription)")
            }
        }
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
                self.context = ContextService.capture()
                self.targetAppName = self.context.appName
                if self.context.isSecureField {
                    self.flashError("Secure field — dictation blocked")
                    return
                }
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
            let outcome = await Formatter.format(raw: raw, context: context)
            let text = outcome.text
            if !raw.isEmpty {
                HistoryStore.shared.save(
                    raw: raw, text: text, appName: targetAppName,
                    audio: audio, engine: engine.activeEngineName + (outcome.usedLLM ? " + AI" : "")
                )
            }
            if !text.isEmpty {
                // Continuation spacing for follow-on hands-free chunks.
                let payload = (returnTo == nil && !lastTranscript.isEmpty) ? text + " " : text
                lastTranscript = text
                inserter.paste(payload)
                if outcome.pressEnter {
                    inserter.pressReturn(after: 0.55)
                }
                Sounds.play(.paste)
                if AutoLearn.enabled {
                    scheduleAutoLearn(pasted: text)
                }
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

    /// Experimental dictionary auto-learning: ~12 s after the paste, re-read
    /// the field via AX and diff against what we pasted (PLAN.md §4.7).
    private func scheduleAutoLearn(pasted: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self else { return }
            let snapshot = ContextService.capture()
            guard snapshot.appName == self.targetAppName else { return }
            let fieldNow = (snapshot.textBefore ?? "") + (snapshot.textAfter ?? "")
            guard !fieldNow.isEmpty else { return }
            for term in AutoLearn.candidates(pasted: pasted, fieldNow: fieldNow) {
                DictionaryStore.shared.addTerm(term, autoLearned: true)
            }
        }
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
