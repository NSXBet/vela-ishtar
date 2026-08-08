// Sources/VelaCore/CurveScrub.swift
// The math behind the curve-hover scrubber (v0.5.1): hovering today's curve
// shows a crosshair + dot snapped to the nearest OBSERVED hour and an
// Oura-style readout ("2 pm · $31.40"). Why this lives in VelaCore: the view
// renders, but the rules — which hour the pointer means, how gaps behave, how
// the readout speaks — are specified and tested here. "Gaps stay gaps" is the
// standing design rule: the scrubber must never invent a value for an hour
// the gateway didn't report, so a pointer past the last observed hour snaps
// BACK to it rather than showing a confident nothing.
// RELEVANT FILES: Tests/VelaCoreTests/CurveScrubTests.swift, Sources/App/CurveView.swift

import Foundation

public enum CurveScrub {

    /// One scrubbed sample: the snapped hour, its canonical x on the lane
    /// (the SAME formula the polyline draws with, so the dot always sits on
    /// the line), and the observed cumulative value.
    public struct ScrubPoint: Equatable {
        public let hour: Int
        public let x: Double
        public let value: Double
    }

    /// The canonical x of a UTC hour on a lane of `laneWidth` points.
    /// This is CurveView's `x(for:)` formula — hour 23 is the right edge.
    public static func xPosition(forHour hour: Int, laneWidth: Double) -> Double {
        laneWidth * Double(hour) / 23.0
    }

    /// The lane hour a pointer at `atX` means, clamped into 0...23.
    /// Proportional position, rounded to the nearest hour.
    public static func hour(atX x: Double, laneWidth: Double) -> Int {
        let fraction = (x / laneWidth).clamped(to: 0...1)
        return Int((fraction * 23).rounded())
    }

    /// Where the scrub dot lands for a pointer at `atX`, or nil when the day
    /// has no observed hours at all. The snap is to the nearest NON-NIL hour:
    /// a gap hour never answers, so hovering beyond the data keeps the dot on
    /// the last honest sample instead of sliding into silence.
    public static func scrubPoint(atX x: Double, hourly: [Double?], laneWidth: Double) -> ScrubPoint? {
        let target = hour(atX: x, laneWidth: laneWidth)
        var best: (hour: Int, distance: Int)?
        for (hour, value) in hourly.enumerated() where value != nil {
            let distance = abs(hour - target)
            if best == nil || distance < best!.distance {
                best = (hour, distance)
            }
        }
        guard let best, let value = hourly[best.hour] else { return nil }
        return ScrubPoint(hour: best.hour, x: xPosition(forHour: best.hour, laneWidth: laneWidth), value: value)
    }

    /// The readout line: "2 pm · $31.40". The curve's x-axis is UTC (the
    /// gateway bills in UTC), but the card speaks the user's LOCAL time —
    /// the hour you'd glance at your watch for. 12-hour clock with am/pm;
    /// money is always two decimals. `anchor` is the date the UTC hour is
    /// read against — production leaves it at the default (now, because the
    /// curve shows today's spend); tests inject a fixed date so the
    /// conversion is deterministic.
    public static func readoutText(utcHour: Int, value: Double, calendar: Calendar = .current, anchor: Date = Date()) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // Anchor on the anchor's real date, not a fixed reference day: the
        // UTC→local conversion uses the DST offset in force on the anchor
        // date, and a hardcoded past date (2000-01-01) carries a stale offset
        // in zones whose DST rules changed since — e.g. America/Sao_Paulo
        // observed DST in Jan 2000 and hasn't since 2019, so the readout ran
        // an hour ahead all year.
        // timeZone: belongs INSIDE the components — DateComponents(year:month:
        // day:hour:) silently assumes the calendar's own zone, which is the
        // bug that makes "UTC hour" mean whatever zone the machine is in.
        var components = utc.dateComponents([.year, .month, .day], from: anchor)
        components.timeZone = TimeZone(identifier: "UTC")!
        components.hour = utcHour
        let date = utc.date(from: components) ?? Date(timeIntervalSince1970: Double(utcHour) * 3600)
        let localHour = calendar.component(.hour, from: date)
        let hour12 = localHour % 12 == 0 ? 12 : localHour % 12
        let meridiem = localHour < 12 ? "am" : "pm"
        // The format string carries NO literal text — only specifiers — and
        // the middle dot arrives as a %C argument. A literal "·" inside the
        // format is one byte pattern a careless re-encode can mangle, and the
        // first thing that breaks is the " · $" boundary: the card renders
        // "2 pm ·" and swallows the money.
        return String(format: "%d %@ %C $%.2f", hour12, meridiem, 0x00B7, value)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
