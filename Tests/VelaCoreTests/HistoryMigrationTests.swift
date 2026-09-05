// Tests/VelaCoreTests/HistoryMigrationTests.swift
// Verifies the loss-preserving schema-1 → schema-2 migration (WP-02 02.3):
// every fixture shape in Tests/Fixtures/history/ — valid legacy files,
// corrupt JSON, malformed arrays, duplicate keys, ISO-vs-bare day keys —
// migrates without irreversible loss: good days become legacyHour
// observations under the unassigned legacy scope, questionable records are
// quarantined with a reason, and the original bytes are backed up verbatim.
// RELEVANT FILES: Sources/VelaCore/HistoryMigration.swift,
// Sources/VelaCore/HistoryRepository.swift, Tests/Fixtures/history/

import Testing
import Foundation
@testable import VelaCore

struct HistoryMigrationTests {
    /// Absolute path of a Tests/Fixtures/history/ fixture, derived from this
    /// file's location so it works from any checkout/worktree. (Package.swift
    /// is a wave-1 hot spot, so fixtures load by path, not Bundle.module.)
    static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VelaCoreTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/history/\(name)")
    }

    static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    static func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaHistoryMigrationTests-\(UUID().uuidString)")
    }

    private var legacyScopeID: String { HistoryMigration.legacyScopeID }

    // MARK: - valid schema-1 migration

    @Test("a valid schema-1 fixture migrates to observations with legacyHour precision and slot-start receipt times")
    func validFixtureMigratesToLegacyHourObservations() throws {
        let plan = HistoryMigration.plan(try Self.fixtureData("valid-schema1.json"))
        guard case .migrateLegacy(let envelope, let quarantined) = plan else {
            Issue.record("expected migrateLegacy, got \(plan)")
            return
        }
        #expect(quarantined.isEmpty)
        #expect(envelope.version == 2)
        #expect(envelope.revision == 1)

        let days = envelope.days[legacyScopeID]
        #expect(days?.count == 2)

        // 2026-08-01: three observations at hours 9 (10.0), 22 (120), 23 (160.42).
        let day1 = try #require(days?["2026-08-01"])
        #expect(day1.count == 3)
        #expect(day1.map(\.cumulativeAmount) == [10.0, 120.0, 160.42])
        #expect(day1.allSatisfy { $0.precision == .legacyHour })
        // receivedAt is the UTC START of the slot hour — the only honest
        // timestamp a legacy slot carries. No exact receipt is fabricated.
        #expect(day1[0].receivedAt == ISODate.parse("2026-08-01T09:00:00Z")!)
        #expect(day1[1].receivedAt == ISODate.parse("2026-08-01T22:00:00Z")!)
        #expect(day1[2].receivedAt == ISODate.parse("2026-08-01T23:00:00Z")!)
        // Legacy limit/policy context is preserved per observation.
        #expect(day1.allSatisfy { $0.limitEnabled && $0.limitUSD == 400 })
        // Scope is the reserved unassigned legacy identity.
        #expect(day1.allSatisfy { $0.scope.opaqueID.uuidString == self.legacyScopeID })
        #expect(day1.allSatisfy { $0.scope.gatewayOrigin == "legacy-unassigned" })
        // Day labels survive as GatewayDay values.
        #expect(day1.allSatisfy { $0.gatewayDay.key == "2026-08-01" })

        // Coverage metadata is honest about the partial day.
        let coverage1 = try #require(envelope.coverage[legacyScopeID]?["2026-08-01"])
        #expect(coverage1.firstObservationAt == ISODate.parse("2026-08-01T09:00:00Z")!)
        #expect(coverage1.lastObservationAt == ISODate.parse("2026-08-01T23:00:00Z")!)
        #expect(coverage1.isComplete == false)
    }

    @Test("migrated observation IDs are deterministic, so re-running the migration is byte-identical")
    func migrationIsDeterministic() throws {
        let raw = try Self.fixtureData("valid-schema1.json")
        guard case .migrateLegacy(let first, _) = HistoryMigration.plan(raw),
              case .migrateLegacy(let second, _) = HistoryMigration.plan(raw) else {
            Issue.record("expected migrateLegacy on both runs")
            return
        }
        #expect(first == second)
        #expect(first.days == second.days)
    }

    @Test("bare and ISO keys for the same logical day merge into one migrated day")
    func isoAndBareKeysMerge() throws {
        let plan = HistoryMigration.plan(try Self.fixtureData("legacy-bare-keys.json"))
        guard case .migrateLegacy(let envelope, let quarantined) = plan else {
            Issue.record("expected migrateLegacy, got \(plan)")
            return
        }
        #expect(quarantined.isEmpty)
        let days = try #require(envelope.days[legacyScopeID])
        // "2026-07-02T00:00:00Z" normalized onto "2026-07-02".
        #expect(days["2026-07-02T00:00:00Z"] == nil)
        #expect(days["2026-07-02"]?.map(\.cumulativeAmount) == [6.0])
        #expect(days["2026-07-01"]?.count == 2)
        #expect(days["2026-07-03"]?.count == 1)
    }

    // MARK: - uncertain data is quarantined, not deleted

    @Test("malformed hourly arrays are quarantined with a reason while clean days still migrate")
    func malformedArraysAreQuarantined() throws {
        let plan = HistoryMigration.plan(try Self.fixtureData("malformed-array.json"))
        guard case .migrateLegacy(let envelope, let quarantined) = plan else {
            Issue.record("expected migrateLegacy, got \(plan)")
            return
        }
        let days = try #require(envelope.days[legacyScopeID])
        // The clean day migrates; both malformed days are quarantined.
        #expect(days["2026-08-03"]?.map(\.cumulativeAmount) == [120.0])
        #expect(days["2026-08-01"] == nil)
        #expect(days["2026-08-02"] == nil)
        let reasons = quarantined.map(\.reason)
        #expect(reasons.contains(.malformedArray))
        #expect(reasons.contains(.undecodable))
        // Quarantine preserves the day's payload for recovery (payloads are
        // re-serialized JSON: 1.0 encodes as "1").
        let malformed = try #require(quarantined.first { $0.originalKey == "2026-08-01" })
        #expect(malformed.payload.contains("[1,2,3]"))
    }

    @Test("duplicate day keys are quarantined instead of silently last-wins merged")
    func duplicateKeysAreQuarantined() throws {
        let plan = HistoryMigration.plan(try Self.fixtureData("duplicate-keys.json"))
        guard case .migrateLegacy(let envelope, let quarantined) = plan else {
            Issue.record("expected migrateLegacy, got \(plan)")
            return
        }
        let days = try #require(envelope.days[legacyScopeID])
        // The duplicated day is excluded; the unique day migrates.
        #expect(days["2026-08-01"] == nil)
        #expect(days["2026-08-02"]?.map(\.cumulativeAmount) == [5.0])
        #expect(quarantined.contains { $0.originalKey == "2026-08-01" && $0.reason == .duplicateKey })
    }

    @Test("corrupt JSON is reported, never partially parsed")
    func corruptJSONIsReported() throws {
        let plan = HistoryMigration.plan(try Self.fixtureData("corrupt.json"))
        guard case .corrupt = plan else {
            Issue.record("expected corrupt, got \(plan)")
            return
        }
    }

    @Test("a day whose readings decrease mid-day is quarantined as contaminated, not migrated into derived views")
    func contaminatedDayIsQuarantined() {
        var hourly = Array(repeating: "null", count: 24)
        hourly[0] = "160.42"; hourly[1] = "160.42"; hourly[2] = "160.42"
        hourly[7] = "15.33"; hourly[8] = "31.60"
        let json = """
        {"2026-08-05":{"hourly":[\(hourly.joined(separator: ","))],"limit":400,"exhaustedAt":null}}
        """
        let plan = HistoryMigration.plan(Data(json.utf8))
        guard case .migrateLegacy(let envelope, let quarantined) = plan else {
            Issue.record("expected migrateLegacy, got \(plan)")
            return
        }
        #expect(envelope.days[legacyScopeID]?["2026-08-05"] == nil)
        #expect(quarantined.contains { $0.originalKey == "2026-08-05" && $0.reason == .contaminated })
    }

    @Test("an unusable day label is quarantined as invalidDayKey")
    func invalidDayKeyIsQuarantined() {
        var hourly = Array(repeating: "null", count: 24)
        hourly[5] = "12.0"
        let json = """
        {"not-a-date":{"hourly":[\(hourly.joined(separator: ","))],"limit":400,"exhaustedAt":null}}
        """
        let plan = HistoryMigration.plan(Data(json.utf8))
        guard case .migrateLegacy(let envelope, let quarantined) = plan else {
            Issue.record("expected migrateLegacy, got \(plan)")
            return
        }
        #expect(envelope.days[legacyScopeID]?["not-a-date"] == nil)
        #expect(quarantined.contains { $0.originalKey == "not-a-date" && $0.reason == .invalidDayKey })
    }

    // MARK: - schema-2 passthrough and idempotency

    @Test("a schema-2 envelope loads as-is without migration")
    func schema2LoadsAsIs() throws {
        let observation = Observation(
            id: UUID(),
            scope: UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com"),
            gatewayDay: GatewayDay(spendDate: "2026-08-01")!,
            receivedAt: ISODate.parse("2026-08-01T12:00:00Z")!,
            cumulativeAmount: 42,
            limitEnabled: true,
            limitUSD: 400,
            precision: .exactReceipt
        )
        let envelope = HistoryEnvelope(
            revision: 7,
            days: [observation.scope.opaqueID.uuidString: ["2026-08-01": [observation]]],
            coverage: [:]
        )
        let data = try envelope.encodedForPersistence(using: JSONEncoder())
        let plan = HistoryMigration.plan(data)
        guard case .alreadyCurrent(let loaded) = plan else {
            Issue.record("expected alreadyCurrent, got \(plan)")
            return
        }
        #expect(loaded == envelope)
        // Round-trip keeps the observation's identity and precision intact.
        let restored = try #require(loaded.days[observation.scope.opaqueID.uuidString]?["2026-08-01"]?.first)
        #expect(restored == observation)
    }

    @Test("a file claiming schema 2 that does not decode as an envelope is corrupt, not silently migrated")
    func falseSchema2IsCorrupt() {
        let plan = HistoryMigration.plan(Data("{\"version\":2,\"garbage\":true}".utf8))
        guard case .corrupt = plan else {
            Issue.record("expected corrupt, got \(plan)")
            return
        }
    }

    // MARK: - byte-preserving backup (via the repository, the real caller)

    @Test("migration keeps a byte-preserving backup of the version-1 fixture, recoverable unchanged")
    func migrationBackupIsBytePreserving() async throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureBytes = try Self.fixtureData("valid-schema1.json")
        try fixtureBytes.write(to: directory.appendingPathComponent("history.json"))

        let repository = HistoryRepository(directory: directory)
        let status = await repository.load()
        guard case .migratedFromLegacy = status else {
            Issue.record("expected migratedFromLegacy, got \(status)")
            return
        }

        // The backup is a verbatim copy of the original schema-1 bytes.
        let backup = try Data(contentsOf: directory.appendingPathComponent(HistoryRepository.legacyBackupFileName))
        #expect(backup == fixtureBytes)

        // And the active file is now a decodable schema-2 envelope.
        let active = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        guard case .alreadyCurrent = HistoryMigration.plan(active) else {
            Issue.record("active file did not become schema 2")
            return
        }
    }

    @Test("an interrupted migration re-runs cleanly: the original file survives a failed schema-2 write")
    func interruptedMigrationPreservesTheOnlyGoodFile() async throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureBytes = try Self.fixtureData("valid-schema1.json")
        let historyURL = directory.appendingPathComponent("history.json")
        try fixtureBytes.write(to: historyURL)

        // Simulate a crash: backup + quarantine land, but the schema-2 write
        // fails (read-only destination) — the seam makes this deterministic.
        let filesystem = ReadOnlyFilesystem(base: FileManagerHistoryFilesystem())
        let repository = HistoryRepository(directory: directory, filesystem: filesystem)
        let status = await repository.load()
        guard case .migratedFromLegacy = status else {
            Issue.record("expected migratedFromLegacy, got \(status)")
            return
        }

        // The ONLY good file — the original schema-1 bytes — is untouched.
        let onDisk = try Data(contentsOf: historyURL)
        #expect(onDisk == fixtureBytes)

        // Restarting with a working filesystem migrates successfully and is
        // not poisoned by the interrupted attempt.
        let retry = HistoryRepository(directory: directory)
        let retryStatus = await retry.load()
        guard case .migratedFromLegacy = retryStatus else {
            Issue.record("expected migratedFromLegacy on retry, got \(retryStatus)")
            return
        }
        let migrated = try Data(contentsOf: historyURL)
        guard case .alreadyCurrent = HistoryMigration.plan(migrated) else {
            Issue.record("retry did not produce schema 2")
            return
        }
        // The backup was written by the first attempt and not churned.
        let backup = try Data(contentsOf: directory.appendingPathComponent(HistoryRepository.legacyBackupFileName))
        #expect(backup == fixtureBytes)
    }
}

