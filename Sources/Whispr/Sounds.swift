import AppKit

enum Sounds {
    enum Cue {
        case start, stop, paste
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "whispr.sounds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "whispr.sounds") }
    }

    static func play(_ cue: Cue) {
        guard enabled else { return }
        let name: NSSound.Name
        switch cue {
        case .start: name = "Morse"
        case .stop: name = "Pop"
        case .paste: name = "Tink"
        }
        NSSound(named: name)?.play()
    }
}
