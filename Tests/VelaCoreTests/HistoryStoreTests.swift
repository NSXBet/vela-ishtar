// Tests/VelaCoreTests/HistoryStoreTests.swift
// Verifies DayRecord round-tripping, UTC-day keying of the current hourly
// slot, atomic save/load, and the "missing file is empty history, not an
// error" contract.
// Why: this is the only persisted state in the app; a keying bug here
// would silently corrupt or lose a day's history across launches.
// RELEVANT FILES: Sources/VelaCore/HistoryStore.swift

import Testing
import Foundation
@testable import VelaCore

struct HistoryStoreTests {
    // A fresh, never-before-used subdirectory of the system temp dir, so
    // tests never touch a real user's history.json and never collide with
    // each other.
    static func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaHistoryStoreTests-\(UUID().uuidString)")
    }

    @Test("record fills the current UTC hour's slot for that UTC day")
    func recordFillsCurrentUTCHourSlot() {
        var store = HistoryStore(directory: Self.freshDirectory())
        let now = ISODate.parse("2026-08-01T14:23:00Z")!
        store.record(spentToday: 12.5, limit: 50, at: now, spendDate: "2026-08-01")

        let day = store.day(utcDate: now)
        #expect(day != nil)
        #expect(day!.limit == 50)
        #expect(day!.hourly.count == 24)
        #expect(day!.hourly[14] == 12.5)
        // Every other hour slot is untouched.
        for hour in 0..<24 where hour != 14 {
            #expect(day!.hourly[hour] == nil)
        }
        #expect(day!.exhaustedAt == nil)
    }

    @Test("a local timestamp keys by its UTC day, not the local calendar day")
    func recordKeysByUTCDayAcrossLocalMidnight() {
        var store = HistoryStore(directory: Self.freshDirectory())
        // Local (-03:00) 2026-08-01 22:30 is 2026-08-02 01:30 UTC.
        let localTimestamp = ISODate.parse("2026-08-01T22:30:00-03:00")!
        store.record(spentToday: 5, limit: 20, at: localTimestamp, spendDate: "2026-08-02")

        // Looking up by the equivalent UTC-day instant finds the record.
        let utcDay = ISODate.parse("2026-08-02T01:30:00Z")!
        let day = store.day(utcDate: utcDay)
        #expect(day != nil)
        #expect(day!.hourly[1] == 5)

        // The local-calendar day (2026-08-01) has nothing recorded.
        let wrongDay = ISODate.parse("2026-08-01T12:00:00Z")!
        #expect(store.day(utcDate: wrongDay) == nil)
    }

    @Test("day(utcDate:) returns nil for a day with no records")
    func dayReturnsNilWhenAbsent() {
        let store = HistoryStore(directory: Self.freshDirectory())
        let someDay = ISODate.parse("2026-08-01T12:00:00Z")!
        #expect(store.day(utcDate: someDay) == nil)
    }

    // MARK: - Day-boundary fix (v0.1.2 regression tests)

    @Test("a poll just after local UTC midnight with the gateway still on yesterday files under the gateway's day, so spend never decreases within a day")
    func recordKeysByGatewaySpendDateAcrossTheSeam() {
        var store = HistoryStore(directory: Self.freshDirectory())
        // The real-world bug: at 00:30 UTC on Aug 2, the gateway's
        // spend_date is still Aug 1 (its day boundary lags the clock).
        // Keying by the local date would file yesterday's total under
        // today — and the next poll (spend_date now Aug 2, spend back to
        // a small number) would make the curve DECREASE within "today".
        let justAfterMidnight = ISODate.parse("2026-08-02T00:30:00Z")!
        store.record(spentToday: 160.42, limit: 400, at: justAfterMidnight, spendDate: "2026-08-01")

        // Filed under the gateway's day (Aug 1), NOT the clock's day (Aug 2).
        #expect(store.day(spendDate: "2026-08-01")?.hourly[0] == 160.42)
        #expect(store.day(spendDate: "2026-08-02") == nil)

        // The gateway ticks over; the next poll carries a fresh small total.
        // Each day is internally non-decreasing — no within-day decrease.
        let later = ISODate.parse("2026-08-02T01:15:00Z")!
        store.record(spentToday: 2.74, limit: 400, at: later, spendDate: "2026-08-02")
        #expect(store.day(spendDate: "2026-08-02")?.hourly[1] == 2.74)
        // Yesterday's record is untouched.
        #expect(store.day(spendDate: "2026-08-01")?.hourly[0] == 160.42)
    }

    // MARK: - Monotonic guard (v0.2.0)

    @Test("record never overwrites an occupied slot with a smaller value (same-slot restatement)")
    func recordIgnoresDownwardRestatementInSameSlot() {
        var store = HistoryStore(directory: Self.freshDirectory())
        let t1 = ISODate.parse("2026-08-01T14:10:00Z")!
        let t2 = ISODate.parse("2026-08-01T14:40:00Z")!
        store.record(spentToday: 100.0, limit: 400, at: t1, spendDate: "2026-08-01")
        // Same UTC hour (14), gateway restates the reading DOWN by $30.
        // A cumulative total never decreases, so the slot must keep 100.
        store.record(spentToday: 70.0, limit: 400, at: t2, spendDate: "2026-08-01")
        #expect(store.day(spendDate: "2026-08-01")?.hourly[14] == 100.0)
    }

    @Test("record allows an upward write into an occupied slot (normal growth)")
    func recordAllowsUpwardWriteInSameSlot() {
        var store = HistoryStore(directory: Self.freshDirectory())
        let t1 = ISODate.parse("2026-08-01T14:10:00Z")!
        let t2 = ISODate.parse("2026-08-01T14:40:00Z")!
        store.record(spentToday: 100.0, limit: 400, at: t1, spendDate: "2026-08-01")
        store.record(spentToday: 131.5, limit: 400, at: t2, spendDate: "2026-08-01")
        #expect(store.day(spendDate: "2026-08-01")?.hourly[14] == 131.5)
    }

    @Test("record keeps a tiny downward restatement within tolerance from wedging the slot")
    func recordKeepsTinyRestatementWithinTolerance() {
        var store = HistoryStore(directory: Self.freshDirectory())
        let t1 = ISODate.parse("2026-08-01T14:10:00Z")!
        let t2 = ISODate.parse("2026-08-01T14:40:00Z")!
        store.record(spentToday: 100.0, limit: 400, at: t1, spendDate: "2026-08-01")
        // A $0.30 dip (0.3%, under the 1%-of-existing tolerance) is written
        // through so the slot doesn't get stuck slightly high forever.
        store.record(spentToday: 99.70, limit: 400, at: t2, spendDate: "2026-08-01")
        #expect(store.day(spendDate: "2026-08-01")?.hourly[14] == 99.70)
    }

    @Test("record still stamps exhaustedAt on the first crossing even when the slot write is guarded")
    func recordStampsExhaustedAtWithGuard() {
        var store = HistoryStore(directory: Self.freshDirectory())
        let t1 = ISODate.parse("2026-08-01T14:10:00Z")!
        store.record(spentToday: 50.0, limit: 400, at: t1, spendDate: "2026-08-01")
        // A same-hour poll that reaches the limit (upward) must still set exhaustedAt.
        let t2 = ISODate.parse("2026-08-01T14:40:00Z")!
        store.record(spentToday: 400.0, limit: 400, at: t2, spendDate: "2026-08-01")
        #expect(store.day(spendDate: "2026-08-01")?.exhaustedAt == t2)
    }

    // MARK: - Contaminated-day filter (v0.1.2)

    @Test("load drops a day whose spend decreases sharply mid-day (pre-fix contaminated data)")
    func loadDropsContaminatedDay() throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The exact shape the bug produced: hours 0-2 hold the previous
        // day's total, then the day "restarts" small at hour 7. A real
        // contaminated day has all 24 slots (record() always writes the
        // full array), so the fixture must too -- a short array is the
        // MALFORMED case (reset to 24-nil), not the contaminated case.
        var hourly = Array(repeating: "null", count: 24)
        hourly[0] = "160.42"; hourly[1] = "160.42"; hourly[2] = "160.42"
        hourly[7] = "15.33"; hourly[8] = "31.60"
        let contaminatedJSON = """
        {"2026-08-05":{"hourly":[\(hourly.joined(separator: ","))],"limit":400,"exhaustedAt":null}}
        """
        try contaminatedJSON.data(using: .utf8)!.write(to: directory.appendingPathComponent("history.json"))

        var store = HistoryStore(directory: directory)
        try store.load()
        #expect(store.day(spendDate: "2026-08-05") == nil)
    }

    @Test("load keeps an honest monotonic day")
    func loadKeepsCleanDay() throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var cleanHourly = Array(repeating: "null", count: 24)
        cleanHourly[0] = "2.74"; cleanHourly[1] = "13.01"; cleanHourly[2] = "13.01"; cleanHourly[3] = "28.40"
        let cleanJSON = """
        {"2026-08-04":{"hourly":[\(cleanHourly.joined(separator: ","))],"limit":400,"exhaustedAt":null}}
        """
        try cleanJSON.data(using: .utf8)!.write(to: directory.appendingPathComponent("history.json"))

        var store = HistoryStore(directory: directory)
        try store.load()
        #expect(store.day(spendDate: "2026-08-04")?.hourly[3] == 28.40)
    }

    @Test("load keeps a day whose tiny mid-day dip is within the restatement tolerance")
    func loadKeepsHonestRestatement() throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Peak 100, then a 0.30 dip (0.3% — under the 1%-of-peak tolerance):
        // the gateway restated a reading downward by a few cents.
        var restatedHourly = Array(repeating: "null", count: 24)
        restatedHourly[0] = "50.0"; restatedHourly[1] = "100.0"; restatedHourly[2] = "99.70"; restatedHourly[3] = "120.0"
        let restatedJSON = """
        {"2026-08-03":{"hourly":[\(restatedHourly.joined(separator: ","))],"limit":400,"exhaustedAt":null}}
        """
        try restatedJSON.data(using: .utf8)!.write(to: directory.appendingPathComponent("history.json"))

        var store = HistoryStore(directory: directory)
        try store.load()
        #expect(store.day(spendDate: "2026-08-03") != nil)
    }

    @Test("save writes history.json, and load on a fresh instance reads it back")
    func saveThenLoadRoundTrips() throws {
        let directory = Self.freshDirectory()
        var writer = HistoryStore(directory: directory)
        let now = ISODate.parse("2026-08-01T14:23:00Z")!
        writer.record(spentToday: 12.5, limit: 50, at: now, spendDate: "2026-08-01")
        try writer.save()

        var reader = HistoryStore(directory: directory)
        try reader.load()
        let day = reader.day(utcDate: now)
        #expect(day != nil)
        #expect(day!.hourly[14] == 12.5)
        #expect(day!.limit == 50)
    }

    @Test("load on a directory with no history.json yet leaves an empty history, and does not throw")
    func loadOnEmptyDirectoryDoesNotThrow() throws {
        var store = HistoryStore(directory: Self.freshDirectory())
        try store.load()
        let someDay = ISODate.parse("2026-08-01T12:00:00Z")!
        #expect(store.day(utcDate: someDay) == nil)
    }

    @Test("save creates the directory if it does not already exist")
    func saveCreatesMissingDirectory() throws {
        let directory = Self.freshDirectory()
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        var store = HistoryStore(directory: directory)
        let now = ISODate.parse("2026-08-01T14:23:00Z")!
        store.record(spentToday: 1, limit: 10, at: now, spendDate: "2026-08-01")
        try store.save()

        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
    }

    @Test("DayRecord round-trips through Codable")
    func dayRecordCodableRoundTrip() throws {
        let exhaustedAt = ISODate.parse("2026-08-01T18:40:00Z")!
        var hourly: [Double?] = Array(repeating: nil, count: 24)
        hourly[9] = 3.5
        let original = DayRecord(hourly: hourly, limit: 50, exhaustedAt: exhaustedAt)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DayRecord.self, from: data)
        #expect(decoded == original)
    }

    @Test("record sets exhaustedAt to the instant spend first reaches the limit")
    func recordSetsExhaustedAtOnFirstCrossing() {
        var store = HistoryStore(directory: Self.freshDirectory())
        let underLimit = ISODate.parse("2026-08-01T09:00:00Z")!
        let crossing = ISODate.parse("2026-08-01T14:23:00Z")!
        store.record(spentToday: 40, limit: 50, at: underLimit, spendDate: "2026-08-01")
        store.record(spentToday: 50, limit: 50, at: crossing, spendDate: "2026-08-01")

        let day = store.day(utcDate: crossing)
        #expect(day?.exhaustedAt == crossing)
    }

    @Test("record does not overwrite exhaustedAt on a later poll that is still over the limit")
    func recordDoesNotOverwriteExhaustedAt() {
        var store = HistoryStore(directory: Self.freshDirectory())
        let firstCrossing = ISODate.parse("2026-08-01T14:23:00Z")!
        let laterPoll = ISODate.parse("2026-08-01T16:00:00Z")!
        store.record(spentToday: 50, limit: 50, at: firstCrossing, spendDate: "2026-08-01")
        store.record(spentToday: 55, limit: 50, at: laterPoll, spendDate: "2026-08-01")

        let day = store.day(utcDate: laterPoll)
        #expect(day?.exhaustedAt == firstCrossing)
    }

    @Test("load normalizes a hand-edited day record whose hourly array is not 24 slots, so a later record() does not crash")
    func loadNormalizesMalformedHourlyArray() throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Hand-craft a history.json with a day record that only has 3 hourly
        // slots -- e.g. from manual editing or a corrupted write. Without
        // normalization, record() would index this array by UTC hour
        // (0...23) and crash with an out-of-bounds write.
        let malformedJSON = """
        {"2026-08-01":{"hourly":[1.0,2.0,3.0],"limit":50,"exhaustedAt":null}}
        """
        try malformedJSON.data(using: .utf8)!.write(to: directory.appendingPathComponent("history.json"))

        var store = HistoryStore(directory: directory)
        try store.load()

        // The malformed day was reset to a fresh 24-nil-slot array, so its
        // old readings are gone but the shape is safe to index into.
        let malformedDay = ISODate.parse("2026-08-01T12:00:00Z")!
        #expect(store.day(utcDate: malformedDay)?.hourly.count == 24)

        // Recording at hour 23 (out of range for the original 3-slot array)
        // must not crash.
        let lateHour = ISODate.parse("2026-08-01T23:00:00Z")!
        store.record(spentToday: 10, limit: 50, at: lateHour, spendDate: "2026-08-01")
        #expect(store.day(utcDate: lateHour)?.hourly[23] == 10)
    }

    // MARK: - allDays accessor (v0.2.0)

    @Test("allDays exposes the post-filter dict for PaceEngine's median benchmark")
    func allDaysExposesFilteredDict() throws {
        let directory = Self.freshDirectory()
        var store = HistoryStore(directory: directory)

        // Record 5 clean past days + today.
        let pastDates = ["2026-08-01", "2026-08-02", "2026-08-03", "2026-08-04", "2026-08-05"]
        for (i, dateStr) in pastDates.enumerated() {
            let t = ISODate.parse("\(dateStr)T14:00:00Z")!
            store.record(spentToday: Double(10 + i * 10), limit: 400, at: t, spendDate: dateStr)
        }
        // Today (in-progress).
        let today = ISODate.parse("2026-08-06T14:00:00Z")!
        store.record(spentToday: 999, limit: 400, at: today, spendDate: "2026-08-06")
        try store.save()

        // Load into a fresh instance — allDays must include all 6 days.
        var reader = HistoryStore(directory: directory)
        try reader.load()
        #expect(reader.allDays.count == 6)

        // Median at hour 14 excluding today: [10, 20, 30, 40, 50] → 30.
        let median = PaceEngine.medianSpend(atHourUTC: 14, in: reader.allDays, excluding: "2026-08-06")
        #expect(median == 30)
    }

    @Test("a contaminated past day is dropped by load and absent from allDays, so it can never feed the median")
    func allDaysOmitsContaminatedDays() throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Write 4 clean days + 1 contaminated day (decreasing series) as
        // a single JSON fixture — avoids JSONSerialization round-trip issues.
        let cleanDays = (0..<4).map { i -> String in
            let dateStr = "2026-08-0\(i + 1)"
            let value = 10.0 + Double(i) * 10.0
            var h = Array(repeating: "null", count: 24)
            h[14] = "\(value)"
            return """
            "\(dateStr)":{"hourly":[\(h.joined(separator: ","))],"limit":400,"exhaustedAt":null}
            """
        }
        var contaminatedHourly = Array(repeating: "null", count: 24)
        contaminatedHourly[0] = "160.42"; contaminatedHourly[1] = "160.42"; contaminatedHourly[2] = "160.42"
        contaminatedHourly[7] = "15.33"; contaminatedHourly[8] = "31.60"
        let contaminated = """
        "2026-08-05":{"hourly":[\(contaminatedHourly.joined(separator: ","))],"limit":400,"exhaustedAt":null}
        """
        let json = "{" + (cleanDays + [contaminated]).joined(separator: ",") + "}"
        try json.data(using: .utf8)!.write(to: directory.appendingPathComponent("history.json"))

        var reader = HistoryStore(directory: directory)
        try reader.load()

        // Contaminated day dropped: only 4 clean days remain.
        #expect(reader.allDays.count == 4)
        #expect(reader.allDays["2026-08-05"] == nil)

        // 4 days < 5-day gate → median is nil.
        #expect(PaceEngine.medianSpend(atHourUTC: 14, in: reader.allDays, excluding: "2026-08-06") == nil)
    }
}
