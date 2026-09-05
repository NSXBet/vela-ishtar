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
        // The reading keeps its true receipt instant as a late reading
        // (B01): hour 0 of Aug 1 is 24 hours BEFORE it in receipt order,
        // so it has no honest hourly slot.
        let justAfterMidnight = ISODate.parse("2026-08-02T00:30:00Z")!
        store.record(spentToday: 160.42, limit: 400, at: justAfterMidnight, spendDate: "2026-08-01")

        // Filed under the gateway's day (Aug 1), NOT the clock's day (Aug 2).
        let day1 = store.day(spendDate: "2026-08-01")
        #expect(day1?.lateReadings?.last?.amount == 160.42)
        #expect(day1?.lateReadings?.last?.at == justAfterMidnight)
        #expect(store.day(spendDate: "2026-08-02") == nil)

        // The gateway ticks over; the next poll carries a fresh small total.
        // Each day is internally non-decreasing — no within-day decrease.
        let later = ISODate.parse("2026-08-02T01:15:00Z")!
        store.record(spentToday: 2.74, limit: 400, at: later, spendDate: "2026-08-02")
        #expect(store.day(spendDate: "2026-08-02")?.hourly[1] == 2.74)
        // Yesterday's record is untouched.
        #expect(store.day(spendDate: "2026-08-01")?.lateReadings?.last?.amount == 160.42)
    }

    // MARK: - B01 regression (§12.1 ascending post-midnight sequence)

    // The reproduced data-loss sequence: the gateway day stays Aug 1 across
    // local midnight while spend grows 120 → 160 → 165. The old store wrote
    // 165 into hour 0 (BEFORE hours 22/23 in receipt order); the load-time
    // contamination filter then saw a decrease in array order and DELETED
    // the entire day. The day must survive with last observed 165, and the
    // late value must never land in hour 0.
    @Test("§12.1: ascending post-midnight readings survive save/load with the day preserved and last observed 165")
    func b01AscendingSeamSurvivesSaveAndLoad() throws {
        let directory = Self.freshDirectory()
        var store = HistoryStore(directory: directory)
        store.record(spentToday: 120, limit: 400,
                     at: ISODate.parse("2026-08-01T22:10:00Z")!, spendDate: "2026-08-01")
        store.record(spentToday: 160, limit: 400,
                     at: ISODate.parse("2026-08-01T23:50:00Z")!, spendDate: "2026-08-01")
        store.record(spentToday: 165, limit: 400,
                     at: ISODate.parse("2026-08-02T00:30:00Z")!, spendDate: "2026-08-01")
        try store.save()

        var restored = HistoryStore(directory: directory)
        try restored.load()

        // Required: the day is preserved, with last observed 165.
        let preserved = restored.day(spendDate: "2026-08-01")
        #expect(preserved != nil)
        #expect(preserved?.hourly[22] == 120)
        #expect(preserved?.hourly[23] == 160)
        #expect(preserved?.lastObservedAmount == 165)
        // The late value is NEVER written into the day's earliest hour.
        #expect(preserved?.hourly[0] == nil)
        #expect(preserved?.lateReadings?.count == 1)
        #expect(preserved?.lateReadings?.first?.amount == 165)
        #expect(preserved?.lateReadings?.first?.at == ISODate.parse("2026-08-02T00:30:00Z")!)
        // And the day is not flagged contaminated.
        #expect(HistoryStore.isContaminated(preserved!) == false)
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

    // MARK: - Running-max monotonic guard (v0.2.1)

    @Test("a downward reading into a LATER empty slot is rejected — the guard uses the day's running max, not just the same slot")
    func recordRejectsDecreaseIntoEmptyLaterSlot() {
        var store = HistoryStore(directory: Self.freshDirectory())
        store.record(spentToday: 100.0, limit: 400, at: ISODate.parse("2026-08-01T14:10:00Z")!, spendDate: "2026-08-01")
        // Hour 15 slot is EMPTY; the per-slot guard would have written 60
        // straight in. The running-max guard rejects it: a cumulative total
        // can't drop from 100 to 60 inside one gateway day.
        store.record(spentToday: 60.0, limit: 400, at: ISODate.parse("2026-08-01T15:05:00Z")!, spendDate: "2026-08-01")
        #expect(store.day(spendDate: "2026-08-01")?.hourly[15] == nil)
        // The honest hour-14 reading is untouched.
        #expect(store.day(spendDate: "2026-08-01")?.hourly[14] == 100.0)
    }

    @Test("a decrease across the gateway seam (hour 23 high, hour 0 low) leaves hour 0 empty, not a zigzag")
    func recordRejectsCrossSeamDecreaseIntoEmptySlot() {
        var store = HistoryStore(directory: Self.freshDirectory())
        store.record(spentToday: 160.42, limit: 400, at: ISODate.parse("2026-08-01T23:50:00Z")!, spendDate: "2026-08-01")
        // The gateway's day boundary leads the local clock: a 00:30 poll on
        // the same gateway day writes into hour 0 — an empty slot. The old
        // per-slot guard accepted this and drew a right-to-left zigzag.
        store.record(spentToday: 2.74, limit: 400, at: ISODate.parse("2026-08-02T00:30:00Z")!, spendDate: "2026-08-01")
        #expect(store.day(spendDate: "2026-08-01")?.hourly[0] == nil)
        #expect(store.day(spendDate: "2026-08-01")?.hourly[23] == 160.42)
    }

    @Test("honest growth into a later empty slot is accepted — the guard never blocks a real increase")
    func recordAllowsGrowthIntoEmptyLaterSlot() {
        var store = HistoryStore(directory: Self.freshDirectory())
        store.record(spentToday: 100.0, limit: 400, at: ISODate.parse("2026-08-01T14:10:00Z")!, spendDate: "2026-08-01")
        store.record(spentToday: 120.0, limit: 400, at: ISODate.parse("2026-08-01T15:05:00Z")!, spendDate: "2026-08-01")
        #expect(store.day(spendDate: "2026-08-01")?.hourly[15] == 120.0)
    }

    // MARK: - Audit #4 closure (day continuing past local midnight)

    // Audit #4 claimed dayTotal/isContaminated break on a day that continues
    // past local midnight. The claim's mechanism is a LAGGING-seam write: a
    // poll just after local midnight whose gateway spend_date is still
    // yesterday, carrying a small value that would corrupt the day's curve.
    // The store keys by the gateway's spend_date and the running-max guard
    // rejects that downward write (proven by
    // recordRejectsCrossSeamDecreaseIntoEmptySlot). This test drives the
    // lagging seam through the public record() API and asserts the day is
    // left CLEAN: no downward slot written, honest readings intact, not
    // flagged contaminated. Expected to PASS — the pass closes #4.
    @Test("audit #4: a lagging-seam write after local midnight leaves the gateway day clean and uncontaminated")
    func audit4LaggingSeamLeavesDayClean() {
        var store = HistoryStore(directory: Self.freshDirectory())
        // Late evening on the gateway's day.
        store.record(spentToday: 120.0, limit: 400, at: ISODate.parse("2026-08-01T22:10:00Z")!, spendDate: "2026-08-01")
        store.record(spentToday: 160.42, limit: 400, at: ISODate.parse("2026-08-01T23:50:00Z")!, spendDate: "2026-08-01")
        // Local clock ticks past midnight; the gateway's spend_date is STILL
        // 2026-08-01 but its cumulative reading has momentarily reset low
        // (its new-day total hasn't caught up). This is the lagging-seam
        // downward write #4 worried about — it must be rejected.
        store.record(spentToday: 2.74, limit: 400, at: ISODate.parse("2026-08-02T00:30:00Z")!, spendDate: "2026-08-01")

        let day = store.day(spendDate: "2026-08-01")!
        // The downward seam write was rejected: hour 0 stays empty, the
        // honest evening readings are intact, and the day's curve has no
        // decrease for either dayTotal or isContaminated to trip on.
        #expect(day.hourly[0] == nil)
        #expect(day.hourly[22] == 120.0)
        #expect(day.hourly[23] == 160.42)
        #expect(day.hourly.compactMap { $0 } == [120.0, 160.42])
        #expect(HistoryStore.isContaminated(day) == false)
    }

    @Test("a downward reading below the running max but within tolerance is written through, so the slot doesn't wedge at a stale high")
    func recordWritesThroughWithinToleranceDip() {
        var store = HistoryStore(directory: Self.freshDirectory())
        store.record(spentToday: 100.0, limit: 400, at: ISODate.parse("2026-08-01T14:10:00Z")!, spendDate: "2026-08-01")
        // 99.0 is below the running max (100) but within the 1% tolerance —
        // writing it through keeps the displayed value from sticking high.
        store.record(spentToday: 99.0, limit: 400, at: ISODate.parse("2026-08-01T15:05:00Z")!, spendDate: "2026-08-01")
        #expect(store.day(spendDate: "2026-08-01")?.hourly[15] == 99.0)
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

    @Test("load persists the cleaned history so a contaminated day is gone from disk, not just from memory")
    func loadPersistsCleanedHistory() throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1 clean day + 1 contaminated day.
        var cleanHourly = Array(repeating: "null", count: 24)
        cleanHourly[14] = "42.0"
        var contaminatedHourly = Array(repeating: "null", count: 24)
        contaminatedHourly[0] = "160.42"; contaminatedHourly[1] = "160.42"
        contaminatedHourly[7] = "15.33"
        let json = """
        {"2026-08-01":{"hourly":[\(cleanHourly.joined(separator: ","))],"limit":400,"exhaustedAt":null},"2026-08-02":{"hourly":[\(contaminatedHourly.joined(separator: ","))],"limit":400,"exhaustedAt":null}}
        """
        let fileURL = directory.appendingPathComponent("history.json")
        try json.data(using: .utf8)!.write(to: fileURL)

        var store = HistoryStore(directory: directory)
        try store.load()

        // In-memory: contaminated day is gone.
        #expect(store.allDays.count == 1)
        #expect(store.allDays["2026-08-02"] == nil)

        // On-disk: the file was re-saved without the contaminated day.
        let persisted = try Data(contentsOf: fileURL)
        let persistedDict = try JSONDecoder().decode([String: DayRecord].self, from: persisted)
        #expect(persistedDict.count == 1)
        #expect(persistedDict["2026-08-02"] == nil)
    }

    // MARK: - spend_date key normalization (v0.3.0)

    // The gateway has emitted spend_date in two shapes — a bare date
    // ("2026-08-06") and a full ISO timestamp ("2026-08-07T00:00:00Z") — for
    // the SAME logical day. Keying the store by the raw string splits one day
    // across two keys, under-counting history and breaking the ghost/strip
    // windows. The canonical key is always the bare "yyyy-MM-dd".

    @Test("record normalizes a full-ISO spend_date to the bare day key")
    func recordNormalizesFullISOSpendDate() {
        var store = HistoryStore(directory: Self.freshDirectory())
        let now = ISODate.parse("2026-08-07T14:23:00Z")!
        store.record(spentToday: 12.5, limit: 50, at: now, spendDate: "2026-08-07T00:00:00Z")

        #expect(store.allDays["2026-08-07"] != nil)
        #expect(store.allDays["2026-08-07T00:00:00Z"] == nil)
    }

    @Test("a bare-date and a full-ISO spend_date for the same day merge into one record")
    func recordMergesBareAndISOKeysForOneDay() {
        var store = HistoryStore(directory: Self.freshDirectory())
        store.record(spentToday: 10, limit: 50, at: ISODate.parse("2026-08-07T09:00:00Z")!, spendDate: "2026-08-07")
        store.record(spentToday: 20, limit: 50, at: ISODate.parse("2026-08-07T15:00:00Z")!, spendDate: "2026-08-07T00:00:00Z")

        #expect(store.allDays.count == 1)
        let day = store.allDays["2026-08-07"]
        #expect(day?.hourly[9] == 10)
        #expect(day?.hourly[15] == 20)
    }

    @Test("day(spendDate:) finds a record whether asked with a bare or full-ISO key")
    func dayLookupNormalizesTheQueryKey() {
        var store = HistoryStore(directory: Self.freshDirectory())
        store.record(spentToday: 42, limit: 50, at: ISODate.parse("2026-08-07T10:00:00Z")!, spendDate: "2026-08-07")

        #expect(store.day(spendDate: "2026-08-07T00:00:00Z")?.hourly[10] == 42)
        #expect(store.day(spendDate: "2026-08-07")?.hourly[10] == 42)
    }

    @Test("load migrates full-ISO keys on disk to bare day keys, merging collisions")
    func loadMigratesISOKeysToBareDayKeys() throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // One bare-keyed day and one ISO-keyed day for the SAME logical day,
        // plus one ISO-keyed day with no bare counterpart.
        var h1 = Array(repeating: "null", count: 24); h1[9] = "10.0"
        var h2 = Array(repeating: "null", count: 24); h2[15] = "20.0"
        var h3 = Array(repeating: "null", count: 24); h3[12] = "7.0"
        let json = """
        {"2026-08-07":{"hourly":[\(h1.joined(separator: ","))],"limit":400,"exhaustedAt":null},"2026-08-07T00:00:00Z":{"hourly":[\(h2.joined(separator: ","))],"limit":400,"exhaustedAt":null},"2026-08-08T00:00:00Z":{"hourly":[\(h3.joined(separator: ","))],"limit":400,"exhaustedAt":null}}
        """
        try json.data(using: .utf8)!.write(to: directory.appendingPathComponent("history.json"))

        var store = HistoryStore(directory: directory)
        try store.load()

        // Two logical days, both bare-keyed. The 08-07 collision merged hourly.
        #expect(store.allDays["2026-08-07"]?.hourly[9] == 10)
        #expect(store.allDays["2026-08-07"]?.hourly[15] == 20)
        #expect(store.allDays["2026-08-08"]?.hourly[12] == 7)
        #expect(store.allDays["2026-08-07T00:00:00Z"] == nil)
        #expect(store.allDays["2026-08-08T00:00:00Z"] == nil)
    }

    // MARK: - exhaustedAt guard for no-limit accounts (audit #9)

    // The gateway's "no daily limit" state is `limitEnabled == false`, and it
    // comes in two shapes: a disabled limit whose configured value is still
    // nonzero, and a zero limit. Both must never stamp exhaustedAt. Gating on
    // `limitEnabled` (PaceEngine.verdict's own signal) covers both; a `limit >
    // 0` check would still stamp the disabled-but-nonzero case.

    @Test("a disabled limit with a nonzero configured value never stamps exhaustedAt")
    func recordWithDisabledLimitNeverStampsExhaustedAt() {
        var store = HistoryStore(directory: Self.freshDirectory())
        // limitEnabled false, configured value 400 still present. Spend passes
        // 400 — but the limit is OFF, so this is not exhaustion.
        store.record(spentToday: 350, limit: 400, limitEnabled: false, at: ISODate.parse("2026-08-01T09:00:00Z")!, spendDate: "2026-08-01")
        store.record(spentToday: 500, limit: 400, limitEnabled: false, at: ISODate.parse("2026-08-01T15:00:00Z")!, spendDate: "2026-08-01")
        #expect(store.day(spendDate: "2026-08-01")?.exhaustedAt == nil)
    }

    @Test("a disabled zero limit never stamps exhaustedAt, even at spent 0")
    func recordWithDisabledZeroLimitNeverStampsExhaustedAt() {
        var store = HistoryStore(directory: Self.freshDirectory())
        // The original bug shape: limit 0 + disabled. First poll has
        // spentToday 0, and 0 >= 0 — without the limitEnabled guard this
        // stamped exhaustion immediately.
        store.record(spentToday: 0, limit: 0, limitEnabled: false, at: ISODate.parse("2026-08-01T09:00:00Z")!, spendDate: "2026-08-01")
        #expect(store.day(spendDate: "2026-08-01")?.exhaustedAt == nil)
    }

    @Test("an enabled limit still stamps exhaustedAt on the first crossing (guard does not over-suppress)")
    func recordWithEnabledLimitStillStampsExhaustedAt() {
        var store = HistoryStore(directory: Self.freshDirectory())
        let crossing = ISODate.parse("2026-08-01T14:23:00Z")!
        store.record(spentToday: 40, limit: 50, limitEnabled: true, at: ISODate.parse("2026-08-01T09:00:00Z")!, spendDate: "2026-08-01")
        store.record(spentToday: 50, limit: 50, limitEnabled: true, at: crossing, spendDate: "2026-08-01")
        #expect(store.day(spendDate: "2026-08-01")?.exhaustedAt == crossing)
    }

    // MARK: - History retention prune (audit #11)

    @Test("recording more than 90 days keeps only the newest 90 after save + reload")
    func recordPrunesHistoryToNewest90Days() throws {
        let directory = Self.freshDirectory()
        var writer = HistoryStore(directory: directory)
        // 95 consecutive gateway days ending 2026-08-03, built by walking a
        // UTC calendar back day by day so month/year boundaries format right.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let lastDay = ISODate.parse("2026-08-03T14:00:00Z")!
        let days = (0..<95).map { fmt.string(from: cal.date(byAdding: .day, value: -94 + $0, to: lastDay)!) }
        #expect(days.count == 95)
        for (i, dateStr) in days.enumerated() {
            let t = ISODate.parse("\(dateStr)T14:00:00Z")!
            writer.record(spentToday: Double(10 + i), limit: 400, at: t, spendDate: dateStr)
        }
        try writer.save()

        var reader = HistoryStore(directory: directory)
        try reader.load()

        // Only the newest 90 days survive. The five oldest are gone.
        #expect(reader.allDays.count == 90)
        for dateStr in days.prefix(5) {
            #expect(reader.allDays[dateStr] == nil)
        }
        for dateStr in days.suffix(90) {
            #expect(reader.allDays[dateStr] != nil)
        }
    }
}
