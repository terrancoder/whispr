import AppKit
import CoreGraphics

/// Inserts text at the cursor of the frontmost app: pasteboard snapshot →
/// write (marked transient) → synthetic ⌘V → restore prior clipboard after
/// verifying we still own it (PLAN.md §4.6; timings tuned per VoiceInk).
final class Inserter {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.transientType)
        let ourChangeCount = pasteboard.changeCount

        // Give the pasteboard write a beat to settle before the paste keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            Self.postCmdV()
            // Restore the user's clipboard once the target app has consumed ours.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                if pasteboard.changeCount == ourChangeCount {
                    Self.restore(saved, to: pasteboard)
                }
            }
        }
    }

    // MARK: - Pasteboard snapshot/restore

    private func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    /// Capture the frontmost app's current selection via synthetic ⌘C with
    /// clipboard save/restore — the fallback when AX gives no selected text
    /// (PLAN.md §4.8; Electron/web apps often hide selection from AX).
    func captureSelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        let baseline = pasteboard.changeCount
        Self.postKey(0x08, flags: .maskCommand) // ⌘C

        var copied: String?
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(60))
            if pasteboard.changeCount != baseline {
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        Self.restore(saved, to: pasteboard)
        let trimmed = copied?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : copied
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(10_000)
        up.post(tap: .cghidEventTap)
    }

    /// Synthesize Return after the paste has settled ("press enter" command).
    func pressReturn(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let returnKey: CGKeyCode = 36
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
            else { return }
            down.post(tap: .cghidEventTap)
            usleep(10_000)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Synthetic ⌘V

    private static func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        guard
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        usleep(10_000)
        vUp.post(tap: .cghidEventTap)
    }
}
