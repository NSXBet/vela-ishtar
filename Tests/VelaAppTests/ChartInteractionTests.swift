// Tests/VelaAppTests/ChartInteractionTests.swift
// WP-07 07.3: the chart's honesty rules at the math boundary — segmented
// observed paths with NO invented zero origin (B15), hover-state scrub
// resolution that never invents a value for an unobserved hour, and the
// "last observed" marker rule while data is stale.
// RELEVANT FILES: Sources/App/CurveView.swift, Sources/VelaCore/CurveScrub.swift,
// Sources/VelaCore/Freshness.swift, Sources/VelaCore/DayStrip.swift

import Foundation
import Testing
@testable import VelaCore

@Suite("WP-07 chart interaction")
struct ChartInteractionTests {

    // MARK: - B15: segmented observed paths

    @Test("observed runs break at gaps — no path bridges an unobserved stretch")
    func runsSegmentAtGaps() {
        let hourly: [Double?] = [nil, 5, 6, nil, nil, 9, nil]
        let runs = CurveView.observedRuns(hourly: hourly)
        #expect(runs.count == 2)
        #expect(runs[0].map(\.hour) == [1, 2] && runs[0].map(\.value) == [5.0, 6.0])
        #expect(runs[1].map(\.hour) == [5] && runs[1].map(\.value) == [9.0])
    }

    @Test("the path starts at the FIRST OBSERVED hour, never an invented $0 origin")
    func noInventedZeroOrigin() {
        // Late-start day: hours 0–9 unobserved (app opened at 10am).
        var hourly = Array<Double?>(repeating: nil, count: 24)
        hourly[10] = 20
        hourly[11] = 25
        let runs = CurveView.observedRuns(hourly: hourly)
        #expect(runs.count == 1)
        #expect(runs[0].first?.hour == 10)   // not 0 — no midnight anchor
        #expect(runs[0].first?.value == 20)  // not 0 — no invented baseline
    }

    @Test("a fully unobserved day draws nothing (no-spend is an empty lane)")
    func emptyDayDrawsNothing() {
        #expect(CurveView.observedRuns(hourly: Array(repeating: nil, count: 24)).isEmpty)
    }

    @Test("adjacent observations form ONE continuous run")
    func contiguousHoursJoin() {
        let hourly: [Double?] = [1, 2, 3, 4, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil]
        let runs = CurveView.observedRuns(hourly: hourly)
        #expect(runs.count == 1)
        #expect(runs[0].count == 4)
    }

    // MARK: - Hover resolution (hover survives data ticks; gaps stay gaps)

    @Test("scrub snaps to the nearest OBSERVED hour — a gap hour never answers")
    func scrubNeverInventsValues() {
        let hourly: [Double?] = [nil, 5, nil, nil, 9, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil]
        let lane = 284.0
        // Pointer at hour 3 (a gap): snaps to the NEAREST observed hour —
        // hour 4 (distance 1) beats hour 1 (distance 2). A gap never
        // answers with a value; the nearest honest sample does.
        let point = CurveScrub.scrubPoint(atX: CurveScrub.xPosition(forHour: 3, laneWidth: lane), hourly: hourly, laneWidth: lane)
        #expect(point?.hour == 4)
        #expect(point?.value == 9)
    }

    @Test("an all-gap day has no scrub point at all")
    func scrubOnEmptyDayIsNil() {
        #expect(CurveScrub.scrubPoint(atX: 100, hourly: Array(repeating: nil, count: 24), laneWidth: 284) == nil)
    }

    @Test("hover re-derive after a data tick keeps the pointer's logical hour")
    func scrubSurvivesDataTick() {
        let before: [Double?] = [1, 2, 3] + Array(repeating: nil, count: 21)
        let point = CurveScrub.scrubPoint(atX: CurveScrub.xPosition(forHour: 2, laneWidth: 284), hourly: before, laneWidth: 284)
        #expect(point?.hour == 2)
        // Fresh data lands under a stationary pointer: same hour, new value.
        let after: [Double?] = [1, 2, 7] + Array(repeating: nil, count: 21)
        let rederived = CurveScrub.scrubPoint(atX: point!.x, hourly: after, laneWidth: 284)
        #expect(rederived?.hour == 2)
        #expect(rederived?.value == 7)
    }

    // MARK: - 07.3: 'last observed' while stale

    @Test("stale reading keeps the last observed value; freshness says stale")
    func staleKeepsLastObserved() {
        let received = Date(timeIntervalSince1970: 1_787_000_000)
        let now = received.addingTimeInterval(Freshness.maxAgeSeconds + 60)
        let freshness = Freshness.derive(receivedAt: received, now: now)
        if case .stale(let last) = freshness {
            #expect(last == received)   // the marker: 'last observed' at receipt time
        } else {
            Issue.record("expected stale beyond the freshness window")
        }
    }

    @Test("legacy hour precision never claims an exact age")
    func legacyPrecisionConservative() {
        // A legacy reading received 14:59 sits in the 14:00 slot; the
        // conservative age must measure from slot START.
        let slot = Date(timeIntervalSince1970: 1_787_010_000) // arbitrary instant inside an hour
        let now = slot.addingTimeInterval(59 * 60)            // 59 minutes later
        let exact = Freshness.derive(receivedAt: slot, precision: .exactReceipt, now: now)
        let legacy = Freshness.derive(receivedAt: slot, precision: .legacyHour, now: now)
        // Same wall-time reading: exact may still be fresh; legacy (aged
        // from slot start) is at least the slot offset staler.
        #expect(!legacy.isFresh || exact.isFresh)
    }

    // MARK: - 07.3: persistent selected day / sparse-week legibility

    @Test("sparse week pins observed days to level 1 — a lone day cannot over-claim")
    func sparseWeekStaysLegible() {
        let days: [DayStrip.Day] = (0..<7).map { index in
            DayStrip.Day(
                key: "2026-09-0\(index + 1)",
                total: index == 2 ? 42.0 : nil,
                isToday: index == 2,
                exhausted: false
            )
        }
        #expect(DayStrip.intensities(week: days)[2] == 1)
        #expect(DayStrip.intensities(week: days).allSatisfy { $0 <= 1 })
    }

    @Test("week totals say 'last observed' — a gap day answers silence, not $0.00")
    func gapDayHoverIsSilent() {
        #expect(DayStrip.hoverText(total: nil) == nil)   // gap: silence, not $0.00
        #expect(DayStrip.hoverText(total: 42.18) == "$42.18")
    }
}
