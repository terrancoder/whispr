import Foundation

/// Experimental auto-learning (PLAN.md §4.7): after a paste, re-read the
/// focused field and diff — words you typed over our output become dictionary
/// candidates ("never make the same mistake twice"). Conservative filters:
/// small edit distance, real-word check against the system dictionary, no
/// short/common words. Toggle: Settings → whispr.autolearn.
enum AutoLearn {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "whispr.autolearn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "whispr.autolearn") }
    }

    private static let systemWords: Set<String> = {
        guard let content = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else {
            return []
        }
        return Set(content.split(separator: "\n").map { $0.lowercased() })
    }()

    /// Compare what we pasted with what's in the field now; return new terms
    /// worth learning.
    static func candidates(pasted: String, fieldNow: String) -> [String] {
        let pastedWords = words(of: pasted)
        let pastedSet = Set(pastedWords.map { $0.lowercased() })
        var found: [String] = []
        for word in words(of: fieldNow) {
            let lower = word.lowercased()
            guard word.count >= 4, word.count <= 40,
                  !pastedSet.contains(lower),
                  !systemWords.contains(lower),          // not a normal English word
                  word.first?.isLetter == true,
                  !found.contains(where: { $0.lowercased() == lower })
            else { continue }
            // Must be a *correction* of something we pasted (typed-over ASR
            // miss), not brand-new prose the user added.
            guard pastedWords.contains(where: { editDistance($0.lowercased(), lower) <= 2 && $0.lowercased() != lower }) else {
                continue
            }
            found.append(word)
            if found.count >= 3 { break } // conservative per-dictation cap
        }
        return found
    }

    private static func words(of text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }.map(String.init)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        if abs(a.count - b.count) > 2 { return 3 }
        let aChars = Array(a), bChars = Array(b)
        var previous = Array(0...bChars.count)
        for (i, ca) in aChars.enumerated() {
            var current = [i + 1]
            for (j, cb) in bChars.enumerated() {
                current.append(min(
                    previous[j] + (ca == cb ? 0 : 1),
                    previous[j + 1] + 1,
                    current[j] + 1
                ))
            }
            previous = current
        }
        return previous[bChars.count]
    }
}
