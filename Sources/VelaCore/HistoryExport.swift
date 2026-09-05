// Sources/VelaCore/HistoryExport.swift
// WP-09 09.3: CSV export from an explicitly selected history range.
// Why: F03's data-control promise — the user can take their own observed
// history out of the app in a form that survives spreadsheet round-trips.
// Absent values export as EMPTY cells, never zeroes (a missing reading is
// not a zero-spend fact); decimals use the invariant dot; labels get
// proper RFC 4180 quoting and a formula-injection-safe apostrophe prefix
// on cells a spreadsheet would execute.
// RELEVANT FILES: Sources/VelaCore/HistoryRepository.swift, Sources/VelaCore/Observation.swift,
// Tests/VelaCoreTests/HistoryExportTests.swift, Sources/App/HistoryWindowController.swift

import Foundation

/// Pure CSV assembly. No dialogs, no file I/O — the window controller owns
/// the user-initiated NSSavePanel; this type owns the bytes.
public enum HistoryExport {
    /// The five columns §9 WP-09 pins: billing day, observation time,
    /// precision, amount, coverage.
    public static let header = "billing_day,observation_time,precision,amount_usd,coverage"

    /// One row per observation across the selected scope/range, receipt
    /// order. Every value derives from the observation; no token or token
    /// ID can appear — the scope is not a column at all.
    public static func csv(scope: UsageScope, day: GatewayDay, observations: [Observation]) -> String {
        // Selected-scope isolation (§7.2): a row whose scope disagrees with
        // the export's scope must NEVER be written — silently exporting
        // another credential's spend would be a data-integrity breach.
        let scoped = observations.filter { $0.scope == scope }
        let complete = Self.dayComplete(day: day, observations: scoped)
        var lines = [header]
        for observation in scoped {
            lines.append(row(for: observation, isCompleteDay: complete))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Assembles a full export for several days (an explicitly selected
    /// range) in chronological day order. Mixed-scope input is filtered to
    /// the requested scope; per-day completeness comes from the retention
    /// engine's coverage computation.
    public static func csv(scope: UsageScope, days: [(day: GatewayDay, observations: [Observation])]) -> String {
        var lines = [header]
        for entry in days.sorted(by: { $0.day.key < $1.day.key }) {
            let scoped = entry.observations.filter { $0.scope == scope }
            let complete = Self.dayComplete(day: entry.day, observations: scoped)
            for observation in scoped {
                lines.append(row(for: observation, isCompleteDay: complete))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Per-day completeness via HistoryRetentionEngine.coverage — the same
    /// computation the repository uses for its coverage map.
    private static func dayComplete(day: GatewayDay, observations: [Observation]) -> Bool {
        HistoryRetentionEngine.coverage(dayKey: day.key, observations: observations).isComplete
    }

    /// A suggested, spreadsheet-safe file name for a day export.
    public static func suggestedFileName(scope: UsageScope, day: GatewayDay) -> String {
        "vela-history-\(day.key).csv"
    }

    // MARK: - Row assembly

    static func row(for observation: Observation, isCompleteDay: Bool) -> String {
        let day = cell(observation.gatewayDay.key)
        let time = cell(isoSeconds(observation.receivedAt))
        let precision = cell(observation.precision == .exactReceipt ? "exact" : "legacy_hour")
        let amount = cell(decimal(observation.cumulativeAmount))
        let coverage = cell(coverageLabel(observation, isCompleteDay: isCompleteDay))
        return [day, time, precision, amount, coverage].joined(separator: ",")
    }

    /// Invariant-dot decimal, full precision (String(format:) never applies
    /// the user's locale group separators).
    static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.6f", value)
    }

    static func isoSeconds(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The per-row coverage column: honest per-observation honesty markers.
    /// A legacy-hour reading is "hour_precision"; an exact receipt whose
    /// day the repository later marked incomplete is "partial_day"; a
    /// complete day is "complete". Absent → empty string.
    static func coverageLabel(_ observation: Observation, isCompleteDay: Bool) -> String {
        if observation.precision == .legacyHour { return "hour_precision" }
        return isCompleteDay ? "complete" : "partial_day"
    }

    /// RFC 4180 field: quote when needed; a leading =+-@ (or tab/CR) gets
    /// an apostrophe prefix so spreadsheets never execute the cell.
    static func cell(_ raw: String) -> String {
        var value = raw
        if let first = value.first, first == "=" || first == "+" || first == "-" || first == "@" || first == "\t" {
            value = "'" + value
        }
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            value = "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
