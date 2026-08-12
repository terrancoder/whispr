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

    /// Command-mode trigger (hold, speak an instruction over selected text).
    /// nil = disabled. Default: Right ⌘.
    static var commandCurrent: PttKey? {
        get {
            switch UserDefaults.standard.string(forKey: "whispr.cmdKey") {
            case nil: return .rightCommand
            case "off": return nil
            case let raw?: return PttKey(rawValue: raw) ?? .rightCommand
            }
        }
        set { UserDefaults.standard.set(newValue?.rawValue ?? "off", forKey: "whispr.cmdKey") }
    }
}

struct SettingsView: View {
    static let languages: [(String, String)] = [
        ("English", "en-US"), ("English (UK)", "en-GB"), ("Bengali", "bn"),
        ("Hindi", "hi"), ("Urdu", "ur"), ("Arabic", "ar"),
        ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Portuguese", "pt"), ("Italian", "it"), ("Dutch", "nl"),
        ("Polish", "pl"), ("Russian", "ru"), ("Ukrainian", "uk"),
        ("Turkish", "tr"), ("Vietnamese", "vi"), ("Japanese", "ja"),
        ("Korean", "ko"), ("Chinese", "zh"),
    ]
    /// Languages outside Parakeet's 25 → routed to WhisperKit.
    static let whisperOnly: Set<String> = ["bn", "hi", "ur", "ar", "tr", "vi", "ja", "ko", "zh"]

    @ObservedObject var controller: AppController
    @State private var retention = Retention.current
    @State private var pttKey = PttKey.current
    @State private var soundsOn = Sounds.enabled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var localeOverride = UserDefaults.standard.string(forKey: "whispr.locale") ?? ""
    @State private var cleanup = CleanupLevel.current
    @State private var autoLearn = AutoLearn.enabled
    @State private var cmdKeyRaw = PttKey.commandCurrent?.rawValue ?? "off"

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
                Picker("Command mode key", selection: $cmdKeyRaw) {
                    Text("Off").tag("off")
                    ForEach(PttKey.allCases) { key in Text(key.label).tag(key.rawValue) }
                }
                .onChange(of: cmdKeyRaw) { _, newValue in
                    PttKey.commandCurrent = newValue == "off" ? nil : PttKey(rawValue: newValue)
                    controller.reloadHotkeys()
                }
                if pttKey == .fn {
                    Text("Set System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, or macOS will pop emoji/dictation on every press.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Dictation language", selection: $localeOverride) {
                    Text("System default").tag("")
                    Text("Auto-detect (Whisper)").tag("auto")
                    Divider()
                    ForEach(Self.languages, id: \.1) { name, code in
                        Text(name).tag(code)
                    }
                }
                .onChange(of: localeOverride) { _, newValue in
                    if newValue.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "whispr.locale")
                    } else {
                        UserDefaults.standard.set(newValue, forKey: "whispr.locale")
                    }
                }
                if localeOverride == "auto" || Self.whisperOnly.contains(localeOverride) {
                    Text("This language uses the Whisper engine — a ~626 MB model downloads on first use, and transcription is a bit slower than Parakeet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Engine", value: controller.engineName)
            }

            Section("AI cleanup") {
                Picker("Cleanup level", selection: $cleanup) {
                    ForEach(CleanupLevel.allCases) { level in Text(level.label).tag(level) }
                }
                .onChange(of: cleanup) { _, newValue in CleanupLevel.current = newValue }
                LabeledContent("Local AI model", value: controller.llmStatus)
                Toggle("Auto-learn dictionary from my edits (experimental)", isOn: $autoLearn)
                    .onChange(of: autoLearn) { _, newValue in AutoLearn.enabled = newValue }
                Button("Open Dictionary…") { WindowManager.shared.showDictionary() }
                if controller.llmStatus.hasPrefix("Not installed") {
                    Text("Run `scripts/setup-llm.sh` in the repo once (downloads a ~2.3 GB local model), then restart whispr. Dictation works without it — you just get rules-only cleanup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Styles (tone per app category)") {
                ForEach(AppCategory.allCases) { category in
                    Picker(category.label, selection: Binding(
                        get: { category.style },
                        set: { category.style = $0 }
                    )) {
                        ForEach(Style.allCases) { style in Text(style.label).tag(style) }
                    }
                }
                Text("Styles adjust capitalization, punctuation, and spacing only — never your words. Detected from the frontmost app when you dictate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
