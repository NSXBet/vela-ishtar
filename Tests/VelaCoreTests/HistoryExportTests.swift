// Tests/VelaCoreTests/HistoryExportTests.swift
// WP-09 09.3: CSV export. Pins: header columns, invariant-dot decimals,
// absent values as EMPTY cells, RFC 4180 quoting, formula-injection
// prefix, CRLF line endings that survive spreadsheet round-trips, and
// no token/tokenID content anywhere in the output.
// RELEVANT FILES: Sources/VelaCore/HistoryExport.swift

import Testing
import Foundation
@testable import VelaCore

struct HistoryExportTests {
    static let scope = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com")

    static func observation(at time: String, amount: Double?, day: String = "2026-08-01",
                            precision: Observation.Precision = .exactReceipt) -> Observation {
        Observation(
            id: UUID(),
            scope: scope,
            gatewayDay: GatewayDay(spendDate: day)!,
            receivedAt: ISODate.parse(time)!,
            cumulativeAmount: amount ?? 0, // non-finite stands in for "absent"
            limitEnabled: true,
            limitUSD: 400,
            precision: precision
        )
    }

    @Test("header is exactly the five §9 columns")
    func header() {
        let lines = HistoryExport.csv(scope: Self.scope, day: GatewayDay(spendDate: "2026-08-01")!, observations: [])
            .split(separator: "\r\n").map(String.init)
        #expect(lines == [HistoryExport.header])
        #expect(HistoryExport.header == "billing_day,observation_time,precision,amount_usd,coverage")
    }

    @Test("rows carry day/time/precision/amount/coverage; decimals use the invariant dot")
    func decimalAndColumns() {
        let csv = HistoryExport.csv(
            scope: Self.scope,
            day: GatewayDay(spendDate: "2026-08-01")!,
            observations: [
                Self.observation(at: "2026-08-01T00:05:00Z", amount: 12.5),
                Self.observation(at: "2026-08-01T23:55:00Z", amount: 50),
            ]
        )
        let rows = csv.split(separator: "\r\n").map(String.init)
        #expect(rows.count == 3)
        let fields = rows[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[0] == "2026-08-01")
        #expect(fields[1] == "2026-08-01T00:05:00Z")
        #expect(fields[2] == "exact")
        #expect(fields[3] == "12.500000")
        #expect(!fields[3].contains(","))
        #expect(fields[4] == "complete", "day-spanning observations are a complete day")
    }

    @Test("legacy-hour precision is labeled, not passed off as exact")
    func legacyPrecision() {
        let csv = HistoryExport.csv(
            scope: Self.scope,
            day: GatewayDay(spendDate: "2026-08-01")!,
            observations: [Self.observation(at: "2026-08-01T10:00:00Z", amount: 1, precision: .legacyHour)]
        )
        #expect(csv.contains("legacy_hour"))
        #expect(csv.contains("hour_precision"))
    }

    @Test("multi-day export sorts chronologically")
    func dayOrdering() {
        let dayA = GatewayDay(spendDate: "2026-08-02")!
        let dayB = GatewayDay(spendDate: "2026-08-01")!
        let csv = HistoryExport.csv(
            scope: Self.scope,
            days: [
                (day: dayA, observations: [Self.observation(at: "2026-08-02T10:00:00Z", amount: 2, day: "2026-08-02")]),
                (day: dayB, observations: [Self.observation(at: "2026-08-01T10:00:00Z", amount: 1, day: "2026-08-01")]),
            ]
        )
        let rows = csv.split(separator: "\r\n").map(String.init)
        #expect(rows.count == 3)
        #expect(rows[1].hasPrefix("2026-08-01,"))
        #expect(rows[2].hasPrefix("2026-08-02,"))
    }

    @Test("formula-injection: leading =+-@ cells get an apostrophe prefix")
    func formulaInjection() {
        for dangerous in ["=cmd()", "+SUM(A1)", "-1+2", "@x"] {
            let escaped = HistoryExport.cell(dangerous)
            #expect(escaped.hasPrefix("'"))
            #expect(!escaped.hasPrefix("=") || escaped.hasPrefix("'="))
        }
    }

    @Test("quoting: commas, quotes, newlines are RFC 4180 safe")
    func quoting() {
        #expect(HistoryExport.cell("plain") == "plain")
        #expect(HistoryExport.cell("a,b") == "\"a,b\"")
        #expect(HistoryExport.cell("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(HistoryExport.cell("line\nbreak") == "\"line\nbreak\"")
    }

