import AppKit
import AVFoundation
import SwiftUI

/// Manages the standalone History and Settings windows for our
/// NSApplication-lifecycle app.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func showHistory() {
        show(key: "history", title: "whispr — History", size: NSSize(width: 640, height: 520)) {
            AnyView(HistoryView())
        }
    }

    func showSettings(controller: AppController) {
        show(key: "settings", title: "whispr — Settings", size: NSSize(width: 480, height: 420)) {
            AnyView(SettingsView(controller: controller))
        }
    }

    private func show(key: String, title: String, size: NSSize, content: () -> AnyView) {
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: content())
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - History

struct HistoryView: View {
    @State private var items: [Dictation] = []
    @State private var search = ""
    @State private var player: AVAudioPlayer?
    @State private var playingId: Int64?

    private var filtered: [Dictation] {
        guard !search.isEmpty else { return items }
        return items.filter {
            $0.text.localizedCaseInsensitiveContains(search)
                || $0.rawText.localizedCaseInsensitiveContains(search)
                || ($0.appName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private var grouped: [(String, [Dictation])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        let groups = Dictionary(grouping: filtered) { formatter.string(from: $0.createdAt) }
        return groups.sorted { ($0.value.first?.createdAt ?? .distantPast) > ($1.value.first?.createdAt ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search history…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button("Clear All", role: .destructive) {
                    HistoryStore.shared.deleteAll()
                }
                .disabled(items.isEmpty)
            }
            .padding(12)

            if filtered.isEmpty {
                Spacer()
                Text(items.isEmpty ? "No dictations yet — hold fn and speak." : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(grouped, id: \.0) { day, records in
                        Section(day) {
                            ForEach(records) { record in
                                row(record)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.changed)) { _ in
            reload()
        }
    }

    private func row(_ record: Dictation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.text)
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Text(record.createdAt, style: .time)
                if let app = record.appName { Text(app) }
                Text(String(format: "%.0fs · %@", record.duration, record.engine))
                Spacer()
                if HistoryStore.shared.audioURL(for: record) != nil {
                    Button {
                        togglePlay(record)
                    } label: {
                        Image(systemName: playingId == record.id ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Play recording")
                }
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(record.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                Button(role: .destructive) {
                    HistoryStore.shared.delete(record)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func togglePlay(_ record: Dictation) {
        if playingId == record.id {
            player?.stop()
            player = nil
            playingId = nil
            return
        }
        guard let url = HistoryStore.shared.audioURL(for: record),
              let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        player = newPlayer
        playingId = record.id
        newPlayer.play()
        let id = record.id
        DispatchQueue.main.asyncAfter(deadline: .now() + newPlayer.duration + 0.1) {
            if playingId == id { playingId = nil; player = nil }
        }
    }

    private func reload() {
        items = HistoryStore.shared.recent()
    }
}
