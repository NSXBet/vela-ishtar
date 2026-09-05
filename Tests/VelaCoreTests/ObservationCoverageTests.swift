// Tests/VelaCoreTests/ObservationCoverageTests.swift
// Verifies ObservationCoverage's median policy (WP-04, 04.3/04.4; §7.4):
// previous 14 CALENDAR days window, >=5-day gate, same-scope only, never
// future or today, never the unassigned-legacy archive.
// RELEVANT FILES: Sources/VelaCore/ObservationCoverage.swift

import Testing
import Foundation
@testable import VelaCore

struct ObservationCoverageTests {
    let scope = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://test")

    private func obs(_ cumulative: Double, _ dayKey: String, _ time: String, scope s: UsageScope? = nil) -> Observation {
        let iso = dayKey + "T" + time + (time.hasSuffix("Z") ? "" : "Z")
        return Observation(id: UUID(), scope: s ?? scope,
                    gatewayDay: GatewayDay(spendDate: dayKey)!,
                    receivedAt: ISODate.parse(iso)!, cumulativeAmount: cumulative,
                    limitEnabled: true, limitUSD: 400, precision: .exactReceipt)
    }

    private func day(_ byDay: inout [String: [Observation]], _ key: String, _ cumulative: Double, scope s: UsageScope? = nil) {
        byDay[key] = [obs(cumulative, key, "12:30:00", scope: s)]
    }

    @Test("medianSpend honors the 14-CALENDAR-day cutoff: day 15 back contributes nothing")
    func fourteenDayCutoff() {
        // Today = 2026-08-16. In-window: 08-02..08-06 (14..10 days back).
        // 2026-08-01 is 15 calendar days back -> outside the window.
        var byDay: [String: [Observation]] = [:]
        for i in 2...6 { day(&byDay, String(format: "2026-08-%02d", i), 10) }
        // In-window median exists with exactly 5 days:
        let m = ObservationCoverage.medianSpend(
            atHourUTC: 12, observationsByDay: byDay, scope: scope,
            todayKey: "2026-08-15", now: ISODate.parse("2026-08-15T12:00:00Z")!)
        #expect(m == 10)
        // Add 4 MORE out-of-window days (07-28..07-31): still excluded —
        // the window is calendar, so they cannot pad the gate.
        for k in ["2026-07-28", "2026-07-29", "2026-07-30", "2026-07-31"] {
            day(&byDay, k, 9999)
        }
        let m2 = ObservationCoverage.medianSpend(
            atHourUTC: 12, observationsByDay: byDay, scope: scope,
            todayKey: "2026-08-15", now: ISODate.parse("2026-08-15T12:00:00Z")!)
        #expect(m2 == 10) // the 9999 outliers never entered
    }

    @Test("medianSpend never uses today or future history")
    func futureAndTodayExcluded() {
        var byDay: [String: [Observation]] = [:]
        for i in 2...6 { day(&byDay, String(format: "2026-08-%02d", i), 10) }
        // Today's in-progress reading is huge; must be excluded.
        day(&byDay, "2026-08-15", 5000)
        // A future day (clock skew) is excluded too.
        day(&byDay, "2026-08-16", 6000)
        let m = ObservationCoverage.medianSpend(
            atHourUTC: 12, observationsByDay: byDay, scope: scope,
            todayKey: "2026-08-15", now: ISODate.parse("2026-08-15T12:00:00Z")!)
        #expect(m == 10)
    }

    @Test("medianSpend is same-scope only: another credential never contributes")
    func otherScopeExcluded() {
        var byDay: [String: [Observation]] = [:]
        for i in 2...6 { day(&byDay, String(format: "2026-08-%02d", i), 10) }
        // 5 days from ANOTHER scope with huge values — must not rescue the
        // gate for our scope nor pollute the median.
        let other = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://elsewhere")
        for i in 2...6 { day(&byDay, String(format: "2026-07-%02d", 20 + i), 7777, scope: other) }
        let m = ObservationCoverage.medianSpend(
            atHourUTC: 12, observationsByDay: byDay, scope: scope,
            todayKey: "2026-08-15", now: ISODate.parse("2026-08-15T12:00:00Z")!)
        #expect(m == 10)
    }

    @Test("medianSpend never uses the unassigned-legacy archive scope")
    func legacyArchiveExcluded() {
        var byDay: [String: [Observation]] = [:]
        for i in 2...6 { day(&byDay, String(format: "2026-08-%02d", i), 10) }
        let legacy = UsageScope(
            kind: .credential,
            opaqueID: UUID(uuidString: HistoryMigration.legacyScopeID)!,
            gatewayOrigin: "legacy-unassigned")
        for k in ["2026-07-20", "2026-07-21", "2026-07-22", "2026-07-23", "2026-07-24"] {
            day(&byDay, k, 8888, scope: legacy)
        }
        let m = ObservationCoverage.medianSpend(
            atHourUTC: 12, observationsByDay: byDay, scope: scope,
            todayKey: "2026-08-15", now: ISODate.parse("2026-08-15T12:00:00Z")!)
        #expect(m == 10)
    }

    @Test("medianSpend returns nil below the 5-day gate — never a fabricated benchmark")
    func belowGateReturnsNil() {
        var byDay: [String: [Observation]] = [:]
        for i in 2...5 { day(&byDay, String(format: "2026-08-%02d", i), 10) } // 4 days
        let m = ObservationCoverage.medianSpend(
            atHourUTC: 12, observationsByDay: byDay, scope: scope,
            todayKey: "2026-08-15", now: ISODate.parse("2026-08-15T12:00:00Z")!)
        #expect(m == nil)
    }

    @Test("coverage gates: exactly 10 minutes qualifies; 5 minutes does not")
    func continuousCoverageGate() {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let day = GatewayDay(spendDate: "2026-08-01")!
        // 7 readings 100s apart = 10 min continuous coverage -> qualified.
        #expect(ObservationCoverage.paceVerdict(
            recent: qualifying(spacing: 100, count: 7, now: now),
            scope: scope, day: day, now: now
        ) == .qualified)
        // 6 readings 60s apart = 5 min coverage -> coverageTooShort.
        let verdict = ObservationCoverage.paceVerdict(
            recent: qualifying(spacing: 60, count: 6, now: now),
            scope: scope, day: day, now: now)
        guard case .insufficientEvidence(let r) = verdict else {
            Issue.record("expected insufficientEvidence, got \(verdict)")
            return
        }
        guard case .coverageTooShort = r else {
            Issue.record("expected coverageTooShort, got \(r)")
            return
        }
    }

    // MARK: helpers

    private func qualifying(spacing: TimeInterval, count: Int, now: Date) -> [Observation] {
        // Anchor the LAST reading 30s before `now` (fresh), spacing back.
        let start = now.addingTimeInterval(-30 - Double(count - 1) * spacing)
        return (0..<count).map { i in
            obs(100 + Double(i) * 10, "2026-08-01",
                timeString(start.addingTimeInterval(Double(i) * spacing)))
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")!
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date) + "Z"
    }
}
