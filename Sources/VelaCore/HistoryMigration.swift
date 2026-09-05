// Sources/VelaCore/HistoryMigration.swift
// Pure, loss-preserving schema-1 → schema-2 migration (WP-02, 02.3).
// Why: legacy history.json is a [String: DayRecord] dict with known
// failure shapes — corrupt JSON, malformed hourly arrays, duplicate keys,
// ISO-vs-bare day keys for the same logical day. Nothing uncertain is ever
// silently dropped: every questionable record lands in a quarantine entry
// with an explanation, and the original bytes are backed up by the caller
// before the schema-2 write. The function is pure (bytes in, plan out) so
// re-running it after an interruption derives the identical result.
// RELEVANT FILES: Sources/VelaCore/HistoryRepository.swift,
// Sources/VelaCore/Observation.swift, Sources/VelaCore/HistoryStore.swift,
// Tests/VelaCoreTests/HistoryMigrationTests.swift, Tests/Fixtures/history/

import Foundation

/// Plans the migration of raw history.json bytes. Pure: no file I/O here;
/// HistoryRepository performs the backup/quarantine/write steps.
public enum HistoryMigration {

    /// A legacy record that could not be trusted and is preserved raw,
    /// with a reason, instead of being deleted (§7.3).
    public struct QuarantinedRecord: Equatable, Sendable {
        public enum Reason: String, Equatable, Sendable {
            /// The day's hourly array was not 24 numeric/nil slots.
            case malformedArray
            /// The day key appeared more than once; last-wins is arbitrary.
            case duplicateKey
            /// The day key is not a usable calendar-day label.
            case invalidDayKey
            /// The day's readings decrease mid-day (pre-fix contaminated
            /// data); excluded from derived views but preserved raw.
            case contaminated
            /// The day's record failed to decode at all.
            case undecodable
        }
        public let reason: Reason
        public let originalKey: String
        /// The raw JSON payload of the quarantined day record.
        public let payload: String

        public init(reason: Reason, originalKey: String, payload: String) {
            self.reason = reason
            self.originalKey = originalKey
            self.payload = payload
        }
    }

    public enum Plan: Equatable, Sendable {
        /// The bytes are already a schema-2 envelope; load directly.
        case alreadyCurrent(HistoryEnvelope)
        /// A legacy schema-1 file; migrate to this envelope and quarantine
        /// these records. Caller must back up the original bytes first.
        case migrateLegacy(envelope: HistoryEnvelope, quarantined: [QuarantinedRecord])
        /// Not parseable as either schema. Caller retains the original file
        /// and quarantines a byte copy.
        case corrupt(reason: String)
    }

    /// The scope key every migrated legacy day lands under. §7.3: without a
    /// proven legacy account identity, legacy history stays an UNASSIGNED
    /// archive — never silently attached to the next credential, never in
    /// personal comparisons.
    public static let legacyScopeID = "00000000-0000-0000-0000-000000000000"

    private static let legacyScope = UsageScope(
        kind: .credential,
        opaqueID: UUID(uuidString: legacyScopeID)!,
        gatewayOrigin: "legacy-unassigned"
    )

    /// Analyzes raw history bytes and returns the migration plan.
    public static func plan(_ raw: Data) -> Plan {
        guard let top = try? JSONSerialization.jsonObject(with: raw),
              let dict = top as? [String: Any] else {
            return .corrupt(reason: "not a JSON object")
        }
        if let version = dict["version"] as? Int, version == HistoryEnvelope.currentVersion {
            if let envelope = try? JSONDecoder().decode(HistoryEnvelope.self, from: raw) {
                return .alreadyCurrent(envelope)
            }
            return .corrupt(reason: "claims schema 2 but does not decode as a history envelope")
        }
        return migrateLegacy(dict: dict, duplicateKeys: duplicateTopLevelKeys(in: raw))
    }

    // MARK: - legacy migration

