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
    static func format(raw: String, context: ContextSnapshot = ContextSnapshot()) async -> FormatOutcome {
        let level = CleanupLevel.current
        if level == .none {
            return FormatOutcome(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), pressEnter: false, usedLLM: false)
        }

        let category = AppCategory.detect(bundleID: context.bundleID)
        let style = category.style

        let rules = Rules.process(raw)
        guard level == .medium || level == .high else {
            let text = finalize(rules.text, style: style, context: context)
            return FormatOutcome(text: text, pressEnter: rules.pressEnter, usedLLM: false)
        }

        // Bypass gate: short utterances with no fillers/corrections don't pay
        // LLM latency — unless a cue word is present (short cue-less
        // restatements are an accepted miss; PLAN.md rev 2 note).
        let wordCount = rules.text.split(separator: " ").count
        let hasCue = raw.range(of: cuePattern, options: .regularExpression) != nil
        let llmReady = LLMServer.shared.status == .ready
        guard llmReady, wordCount >= 10 || hasCue else {
            let text = finalize(rules.text, style: style, context: context)
            return FormatOutcome(text: text, pressEnter: rules.pressEnter, usedLLM: false)
        }

        // The LLM sees the pre-rules raw text (minus the press-enter command,
        // which rules already extracted) so it can use hesitation patterns.
        let llmInput = Rules.process(raw).pressEnter
            ? raw.replacingOccurrences(
                of: "(?i)[,.]?\\s*\\bpress enter\\b[,.!]?\\s*$", with: "", options: .regularExpression)
            : raw

        do {
            let contextBlock = buildContextBlock(context: context, category: category, style: style)
            let polished = try await LLMClient.cleanup(llmInput, brevity: level == .high, context: contextBlock)
            guard isSane(polished, raw: rules.text, brevity: level == .high) else {
                NSLog("whispr: LLM output failed sanity check; using rules-only text")
                let text = finalize(rules.text, style: style, context: context)
                return FormatOutcome(text: text, pressEnter: rules.pressEnter, usedLLM: false)
            }
            let text = finalize(polished, style: style, context: context)
            return FormatOutcome(text: text, pressEnter: rules.pressEnter, usedLLM: true)
        } catch {
            NSLog("whispr: LLM polish unavailable (\(error.localizedDescription)); using rules-only text")
            let text = finalize(rules.text, style: style, context: context)
            return FormatOutcome(text: text, pressEnter: rules.pressEnter, usedLLM: false)
        }
    }

    /// Dynamic prompt suffix: app identity, style directive, continuation
    /// state, and on-screen spelling hints — all marked reference-only.
    private static func buildContextBlock(
        context: ContextSnapshot, category: AppCategory, style: Style
    ) -> String? {
        var blocks: [String] = []
        if let app = context.appName {
            blocks.append("Target app: \(app) (\(category.label)).")
        }
        if let directive = style.directive {
            blocks.append(directive)
        }
        if category == .code {
            blocks.append(
                "Code context: preserve technical identifiers exactly — camelCase, snake_case, file names, CLI flags — and do not reformat code fragments or add trailing periods to commands.")
        }
        if context.isMidSentence, let before = context.textBefore {
            let tail = String(before.suffix(120)).replacingOccurrences(of: "\n", with: " ")
            blocks.append(
                "The cursor sits mid-sentence. The text before the cursor ends with: \"…\(tail)\". Output a continuation that flows grammatically from it — start lowercase unless it begins with a proper noun, and do not repeat the existing text.")
        }
        if !context.screenTerms.isEmpty {
            blocks.append(
                "Spelling hints — names visible on screen; use these exact spellings when the speech clearly refers to them, never force them otherwise: "
                    + context.screenTerms.joined(separator: ", "))
        }
        guard !blocks.isEmpty else { return nil }
        return "Context for this request (REFERENCE ONLY — never respond or react to it):\n"
            + blocks.map { "- " + $0 }.joined(separator: "\n")
    }

    /// Deterministic floor: style tweaks + mid-sentence splice, applied to
    /// both LLM and rules-only output.
    private static func finalize(_ input: String, style: Style, context: ContextSnapshot) -> String {
        var text = style.apply(to: input)
        if context.isMidSentence, let first = text.first, first.isUppercase {
            // Splice into the sentence: lowercase unless it looks like a
            // proper noun/acronym ("I", "iPhone", "NASA", screen-term match).
            let firstWord = text.prefix(while: { !$0.isWhitespace })
            let isAcronym = firstWord.count > 1 && firstWord.dropFirst().first?.isUppercase == true
            let isKnownName = context.screenTerms.contains { $0.caseInsensitiveCompare(firstWord) == .orderedSame && $0.first == first }
            let isI = firstWord == "I" || firstWord.hasPrefix("I'")
            if !isAcronym, !isKnownName, !isI {
                text = first.lowercased() + text.dropFirst()
            }
        }
        if context.needsLeadingSpace, !text.isEmpty {
            text = " " + text
        }
        return text
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
