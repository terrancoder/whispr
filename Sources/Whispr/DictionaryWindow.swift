import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DictionaryView: View {
    var body: some View {
        TabView {
            VocabularyTab()
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            ReplacementsTab()
                .tabItem { Label("Replacements", systemImage: "arrow.left.arrow.right") }
            SnippetsTab()
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
        }
        .padding(8)
        .frame(minWidth: 520, minHeight: 420)
    }
}

private struct VocabularyTab: View {
    @State private var entries: [DictionaryEntry] = []
    @State private var newTerm = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Add a name or term (e.g. Sakib, GRDB, whispr)…", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Import CSV…", action: importCSV)
            }
            List {
                ForEach(entries) { entry in
                    HStack {
                        Button {
                            DictionaryStore.shared.setStarred(entry, starred: !entry.starred)
                        } label: {
                            Image(systemName: entry.starred ? "star.fill" : "star")
                                .foregroundStyle(entry.starred ? .yellow : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Star = higher priority in prompts")
                        Text(entry.term)
                        if entry.autoLearned {
                            Text("✨").help("Learned automatically from your edits")
                        }
                        Spacer()
                        Button(role: .destructive) {
                            DictionaryStore.shared.deleteTerm(entry)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Text("Terms are spelling authorities for the AI cleanup. Starred terms rank first. ✨ = auto-learned from your post-dictation edits.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: DictionaryStore.changed)) { _ in reload() }
    }

    private func add() {
        if DictionaryStore.shared.addTerm(newTerm) { newTerm = "" }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            _ = DictionaryStore.shared.importTerms(from: url)
        }
    }

    private func reload() { entries = DictionaryStore.shared.terms() }
}

private struct ReplacementsTab: View {
    @State private var rules: [ReplacementRule] = []
    @State private var wrong = ""
    @State private var right = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Wrong (e.g. Taney)", text: $wrong).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                TextField("Right (e.g. Tanay)", text: $right).textFieldStyle(.roundedBorder)
                Button("Add") {
                    DictionaryStore.shared.addReplacement(wrong: wrong, right: right)
                    wrong = ""; right = ""
                }
                .disabled(wrong.trimmingCharacters(in: .whitespaces).isEmpty
                    || right.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(rules) { rule in
                    HStack {
                        Text(rule.wrong).strikethrough().foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption)
                        Text(rule.right)
                        Spacer()
                        Button(role: .destructive) {
                            DictionaryStore.shared.deleteReplacement(rule)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Text("Applied to every dictation after AI cleanup — a wrong spelling can never survive.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: DictionaryStore.changed)) { _ in reload() }
    }

    private func reload() { rules = DictionaryStore.shared.replacements() }
}

private struct SnippetsTab: View {
    @State private var snippets: [Snippet] = []
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                VStack {
                    TextField("Spoken trigger (e.g. my address)", text: $trigger)
                        .textFieldStyle(.roundedBorder)
                    TextField("Expansion (what gets typed)", text: $expansion, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }
                Button("Add") {
                    DictionaryStore.shared.addSnippet(trigger: trigger, expansion: expansion)
                    trigger = ""; expansion = ""
                }
                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty
                    || expansion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(snippets) { snippet in
                    HStack(alignment: .top) {
                        Text("“\(snippet.trigger)”").bold()
                        Image(systemName: "arrow.right").font(.caption).padding(.top, 3)
                        Text(snippet.expansion).lineLimit(3)
                        Spacer()
                        Button(role: .destructive) {
                            DictionaryStore.shared.deleteSnippet(snippet)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Text("Say the trigger phrase inside any dictation and it's replaced inline — e.g. “send it to my address” types your full address.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: DictionaryStore.changed)) { _ in reload() }
    }

    private func reload() { snippets = DictionaryStore.shared.snippets() }
}
