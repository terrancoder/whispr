import Foundation
import GRDB

struct DictionaryEntry: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "dictionaryEntry"
    var id: Int64?
    var term: String
    var starred: Bool = false
    var autoLearned: Bool = false
    var usageCount: Int = 0
    var createdAt: Date = Date()
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct ReplacementRule: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "replacementRule"
    var id: Int64?
    var wrong: String
    var right: String
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct Snippet: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "snippet"
    var id: Int64?
    var trigger: String
    var expansion: String
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Personal dictionary, replacement rules, and snippets (PLAN.md §4.7 / M6).
/// Backed by the shared whispr.sqlite; all local.
final class DictionaryStore {
    static let shared = DictionaryStore()
    static let changed = Notification.Name("whispr.dictionaryChanged")
    private var db: DatabaseQueue? { HistoryStore.shared.dbQueue }
    private init() {}

    private func notify() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: - Dictionary terms

    func terms() -> [DictionaryEntry] {
        (try? db?.read {
            try DictionaryEntry
                .order(Column("starred").desc, Column("usageCount").desc, Column("term").asc)
                .fetchAll($0)
        }) ?? []
    }

    @discardableResult
    func addTerm(_ term: String, autoLearned: Bool = false) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return false }
        var entry = DictionaryEntry(id: nil, term: trimmed, autoLearned: autoLearned, createdAt: Date())
        do {
            try db?.write { try entry.insert($0) }
            notify()
            return true
        } catch { return false }
    }

    func setStarred(_ entry: DictionaryEntry, starred: Bool) {
        guard let id = entry.id else { return }
        _ = try? db?.write {
            try $0.execute(sql: "UPDATE dictionaryEntry SET starred = ? WHERE id = ?", arguments: [starred, id])
        }
        notify()
    }

    func deleteTerm(_ entry: DictionaryEntry) {
        guard let id = entry.id else { return }
        _ = try? db?.write { try DictionaryEntry.deleteOne($0, key: id) }
        notify()
    }

    /// CSV/newline-separated bulk import (Wispr supports 1,000-entry CSVs).
    func importTerms(from url: URL) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var added = 0
        for piece in content.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" }) {
            if addTerm(String(piece)) { added += 1 }
            if added >= 1000 { break }
        }
        return added
    }

    /// Prompt block terms: starred first, capped so the prompt stays small.
    func vocabularyForPrompt(limit: Int = 50) -> [String] {
        Array(terms().prefix(limit).map(\.term))
    }

    // MARK: - Replacements

    func replacements() -> [ReplacementRule] {
        (try? db?.read { try ReplacementRule.order(Column("wrong").asc).fetchAll($0) }) ?? []
    }

    func addReplacement(wrong: String, right: String) {
        let w = wrong.trimmingCharacters(in: .whitespaces)
        let r = right.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !r.isEmpty else { return }
        var rule = ReplacementRule(id: nil, wrong: w, right: r)
        _ = try? db?.write { try rule.insert($0) }
        notify()
    }

    func deleteReplacement(_ rule: ReplacementRule) {
        guard let id = rule.id else { return }
        _ = try? db?.write { try ReplacementRule.deleteOne($0, key: id) }
        notify()
    }

    // MARK: - Snippets

    func snippets() -> [Snippet] {
        (try? db?.read { try Snippet.order(Column("trigger").asc).fetchAll($0) }) ?? []
    }

    func addSnippet(trigger: String, expansion: String) {
        let t = trigger.trimmingCharacters(in: .whitespaces)
        let e = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !e.isEmpty else { return }
        var snippet = Snippet(id: nil, trigger: t, expansion: e)
        _ = try? db?.write { try snippet.insert($0) }
        notify()
    }

    func deleteSnippet(_ snippet: Snippet) {
        guard let id = snippet.id else { return }
        _ = try? db?.write { try Snippet.deleteOne($0, key: id) }
        notify()
    }

    // MARK: - Text application (deterministic layer)

    /// Applies replacement rules and snippet expansions — runs on rules-only
    /// AND LLM output, so a wrong spelling can never survive.
    func applyToText(_ input: String) -> String {
        var text = input
        for rule in replacements() {
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: rule.wrong))\\b"
            text = text.replacingOccurrences(of: pattern, with: rule.right, options: .regularExpression)
        }
        for snippet in snippets() {
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: snippet.trigger))\\b"
            text = text.replacingOccurrences(of: pattern, with: snippet.expansion, options: .regularExpression)
        }
        return text
    }
}
