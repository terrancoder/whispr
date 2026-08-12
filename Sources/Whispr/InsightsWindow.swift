import SwiftUI

/// Local-only usage stats computed from history (PLAN.md M8) — WPM, streaks,
/// per-app breakdown, words cleaned. Nothing is compared to other users
/// because nothing ever leaves this Mac.
struct InsightsView: View {
    @State private var items: [Dictation] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    stat("Total words", "\(totalWords)")
                    stat("Avg WPM", avgWPM > 0 ? "\(avgWPM)" : "—")
                    stat("Day streak", "\(streak)")
                    stat("Dictations", "\(items.count)")
                    stat("AI-cleaned", "\(cleanedCount)")
                }

                if !perApp.isEmpty {
                    Text("By app").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(perApp.prefix(8), id: \.0) { app, words in
                            HStack {
                                Text(app)
                                Spacer()
                                Text("\(words) words").foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                Capsule()
                                    .fill(.tint)
                                    .frame(
                                        width: geo.size.width * CGFloat(words) / CGFloat(max(perApp.first?.1 ?? 1, 1)),
                                        height: 5)
                            }
                            .frame(height: 5)
                        }
                    }
                }

                if items.isEmpty {
                    Text("Dictate a few times and your stats will appear here.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { items = HistoryStore.shared.recent(limit: 5000) }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.changed)) { _ in
            items = HistoryStore.shared.recent(limit: 5000)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var totalWords: Int {
        items.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    private var avgWPM: Int {
        let totalMinutes = items.reduce(0.0) { $0 + $1.duration } / 60
        guard totalMinutes > 0.05 else { return 0 }
        return Int(Double(totalWords) / totalMinutes)
    }

    private var cleanedCount: Int {
        items.filter { $0.rawText != $0.text }.count
    }

    private var streak: Int {
        let calendar = Calendar.current
        let days = Set(items.map { calendar.startOfDay(for: $0.createdAt) })
        var count = 0
        var day = calendar.startOfDay(for: Date())
        while days.contains(day) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    private var perApp: [(String, Int)] {
        var counts: [String: Int] = [:]
        for item in items {
            counts[item.appName ?? "Unknown", default: 0] += item.text.split(separator: " ").count
        }
        return counts.sorted { $0.value > $1.value }
    }
}
