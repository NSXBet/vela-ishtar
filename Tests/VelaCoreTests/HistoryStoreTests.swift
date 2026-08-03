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
        store.record(spentToday: 12.5, limit: 50, at: now)

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
        store.record(spentToday: 5, limit: 20, at: localTimestamp)

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

    @Test("save writes history.json, and load on a fresh instance reads it back")
    func saveThenLoadRoundTrips() throws {
        let directory = Self.freshDirectory()
        var writer = HistoryStore(directory: directory)
        let now = ISODate.parse("2026-08-01T14:23:00Z")!
        writer.record(spentToday: 12.5, limit: 50, at: now)
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
        store.record(spentToday: 1, limit: 10, at: now)
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
        store.record(spentToday: 40, limit: 50, at: underLimit)
        store.record(spentToday: 50, limit: 50, at: crossing)

        let day = store.day(utcDate: crossing)
        #expect(day?.exhaustedAt == crossing)
    }

    @Test("record does not overwrite exhaustedAt on a later poll that is still over the limit")
    func recordDoesNotOverwriteExhaustedAt() {
        var store = HistoryStore(directory: Self.freshDirectory())
        let firstCrossing = ISODate.parse("2026-08-01T14:23:00Z")!
        let laterPoll = ISODate.parse("2026-08-01T16:00:00Z")!
        store.record(spentToday: 50, limit: 50, at: firstCrossing)
        store.record(spentToday: 55, limit: 50, at: laterPoll)

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
        store.record(spentToday: 10, limit: 50, at: lateHour)
        #expect(store.day(utcDate: lateHour)?.hourly[23] == 10)
    }
}
