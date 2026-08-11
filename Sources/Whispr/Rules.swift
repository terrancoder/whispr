import Foundation

struct RulesResult {
    var text: String
    /// "press enter" spoken at the end of the dictation → synthesize Return
    /// after the paste (desktop-Wispr behavior; end-of-dictation only).
    var pressEnter: Bool = false
}

/// Deterministic post-processing (PLAN.md §4.4). Always runs; this is the
/// guaranteed floor under the LLM polish layer.
enum Rules {
    /// Spoken command → literal replacement. Matched case-insensitively as
    /// standalone phrases. Order matters: longer phrases first.
    private static let spokenCommands: [(String, String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("question mark", "?"),
        ("exclamation mark", "!"),
        ("exclamation point", "!"),
        ("em dash", "—"),
        ("m dash", "—"),
        ("semicolon", ";"),
        ("colon", ":"),
        ("comma", ","),
        ("period", "."),
        ("full stop", "."),
        ("open paren", "("),
        ("close paren", ")"),
        ("open quote", "\u{201C}"),
        ("close quote", "\u{201D}"),
        ("percent sign", "%"),
        ("hashtag", "#"),
        ("at sign", "@"),
        ("tilde", "~"),
        ("degree sign", "°"),
        ("degrees celsius", "°C"),
        ("degrees fahrenheit", "°F"),
        ("open bracket", "["),
        ("close bracket", "]"),
        ("open angle bracket", "<"),
        ("close angle bracket", ">"),
        ("trademark sign", "™"),
        ("copyright sign", "©"),
        ("ellipsis", "…"),
        ("dot dot dot", "…"),
    ]

    private static let fillers = ["um", "uh", "uhm", "erm", "mm-hmm", "uh-huh"]

    static func process(_ input: String) -> RulesResult {
        var pressEnter = false
        var text = input

        // "press enter" at the very end of the dictation (allow trailing punctuation).
        if let range = text.range(
            of: "(?i)[,.]?\\s*\\bpress enter\\b[,.!]?\\s*$", options: .regularExpression
        ) {
            text.removeSubrange(range)
            pressEnter = true
        }

        return RulesResult(text: apply(to: text), pressEnter: pressEnter)
    }

    static func apply(to input: String) -> String {
        var text = input

        // Spoken punctuation commands. SpeechAnalyzer already punctuates from
        // prosody; these handle the explicit commands it transcribes verbatim.
        for (phrase, replacement) in spokenCommands {
            let pattern = "(?i)(?:[,.]\\s*)?\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b[,.]?"
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        // Filler words.
        for filler in fillers {
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: filler))\\b[,.]?\\s*"
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        // Whitespace normalization: no space before punctuation, collapse runs.
        text = text.replacingOccurrences(of: "\\s+([.,;:!?])", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Capitalize sentence starts (cheap pass; the LLM layer will do better).
        text = capitalizeSentences(text)
        return text
    }

    private static func capitalizeSentences(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var result = ""
        var capitalizeNext = true
        for ch in input {
            if capitalizeNext, ch.isLetter {
                result.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                result.append(ch)
            }
            if ".!?\n".contains(ch) { capitalizeNext = true }
        }
        return result
    }
}
