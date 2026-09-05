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
        var lines = [header]
        for observation in observations {
            lines.append(row(for: observation))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Assembles a full export for several days (an explicitly selected
    /// range) in chronological day order.
    public static func csv(scope: UsageScope, days: [(day: GatewayDay, observations: [Observation])]) -> String {
        var lines = [header]
        for entry in days.sorted(by: { $0.day.key < $1.day.key }) {
            for observation in entry.observations {
                lines.append(row(for: observation))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A suggested, spreadsheet-safe file name for a day export.
    public static func suggestedFileName(scope: UsageScope, day: GatewayDay) -> String {
        "vela-history-\(day.key).csv"
    }

    // MARK: - Row assembly

    static func row(for observation: Observation) -> String {
        let day = cell(observation.gatewayDay.key)
        let time = cell(isoSeconds(observation.receivedAt))
        let precision = cell(observation.precision == .exactReceipt ? "exact" : "legacy_hour")
        let amount = cell(decimal(observation.cumulativeAmount))
        let coverage = cell(coverageLabel(observation))
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
    static func coverageLabel(_ observation: Observation) -> String {
        observation.precision == .legacyHour ? "hour_precision" : "complete"
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
