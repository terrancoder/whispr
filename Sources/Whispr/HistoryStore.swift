import AVFoundation
import Foundation
import GRDB

/// Local-storage retention, mirroring Wispr's controls (PLAN.md §4.9).
enum Retention: String, CaseIterable, Identifiable {
    case forever
    case day      // auto-delete after 24 h
    case never    // don't store dictations at all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .forever: return "Keep history"
        case .day: return "Auto-delete after 24 hours"
        case .never: return "Never store"
        }
    }

    static var current: Retention {
        get { Retention(rawValue: UserDefaults.standard.string(forKey: "whispr.retention") ?? "") ?? .forever }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "whispr.retention") }
    }
}

struct Dictation: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "dictation"

    var id: Int64?
    var createdAt: Date
    var rawText: String
    var text: String
    var appName: String?
    var duration: Double
    var audioPath: String?
    var engine: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// SQLite-backed dictation history (GRDB). All methods are safe to call from
/// any thread; GRDB serializes access internally.
final class HistoryStore {
    static let shared = HistoryStore()
    static let changed = Notification.Name("whispr.historyChanged")

    private let dbQueue: DatabaseQueue?

    static var baseDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var audioDir: URL {
        let dir = baseDir.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "dictation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("rawText", .text).notNull()
                t.column("text", .text).notNull()
                t.column("appName", .text)
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("audioPath", .text)
                t.column("engine", .text).notNull().defaults(to: "")
            }
        }
        do {
            let queue = try DatabaseQueue(path: Self.baseDir.appendingPathComponent("whispr.sqlite").path)
            try migrator.migrate(queue)
            dbQueue = queue
        } catch {
            NSLog("whispr: history database unavailable: \(error.localizedDescription)")
            dbQueue = nil
        }
    }

    // MARK: - Writes

    /// Persists a dictation (and its audio) per the retention setting.
    func save(raw: String, text: String, appName: String?, audio: [AVAudioPCMBuffer], engine: String) {
        guard Retention.current != .never, let dbQueue else { return }
        let duration = audio.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        let audioPath = writeAudio(audio)
        var record = Dictation(
            id: nil, createdAt: Date(), rawText: raw, text: text,
            appName: appName, duration: duration, audioPath: audioPath, engine: engine
        )
        do {
            try dbQueue.write { try record.insert($0) }
            NotificationCenter.default.post(name: Self.changed, object: nil)
        } catch {
            NSLog("whispr: history save failed: \(error.localizedDescription)")
        }
    }

    private func writeAudio(_ buffers: [AVAudioPCMBuffer]) -> String? {
        guard let first = buffers.first else { return nil }
        let name = "\(UUID().uuidString).wav"
        let url = Self.audioDir.appendingPathComponent(name)
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: first.format.settings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            for buffer in buffers { try file.write(from: buffer) }
            return name
        } catch {
            return nil
        }
    }

    func delete(_ dictation: Dictation) {
        guard let dbQueue, let id = dictation.id else { return }
        if let audioPath = dictation.audioPath {
            try? FileManager.default.removeItem(at: Self.audioDir.appendingPathComponent(audioPath))
        }
        _ = try? dbQueue.write { try Dictation.deleteOne($0, key: id) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func deleteAll() {
        guard let dbQueue else { return }
        _ = try? dbQueue.write { try Dictation.deleteAll($0) }
        try? FileManager.default.removeItem(at: Self.audioDir)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: - Reads

    func recent(limit: Int = 500) -> [Dictation] {
        guard let dbQueue else { return [] }
        return (try? dbQueue.read {
            try Dictation.order(Column("createdAt").desc).limit(limit).fetchAll($0)
        }) ?? []
    }

    func audioURL(for dictation: Dictation) -> URL? {
        guard let path = dictation.audioPath else { return nil }
        let url = Self.audioDir.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Maintenance

    /// Applies retention on launch: 24 h auto-delete, plus 14-day audio cap
    /// (Wispr keeps playback audio 14 days).
    func applyRetention() {
        guard let dbQueue else { return }
        if Retention.current == .day {
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            let old = (try? dbQueue.read {
                try Dictation.filter(Column("createdAt") < cutoff).fetchAll($0)
            }) ?? []
            for record in old {
                if let path = record.audioPath {
                    try? FileManager.default.removeItem(at: Self.audioDir.appendingPathComponent(path))
                }
            }
            _ = try? dbQueue.write { try Dictation.filter(Column("createdAt") < cutoff).deleteAll($0) }
        }
        // Audio older than 14 days goes regardless of retention mode.
        let audioCutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        let stale = (try? dbQueue.read {
            try Dictation.filter(Column("createdAt") < audioCutoff && Column("audioPath") != nil).fetchAll($0)
        }) ?? []
        guard !stale.isEmpty else { return }
        for record in stale {
            if let path = record.audioPath {
                try? FileManager.default.removeItem(at: Self.audioDir.appendingPathComponent(path))
            }
        }
        _ = try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE dictation SET audioPath = NULL WHERE createdAt < ?",
                arguments: [audioCutoff]
            )
        }
    }
}
