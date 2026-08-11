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

        let soundsItem = NSMenuItem(title: "Sounds", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundsItem.target = self
        soundsItem.state = Sounds.enabled ? .on : .off
        menu.addItem(soundsItem)

        let permsItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibility(_:)), keyEquivalent: "")
        permsItem.target = self
        menu.addItem(permsItem)

        menu.addItem(.separator())

        let hint = NSMenuItem(title: "Hold fn to dictate · Esc cancels", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

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

    @objc private func openAccessibility(_ sender: NSMenuItem) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
