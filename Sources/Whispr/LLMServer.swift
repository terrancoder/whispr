import Foundation

/// Manages a local `mlx_lm.server` child process (OpenAI-compatible,
/// localhost-only). Installed by `scripts/setup-llm.sh` into
/// ~/Library/Application Support/whispr/llm. If absent, the app simply runs
/// without LLM polish (rules-only) — never a hard dependency (PLAN.md §4.4).
@MainActor
final class LLMServer {
    enum Status: Equatable {
        case notInstalled
        case starting
        case ready
        case failed(String)
        case stopped
    }

    static let shared = LLMServer()
    nonisolated static let port = 18321
    nonisolated static var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Known-good dictation-cleanup model for 16 GB (PLAN.md §3): non-thinking
    /// instruct Qwen, 4-bit MLX, ~2.3 GB.
    nonisolated static var model: String {
        UserDefaults.standard.string(forKey: "whispr.llmModel")
            ?? "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    }

    @Published private(set) var status: Status = .stopped
    var onStatusChange: ((Status) -> Void)?

    private var process: Process?
    private var restarts = 0

    nonisolated static var venvPython: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whispr/llm/venv/bin/python")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.venvPython.path)
    }

    func start() {
        guard process == nil else { return }
        guard isInstalled else {
            setStatus(.notInstalled)
            return
        }
        setStatus(.starting)

        let proc = Process()
        proc.executableURL = Self.venvPython
        proc.arguments = [
            "-m", "mlx_lm", "server",
            "--model", Self.model,
            "--host", "127.0.0.1",
            "--port", String(Self.port),
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in self?.processDied(code: p.terminationStatus) }
        }
        do {
            try proc.run()
            process = proc
            Task { await self.waitUntilHealthy() }
        } catch {
            setStatus(.failed("launch: \(error.localizedDescription)"))
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        setStatus(.stopped)
    }

    private func processDied(code: Int32) {
        process = nil
        // `python -m mlx_lm server` fails fast on old versions that only ship
        // the mlx_lm.server entry point; retry once with the legacy spelling.
        if restarts < 2 {
            restarts += 1
            setStatus(.starting)
            startLegacy()
        } else {
            setStatus(.failed("server exited (\(code))"))
        }
    }

    private func startLegacy() {
        let proc = Process()
        proc.executableURL = Self.venvPython
        proc.arguments = [
            "-m", "mlx_lm.server",
            "--model", Self.model,
            "--host", "127.0.0.1",
            "--port", String(Self.port),
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in self?.processDied(code: p.terminationStatus) }
        }
        do {
            try proc.run()
            process = proc
            Task { await self.waitUntilHealthy() }
        } catch {
            setStatus(.failed("launch: \(error.localizedDescription)"))
        }
    }

    /// Model load (and possibly first-run download) can take a while.
    private func waitUntilHealthy() async {
        let deadline = Date().addingTimeInterval(15 * 60)
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = 2
        while Date() < deadline {
            if process == nil { return } // died; handler owns status
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                restarts = 0
                setStatus(.ready)
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        setStatus(.failed("server never became healthy"))
    }

    private func setStatus(_ new: Status) {
        status = new
        onStatusChange?(new)
    }
}
