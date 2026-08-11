import AVFoundation
import ApplicationServices

enum Permissions {
    /// Prompts the system Accessibility dialog (deep-links to the Settings
    /// pane) if the app isn't trusted yet. The event tap needs this.
    static func promptForAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
