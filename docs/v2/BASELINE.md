# Vela Ishtar 2.0 — Baseline Report

WP-00 item 00.1. Captured at WP-00 execution time on the `v2.0` branch.

## Baseline facts

| Item | Value |
|---|---|
| Baseline commit | `6a765c2` — "v2.0 baseline: preserve direct daily model data work (pre-WP-00 checkpoint)" (on top of `241ee4a` v1.0.4) |
| Toolchain | Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101), Target: arm64-apple-macosx26.0 |
| OS | macOS 26.6.2 (Build 25G83), Apple Silicon (M4 Pro) |
| Baseline test count | 251 tests in 17 suites — all passing before WP-00 changes (Swift Testing framework) |
| Working-tree state preserved | Yes. The direct daily-model-data work (snapshot-differencing retirement + `today`/`today_models` support: `TodayModelRows.swift`, tolerant decode in `Models.swift`, updated `PollStateMachine`/`HistoryStore` + tests) is committed in the checkpoint. The retired snapshot subsystem (ModelSnapshots/TodayModelSplit) stays deleted. |

## Verification evidence at WP-00

| Check | Result |
|---|---|
| `make test` (pinned `-swift-version 5`) | PASS — 255 tests in 18 suites (251 existing + 4 new TestSupport smoke tests), exit 0 |
| Strict app build (§12.3 command + pinned mode), see below | exit 0 |
| App harness target build (`swift build --target VelaCore`) | PASS (warnings only, see integration blockers) |
| WP-00 scope check (`git status`) | Only the WP-00 file list modified/created |
| Fixture hygiene | `Tests/Fixtures/usage/*.json` — synthetic token_ids (`11111111-2222-4333-…`), no real credentials |

Strict build command actually run (§12.3 with the pinned language mode):

```sh
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  Sources/VelaCore/*.swift Sources/App/*.swift \
  -o /tmp/vela-wp00-build/VelaIshtar \
  -framework Cocoa -framework ServiceManagement \
  -framework Security -framework QuartzCore
```

## Core performance measurements (Tools/performance_main.swift)

Machine: M4 Pro, macOS 26.6.2, `-O` build. Median wall-clock per iteration
after warmup. These are this-machine regression baselines, not §6 release
gates.

| Path | Median |
|---|---|
| `history.save` 90 days × 12 slots (cold, encode + atomic write) | ~5.05 ms |
| `history.load` 90 days × 12 slots (cold, read + decode + clean) | ~0.75 ms |
| `history.record` single observation (warm) | ~0.0008 ms |
| `burnbuffer.record` 1 sample (warm) | < 0.0001 ms |
| `paceEngine.verdict` (warm) | ~0.0008 ms |
| usage JSON decode (warm) | ~0.0055 ms |

Launch/idle/interaction resource measurements (cold/warm launch, closed
idle, repeated interaction): NOT YET MEASURED — needs the packaged app run
externally from a harness; recorded here as a measurement blocker for WP-12,
with the core-path table above as the reproducible starting point.

## Snapshot tool

`Tools/snapshot_main.swift` output is now configurable via env vars —
`VELA_SNAPSHOT_DIR` (both roots), or `VELA_SNAPSHOT_ASSETS_DIR` /
`VELA_SNAPSHOT_SCRATCH_DIR` individually. Defaults unchanged: committed
`docs/assets/` + scratch `/tmp/vela-snapshots/`. Verified: a run with
`VELA_SNAPSHOT_DIR` set writes only to the configured directory and the
regenerated committed assets are byte-identical (deterministic render), so
default runs still refresh README assets safely.

## Progress record (plan §11 template)

| Package | State | Owner | Accepted base | Task IDs complete | Produced contracts | Test evidence | Metric evidence | Known risks | Next dependency |
|---|---|---|---|---|---|---|---|---|---|
| WP-00 | **accepted** (coordinator-reviewed, integrated) | platform worker (WP00Worker) | `6a765c2` | 00.1 (partial — launch/idle measurements blocked), 00.2, 00.3, 00.4 | `UsageScope`, `UsageSnapshot`, `ModelBreakdownState`, `Observation`, `HistoryEnvelope`, `ConnectionState`, `Freshness`, `BudgetOverview`, `SummaryDisplayState`, `MarkerReceipt`, `UsageTransport`, `RefreshReason` | 255/18 suites pass on `v2.0` @ `77234a1`; strict build exit 0 (2 pre-existing warnings, see blockers) | core-path timings recorded; app-level measurements blocked | see integration blockers | WP-01, WP-02, WP-05 may start from this revision |

## Integration blockers (for the coordinator)

1. **Pre-existing Swift-6-mode error, `Sources/App/AIHubClient.swift:75`** —
   `sending 'completion' risks causing data races` in `deliver()` under
   Swift 6 language mode (strict-concurrency warnings in Swift 5 mode).
   Fix requires touching `AIHubClient.swift`, which is OUTSIDE the WP-00
   allowed file list (not `PopoverView.swift`/`main.swift`, but not in the
   WP-00 list either), so the fix was DEFERRED, not applied. This is why
   the pinned mode is `-swift-version 5` (with strict-concurrency
   diagnostics available opt-in). WP-03 (credential lifecycle/polling)
   should take this file and fix the isolation boundary.
2. **Swift-5-mode strict-concurrency warnings** in `PopoverPanel.swift`,
   `UpdateBellView.swift`, `VersionBulletView.swift` (main-actor-isolated
   calls/properties from `@Sendable` closures — dispatch-based animation
   completion handlers). Warnings only; build exits 0. Fixes require
   touching those App files (outside WP-00 list) — deferred; natural
   owners: WP-06 (presentation) / WP-03.
3. **App-level resource measurements** (launch, idle, interaction) need the
   packaged `.app` exercised outside this worker's scope — deferred to
   WP-12's release gate with the core-path table as baseline.
