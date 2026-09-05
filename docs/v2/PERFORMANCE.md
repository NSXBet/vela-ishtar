# docs/v2/PERFORMANCE.md

<!-- WP-12 (12.2): the measured performance record for the v2.0 candidate.
     Every number below came from a command run on the WP-12 gate machine.
     No target was adjusted to pass; gaps are stated as gaps.
     RELEVANT FILES: V2_IMPLEMENTATION_PLAN.md (§6), Tools/performance_main.swift,
     Tools/perf_harness/lifecycle_main.swift, docs/v2/VERIFICATION.md -->

# Vela Ishtar 2.0 — Performance record

**Machine (baseline, all measurements):** Apple M4 Pro, macOS 26.6.2
(Build 25G32), arm64, Command Line Tools toolchain, `-O` builds pinned to
`-swift-version 5`, display scale 2x (Retina), network not exercised
(fixed fixtures). One machine, one OS build — numbers are baselines for
regression spotting, not a fleet claim.

## Core-path measurements (Tools/performance_main.swift)

Command: `swiftc -O -swift-version 5 -target arm64-apple-macos14.0
Sources/VelaCore/*.swift Tools/performance_main.swift -o /tmp/vela-perf &&
/tmp/vela-perf`. Median wall-clock over 200 iterations (2000 for warm
single-record paths) after a 10% warmup, per the tool's documented method.
Latest run on `wp12-gate` @ `3b32fa3`:

| Path | Median |
|---|---|
| `history.save` 90 days × 12 slots (cold: fresh store, encode + atomic write) | 36.86 ms |
| `history.load` 90 days × 12 slots (cold: read + decode + clean) | 1.50 ms |
| `history.record` single observation (warm, in-memory) | 0.029 ms |
| `burnbuffer.record` 1 sample (warm) | 0.044 ms |
| `paceEngine.verdict` (warm) | 0.0007 ms |
| usage JSON decode (warm, full payload) | 0.0053 ms |

Read against §6.1: the cold save dominates but runs on the actor, off the
interaction path; a single warm poll appends one observation (0.03 ms) and
the coalescer bounds on-disk writes to at most one per accepted poll — well
inside the "no synchronous disk/network I/O on the interaction path" intent.
Decode (0.005 ms) is nowhere near a poll's budget.

WP-00's earlier table (BASELINE.md) reported ~5 ms cold save; the difference
is the WP-02→WP-09 repository work (quarantine, dedup identity, markers) —
the §12.1 regression, backup-abort, and 2 MiB-coarsening tests all now run
inside that path. The load path (1.5 ms) — the one a launch pays — is
unchanged in magnitude.

## Lifecycle spot harness (500 cycles)

§6.1 asks for a 500 open/close + tab/hover cycle retention check. A real
popover cannot be opened headlessly (no `NSStatusItem` frame, no window
server session guarantees in a CLI context), so WP-12 built the closest
executable proxy: `Tools/perf_harness/lifecycle_main.swift` hosts the REAL
`PopoverView` in a hidden `NSPanel`, derives today/month display states via
the real `SummaryPresenter`, and applies them 500 times alternating
today/month (the per-cycle work of open + tab-switch), counting the subview
tree after every cycle.

Command: `swiftc -O -swift-version 5 … Tools/perf_harness/lifecycle_main.swift
-o /tmp/vela-lifecycle && /tmp/vela-lifecycle` — result on `3b32fa3`:

```
cycles applied: 500 (after 20-cycle warmup)
retained PopoverView subviews: 34 (stable == no per-cycle accumulation)
RESULT: STABLE — subview tree returns to baseline every cycle
```

The persistent-composition root (WP-06) holds: zero view-tree growth across
500 full re-derivations. **What this proxy does NOT cover:** window/panel
creation, `makeKeyAndOrderFront`, memory freed only by real teardown, and
WindowServer-side work. Those need the §12.2 soak below.

## §6.1 targets — measured status

| §6.1 target | Status | Evidence |
|---|---|---|
| Idle app CPU ≤0.2% (15-min warm idle, release) | **NOT MEASURED — needs packaged app** | WP-12-blocked (see below) |
| Closed warm footprint ≤60 MiB | **NOT MEASURED — needs packaged app** | WP-12-blocked |
| Summary+history ≤90 MiB (90-day fixture) | **NOT MEASURED — needs packaged app** | WP-12-blocked |
| Retention after 500 cycles (±5 MiB, stable counts) | **PARTIAL — lifecycle proxy executed** | 500 cycles, subview tree stable at 34 (above); footprint delta needs the app |
| Warm summary p95 ≤100 ms | **NOT MEASURED — needs click-to-paint timing** | the derive+apply work per cycle is O(subtree apply) and completes inside the harness run with no accumulated lag, but no p95 was recorded |
| Cached cold paint p95 ≤250 ms | **NOT MEASURED — needs launch timing** | WP-12-blocked |
| Tab response p95 ≤50 ms | **PARTIAL** | alternating period applies complete inside the harness loop; no instrumented p95 |
| Main-thread ≤8 ms p95 per poll | **NOT MEASURED — needs signpost capture in the running app** | `PerformanceSignposts` (WP-06) is wired for this capture |
| No app-driven repeating animation at rest | **VERIFIED by tests** | `BudgetDetailTests` cooldown single-redraw test; pill bitmap render-skip (`PillInputs` equality, StatusItemController); no display links in Sources |
| Background network 1 req/60s ±5s, one in flight | **VERIFIED by tests** | `PollCoordinatorTests` scheduling + in-flight ownership suites |
| Backoff 60/120/240/300 + Retry-After, 401/403 pause | **VERIFIED by tests** | `AIHubClientTests.ladderMatchesSpec/retryAfter120Scenario`; `PollCoordinatorTests` recovery suites |
| Local data ≤2 MiB budget, 90 days, ≤100 receipts | **VERIFIED by tests** | `HistoryRepositoryTests` 2 MiB coarsening + 90-day prune; `HistoryRepositoryMarkerTests` 100-receipt cap |

## WP-12-blocked measurement item (recorded, not invented)

The remaining §6.1 rows need the **packaged `Vela Ishtar.app` running in a
logged-in desktop session** with Instruments (Time Profiler, Allocations,
Energy Log) — cold/warm launch, 15-minute idle, open/close soak with
footprint comparison, wake cases. A CLI harness cannot produce those
numbers honestly, and §6 forbids substituting adjectives. They are
recorded in docs/v2/RELEASE_CHECKLIST.md as the coordinator's measurement
run before release sign-off. The app is built and packaged on this branch
(`make build` → exit 0) so the soak can run the actual artifact.
