import AppKit
import Combine

/// Dictation lifecycle state, observed by the HUD and menu bar.
enum DictationState: Equatable {
    case idle
    case recording
    case processing
    case error(String)
}

@MainActor
final class AppController: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var micLevel: Float = 0
    @Published var enabled = true
    @Published var lastTranscript: String = ""

    private let hotkeys = HotkeyService()
    private let recorder = AudioRecorder()
    private let engine = SpeechAnalyzerEngine()
    private let inserter = Inserter()
    private var hud: HUDPanelController!

    func start() {
        hud = HUDPanelController(controller: self)

        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }

        hotkeys.onFnDown = { [weak self] in self?.beginDictation() }
        hotkeys.onFnUp = { [weak self] in self?.endDictation() }
        hotkeys.onEscape = { [weak self] in
            guard let self, self.state == .recording else { return false }
            self.cancelDictation()
            return true // consume Esc only while recording
        }

        Permissions.promptForAccessibilityIfNeeded()
        hotkeys.startMonitoring()

        // Warm the speech assets for the selected locale in the background.
        Task { try? await engine.prepare() }
    }

    func shutdown() {
        hotkeys.stopMonitoring()
    }

    // MARK: - Dictation flow

    private func beginDictation() {
        guard enabled, state == .idle else { return }
        Task {
            guard await Permissions.ensureMicrophone() else {
                self.flashError("Microphone permission needed")
                return
            }
            do {
                try self.recorder.start()
                self.state = .recording
                self.hud.show()
                Sounds.play(.start)
            } catch {
                self.flashError("Mic error: \(error.localizedDescription)")
            }
        }
    }

    private func endDictation() {
        guard state == .recording else { return }
        let audio = recorder.stop()
        state = .processing
        Sounds.play(.stop)
        Task {
            do {
                let raw = try await engine.transcribe(audio)
                let text = Rules.apply(to: raw)
                self.lastTranscript = text
                if text.isEmpty {
                    self.state = .idle
                    self.hud.hideSoon()
                    return
                }
                self.inserter.paste(text)
                Sounds.play(.paste)
                self.state = .idle
                self.hud.hideSoon()
            } catch {
                self.flashError("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func cancelDictation() {
        _ = recorder.stop()
        state = .idle
        hud.hideSoon()
    }

    func pasteLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        inserter.paste(lastTranscript)
    }

    private func flashError(_ message: String) {
        state = .error(message)
        hud.show()
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if case .error = self.state { self.state = .idle }
            self.hud.hideSoon()
        }
    }
}
