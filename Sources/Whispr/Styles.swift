import Foundation

/// App categories for tone matching, mirroring Wispr's four buckets plus a
/// code bucket (PLAN.md §4.5). Category is detected from the frontmost app's
/// bundle ID; each category maps to a user-configurable style.
enum AppCategory: String, CaseIterable, Identifiable {
    case personalMessaging
    case workMessaging
    case email
    case code
    case other

    var id: String { rawValue }
    var label: String {
        switch self {
        case .personalMessaging: return "Personal messaging"
        case .workMessaging: return "Work messaging"
        case .email: return "Email"
        case .code: return "Code & terminals"
        case .other: return "Everything else"
        }
    }

    static func detect(bundleID: String?) -> AppCategory {
        guard let id = bundleID?.lowercased() else { return .other }
        let map: [(AppCategory, [String])] = [
            (.personalMessaging, [
                "com.apple.mobilesms", "whatsapp", "telegram", "signal", "viber", "messenger",
            ]),
            (.workMessaging, [
                "slack", "teams", "discord", "mattermost", "zulip",
            ]),
            (.email, [
                "com.apple.mail", "outlook", "superhuman", "spark", "mimestream", "proton.mail",
            ]),
            (.code, [
                "com.microsoft.vscode", "cursor", "windsurf", "com.apple.dt.xcode",
                "com.apple.terminal", "iterm2", "warp", "ghostty", "zed", "jetbrains", "sublime",
            ]),
        ]
        for (category, needles) in map where needles.contains(where: { id.contains($0) }) {
            return category
        }
        return .other
    }

    var defaultStyle: Style {
        switch self {
        case .personalMessaging: return .veryCasual
        case .workMessaging: return .casual
        case .email: return .formal
        case .code: return .neutral
        case .other: return .neutral
        }
    }

    var style: Style {
        get {
            let key = "whispr.style.\(rawValue)"
            if let raw = UserDefaults.standard.string(forKey: key), let s = Style(rawValue: raw) {
                return s
            }
            return defaultStyle
        }
        nonmutating set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "whispr.style.\(rawValue)")
        }
    }
}

/// Wispr's styles: affect ONLY caps/punctuation/spacing, never word choice.
enum Style: String, CaseIterable, Identifiable {
    case veryCasual
    case casual
    case excited
    case formal
    case neutral

    var id: String { rawValue }
    var label: String {
        switch self {
        case .veryCasual: return "Very casual (no caps)"
        case .casual: return "Casual"
        case .excited: return "Excited"
        case .formal: return "Formal"
        case .neutral: return "Neutral (no adjustment)"
        }
    }

    /// Short directive appended to the LLM prompt (kept compact and stable).
    var directive: String? {
        switch self {
        case .veryCasual:
            return "Style: very casual — lowercase (keep \"I\" and proper nouns), minimal punctuation, no trailing period."
        case .casual:
            return "Style: casual — normal capitalization, light punctuation, no trailing period on the final sentence."
        case .excited:
            return "Style: excited — normal capitalization; end upbeat sentences with an exclamation point."
        case .formal:
            return "Style: formal — full sentences, proper capitalization and punctuation."
        case .neutral:
            return nil
        }
    }

    /// Deterministic tweaks applied after formatting (also the no-LLM floor).
    func apply(to input: String) -> String {
        var text = input
        switch self {
        case .veryCasual:
            text = Style.lowercaseSentenceStarts(text)
            text = Style.stripTrailingPeriod(text)
        case .casual:
            text = Style.stripTrailingPeriod(text)
        case .excited:
            if text.hasSuffix(".") { text = String(text.dropLast()) + "!" }
        case .formal:
            if let last = text.last, !".!?…".contains(last), !text.isEmpty { text += "." }
        case .neutral:
            break
        }
        return text
    }

    private static func stripTrailingPeriod(_ text: String) -> String {
        // Only single-sentence endings — multi-sentence text keeps its periods.
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        let body = text.dropLast()
        guard !body.contains(". ") else { return text }
        return String(body)
    }

    private static func lowercaseSentenceStarts(_ text: String) -> String {
        var result = ""
        var atStart = true
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if atStart, ch.isLetter {
                // Keep "I" and words that continue uppercase (acronyms, names).
                let next = text.index(after: index)
                let isAcronymOrI = (ch == "I" && (next == text.endIndex || !text[next].isLetter))
                    || (next < text.endIndex && text[next].isUppercase)
                result.append(isAcronymOrI ? ch : Character(ch.lowercased()))
                atStart = false
            } else {
                result.append(ch)
            }
            if ".!?\n".contains(ch) { atStart = true }
            index = text.index(after: index)
        }
        return result
    }
}
