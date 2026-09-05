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
| WP-01 | **accepted** (coordinator-reviewed, integrated) | domain worker (WP01Validation) | `71d7229` | 01.1–01.4 | `ValidatedBudget`, `UsageValidation`, `MoneyFormat`; `UsageResponse` wire-presence flags (`todayPresent`/`todayModelsPresent`) | 293 tests @ WP-01 merge `1ae1ac9` (38 new incl. all §9 regression cases); strict build exit 0 | — | B03/B07/B08/B11 UI surfaces in PopoverView/StatusItemController/CurveView not yet wired (WP-07 owns) | WP-03, WP-04, WP-07, WP-08 |
| WP-02 | **accepted** (coordinator-reviewed, integrated, coordinator-hardened) | storage worker (WP02History) | `71d7229` | 02.1–02.4 | `Observation`, `HistoryEnvelope` (+normalized schema-2 DTO), `HistoryMigration`, `HistoryRepository` actor, `HistoryRetention` | 328 tests @ `6cb2c16` (incl. §12.1 ascending-seam regression, backup-failure abort, cross-process pinned IDs, quarantine dedup, quarantine-only completion); strict build exit 0 | — | Repository not yet wired into app (WP-06); marker-boundary pinning noted for WP-09 | WP-03, WP-04, WP-06, WP-09 |
| WP-05 | **accepted** (coordinator-reviewed, integrated) | design worker (WP05Design) | `71d7229` | 05.1–05.3 | `Sources/App/DesignTokens.swift` (frozen tokens), `docs/v2/DESIGN.md` (state/copy matrix), `Tools/design_fixture_main.swift` (28 fixtures) | fixture tool builds + runs headless (exit 0, writes only `build/v2-design/`); default snapshot behavior byte-identical; suite untouched | measured: hero 151pt worst-case, money 78pt column, row stride 32pt, control min 24pt, status slot 34pt | cgColor-on-dynamic-color caching pattern documented for WP-06 | WP-06, WP-07 |
| WP-03 | **accepted** (coordinator-reviewed, integrated, 10 coordinator-hardening fixes) | lifecycle worker (WP03Lifecycle) | `82d2664` | 03.1–03.4 | `CredentialController` (stable token_id→UUID scope mapping — wired in controller unit scope; live-path wiring = WP-06 gate below; CredentialStatus incl. validationInProgress/invalid), `PollCoordinator` (generation+request-ID ownership, one-shot backoff ladder 60/120/240/300, Retry-After unwrap + header parse, 30s bounded timeout race, receivedAt-at-receipt, UsageValidation seam → PollOutcome carries UsageSnapshot), Swift-6 deliver() isolation fix (B16 blocker #1 closed) | 443 tests / 39 suites on `v2.0` @ merge (incl. stop→restart ownership, Retry-After-120, stepped-clock receipt, commit-serialization, scope-mapping stability); strict build exit 0 | — | `PollCoordinator`/`CredentialController` instantiated NOWHERE in `Sources/App` — live path still `UsagePoller → PollStateMachine` with placeholder `pollScope`. Wiring is WP-06's FIRST deliverable (gate below) | WP-06, WP-10 |
| WP-04 | **accepted** (coordinator-reviewed, integrated, burn-baseline hardening) | analytics worker (WP04Analytics) | `82d2664` | 04.1–04.4 | `Freshness` (90s ceiling, derive/invalidation), `ObservationCoverage` (§7.4 gates: 10min/6 readings/150s gap/30min correction-free, 14-calendar-day medians), timestamped `BurnBuffer` (identity-rebase on scope/day change) | 402→443 tests incl. cross-identity rebase regressions (higher-cumulative + equal-timestamp scope/day changes never fabricate burn) | — | DayStrip left as-is (already §7.4-honest); week hover wording deferred to WP-06/07 | WP-06, WP-09 |
| WP-11 | **accepted** (coordinator-reviewed, integrated) | release worker (WP11Updates) | `82d2664` | 11.1–11.4 | `ReleaseChecker.UpdateState` (neverChecked/checking/current/available/skipped/failed + lastSuccess), `FetchResult`, `isCheckDue` (future-reference rollback guard), `VersionCheck.isTrustedReleaseURL` (HTTPS github.com path-pinned), `WhatsNew.cleanSummary` | +28 tests (offline/404/429/skipped never claim current; unrelated polls never dismiss); live unauthenticated release-metadata check: HTTP 200, PUBLIC — no hosting decision needed | — | PopoverView bell call-site rewire (state: instead of release:) is coordinator-owned, WP-07 wires | WP-07, WP-12 |
| WP-06 | **accepted** (coordinator-reviewed, integrated, scope-wiring gate satisfied) | shell worker (WP06Shell) | `39c2a9c` | 06.1–06.5 | `AppCoordinator` (live wiring: CredentialController+PollCoordinator in main.swift), `SummaryPresenter` (single freshness derivation, DESIGN.md copy), `SummaryDisplayState` (moved to own file), `PerformanceSignposts`; `UsagePoller.swift` deleted (clean cutover) | 453 tests / 41 suites on `v2.0` @ `eebf126` (incl. scope-gate restart regression, presenter clock-determinism, render-invalidation idempotence); strict build exit 0, PopoverPanel:324 warning FIXED, 0 new warnings | signposts registered; full census attachment deferred to WP-12 | period-switch live rewire + full visual conversion = WP-07; PopoverView bell rewire = WP-07 | WP-07, WP-08, WP-09, WP-10 |
| WP-07 | **accepted** (coordinator-reviewed, integrated, visual fixture gate passed) | UI worker (WP07SummaryUI) | `469027a` | 07.1–07.4 | Persistent `PopoverView` composition root (sections-once, stable-ID rows), `SummaryHeaderView`/`ModelsSectionView`/`ConnectionStatusView`/`SecondaryPanelCoordinator`, segmented `CurveView` (no invented zero, `limitEnabled:` param), bell rewire to `UpdateBellView(state:)` — bell/version strict-concurrency warnings GONE | 507 tests / 46 suites on `v2.0` @ `6615586` (incl. B07 root fix in `UsageValidation.modelAvailability`, period-switch no-poll, row-ID stability, auth/invalid row-routing); strict build exit 0 | **Visual gate**: harness extended to render the LIVE converted `PopoverView` via `SummaryPresenter.apply` — 18 `live-state-*.png` (9 §5.3 states × light/dark); auth/invalid states verified to REPLACE model rows with DESIGN.md explanatory rows; explanatory rows render full-width in the reserved stride | period-switch rewire complete; coordinator may consolidate `PopoverView.modelBudgetInputs` → `ModelBudgetSignal.input(from:)` | WP-09, WP-10, WP-12 |
| WP-08 | **accepted** (coordinator-reviewed, integrated) | budget worker (WP08Budget) | `a9ba9f3` | 08.1–08.3 | `BudgetOverview` fleshed out + moved to own file (`GlobalPolicyState`/`ModelSignalState`, `derive`, headroom `max(0, min(global, model))`, relaxed/blocked/invalid states), `BudgetDetailView` (all caps, scroll-bounded), `ModelBudgetSignal.input(from:)` shared conversion | 480 tests / 43 suites at WP-08 merge `469027a` (27 new: all §9 fixtures — global/model bounds, cooldown relaxed, zero-cap blocked, removed cap, failed refresh, no caps) | — | F01 detail surface hosted through WP-07's `SecondaryPanelCoordinator`; live UI integration verified in wave-4 renders | WP-09, WP-10 |

## Wave-4 integration state (2026-09-05)

`v2.0` HEAD after wave-4: **507 tests in 46 suites pass, EXIT=0**
(`/tmp/v2-final4.log`), strict build exit 0. Visual gate closed: the design
harness renders the live converted UI (not mocks) across all §5.3 states.
Wave 5 (WP-09, WP-10) may dispatch from this revision.

## Wave-2 integration state (2026-09-05)

`v2.0` HEAD after wave-2 integration: **443 tests in 39 suites pass**, strict
§12.3 app build exits 0. The AIHubClient Swift-6-mode `deliver()` blocker is
CLOSED (WP-03). Remaining: strict-concurrency WARNINGS in PopoverPanel/
UpdateBell/VersionBullet (WP-06 owns); PopoverView bell call-site rewire
(WP-07); B02/B05/B06/B04/B09/B15/B12/B17 fixes now IN (surfacing through UI
in wave 4). Wave 3 (WP-06) may dispatch from this revision.

## WP-06 acceptance gate — SATISFIED (2026-09-05)

The scope-wiring gate was WP-06's first deliverable and is verified CLOSED:
1. `AppCoordinator.handle(outcome:)` builds the Observation from
   `snapshot.scope` (== `credentials.scope` by construction —
   `PollCoordinator.accept` refuses to commit without it) and routes it to
   BOTH `burnBuffer.record` and `repository.append`. The placeholder
   `pollScope` has zero live call sites (legacy `PollStateMachine.ingest`
   survives only for tests).
2. Regression test `PresentationLifecycleTests.
   commitPathUsesPersistedScopeAcrossRestart` proves the persisted
   token_id→UUID mapping is stable across a simulated restart and that
   session-2 appends land in session-1's history partition.
Post-merge evidence on `v2.0` @ `eebf126`: **453 tests / 41 suites pass,
EXIT=0**; strict build exit 0 with 10 pre-existing warnings, none in
WP-06-touched files (PopoverPanel.swift:324 actor-isolation warning FIXED).
SummaryPresenter derives freshness exactly once per state build and carries
DESIGN.md copy ("Latest observation · HH:mm …"; stale Today renders the
§5.3 explanatory row, not a blank).

## Integration blockers (for the coordinator)

1. **RESOLVED by WP-03**: the Swift-6-mode `deliver()` data-race error in
   `AIHubClient.swift` was fixed during WP-03 (Sendable boxing at the
   isolation boundary). `-swift-version 5` remains pinned for the app build.
2. **Swift-5-mode strict-concurrency warnings** in `UpdateBellView.swift`,
   `VersionBulletView.swift` (main-actor-isolated
   calls/properties from `@Sendable` closures — dispatch-based animation
   completion handlers). Warnings only; build exits 0. Fixes require
   touching those App files (outside WP-00 list) — deferred; natural
   owners: WP-06 (presentation) / WP-03.
3. **App-level resource measurements** (launch, idle, interaction) need the
   packaged `.app` exercised outside this worker's scope — deferred to
   WP-12's release gate with the core-path table as baseline.