/// A seam wrapper whose writes/renames fail — a read-only destination.
/// Reads, copies, and directory creation pass through so the migration can
/// back up and quarantine before the failing schema-2 write.
final class ReadOnlyFilesystem: HistoryFilesystem, @unchecked Sendable {
    let base: FileManagerHistoryFilesystem
    init(base: FileManagerHistoryFilesystem) { self.base = base }

    func exists(at url: URL) -> Bool { base.exists(at: url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func write(_ data: Data, to url: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func replaceItem(at destination: URL, with source: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [String] { try base.contentsOfDirectory(at: url) }
}

// MARK: - cross-process ID stability and backup-failure abort (coordinator fixes)

/// A seam whose COPY fails (simulates full disk / permission on the backup
/// destination). Reads and writes pass through — the migration must refuse
/// to run before any write happens, so only the copy failure is exercised.
final class CopyFailingFilesystem: HistoryFilesystem, @unchecked Sendable {
    let base: FileManagerHistoryFilesystem
    init(base: FileManagerHistoryFilesystem) { self.base = base }

    func exists(at url: URL) -> Bool { base.exists(at: url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func write(_ data: Data, to url: URL) throws {
        Issue.record("no write may happen when the backup failed")
        try base.write(data, to: url)
    }
    func replaceItem(at destination: URL, with source: URL) throws {
        Issue.record("no write may happen when the backup failed")
        try base.replaceItem(at: destination, with: source)
    }
    func copyItem(at source: URL, to destination: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [String] { try base.contentsOfDirectory(at: url) }
}

struct HistoryMigrationIntegrityTests {
    @Test("a failed legacy backup aborts migration: original bytes unchanged, no schema-2 write, surfaced error")
    func failedBackupAbortsMigration() async throws {
        let directory = HistoryMigrationTests.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(HistoryRepository.activeFileName)
        let original = try HistoryMigrationTests.fixtureData("valid-schema1.json")
        try original.write(to: fileURL)

        let repository = HistoryRepository(
            directory: directory,
            filesystem: CopyFailingFilesystem(base: FileManagerHistoryFilesystem())
        )
        let status = await repository.load()

        // Surface a recoverable status, not a silent success.
        guard case .unreadable = status else {
            Issue.record("expected unreadable, got \(status)")
            return
        }
        // The sole good copy is byte-identical on disk.
        let after = try Data(contentsOf: fileURL)
        #expect(after == original)
        // No schema-2 envelope was written anywhere: no backup, no rewrite.
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(HistoryRepository.legacyBackupFileName).path))
        let onDisk = (try? JSONSerialization.jsonObject(with: after)) as? [String: Any]
        #expect(onDisk?["version"] as? Int != HistoryEnvelope.currentVersion)
    }

    @Test("migrated observation IDs are stable across processes (pinned digest value)")
    func migratedIDsAreCrossProcessStable() throws {
        // Derived via the public plan() so the pinned constant survives
        // refactors of stableID internals while still pinning its output.
        let migrated = HistoryMigration.plan(try HistoryMigrationTests.fixtureData("valid-schema1.json"))
        guard case .migrateLegacy(let envelope, _) = migrated else {
            Issue.record("expected migrateLegacy")
            return
        }
        let first = try #require(
            envelope.days[HistoryMigration.legacyScopeID]?["2026-08-01"]?.first)
        // Pin the exact UUID: the constant was computed independently of the
        // production code (fresh-process digest of
        // namespace/scope/day/hour/amount for hour 9, amount 10.0). Hasher
        // is per-process seeded; this failing means IDs changed between
        // processes and migration is no longer idempotent across restarts.
        #expect(first.id.uuidString == "8D997686-B44F-4C06-B60B-97688E5CEE54")
    }

    @Test("schema-2 JSON shape is normalized: scope/policy stored once, referenced by samples, round-trips")
    func persistedJSONIsNormalizedAndRoundTrips() async throws {
        let repository = HistoryRepository(directory: HistoryMigrationTests.freshDirectory())
        let scope = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com")
        let day = try #require(GatewayDay(spendDate: "2026-08-01"))
        let base = ISODate.parse("2026-08-01T09:00:00Z")!
        // Many samples, one shared scope and one shared policy context.
        for i in 0..<50 {
            await repository.append(Observation(
                id: UUID(), scope: scope, gatewayDay: day,
                receivedAt: base.addingTimeInterval(TimeInterval(i * 300)),
                cumulativeAmount: Double(i), limitEnabled: true, limitUSD: 400,
                precision: .exactReceipt
            ))
        }
        try await repository.save()

        let raw = try Data(contentsOf: URL(fileURLWithPath: await repository.directory.path)
            .appendingPathComponent(HistoryRepository.activeFileName))
        let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let scopeID = scope.opaqueID.uuidString

        // Shape: scope metadata appears ONCE in a scope table, not per sample.
        let scopes = try #require(json["scopes"] as? [String: Any])
        #expect(scopes.count == 1)
        #expect(scopes[scopeID] != nil)

        // Shape: the day's policy context appears ONCE; samples reference it.
        let days = try #require(json["days"] as? [String: Any])
        let scopeDays = try #require(days[scopeID] as? [String: Any])
        let dayDTO = try #require(scopeDays["2026-08-01"] as? [String: Any])
        let policies = try #require(dayDTO["policy"] as? [[String: Any]])
        #expect(policies.count == 1)
        let samples = try #require(dayDTO["samples"] as? [[String: Any]])
        #expect(samples.count == 50)
        #expect(samples.allSatisfy { ($0["policy"] as? Int) == 0 })
        // No sample carries its own scope/origin/day/policy duplication.
        #expect(samples.allSatisfy { $0["scopeID"] == nil && $0["gatewayOrigin"] == nil && $0["limitUSD"] == nil })

        // Round-trip: decoded envelope equals the in-memory one, sample for sample.
        let reloaded = HistoryRepository(directory: URL(fileURLWithPath: await repository.directory.path))
        let status = await reloaded.load()
        guard case .loaded = status else {
            Issue.record("expected loaded, got \(status)")
            return
        }
        let envelopeA = await repository.envelope
        let envelopeB = await reloaded.envelope
        #expect(envelopeB == envelopeA)
    }

    @Test("quarantine-only migration completes: every day quarantined yields an empty active scope, not a failed save")
    func quarantineOnlyMigrationCompletes() async throws {
        let directory = HistoryMigrationTests.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureBytes = try HistoryMigrationTests.fixtureData("all-quarantined.json")
        try fixtureBytes.write(to: directory.appendingPathComponent(HistoryRepository.activeFileName))

        let repository = HistoryRepository(directory: directory)
        let status = await repository.load()

        // Migration completes even though NOTHING usable was migrated.
        guard case .migratedFromLegacy = status else {
            Issue.record("expected migratedFromLegacy, got \(status)")
            return
        }
        // Every day record was quarantined with its reason intact.
        let quarantineFile = directory
            .appendingPathComponent(HistoryRepository.quarantineDirectoryName)
            .appendingPathComponent("records.json")
        let entries = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: quarantineFile))
        #expect(entries.count == 3)
        #expect(Set(entries.compactMap { $0["originalKey"] }) == ["2026-08-01", "2026-08-02", "2026-08-03"])

        // The schema-2 file was written: no dangling empty scope entry.
        let raw = try Data(contentsOf: directory.appendingPathComponent(HistoryRepository.activeFileName))
        let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(json["version"] as? Int == HistoryEnvelope.currentVersion)
        let scopes = try #require(json["scopes"] as? [String: Any])
        #expect(scopes.isEmpty)
        let days = try #require(json["days"] as? [String: Any])
        #expect(days.isEmpty)

        // And a reload of that file succeeds as current schema.
        let reloaded = HistoryRepository(directory: directory)
        guard case .loaded = await reloaded.load() else {
            Issue.record("expected loaded on reload")
            return
        }
    }


/// A seam whose write failure is scoped to the ACTIVE history envelope —
/// quarantine and backup writes pass through. Simulates the interrupted
/// migration: quarantine persisted, schema-2 write failed, retry follows.
final class EnvelopeWriteFailingFilesystem: HistoryFilesystem, @unchecked Sendable {
    let base: FileManagerHistoryFilesystem
    init(base: FileManagerHistoryFilesystem) { self.base = base }

    func exists(at url: URL) -> Bool { base.exists(at: url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
    func write(_ data: Data, to url: URL) throws {
        if url.lastPathComponent == HistoryRepository.activeFileName {
            throw CocoaError(.fileWriteNoPermission)
        }
        try base.write(data, to: url)
    }
    func replaceItem(at destination: URL, with source: URL) throws {
        if destination.lastPathComponent == HistoryRepository.activeFileName {
            throw CocoaError(.fileWriteNoPermission)
        }
        try base.replaceItem(at: destination, with: source)
    }
    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [String] { try base.contentsOfDirectory(at: url) }
}

    @Test("quarantine survives a failed migration write + retry without duplicating records")
    func quarantineIsIdempotentAcrossRetries() async throws {
        let directory = HistoryMigrationTests.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureBytes = try HistoryMigrationTests.fixtureData("malformed-array.json")
        try fixtureBytes.write(to: directory.appendingPathComponent(HistoryRepository.activeFileName))

        // First attempt: migration runs (quarantining malformed records)
        // but the schema-2 write FAILS (full disk / read-only destination).
        let failing = EnvelopeWriteFailingFilesystem(base: FileManagerHistoryFilesystem())
        let first = HistoryRepository(directory: directory, filesystem: failing)
        let firstStatus = await first.load()
        guard case .migratedFromLegacy = firstStatus else {
            Issue.record("expected migratedFromLegacy (write failure surfaces via lastError), got \(firstStatus)")
            return
        }

        // In-memory quarantine file holds each distinct record once.
        let quarantineFile = directory
            .appendingPathComponent(HistoryRepository.quarantineDirectoryName)
            .appendingPathComponent("records.json")
        func entryCount() throws -> Int {
            let data = try Data(contentsOf: quarantineFile)
            return try #require(try JSONDecoder().decode([[String: String]].self, from: data).count)
        }
        let afterFirst = try entryCount()
        #expect(afterFirst > 0)

        // Retry on the SAME in-memory state simulates the failed-save path
        // where dirty was set: the migration plan is identical, so the same
        // records are offered again. A second successful repository load
        // (retry path) must not duplicate them.
        let second = HistoryRepository(directory: directory)
        let secondStatus = await second.load()
        // After the failed write, history.json on disk is still legacy —
        // the retry re-migrates and must deduplicate the quarantine.
        guard case .migratedFromLegacy = secondStatus else {
            Issue.record("expected retry to re-migrate, got \(secondStatus)")
            return
        }
        #expect(try entryCount() == afterFirst)
    }
}
