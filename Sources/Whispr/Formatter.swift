import Foundation

/// Cleanup levels, mirroring Wispr's Auto Cleanup tiers (PLAN.md §4.4).
enum CleanupLevel: String, CaseIterable, Identifiable {
    case none    // raw ASR output, untouched
    case light   // deterministic rules only
    case medium  // rules + LLM polish (default)
    case high    // rules + LLM polish with brevity

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None (raw transcript)"
        case .light: return "Light (rules only)"
        case .medium: return "Medium (AI cleanup)"
        case .high: return "High (AI cleanup + brevity)"
        }
    }

    static var current: CleanupLevel {
        get { CleanupLevel(rawValue: UserDefaults.standard.string(forKey: "whispr.cleanup") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "whispr.cleanup") }
    }
}

struct FormatOutcome {
    var text: String
    var pressEnter: Bool
    var usedLLM: Bool
}

/// The formatting pipeline: raw ASR → deterministic rules → (conditional)
/// LLM polish → post-checks. The LLM is additive and can never block or lose
/// an utterance: any failure/timeout ships the rules-only text (PLAN.md §4.4).
enum Formatter {
    /// Correction cues that make even short utterances worth an LLM pass.
    private static let cuePattern =
        "(?i)\\b(scratch that|no wait|wait no|i mean|make that|actually|never ?mind|forget that|delete that|correction)\\b"

    @MainActor
    static func format(raw: String) async -> FormatOutcome {
        let level = CleanupLevel.current
        if level == .none {
            return FormatOutcome(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), pressEnter: false, usedLLM: false)
        }

        let rules = Rules.process(raw)
        guard level == .medium || level == .high else {
            return FormatOutcome(text: rules.text, pressEnter: rules.pressEnter, usedLLM: false)
        }

        // Bypass gate: short utterances with no fillers/corrections don't pay
        // LLM latency — unless a cue word is present (short cue-less
        // restatements are an accepted miss; PLAN.md rev 2 note).
        let wordCount = rules.text.split(separator: " ").count
        let hasCue = raw.range(of: cuePattern, options: .regularExpression) != nil
        let llmReady = LLMServer.shared.status == .ready
        guard llmReady, wordCount >= 10 || hasCue else {
            return FormatOutcome(text: rules.text, pressEnter: rules.pressEnter, usedLLM: false)
        }

        // The LLM sees the pre-rules raw text (minus the press-enter command,
        // which rules already extracted) so it can use hesitation patterns.
        let llmInput = Rules.process(raw).pressEnter
            ? raw.replacingOccurrences(
                of: "(?i)[,.]?\\s*\\bpress enter\\b[,.!]?\\s*$", with: "", options: .regularExpression)
            : raw

        do {
            let polished = try await LLMClient.cleanup(llmInput, brevity: level == .high)
            guard isSane(polished, raw: rules.text, brevity: level == .high) else {
                NSLog("whispr: LLM output failed sanity check; using rules-only text")
                return FormatOutcome(text: rules.text, pressEnter: rules.pressEnter, usedLLM: false)
            }
            return FormatOutcome(text: polished, pressEnter: rules.pressEnter, usedLLM: true)
        } catch {
            NSLog("whispr: LLM polish unavailable (\(error.localizedDescription)); using rules-only text")
            return FormatOutcome(text: rules.text, pressEnter: rules.pressEnter, usedLLM: false)
        }
    }

    /// Over-summarization / hallucination guard: reject empty output, output
    /// that lost most of the content (unless brevity was requested), or
    /// obvious assistant replies to question-shaped dictations.
    private static func isSane(_ output: String, raw: String, brevity: Bool) -> Bool {
        guard !output.isEmpty else { return false }
        let rawLen = Double(raw.count)
        let outLen = Double(output.count)
        if !brevity, rawLen > 80, outLen < rawLen * 0.45 { return false }
        if outLen > rawLen * 3 + 200 { return false } // hallucinated expansion
        return true
    }
}
