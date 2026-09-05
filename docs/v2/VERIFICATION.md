# docs/v2/VERIFICATION.md

<!-- WP-12 (12.1, 12.5): the release-gate verification record. One row per
     §10 acceptance-matrix line; every claim cites a command output or test
     name from the 585-test suite on this branch. Deferred rows name the
     reason. RELEVANT FILES: V2_IMPLEMENTATION_PLAN.md (§10), docs/v2/BASELINE.md,
     docs/v2/PERFORMANCE.md, docs/v2/RELEASE_CHECKLIST.md -->

# Vela Ishtar 2.0 — Verification record

**Branch `wp12-gate` @ `3b32fa3`** (v2.0 @ `f1af8a5` merged in; history:
`bee9b90` shell wiring → `14a9024` merge `0bf7827` → `676d3a1` harness →
`de14bea`/`f1af8a5` gate-fix merge → `3b32fa3` harness verified).

## Gate evidence (12.1)

| Gate | Command | Result (this branch) |
|---|---|---|
| Full suite | `make test` (Swift 5 pinned) | **585 tests / 53 suites passed, EXIT=0** (`/tmp/wp12-final3.log`; final line `✔ Test run with 585 tests in 53 suites passed after 31.549 seconds`) |
| Strict app build (§12.3) | `swiftc -O -target arm64-apple-macos14.0 Sources/VelaCore/*.swift Sources/App/*.swift -o … -framework Cocoa -framework ServiceManagement -framework Security -framework QuartzCore` | **exit 0**; 4 residual warnings, all `var`→`let`/unused-binding lints (HistoryMigration.swift:162, HistoryRepository.swift:621, HistoryRepository.swift:876, UsageValidation.swift:222) — no concurrency warnings (B16 closed: the PopoverPanel:324 actor-isolation warning was fixed in WP-06; zero remain) |
| App package | `make build` | exit 0, `build/Vela Ishtar.app` produced |
| UI matrix | design fixture harness | 46 PNGs rendered (12 live-state × light/dark, 11 state × light/dark + contrast/transparency variants, budget-detail, v1/v2 comparison) — `/tmp/vela-wp12-audit/design-fixtures-583/`; harness exit 0 |
| 500-cycle lifecycle | `Tools/perf_harness/lifecycle_main.swift` | 500 cycles (today/month alternate), subview tree **stable at 34** — no accumulation (see PERFORMANCE.md) |
| Performance core paths | `Tools/performance_main.swift` | table in PERFORMANCE.md |

## B01–B17 findings → regression tests (§12.1 replay)

Each finding has a named, passing test on this branch. Tests pin the §3
behavior (they fail against the pre-fix code by construction — each was
written as the regression for its WP).

| Finding | Package | Test(s) |
|---|---|---|
| B01 midnight data loss | WP-02 | `HistoryStoreTests.b01AscendingSeamSurvivesSaveAndLoad` (§12.1 exact sequence, last observed 165); `audit4` seam continuation pins |
| B02 scope mixing / late results | WP-03 | `PollCoordinatorTests`: "stop before callback: late result never commits"; "A starts -> B accepted (credential changed) -> A completes late: A dropped"; `CredentialLifecycleTests`: "accepted replacement -> new generation, new scope"; "different tokenId → different scope" |
| B03 1e100 percent crash | WP-01 | `UsageValidationTests`: "used_percent = 1e100 clamps before any integer conversion"; "NaN or infinity falls back to 0 with a warning" |
| B04 false forecasts | WP-04 | `PaceEngineTests`: "stale $200/$400 produces NO on-pace-to-stay-under-budget (B04)"; "first 30 seconds of a $399/$400 day produce NO safe-pace claim (B04)" |
| B05 freshness by age | WP-03/04 | `FreshnessTests`: age-based boundaries (90s), "an auth error invalidates trust IMMEDIATELY", "after a process wake past the window, the old reading is stale" |
| B06 401 prompt loop / Keychain-as-absence | WP-03/10 | `PollCoordinatorTests` suite "recovery without loops (03.3, B06)" incl. "cancel dismisses recovery; nothing re-opens it across five ticks"; `SettingsFlowTests` B06 pin: denied Keychain never reads as "no token saved" |
| B07 over-attributed rows | WP-01/07 | `TodayModelRowsTests`: "B07: $80+$70 rows against a $100 day total are rejected, never rendered"; `UsageValidationTests` inconsistency pins |
| B08 month share denominator | WP-01/07 | `UsageValidationTests`: "month share denominator is the authoritative month total, not the row sum" |
| B09 date-blind burn | WP-04 | `BurnBufferTests`: "one minute vs eight hours produce DIFFERENT pulses (B09 regression)"; sleep-gap and real-elapsed-axis pins |
| B10 rebuild churn / 210 ms wait | WP-06/07 | `RenderInvalidationTests`: "identical polls produce an identical SummaryDisplayState"; "period switch … (B10: no data wait)"; `PresentationLifecycleTests`: "period selection re-derives display state without a poll (B10)" |
| B11 unlimited hero contradiction | WP-01/07 | `SummaryStateTests` B11 unlimited hero; `MoneyFormatTests` hero suffix; "zero enabled limit is a real $0 limit, zero disabled limit is unlimited" |
| B12 nil-release "up to date" | WP-11 | `UpdateStateTests`: "a fresh checker is neverChecked, not up to date"; skip/failed/offline never claim current; `VersionCheckTests` |
| B13 swallowed storage errors | WP-02/06 | `HistoryRepositoryTests`: "a full-disk write failure surfaces an error, keeps in-memory state, leaves no orphaned temp file, and recovers"; "an unreadable history file is a surfaced status"; "corrupt history stays recoverable"; plus `f1af8a5` save-propagation tests ("save-propagates-marker-failure") |
| B14 inaccessible custom views | WP-10 | `AccessibilityTests` (15): `tokenFieldAccessibilityHidesSecret`, `periodSwitcherTabsAreFocusableButtons`, curve/week summaries; WP-10 `accessibilityPerformPress` on bell/bullet |
| B15 curve bridging / week totals | WP-02/04/09 | `ChartInteractionTests` "B15: segmented observed paths" (no invented zero origin); `CurveScrubTests` §7.4 hover honesty; `FreshnessTests` precision (slot-start vs exact receipt) |
| B16 Swift-mode/actor warnings | WP-00/06/12 | Swift 5 pinned in `make test` + strict build; **zero concurrency warnings** in the strict build above (the WP-00-era PopoverPanel warning fixed in WP-06) |
| B17 README/changelog drift | WP-11/12 | `WhatsNewTests.cleanSummary` (Markdown bullet never ships); WP-12: README rewritten to v2 behavior + `Makefile readme-version` re-pointed to truth sources (see CHANGELOG) |

