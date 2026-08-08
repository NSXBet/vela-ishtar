// Tests/VelaCoreTests/CurveScrubTests.swift
// Pins the curve-hover scrubber math (v0.5.1): hovering today's curve shows a
// crosshair + dot snapped to the nearest OBSERVED hour, with an Oura-style
// readout ("2 pm · $31.40"). The view renders; the rules live here so they're
// testable: which hour the pointer means, what to do about gaps, and how the
// readout speaks. "Gaps stay gaps" is a design rule — the scrubber must never
// invent a value for an hour the gateway didn't report.
// RELEVANT FILES: Sources/VelaCore/CurveScrub.swift, Sources/App/CurveView.swift

import Foundation
import Testing
@testable import VelaCore

@Suite("CurveScrub")
struct CurveScrubTests {

    // 24-slot day with spend observed through UTC hour 14.
    private let hourly: [Double?] = (0...23).map { $0 <= 14 ? Double($0) * 2.5 : nil }

    // MARK: hour(atX:) — pointer x → lane hour

    @Test("the left edge is hour 0, the right edge hour 23")
    func laneEdges() {
        #expect(CurveScrub.hour(atX: 0, laneWidth: 284) == 0)
        #expect(CurveScrub.hour(atX: 284, laneWidth: 284) == 23)
    }

    @Test("a mid-lane pointer maps to the proportionally nearest hour")
    func midLane() {
        // Half the lane = hour 11.5 → rounds to 12 (banker's would give 12 too; pin the choice).
        #expect(CurveScrub.hour(atX: 142, laneWidth: 284) == 12)
        // x for hour 3 is 284 * 3/23 ≈ 37.04.
        #expect(CurveScrub.hour(atX: 37.0, laneWidth: 284) == 3)
    }

    @Test("a pointer outside the lane clamps to the ends, never out of range")
    func clamps() {
        #expect(CurveScrub.hour(atX: -30, laneWidth: 284) == 0)
        #expect(CurveScrub.hour(atX: 900, laneWidth: 284) == 23)
    }

    // MARK: scrubPoint(atX:hourly:laneWidth:) — snap + gaps

    @Test("the dot lands exactly on the snapped hour's x, not the raw pointer x")
    func snapsToHourX() {
        let point = CurveScrub.scrubPoint(atX: 140, hourly: hourly, laneWidth: 284)
        // 140/284 of the lane = hour 11.34 → hour 11. Its canonical x:
        // 284 * 11/23 ≈ 135.83 — the dot sits there, not on the pointer's 140.
        #expect(point?.hour == 11)
        #expect(abs((point?.x ?? 0) - 284.0 * 11.0 / 23.0) < 0.01)
        #expect(point?.value == 27.5)
    }

    @Test("a pointer past the last observed hour snaps BACK to it — never shows a gap hour")
    func snapsBackOverGaps() {
        // x for hour 20 ≈ 246.9, but hours 15-23 are nil: the honest answer is hour 14.
        let point = CurveScrub.scrubPoint(atX: 246.9, hourly: hourly, laneWidth: 284)
        #expect(point?.hour == 14)
        #expect(point?.value == 35.0)
    }

    @Test("an all-nil day scrubs to nothing — silence over a fabricated zero")
    func allNil() {
        let empty: [Double?] = Array(repeating: nil, count: 24)
        #expect(CurveScrub.scrubPoint(atX: 100, hourly: empty, laneWidth: 284) == nil)
    }

    @Test("a single observed hour answers from anywhere on the lane")
    func singleHour() {
        var day: [Double?] = Array(repeating: nil, count: 24)
        day[9] = 12.0
        #expect(CurveScrub.scrubPoint(atX: 5, hourly: day, laneWidth: 284)?.hour == 9)
        #expect(CurveScrub.scrubPoint(atX: 280, hourly: day, laneWidth: 284)?.hour == 9)
    }

    @Test("an equidistant tie answers the EARLIER hour — the most recent truth")
    func tieBreaksToEarlierHour() {
        // Only hours 10 and 14 observed; a pointer at the hour-12 midpoint is
        // equidistant from both. The earlier sample wins: on a cumulative
        // spend curve the earlier hour is the most recent thing the gateway
        // actually reported, and answering the FUTURE hour would invent
        // knowledge of a bucket that hasn't closed yet.
        var day: [Double?] = Array(repeating: nil, count: 24)
        day[10] = 40.0
        day[14] = 55.0
        let point = CurveScrub.scrubPoint(atX: CurveScrub.xPosition(forHour: 12, laneWidth: 284), hourly: day, laneWidth: 284)
        #expect(point?.hour == 10)
        #expect(point?.value == 40.0)
    }

    // MARK: xPosition(forHour:laneWidth:) — the shared x formula

    @Test("hour x is the same formula draw(_:) uses for the polyline")
    func hourX() {
        #expect(CurveScrub.xPosition(forHour: 0, laneWidth: 284) == 0)
        #expect(CurveScrub.xPosition(forHour: 23, laneWidth: 284) == 284)
        #expect(abs(CurveScrub.xPosition(forHour: 7, laneWidth: 284) - 284.0 * 7.0 / 23.0) < 0.0001)
    }

    // MARK: readoutText(utcHour:value:) — the spoken card

    @Test("the readout is local time plus dollars, separated by a middle dot")
    func readout() {
        // UTC hour 14 → 11 am at UTC-3 (São Paulo's winter offset). A fixed
        // offset zone, not a named one: the Jan-2000 reference day falls
        // inside Brazil's old DST (UTC-2), and the test pins the conversion,
        // not a country's DST history.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -3 * 3600)!
        let text = CurveScrub.readoutText(utcHour: 14, value: 31.4, calendar: calendar)
        #expect(text == "11 am · $31.40")
    }

    @Test("midnight and noon read as 12 am / 12 pm, not 0 / 24")
    func twelveHourEdgeCases() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(CurveScrub.readoutText(utcHour: 0, value: 0, calendar: calendar) == "12 am · $0.00")
        #expect(CurveScrub.readoutText(utcHour: 12, value: 5.5, calendar: calendar) == "12 pm · $5.50")
    }

    @Test("the conversion uses the offset in force at the ANCHOR date, not a hardcoded past day's DST")
    func conversionUsesAnchorDateOffset() {
        // Fixed anchor + fixed zone: no dependence on "today", and no
        // dependence on Brazil's politics. America/Sao_Paulo is UTC-3 on
        // 2026-08-08 but was UTC-2 (DST) on 2000-01-01 — so this assertion
        // fails under any implementation that anchors on 2000-01-01, and
        // passes iff the conversion honors the anchor's date. The zone's
        // PAST DST is the probe; its present/future DST policy is irrelevant.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        // 2026-08-08 12:00 UTC (a Saturday — verified, not assumed).
        let anchor = Date(timeIntervalSince1970: 1786190400)
        #expect(CurveScrub.readoutText(utcHour: 12, value: 0, calendar: calendar, anchor: anchor) == "9 am · $0.00")
    }
}
