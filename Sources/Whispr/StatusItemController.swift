import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let controller: AppController
    private var cancellables: Set<AnyCancellable> = []

    init(controller: AppController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        updateIcon(for: controller.state)
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updateIcon(for: state) }
            .store(in: &cancellables)

        statusItem.menu = buildMenu()
    }

    private func updateIcon(for state: DictationState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch state {
        case .idle: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .command: symbol = "wand.and.stars"
        case .handsFree: symbol = "mic.badge.plus"
        case .processing: symbol = "waveform"
        case .error: symbol = "mic.slash"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "whispr")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let enabledItem = NSMenuItem(title: "Enable Dictation", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = controller.enabled ? .on : .off
        menu.addItem(enabledItem)

        let pasteLast = NSMenuItem(title: "Paste Last Transcript", action: #selector(pasteLast(_:)), keyEquivalent: "")
        pasteLast.target = self
        menu.addItem(pasteLast)

        menu.addItem(.separator())

        let historyItem = NSMenuItem(title: "History…", action: #selector(openHistory(_:)), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let transformMenu = NSMenu()
        for (title, instruction) in Self.transforms {
            let item = NSMenuItem(title: title, action: #selector(runTransform(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = instruction
            transformMenu.addItem(item)
        }
        let transformItem = NSMenuItem(title: "Transform Selection", action: nil, keyEquivalent: "")
        transformItem.submenu = transformMenu
        menu.addItem(transformItem)

        let dictItem = NSMenuItem(title: "Dictionary…", action: #selector(openDictionary(_:)), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let soundsItem = NSMenuItem(title: "Sounds", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundsItem.target = self
        soundsItem.state = Sounds.enabled ? .on : .off
        menu.addItem(soundsItem)

        let permsItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibility(_:)), keyEquivalent: "")
        permsItem.target = self
        menu.addItem(permsItem)

        menu.addItem(.separator())

        let hint = NSMenuItem(title: "Hold fn to dictate · double-tap fn or fn+Space for hands-free", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        let engineItem = NSMenuItem(title: "Engine: …", action: nil, keyEquivalent: "")
        engineItem.isEnabled = false
        menu.addItem(engineItem)
        controller.$engineName
            .receive(on: DispatchQueue.main)
            .sink { name in engineItem.title = "Engine: \(name)" }
            .store(in: &cancellables)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit whispr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        controller.enabled.toggle()
        sender.state = controller.enabled ? .on : .off
    }

    @objc private func pasteLast(_ sender: NSMenuItem) {
        controller.pasteLastTranscript()
    }

    @objc private func toggleSounds(_ sender: NSMenuItem) {
        Sounds.enabled.toggle()
        sender.state = Sounds.enabled ? .on : .off
    }

    @objc private func openHistory(_ sender: NSMenuItem) {
        WindowManager.shared.showHistory()
    }

    private static let transforms: [(String, String)] = [
        ("Polish", "Fix grammar, spelling, and punctuation. Keep the wording and tone."),
        ("Make Concise", "Make this more concise without losing meaning."),
        ("Bullet Points", "Turn this into a clear bulleted list."),
        ("More Professional", "Rewrite this in a professional, polished tone."),
        ("More Casual", "Rewrite this in a relaxed, casual tone."),
        ("Prompt Engineer", "Rewrite this as a clear, well-structured prompt for an AI model, preserving all requirements."),
    ]

    @objc private func runTransform(_ sender: NSMenuItem) {
        guard let instruction = sender.representedObject as? String else { return }
        controller.applyTransform(instruction)
    }

    @objc private func openDictionary(_ sender: NSMenuItem) {
        WindowManager.shared.showDictionary()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        WindowManager.shared.showSettings(controller: controller)
    }

    @objc private func openAccessibility(_ sender: NSMenuItem) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