## §10 acceptance matrix — row by row (12.5)

| Area | Evidence / disposition |
|---|---|
| **Build** | `make test` 585/53 EXIT=0 with Swift 5 pinned; strict §12.3 build exit 0 (table above). Unexplained concurrency warnings: none. |
| **Correctness (B01–B11)** | B01–B11 test map above — all named tests passing. Rounding/scope/date semantics pinned in `MoneyFormatTests`, `UsageValidationTests`, `HistoryStoreTests`, `GatewayDay` pins. |
| **Persistence** | V1→V2 migration: `HistoryMigrationTests` (schema-1 fixture migrates; deterministic IDs → idempotent; corrupt → reported, never partially parsed; quarantines: malformed/duplicate/decreasing/invalid-day; failed legacy backup aborts migration). Backup intact: "the original file survives a failed schema-2 write". Malformed recovery: "corrupt history stays recoverable: original retained, quarantine copy written". Serial writes: "two rapid saves cannot regress disk state"; "several appends … coalesce into one on-disk write". Bounded retention: 90-day prune + 2 MiB coarsening tests. Save-failure propagation: `f1af8a5` tests. |
| **Credentials** | Late-result isolation: B02 tests (dropped late A, stop-before-callback). Candidate validation: `CredentialLifecycleTests` "Transactional replacement (03.2)" suites (write deferred until gateway acceptance; commit serialization). Keychain-denial recovery: SettingsFlow B06 pin + coordinator recovery suite. No secret in data/log/export: `PresentationLifecycleTests` "display state contains no token material (§7.2 hygiene)"; `HistoryExportTests` zero-token CSV; `AccessibilityTests.tokenFieldAccessibilityHidesSecret`. No repeated focus theft: recovery-once-per-episode tests. Clear persistence across restart: `f1af8a5` "clear-persists-across-restart". |
| **Network** | `AIHubClientTests` (stubbed URLProtocol): 200 map, 401/403, 5xx→badStatus, malformed body, oversized-body rejection, Retry-After shorten/120. Coalescing/backoff: `PollCoordinatorTests` backoff ladder 60/120/240/300, in-flight ownership (stop→start race), Retry-After-only-shortens, wake refresh. Timeout: bounded 30s timeout race tests. Invalid payload → `invalidResponse` distinct state. Cancel: cancellation-aware transport tests (no hangs; verified by the suite's 31.5 s wall). |
| **Data truth** | No unsupported zero: "empty day never fabricates a total", "zero day total stays available (zero is a fact)". Complete-day: partial-day `PARTIAL` coverage tests. Exact crossing: §7.4 gates refuse (B04 tests; `ObservationCoverageTests` gates). Status: stale/connecting/auth/invalid each render distinct honest copy (`RenderInvalidationTests`, `ConnectionStatusView` pins). Forecast/median: gated until §7.4 thresholds. No project attribution: `SpendMarkerTests` (deltas labeled observed spend; discontinuities never guessed). |
| **Visual** | 46-fixture live-state matrix regenerated on this branch (`design-fixtures-583/`): every §5.3 state × light/dark, plus increase-contrast and reduce-transparency variants, budget-detail, long-value cases (hero worst 151pt measured by the harness). Static review = fixture PNGs on this branch; no human sign-off recorded here (RELEASE_CHECKLIST item). |
| **Interaction** | Immediate tabs (B10 no-wait tests); hover survives polls (`CurveScrubTests`, WP-07 scrub-restore pins); row-ID stability across spend changes; auth/invalid rows swap without layout jump (`LayoutFixtureTests`); click/dismiss/reopen: presentation lifecycle + history-window reopen-restore tests. No window-size animation: fixed 320×480 panel pins. 500-cycle spot: stable (PERFORMANCE.md). |
| **Accessibility** | `AccessibilityTests` (15 tests): keyboard route (period switcher buttons, panel commands `panelLocalCommandsFire`), VoiceOver copy pure and test-pinned (pill stale/unlimited, curve/week summaries, day strip "no data"), secret hiding, AX press on bell/bullet. No color-only state: every state carries text (freshness line, explanatory rows). Keyboard-only/VoiceOver *live* walkthrough of the packaged app: **deferred** — needs a human at a desktop session (RELEASE_CHECKLIST). |
| **F01** | `BudgetOverviewTests`: nested headroom (model binding, global binding), disabled global → model room alone, cooldown relaxed + expiry re-enforce ("expired cooldown is not relaxed"), zero cap → blocked, invalid → invalid. No request-permission promise: `BudgetDetailTests` disclaimer test. Cooldown expiry single redraw: `BudgetDetailTests`. |
| **F02** | `SpendMarkerTests` (12): 10→25=$15, invalid end, non-finite rejection, midnight discontinuity, token-replacement scopeChanged, downward correction, offline same-day recovery, 80-char name, round-trip, corrupt file. `MarkerFlowTests`: start→finish against latest observation, cancel, no-fabricated-baseline, receipt rows, selected-day anchor, immediate persistence. Persistence/retention: `HistoryRepositoryMarkerTests` (relaunch restore, 100-receipt cap, boundary survives cap + coalescing). |
| **F03** | `HistoryWindowTests`: lazy creation, reopen restores selection, legacy archive distinct, partial/empty honesty, close stops display work. Coverage/legacy precision: `HistoryExportTests` (legacy-hour labeled, chronological, invariant decimals). Clean scoped CSV: exact §9 header, formula-injection guard, mixed-scope filter + partial/complete per-day coverage (`f1af8a5` cases). Lazy window lifecycle: HistoryWindowTests. Clear scoped to one scope (`clearHistory` tests). |
| **Performance** | docs/v2/PERFORMANCE.md — core-path table measured, 500-cycle proxy executed, per-target measured/blocked status with reasons; app-level soak is the recorded coordinator action. |
| **Distribution** | **Deferred to the authorized release action.** Per constraint: no deploy, no release creation, no version bump (Info.plist stays 1.0.4). Release access/update state verified as far as safely possible: WP-11 live unauthenticated release-metadata check (HTTP 200, PUBLIC — recorded in BASELINE.md); `UpdateState` never falsely claims current (B12 tests); `make release` packaging path unchanged and `make build` exit 0 here. Actual publish/notarization/cask-digest reconciliation = RELEASE_CHECKLIST §pending. |
| **Documentation** | README rewritten to v2 behavior (test badge/count, versioned-download block, Swift-5 note, history explorer + markers + export, privacy section unchanged in kind); CHANGELOG 2.0 UNRELEASED entry; `Makefile readme-version` now derives counts from truth sources; B17 drift fixed (285→583→585 badge wiring). README/CHANGELOG claims drift-checked against Sources on this branch. Known limitations: in RELEASE_CHECKLIST. |

## P2 disposition record

All §3.3 P2 findings are closed with tests (map above); none were waived.
Residual P2-class items, all explicitly deferred with reasons:

1. **App-level §6.1 measurements (idle CPU, footprints, cold-paint p95, main-thread p95)** — not executable without the packaged app in a desktop session; not invented (§6 forbids). Coordinator runs the soak before release (RELEASE_CHECKLIST).
2. **Live VoiceOver/keyboard walkthrough** — needs a human with the packaged app; unit-level a11y coverage is complete and pinned.
3. **Notch/pill-size ladder on hardware** — §3.4 investigation item; the automatic fallback logic is unchanged from 1.0.4 and notched-hardware behavior was never demonstrated broken; notched-MacBook spot check stays in the checklist.
4. **B16 residual lints** — 4 `var`→`let`-class warnings remain in strict build (no concurrency warnings). Cosmetic; listed in the gate table; fixing them touches WP-01/02-owned files beyond the WP-12 scope contract.
5. **Perf-tool drift fix note** — `Tools/performance_main.swift` had drifted from the WP-04 Observation API (would not compile); repaired on this branch (`77954f0`), re-measured post-fix.

## Scope-expansion statement

WP-12 production changes, complete list: (a) `performance_main.swift` API
repair; (b) WP-09 shell wiring — `StatusItemController` "History explorer"
menu item + `onOpenHistoryExplorer`, `main.swift` owns the
`HistoryWindowController`, `PopoverView.onOpenHistoryExplorer` +
settings `exportAvailable: true` routed to the explorer (per the WP-12
authorization for WP-09 wiring); (c) `Tools/perf_harness/lifecycle_main.swift`
(new, tools-only). No other production behavior changed.
