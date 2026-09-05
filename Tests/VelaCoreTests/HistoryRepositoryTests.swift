// Tests/VelaCoreTests/HistoryRepositoryTests.swift
// Verifies the serial atomic persistence actor (WP-02 02.2/02.4):
// receipt-time ordering within the billing day, five-minute coalescing that
// preserves policy boundaries, per-day/retention/size bounds, revision
// ordering, surfaced errors, and deterministic failure recovery through the
// injected filesystem seam. RELEVANT FILES:
// Sources/VelaCore/HistoryRepository.swift, Sources/VelaCore/Observation.swift

import Testing
import Foundation
@testable import VelaCore

struct HistoryRepositoryTests {
    static func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaHistoryRepositoryTests-\(UUID().uuidString)")
    }

    static let scopeA = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com")
    static let scopeB = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com")

    static func makeObservation(
        scope: UsageScope = scopeA,
        day: String = "2026-08-01",
        at time: String,
        amount: Double,
        limitEnabled: Bool = true,
        limitUSD: Double = 400,
        precision: Observation.Precision = .exactReceipt
    ) -> Observation {
        Observation(
            id: UUID(),
            scope: scope,
            gatewayDay: GatewayDay(spendDate: day)!,
            receivedAt: ISODate.parse(time)!,
            cumulativeAmount: amount,
            limitEnabled: limitEnabled,
            limitUSD: limitUSD,
            precision: precision
        )
    }

    // MARK: - receipt-time ordering (02.2)

    @Test("observations for one gateway day stay in receipt order, including an after-midnight continuation")
    func receiptTimeOrderingAcrossMidnight() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        await repository.append(Self.makeObservation(at: "2026-08-01T22:10:00Z", amount: 120))
        await repository.append(Self.makeObservation(at: "2026-08-01T23:50:00Z", amount: 160))
        // The §12.1 shape: 00:30 next UTC day, same spend_date. It belongs
        // to the Aug 1 day, AFTER the 23:50 reading — never in hour 0.
        await repository.append(Self.makeObservation(at: "2026-08-02T00:30:00Z", amount: 165))

        let observations = await repository.observations(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!)
        #expect(observations.map(\.cumulativeAmount) == [120, 160, 165])
        #expect(observations.map(\.receivedAt) == [
            ISODate.parse("2026-08-01T22:10:00Z")!,
            ISODate.parse("2026-08-01T23:50:00Z")!,
            ISODate.parse("2026-08-02T00:30:00Z")!,
        ])
    }

    @Test("scopes are isolated: the same day in two scopes never contaminates each other")
    func scopeIsolation() async throws {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        // §12.2 shape: token A $100 at 12:00, token B $20 at 13:00, same day.
        await repository.append(Self.makeObservation(scope: Self.scopeA, at: "2026-08-01T12:00:00Z", amount: 100))
        await repository.append(Self.makeObservation(scope: Self.scopeB, at: "2026-08-01T13:00:00Z", amount: 20))
        try await repository.save()

        let day = GatewayDay(spendDate: "2026-08-01")!
        let a = await repository.observations(scope: Self.scopeA, day: day)
        let b = await repository.observations(scope: Self.scopeB, day: day)
        #expect(a.map(\.cumulativeAmount) == [100])
        #expect(b.map(\.cumulativeAmount) == [20])

        // And the split survives a reload.
        let restored = HistoryRepository(directory: await repository.directory)
        let status = await restored.load()
        #expect(status == .loaded)
        let a2 = await restored.observations(scope: Self.scopeA, day: day)
        let b2 = await restored.observations(scope: Self.scopeB, day: day)
        #expect(a2.map(\.cumulativeAmount) == [100])
        #expect(b2.map(\.cumulativeAmount) == [20])
    }

    // MARK: - coalescing (02.2)

    @Test("five-minute coalescing keeps only the latest ordinary observation per bucket")
    func fiveMinuteCoalescing() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        await repository.append(Self.makeObservation(at: "2026-08-01T10:00:00Z", amount: 10))
        await repository.append(Self.makeObservation(at: "2026-08-01T10:02:00Z", amount: 12))
        await repository.append(Self.makeObservation(at: "2026-08-01T10:04:59Z", amount: 14))
        await repository.append(Self.makeObservation(at: "2026-08-01T10:05:01Z", amount: 16))

        let observations = await repository.observations(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!)
        // First-of-day kept; 10:02 coalesced away by 10:04:59; new bucket kept.
        #expect(observations.map(\.cumulativeAmount) == [10, 14, 16])
        #expect(observations.map(\.receivedAt) == [
            ISODate.parse("2026-08-01T10:00:00Z")!,
            ISODate.parse("2026-08-01T10:04:59Z")!,
            ISODate.parse("2026-08-01T10:05:01Z")!,
        ])
    }

    @Test("coalescing never collapses across a policy-change boundary")
    func coalescingPreservesPolicyBoundaries() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        await repository.append(Self.makeObservation(at: "2026-08-01T10:00:00Z", amount: 10, limitUSD: 400))
        // Same bucket, but the limit changed — a boundary that must survive.
        await repository.append(Self.makeObservation(at: "2026-08-01T10:02:00Z", amount: 12, limitUSD: 500))
        await repository.append(Self.makeObservation(at: "2026-08-01T10:03:00Z", amount: 13, limitUSD: 500))
        // Limit disabled mid-bucket — another boundary.
        await repository.append(Self.makeObservation(at: "2026-08-01T10:04:00Z", amount: 14, limitEnabled: false, limitUSD: 500))

        let observations = await repository.observations(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!)
        #expect(observations.map(\.cumulativeAmount) == [10, 12, 13, 14])
        #expect(observations.map(\.limitUSD) == [400, 500, 500, 500])
        #expect(observations.map(\.limitEnabled) == [true, true, true, false])
    }

    @Test("the per-day cap drops oldest ordinary observations but keeps first, last, and policy boundaries")
    func perDayCapPreservesBoundaries() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        // 400 observations spaced 5.5 minutes apart (past the coalescing
        // bucket edge, so none merge), with a mid-day policy-change boundary
        // at index 200. Spacing overflows into the next clock day, which is
        // fine: receipt order within the declared billing day is what counts.
        let midnight = ISODate.parse("2026-08-01T00:00:00Z")!
        for i in 0..<400 {
            let at = midnight.addingTimeInterval(TimeInterval(i * 330))
            let limitUSD: Double = i == 200 ? 500 : 400
            await repository.append(Observation(
                id: UUID(), scope: Self.scopeA,
                gatewayDay: GatewayDay(spendDate: "2026-08-01")!,
                receivedAt: at, cumulativeAmount: Double(i) + 1,
                limitEnabled: true, limitUSD: limitUSD, precision: .exactReceipt
            ))
        }
        let observations = await repository.observations(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!)
        #expect(observations.count == 320)
        #expect(observations.first?.cumulativeAmount == 1)
        #expect(observations.last?.cumulativeAmount == 400)
        // Both sides of the 400→500 policy boundary survive.
        #expect(observations.contains { $0.cumulativeAmount == 200 && $0.limitUSD == 400 })
        #expect(observations.contains { $0.cumulativeAmount == 201 && $0.limitUSD == 500 })
        // Dropped observations came off the OLDEST ordinary end.
        #expect(!observations.contains { $0.cumulativeAmount == 2 })
    }

    // MARK: - retention (02.2)

    @Test("pruning keeps the newest 90 gateway days, deterministically")
    func retentionPrunesOldestDaysDeterministically() async throws {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let lastDay = ISODate.parse("2026-08-03T00:00:00Z")!
        var keys: [String] = []
        for i in 0..<95 {
            let midnight = calendar.date(byAdding: .day, value: -94 + i, to: lastDay)!
            let key = formatter.string(from: midnight)
            keys.append(key)
            await repository.append(Observation(
                id: UUID(), scope: Self.scopeA, gatewayDay: GatewayDay(spendDate: key)!,
                receivedAt: midnight.addingTimeInterval(3600), cumulativeAmount: Double(i),
                limitEnabled: true, limitUSD: 400, precision: .exactReceipt
            ))
        }
        let envelope = await repository.envelope
        let scopeDays = try #require(envelope.days[Self.scopeA.opaqueID.uuidString])
        #expect(scopeDays.count == 90)
        for key in keys.prefix(5) { #expect(scopeDays[key] == nil) }
        for key in keys.suffix(90) { #expect(scopeDays[key] != nil) }
        // Same input → same survivor set on a second run.
        let again = HistoryRepository(directory: Self.freshDirectory())
        for key in keys {
            let midnight = calendar.date(from: {
                var c = DateComponents(); c.timeZone = TimeZone(identifier: "UTC")
                c.year = Int(key.prefix(4)); c.month = Int(key.dropFirst(5).prefix(2)); c.day = Int(key.suffix(2))
                return c
            }())!
            await again.append(Observation(
                id: UUID(), scope: Self.scopeA, gatewayDay: GatewayDay(spendDate: key)!,
                receivedAt: midnight.addingTimeInterval(3600), cumulativeAmount: 1,
                limitEnabled: true, limitUSD: 400, precision: .exactReceipt
            ))
        }
        let againDays = try #require(await again.envelope.days[Self.scopeA.opaqueID.uuidString])
        #expect(Set(againDays.keys) == Set(scopeDays.keys))
    }

    @Test("the active envelope stays within the 2 MiB budget by coarsening oldest observations first")
    func envelopeSizeBudgetIsEnforced() async throws {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        // ~330K/observation worth of data: 90 days × 320 observations × ~250
        // encoded bytes ≈ 7 MB, far over the 2 MiB budget.
        let midnight = ISODate.parse("2026-08-01T00:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        for dayOffset in 0..<90 {
            let dayMidnight = calendar.date(byAdding: .day, value: -dayOffset, to: midnight)!
            let key = formatter.string(from: dayMidnight)
            for i in 0..<320 {
                await repository.append(Observation(
                    id: UUID(), scope: Self.scopeA, gatewayDay: GatewayDay(spendDate: key)!,
                    receivedAt: dayMidnight.addingTimeInterval(TimeInterval(i * 200)),
                    cumulativeAmount: Double(i) + 0.123456789,
                    limitEnabled: true, limitUSD: 400.5, precision: .exactReceipt
                ))
            }
        }
        try await repository.save()
        let data = try Data(contentsOf: URL(fileURLWithPath: await repository.directory.path)
            .appendingPathComponent("history.json"))
        #expect(data.count <= HistoryRetention.maxEnvelopeBytes)
        // The current day (newest) is never sacrificed for the budget.
        let envelope = await repository.envelope
        #expect(envelope.days[Self.scopeA.opaqueID.uuidString]?["2026-08-01"] != nil)
    }

    // MARK: - revision ordering & coalesced writes (02.4)

    @Test("two rapid saves cannot regress disk state: the second save is a no-op without a new revision")
    func rapidSavesCannotRegressDisk() async throws {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        await repository.append(Self.makeObservation(at: "2026-08-01T10:00:00Z", amount: 10))
        try await repository.save()
        try await repository.save() // no new revision → no-op
        let data = try Data(contentsOf: URL(fileURLWithPath: await repository.directory.path)
            .appendingPathComponent("history.json"))
        let onDisk = try JSONDecoder().decode(HistoryEnvelope.self, from: data)
        #expect(onDisk.revision == 1)

        await repository.append(Self.makeObservation(at: "2026-08-01T10:10:00Z", amount: 20))
        try await repository.save()
        let data2 = try Data(contentsOf: URL(fileURLWithPath: await repository.directory.path)
            .appendingPathComponent("history.json"))
        let onDisk2 = try JSONDecoder().decode(HistoryEnvelope.self, from: data2)
        #expect(onDisk2.revision == 2)
        // Revisions only move forward.
        #expect(onDisk2.revision > onDisk.revision)
    }

    @Test("several appends between saves coalesce into one on-disk write carrying the final revision")
    func coalescedWrites() async throws {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        for i in 0..<5 {
            await repository.append(Self.makeObservation(
                at: "2026-08-01T10:\(String(format: "%02d", i * 10)):00Z", amount: Double(i)))
        }
        try await repository.save()
        let envelope = await repository.envelope
        #expect(envelope.revision == 5)
        let data = try Data(contentsOf: URL(fileURLWithPath: await repository.directory.path)
            .appendingPathComponent("history.json"))
        let onDisk = try JSONDecoder().decode(HistoryEnvelope.self, from: data)
        // Five appends, one save: the file carries the final envelope.
        #expect(onDisk == envelope)
    }

    // MARK: - failure recovery via the injected seam (02.4, B13)

    @Test("a full-disk write failure surfaces an error, keeps in-memory state, leaves no orphaned temp file, and recovers")
    func fullDiskRecovery() async throws {
        let filesystem = ControllableFilesystem(base: FileManagerHistoryFilesystem())
        let directory = Self.freshDirectory()
        let repository = HistoryRepository(directory: directory, filesystem: filesystem)
        await repository.append(Self.makeObservation(at: "2026-08-01T10:00:00Z", amount: 10))

        filesystem.failWrites = true
        await #expect(throws: HistoryRepository.SaveError.self) {
            try await repository.save()
        }
        // The error is surfaced for a storage status, not swallowed (B13).
        let error = await repository.lastError
        #expect(error != nil)

        // No orphaned temp file.
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries.filter { $0.contains(".tmp-") }.isEmpty)

        // Recovery: writes work again, in-memory state intact.
        filesystem.failWrites = false
        try await repository.save()
        let data = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        let onDisk = try JSONDecoder().decode(HistoryEnvelope.self, from: data)
        #expect(onDisk.days[Self.scopeA.opaqueID.uuidString]?["2026-08-01"]?.count == 1)
    }

    @Test("a missing destination directory is created on save")
    func missingDirectoryIsCreated() async throws {
        let directory = Self.freshDirectory().appendingPathComponent("nested/deeper")
        let repository = HistoryRepository(directory: directory)
        await repository.append(Self.makeObservation(at: "2026-08-01T10:00:00Z", amount: 10))
        try await repository.save()
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
    }

    @Test("an unreadable history file is a surfaced status, not a crash or silent empty history")
    func unreadableFileIsSurfaced() async throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("history.json"))
        let filesystem = ControllableFilesystem(base: FileManagerHistoryFilesystem())
        filesystem.failReads = true

        let repository = HistoryRepository(directory: directory, filesystem: filesystem)
        let status = await repository.load()
        guard case .unreadable = status else {
            Issue.record("expected unreadable, got \(status)")
            return
        }
        let error = await repository.lastError
        #expect(error != nil)
        // The original file is retained, untouched.
        let onDisk = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        #expect(onDisk == Data("{}".utf8))
    }

    @Test("corrupt history stays recoverable: original retained, quarantine copy written, repository starts empty")
    func corruptHistoryIsRecoverable() async throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptBytes = try HistoryMigrationTests.fixtureData("corrupt.json")
        try corruptBytes.write(to: directory.appendingPathComponent("history.json"))

        let repository = HistoryRepository(directory: directory)
        let status = await repository.load()
        guard case .corruptRetained(let quarantineName) = status else {
            Issue.record("expected corruptRetained, got \(status)")
            return
        }
        // Original retained byte-for-byte.
        let retained = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        #expect(retained == corruptBytes)
        // Quarantine copy written.
        let quarantine = try #require(quarantineName)
        let copy = try Data(contentsOf: directory.appendingPathComponent(quarantine))
        #expect(copy == corruptBytes)

        // The repository still works: new observations save fine, atomically
        // replacing the corrupt file.
        await repository.append(Self.makeObservation(at: "2026-08-01T10:00:00Z", amount: 10))
        try await repository.save()
        let data = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        guard case .alreadyCurrent = HistoryMigration.plan(data) else {
            Issue.record("corrupt file was not replaced by a valid envelope")
            return
        }
    }

    @Test("load drops orphaned temp files from a crashed write")
    func loadCleansOrphanedTempFiles() async throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: directory.appendingPathComponent("history.json.tmp-abc123"))
        let repository = HistoryRepository(directory: directory)
        _ = await repository.load()
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries.filter { $0.contains(".tmp-") }.isEmpty)
    }

    // MARK: - downward corrections & coverage (02.2)

    @Test("a downward correction is stored and marked as a discontinuity, never erased or turned into negative burn")
    func downwardCorrectionIsMarked() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        await repository.append(Self.makeObservation(at: "2026-08-01T10:00:00Z", amount: 100))
        // Gateway restates the day sharply downward: a correction, stored.
        let outcome = await repository.append(Self.makeObservation(at: "2026-08-01T10:10:00Z", amount: 40))
        #expect(outcome.isDownwardCorrection == true)
        let observations = await repository.observations(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!)
        // Both readings remain, in receipt order — the day is not erased.
        #expect(observations.map(\.cumulativeAmount) == [100, 40])

        // Readings below the day's pre-correction peak keep flagging: the
        // gateway restated the day, so derived views must treat the whole
        // post-correction span as discontinuous from the old baseline until
        // spend recovers past the peak. Readings past the peak are clean.
        let stillBelow = await repository.append(Self.makeObservation(at: "2026-08-01T10:20:00Z", amount: 45))
        #expect(stillBelow.isDownwardCorrection == true)
        let recovered = await repository.append(Self.makeObservation(at: "2026-08-01T10:30:00Z", amount: 120))
        #expect(recovered.isDownwardCorrection == false)
    }

    @Test("coverage reports first/last observation instants and partial-day status honestly")
    func coverageMetadataIsHonest() async throws {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        await repository.append(Self.makeObservation(at: "2026-08-01T09:00:00Z", amount: 10))
        await repository.append(Self.makeObservation(at: "2026-08-01T17:00:00Z", amount: 50))
        let envelope = await repository.envelope
        let coverage = try #require(envelope.coverage[Self.scopeA.opaqueID.uuidString]?["2026-08-01"])
        #expect(coverage.firstObservationAt == ISODate.parse("2026-08-01T09:00:00Z")!)
        #expect(coverage.lastObservationAt == ISODate.parse("2026-08-01T17:00:00Z")!)
        // 09:00→17:00 does not span the billing day: partial, not complete.
        #expect(coverage.isComplete == false)
    }

    @Test("the recent-reading buffer is bounded to 60 minutes and 800 readings")
    func recentBufferIsBounded() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        let base = ISODate.parse("2026-08-01T10:00:00Z")!
        for i in 0..<10 {
            await repository.append(Observation(
                id: UUID(), scope: Self.scopeA,
                gatewayDay: GatewayDay(spendDate: "2026-08-01")!,
                receivedAt: base.addingTimeInterval(TimeInterval(i * 600)),
                cumulativeAmount: Double(i), limitEnabled: true, limitUSD: 400,
                precision: .exactReceipt
            ))
        }
        let recent = await repository.recentReadings
        // The last append (10:00 + 5400s) makes readings older than 60 min
        // before it fall out of the window.
        #expect(recent.allSatisfy { $0.receivedAt >= base.addingTimeInterval(5400 - 3600) })
        #expect(recent.count == 7)
    }
}

/// A filesystem seam with switchable failures, for deterministic
/// full-disk / read-only / unreadable scenarios.
final class ControllableFilesystem: HistoryFilesystem, @unchecked Sendable {
    let base: FileManagerHistoryFilesystem
    var failWrites = false
    var failReads = false
    init(base: FileManagerHistoryFilesystem) { self.base = base }

    func exists(at url: URL) -> Bool { base.exists(at: url) }
    func read(_ url: URL) throws -> Data {
        if failReads { throw CocoaError(.fileReadNoPermission) }
        return try base.read(url)
    }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func write(_ data: Data, to url: URL) throws {
        if failWrites { throw CocoaError(.fileNoSuchFile) }
        try base.write(data, to: url)
    }
    func replaceItem(at destination: URL, with source: URL) throws {
        if failWrites { throw CocoaError(.fileNoSuchFile) }
        try base.replaceItem(at: destination, with: source)
    }
    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [String] { try base.contentsOfDirectory(at: url) }
}