    @Test("non-finite amount exports empty, never zero")
    func absentValues() {
        let csv = HistoryExport.row(for: Self.observation(at: "2026-08-01T10:00:00Z", amount: .nan), isCompleteDay: false)
        let fields = csv.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[3] == "")
    }

    @Test("no token or token ID material can appear: scope is not a column")
    func noTokenMaterial() {
        // The export signature takes the scope only for symmetric API
        // shape — the row builder never receives it. A receipt name with
        // token-looking content is the user's own text, escaped.
        let csv = HistoryExport.csv(
            scope: Self.scope,
            day: GatewayDay(spendDate: "2026-08-01")!,
            observations: [Self.observation(at: "2026-08-01T10:00:00Z", amount: 1)]
        )
        #expect(!csv.contains("sk-"))
        #expect(!csv.contains(Self.scope.opaqueID.uuidString))
    }

    @Test("rows survive a spreadsheet-style round-trip parse")
    func roundTrip() {
        let csv = HistoryExport.csv(
            scope: Self.scope,
            day: GatewayDay(spendDate: "2026-08-01")!,
            observations: [Self.observation(at: "2026-08-01T10:00:00Z", amount: 12.5)]
        )
        // Naive RFC 4180 parser: fields per line, strip quotes.
        let lines = csv.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 3) // header + row + trailing CRLF
        let fields = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields.count == 5)
        #expect(Double(fields[3]) == 12.5)
    }

    @Test("suggested file name is day-keyed and safe")
    func fileName() {
        #expect(HistoryExport.suggestedFileName(scope: Self.scope, day: GatewayDay(spendDate: "2026-08-01")!)
            == "vela-history-2026-08-01.csv")
    }

    // MARK: - scope isolation + honest coverage (coordinator gate)

    @Test("mixed-scope input is filtered to the export scope — no cross-credential rows")
    func mixedScopeFiltered() {
        let otherScope = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com")
        let mine = Self.observation(at: "2026-08-01T10:00:00Z", amount: 10)
        var theirs = Self.observation(at: "2026-08-01T11:00:00Z", amount: 99)
        theirs = Observation(
            id: UUID(), scope: otherScope,
            gatewayDay: theirs.gatewayDay, receivedAt: theirs.receivedAt,
            cumulativeAmount: 99, limitEnabled: true, limitUSD: 400,
            precision: .exactReceipt
        )
        let csv = HistoryExport.csv(scope: Self.scope, day: GatewayDay(spendDate: "2026-08-01")!,
                                    observations: [mine, theirs])
        #expect(csv.contains("10.000000"))
        #expect(!csv.contains("99.000000"), "another scope's spend must never be exported")
    }

    @Test("an exact receipt on a PARTIAL day is partial_day, never complete")
    func exactPartialDayHonest() {
        // One observation at 09:00 does not span the billing day → partial.
        let csv = HistoryExport.csv(
            scope: Self.scope,
            days: [(day: GatewayDay(spendDate: "2026-08-01")!,
                    observations: [Self.observation(at: "2026-08-01T09:00:00Z", amount: 10)])])
        #expect(csv.contains("partial_day"), "a single morning reading is a partial day; got: \(csv)")
        #expect(!csv.contains(",complete"))
    }

    @Test("an exact receipt spanning the full billing day is complete")
    func exactCompleteDayHonest() {
        let csv = HistoryExport.csv(
            scope: Self.scope,
            days: [(day: GatewayDay(spendDate: "2026-08-01")!,
                    observations: [
                        Self.observation(at: "2026-08-01T00:05:00Z", amount: 1),
                        Self.observation(at: "2026-08-01T23:55:00Z", amount: 50),
                    ])])
        #expect(csv.contains(",complete"), "a day-spanning reading set is complete; got: \(csv)")
        #expect(!csv.contains("partial_day"))
    }

    @Test("legacy-hour rows stay hour_precision regardless of day completeness")
    func legacyStaysHourPrecision() {
        let csv = HistoryExport.csv(
            scope: Self.scope,
            days: [(day: GatewayDay(spendDate: "2026-08-01")!,
                    observations: [
                        Self.observation(at: "2026-08-01T09:00:00Z", amount: 10, precision: .legacyHour),
                        Self.observation(at: "2026-08-01T23:55:00Z", amount: 50, precision: .legacyHour),
                    ])])
        #expect(csv.contains("hour_precision"))
        #expect(!csv.contains(",complete"))
    }
}
