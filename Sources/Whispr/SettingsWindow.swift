import AppKit
import ServiceManagement
import SwiftUI

/// Configurable push-to-talk trigger keys (bare modifiers via our event tap).
enum PttKey: String, CaseIterable, Identifiable {
    case fn
    case rightCommand
    case rightOption
    case leftControl

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fn: return "fn (Globe)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .leftControl: return "Left ⌃"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .leftControl: return 59
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .leftControl: return .maskControl
        }
    }

    static var current: PttKey {
        get { PttKey(rawValue: UserDefaults.standard.string(forKey: "whispr.pttKey") ?? "") ?? .fn }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "whispr.pttKey") }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var retention = Retention.current
    @State private var pttKey = PttKey.current
    @State private var soundsOn = Sounds.enabled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var localeOverride = UserDefaults.standard.string(forKey: "whispr.locale") ?? ""
    @State private var cleanup = CleanupLevel.current

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Push-to-talk key", selection: $pttKey) {
                    ForEach(PttKey.allCases) { key in Text(key.label).tag(key) }
                }
                .onChange(of: pttKey) { _, newValue in
                    PttKey.current = newValue
                    controller.reloadHotkeys()
                }
                if pttKey == .fn {
                    Text("Set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, or macOS will pop emoji/dictation on every press.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Language override (e.g. en-US, empty = system)", text: $localeOverride)
                    .onSubmit {
                        let trimmed = localeOverride.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            UserDefaults.standard.removeObject(forKey: "whispr.locale")
                        } else {
                            UserDefaults.standard.set(trimmed, forKey: "whispr.locale")
                        }
                    }
                LabeledContent("Engine", value: controller.engineName)
            }

            Section("AI cleanup") {
                Picker("Cleanup level", selection: $cleanup) {
                    ForEach(CleanupLevel.allCases) { level in Text(level.label).tag(level) }
                }
                .onChange(of: cleanup) { _, newValue in CleanupLevel.current = newValue }
                LabeledContent("Local AI model", value: controller.llmStatus)
                if controller.llmStatus.hasPrefix("Not installed") {
                    Text("Run `scripts/setup-llm.sh` in the repo once (downloads a ~2.3 GB local model), then restart whispr. Dictation works without it — you just get rules-only cleanup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("History") {
                Picker("Retention", selection: $retention) {
                    ForEach(Retention.allCases) { r in Text(r.label).tag(r) }
                }
                .onChange(of: retention) { _, newValue in Retention.current = newValue }
                Button("Open History…") { WindowManager.shared.showHistory() }
            }

            Section("System") {
                Toggle("Sounds", isOn: $soundsOn)
                    .onChange(of: soundsOn) { _, newValue in Sounds.enabled = newValue }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Button("Accessibility Settings…") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 380)
    }
}
