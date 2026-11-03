import Charts
import SwiftUI

/// Dictation totals, speed and streaks, computed from counts kept on this Mac.
struct InsightsView: View {
    @EnvironmentObject var appState: AppState
    @State private var confirmingReset = false

    private static let chartDays = 14

    var body: some View {
        let summary = appState.usageSummary
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Insights", icon: "chart.bar.fill") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        StatTile(value: summary.totalWords.formatted(), label: "Words dictated")
                        StatTile(value: summary.wordsThisWeek.formatted(), label: "Words in the last 7 days")
                        StatTile(value: summary.wordsPerMinute > 0 ? "\(summary.wordsPerMinute) wpm" : "—", label: "Speaking speed")
                        StatTile(value: Self.durationText(summary.timeSavedSeconds), label: "Time saved vs. typing")
                        StatTile(value: Self.daysText(summary.currentStreak), label: "Current streak")
                        StatTile(value: Self.daysText(summary.longestStreak), label: "Longest streak")
                    }
                    Text("Time saved compares your speaking time with typing the same words at \(Int(UsageStatsCore.typingWordsPerMinute)) words per minute.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsCard("Last \(Self.chartDays) days", icon: "calendar") {
                    Chart(recentDays, id: \.date) { day in
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Words", day.words)
                        )
                        .foregroundStyle(Color.accentColor)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .frame(height: 160)
                }

                SettingsCard("Privacy", icon: "lock.fill") {
                    Toggle("Keep dictation stats", isOn: $appState.usageStatsEnabled)
                    HStack(alignment: .top) {
                        Text("Only daily counts of words, recording time and dictations are stored, on this Mac. No dictated text is kept for these stats.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Reset Stats…") { confirmingReset = true }
                            .disabled(appState.usageDays.isEmpty)
                    }
                }
            }
            .padding(24)
        }
        .confirmationDialog("Reset all dictation stats?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { appState.resetUsageStats() }
        } message: {
            Text("Totals and streaks start again from zero.")
        }
    }

    private var recentDays: [(date: Date, words: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<Self.chartDays).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = UsageStatsCore.dayKey(for: date, calendar: calendar)
            return (date, appState.usageDays[key]?.words ?? 0)
        }
    }

    static func daysText(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }

    static func durationText(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return seconds > 0 ? "< 1 min" : "0 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}
