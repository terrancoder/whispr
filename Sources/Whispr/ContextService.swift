import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Everything we know about where the dictation is going, captured at
/// dictation start (PLAN.md §4.5). All reads are local Accessibility calls —
/// no screenshots, no OCR, nothing leaves the machine.
struct ContextSnapshot {
    var appName: String?
    var bundleID: String?
    var textBefore: String?
    var textAfter: String?
    var selectedText: String?
    var isSecureField: Bool = false
    var secureInputActive: Bool = false
    /// Proper-noun-ish terms harvested from visible window text, used for
    /// spelling hints in the LLM prompt.
    var screenTerms: [String] = []

    /// The field ends mid-sentence → dictation should splice in lowercase.
    var isMidSentence: Bool {
        guard let before = textBefore?.trimmingCharacters(in: .whitespacesAndNewlines),
              let last = before.last else { return false }
        return !".!?\n:;".contains(last)
    }

    var needsLeadingSpace: Bool {
        guard let before = textBefore, let last = before.last else { return false }
        return !last.isWhitespace && !last.isNewline
    }
}

enum ContextService {
    private static let maxFieldText = 400
    private static let maxWalkElements = 120
    private static let maxTerms = 30

    /// Capture a snapshot of the frontmost app + focused element. Fast,
    /// bounded, and safe to call on the main thread at dictation start.
    static func capture() -> ContextSnapshot {
        var snapshot = ContextSnapshot()
        snapshot.secureInputActive = IsSecureEventInputEnabled()

        guard let app = NSWorkspace.shared.frontmostApplication else { return snapshot }
        snapshot.appName = app.localizedName
        snapshot.bundleID = app.bundleIdentifier

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Wake lazy Chromium/Electron AX trees (no-op elsewhere).
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let focused: AXUIElement = copyAttribute(appElement, kAXFocusedUIElementAttribute) else {
            snapshot.screenTerms = harvestTerms(appElement: appElement)
            return snapshot
        }

        let role: String? = copyAttribute(focused, kAXRoleAttribute)
        if role == "AXSecureTextField" {
            snapshot.isSecureField = true
            return snapshot
        }

        if let value: String = copyAttribute(focused, kAXValueAttribute), !value.isEmpty {
            let caret = caretIndex(of: focused, valueLength: value.count)
            let chars = Array(value)
            let split = min(max(caret, 0), chars.count)
            snapshot.textBefore = String(chars[max(0, split - maxFieldText)..<split])
            snapshot.textAfter = String(chars[split..<min(chars.count, split + maxFieldText)])
        }
        snapshot.selectedText = copyAttribute(focused, kAXSelectedTextAttribute)
        snapshot.screenTerms = harvestTerms(appElement: appElement)
        return snapshot
    }

    private static func caretIndex(of element: AXUIElement, valueLength: Int) -> Int {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return valueLength }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return valueLength }
        return range.location
    }

    /// Bounded BFS over the focused window collecting static-text/title values;
    /// extracts capitalized tokens as spelling hints (names, product words).
    private static func harvestTerms(appElement: AXUIElement) -> [String] {
        guard let window: AXUIElement = copyAttribute(appElement, kAXFocusedWindowAttribute) else {
            return []
        }
        var texts: [String] = []
        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty, visited < maxWalkElements {
            let element = queue.removeFirst()
            visited += 1
            if let title: String = copyAttribute(element, kAXTitleAttribute), !title.isEmpty {
                texts.append(title)
            }
            if let role: String = copyAttribute(element, kAXRoleAttribute),
               role == kAXStaticTextRole as String,
               let value: String = copyAttribute(element, kAXValueAttribute), value.count < 500 {
                texts.append(value)
            }
            if let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children.prefix(20))
            }
        }
        return properNouns(in: texts)
    }

    private static func properNouns(in texts: [String]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        let common: Set<String> = [
            "The", "This", "That", "And", "But", "For", "New", "You", "Your", "All",
            "Today", "Yesterday", "Tomorrow", "File", "Edit", "View", "Window", "Help",
        ]
        for text in texts {
            for rawWord in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
                let word = rawWord.trimmingCharacters(in: .punctuationCharacters)
                guard word.count >= 3, word.count <= 30,
                      let first = word.first, first.isUppercase,
                      word.dropFirst().contains(where: { $0.isLowercase }),
                      !common.contains(word), !seen.contains(word.lowercased())
                else { continue }
                seen.insert(word.lowercased())
                terms.append(word)
                if terms.count >= maxTerms { return terms }
            }
        }
        return terms
    }

    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }
}