    private static func migrateLegacy(dict: [String: Any], duplicateKeys: Set<String>) -> Plan {
        var quarantined: [QuarantinedRecord] = []
        var decodedDays: [String: DayRecord] = [:]

        for (key, value) in dict {
            let payload = (try? JSONSerialization.data(withJSONObject: value))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "<unserializable>"

            if duplicateKeys.contains(key) {
                // The day key appears twice in the raw file; both parsers
                // silently keep one of them. Uncertain data is quarantined
                // with its (parser-visible) payload, never silently merged.
                quarantined.append(QuarantinedRecord(reason: .duplicateKey, originalKey: key, payload: payload))
                continue
            }
            guard let day = decodeDayRecord(value) else {
                quarantined.append(QuarantinedRecord(reason: .undecodable, originalKey: key, payload: payload))
                continue
            }
            if day.hourly.count != 24 {
                // A malformed array's values are unusable as hourly data.
                // Preserve the raw record; do not silently reset to nil.
                quarantined.append(QuarantinedRecord(reason: .malformedArray, originalKey: key, payload: payload))
                continue
            }
            decodedDays[key] = day
        }

        // Normalize ISO day keys ("2026-08-07T00:00:00Z") onto their bare
        // day label, merging collisions max-per-hour like the legacy store.
        var merged: [String: DayRecord] = [:]
        for (key, day) in decodedDays {
            let bare = ISODate.dayKey(key)
            guard GatewayDay(spendDate: bare) != nil else {
                let payload = (try? JSONEncoder().encode(day))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "<unserializable>"
                quarantined.append(QuarantinedRecord(reason: .invalidDayKey, originalKey: key, payload: payload))
                continue
            }
            if var existing = merged[bare] {
                for hour in 0..<24 {
                    switch (existing.hourly[hour], day.hourly[hour]) {
                    case let (a?, b?): existing.hourly[hour] = max(a, b)
                    case (nil, let b?): existing.hourly[hour] = b
                    default: break
                    }
                }
                existing.limit = max(existing.limit, day.limit)
                if existing.exhaustedAt == nil { existing.exhaustedAt = day.exhaustedAt }
                merged[bare] = existing
            } else {
                merged[bare] = day
            }
        }

        // Contaminated days (cumulative readings decrease mid-day) are
        // pre-fix corrupt data: quarantined, never migrated into derived
        // views where they would poison medians.
        var envelopeDays: [String: [Observation]] = [:]
        var coverage: [String: HistoryEnvelope.Coverage] = [:]
        for (dayKey, day) in merged {
            if HistoryStore.isContaminated(day) {
                let payload = (try? JSONEncoder().encode(day))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "<unserializable>"
                quarantined.append(QuarantinedRecord(reason: .contaminated, originalKey: dayKey, payload: payload))
                continue
            }
            guard let gatewayDay = GatewayDay(spendDate: dayKey) else { continue }
            let observations = hourlyObservations(day: day, gatewayDay: gatewayDay)
            envelopeDays[dayKey] = observations
            coverage[dayKey] = HistoryRetentionEngine.coverage(dayKey: dayKey, observations: observations)
        }

        let envelope = HistoryEnvelope(
            revision: 1,
            days: [legacyScopeID: envelopeDays],
            coverage: [legacyScopeID: coverage]
        )
        return .migrateLegacy(envelope: envelope, quarantined: quarantined)
    }

    /// Converts one legacy day's hourly slots into observations. Legacy
    /// values get `.legacyHour` precision and their receivedAt is the UTC
    /// START of the slot hour — the only honest timestamp a slot carries;
    /// no exact receipt time is fabricated for legacy samples (B15).
    /// `limitEnabled` is true: the legacy store only ever recorded days
    /// under an enabled limit policy.
    private static func hourlyObservations(day: DayRecord, gatewayDay: GatewayDay) -> [Observation] {
        guard let midnight = gatewayDay.startOfDayUTC else { return [] }
        var observations: [Observation] = []
        for (hour, value) in day.hourly.enumerated() {
            guard let amount = value else { continue }
            // Stable, content-derived ID: the same legacy file migrates to
            // the same observation IDs on every run, so re-running the
            // migration after an interruption is byte-identical.
            let id = stableID(scope: legacyScopeID, day: gatewayDay.key, hour: hour, amount: amount)
            observations.append(Observation(
                id: id,
                scope: legacyScope,
                gatewayDay: gatewayDay,
                receivedAt: midnight.addingTimeInterval(TimeInterval(hour * 3600)),
                cumulativeAmount: amount,
                limitEnabled: true,
                limitUSD: day.limit,
                precision: .legacyHour
            ))
        }
        return observations
    }

    /// Deterministic UUID for a migrated legacy observation (namespace-style
    /// mixing of scope/day/hour/amount into UUID bytes). Determinism is what
    /// makes the migration idempotent across interrupted restarts.
    private static func stableID(scope: String, day: String, hour: Int, amount: Double) -> UUID {
        var hasher = Hasher()
        hasher.combine(scope)
        hasher.combine(day)
        hasher.combine(hour)
        hasher.combine(amount.bitPattern)
        let h1 = hasher.finalize()
        var hasher2 = Hasher()
        hasher2.combine(h1)
        hasher2.combine("vela-legacy-observation")
        let h2 = hasher2.finalize()
        var bytes = withUnsafeBytes(of: h1.bigEndian) { Array($0) } + withUnsafeBytes(of: h2.bigEndian) { Array($0) }
        // Set version 4 / variant bits so the UUID is well-formed.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Scans the raw bytes for duplicate TOP-LEVEL keys. JSONSerialization
    /// and JSONDecoder both collapse duplicates silently (last wins), so
    /// detecting them needs this small depth-0 string scanner over the
    /// object. The history file is a flat day-label → record object, so a
    /// depth-0 scan is exactly the right granularity.
    private static func duplicateTopLevelKeys(in raw: Data) -> Set<String> {
        guard let text = String(data: raw, encoding: .utf8) else { return [] }
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        var depth = 0
        var inString = false
        var escaped = false
        var token = ""
        var expectKey = false
        for char in text {
            if inString {
                if escaped {
                    token.append(char)
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                    if depth == 1 && expectKey {
                        if !seen.insert(token).inserted { duplicates.insert(token) }
                        expectKey = false
                    }
                } else {
                    token.append(char)
                }
                continue
            }
            switch char {
            case "\"":
                inString = true
                token = ""
            case "{":
                depth += 1
                if depth == 1 { expectKey = true }
            case "}":
                depth -= 1
            case "," where depth == 1:
                expectKey = true
            default:
                break
            }
        }
        return duplicates
    }

    private static func decodeDayRecord(_ value: Any) -> DayRecord? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(DayRecord.self, from: data)
    }
}
