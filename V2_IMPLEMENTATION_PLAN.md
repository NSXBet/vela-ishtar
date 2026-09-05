# Vela Ishtar 2.0 — Project Assessment and Implementation Plan

> **For agentic workers:** Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` when implementation is requested. This document is the master handoff: read the global constraints, shared contracts, dependency map, and assigned work package before editing. Checkboxes track future implementation, not work completed during this assessment.

**Goal:** Make Vela Ishtar an exceptionally polished, trustworthy, lightweight personal AI Hub instrument, with useful depth available on demand.

**Architecture:** Retain native AppKit, the bitmap menu-bar pill, and a small Foundation domain layer. Separate transport, credential lifecycle, time-aware observations, persistence, and presentation; update persistent views from immutable display state. Derive new features locally from validated readings without additional continuous network traffic.

**Tech stack:** Swift, AppKit, Foundation/URLSession, Security/Keychain, ServiceManagement, QuartzCore, Swift Testing; macOS 14+, Apple Silicon; no third-party runtime dependencies.

**Spec:** Sections 4–7 of this same document define the proposed product, design, resource budget, and architecture. Sections 1–3 record the existing system and assessment evidence. Sections 8–11 define execution.

**Assessment date:** 2026-09-05. **Baseline:** HEAD `241ee4a`, version `1.0.4`, plus the existing uncommitted working tree. **Status:** Proposal ready for review and subsequent orchestration; application implementation has not started. Product recommendations are proposed defaults, not a claim of user approval of every feature.

## Global constraints

- Keep macOS 14+ and Apple Silicon support. Do not raise the OS floor to obtain a new visual effect.
- Keep AppKit and zero third-party runtime dependencies. No web runtime, embedded browser, local AI model, or daemon.
- Preserve the global-budget meaning of the pill border and the separate model-cap indicator.
- Treat money, observation time, billing-day label, credential scope, and freshness as separate facts.
- A model's spend contributes to both its nested cap and the global budget; these are not separate wallets.
- A disabled global limit is unlimited; a model cap of zero is blocked. Preserve these different semantics.
- Never hardcode model names, model limits, available routes, grace amounts, or cooldown availability.
- Do not infer actual request permission from budget room alone. Routing, credential authorization, and other limits may also apply.
- No invented zeroes, completed-day totals, project attribution, model prices, or confident forecasts from insufficient data.
- No new production network destination or write operation is needed for the recommended core v2 scope.
- Default experience stays silent: no sounds, notifications, gamification, leaderboards, generated advice, or recurring attention animation.
- Honor Reduce Motion, Reduce Transparency, Increase Contrast, keyboard access, and VoiceOver.
- Do not expose tokens in logs, fixtures, screenshots, exports, the clipboard, or process arguments.
- Preserve existing uncommitted work. Do not reset, clean, or accidentally resurrect the retired snapshot subsystem.
- Measure resource use before claiming improvement. The targets in section 6 are proposed release gates, not measurements of the current app.

## Navigation

1. [What the app is and does](#1-what-the-app-is-and-does)
2. [Architecture and file map](#2-architecture-and-file-map)
3. [Assessment, bugs, and evidence](#3-assessment-bugs-and-evidence)
4. [V2 product direction](#4-v2-product-direction)
5. [Premium experience specification](#5-premium-experience-specification)
6. [Performance and resource contract](#6-performance-and-resource-contract)
7. [Target architecture and shared contracts](#7-target-architecture-and-shared-contracts)
8. [Orchestrator execution rules](#8-orchestrator-execution-rules)
9. [Implementation work packages](#9-implementation-work-packages)
10. [Release acceptance matrix](#10-release-acceptance-matrix)
11. [Agent handoff templates](#11-agent-handoff-templates)
12. [Reproduction examples and references](#12-reproduction-examples-and-references)

## 1. What the app is and does

### 1.1 Purpose and boundaries

Vela Ishtar gives NSX colleagues an ambient view of personal AI Hub spend. The dashboard requires a deliberate visit; this app keeps a small instrument in the macOS menu bar. Its useful questions are: how much has been spent, which budget is becoming restrictive, what generated the spend, and how the observed day compares with previous observations.

It is a **read-only companion to an existing gateway**, not a gateway, chat client, request proxy, billing system, or team administration tool. It does not intercept prompts, know which editor produced each request, change model routing, enforce budgets, or activate cooldowns. Backend scope and availability constrain what the frontend can truthfully promise.

The original design explicitly valued “calm assurance.” V2 should deepen this identity. The app already has visual authorship; the opportunity is not to surround it with generic dashboards.

### 1.2 Current user journeys

| Journey | Current behavior | Important qualification |
|---|---|---|
| Launch | Accessory app, no Dock icon; creates a status item and starts polling | Loads history synchronously first; token lookup can require Keychain interaction |
| First run | Secure token field, Save, Keychain explanation | Saves before validating against the gateway; no full connection-state model |
| Ambient monitoring | Pill: daily dollars, burn sparkline, global budget border | Sparkline currently represents 60 successful observations, not necessarily 60 minutes |
| Budget warning | Border changes at 50%, 75%, 90%; amount dims at 100% | Separate 4pt dot for an alarming/blocked model cap; 90% warning is not exhaustion |
| Open detail | Nonactivating floating panel with daily hero, pace, optional model cap, curve, models, week strip, footer | 320pt width; much of the view hierarchy is rebuilt on updates |
| Inspect models | Today/Month changes the models section | The hero remains daily; switching is not a whole-panel period change |
| Inspect curve/week | Hover reveals observed spend | Local hourly observations are not a server-supplied complete transaction history |
| Offline | After two failures, retained reading dims and a banner appears | Before any success, errors can remain an indefinite “Connecting” state |
| Replace token | API key link opens secure entry | Poller/history are not reset or partitioned by credential identity |
| Utilities | Right-click: copy spend, open history folder, pill size, quit | Automatic size checks window visibility; real notch coverage remains unverified |
| Start at login | ServiceManagement registration toggle | Failures and approval-required states are not explained |
| Updates | GitHub release comparison at launch/open, at most every six hours | No installation; nil result conflates unknown, failure, skipped, and current |

### 1.3 Data the code actually consumes

One authenticated request: `GET https://ai-llm-gateway.fbr.land/v1/me/usage`.

| Payload field | Use | Limit of knowledge |
|---|---|---|
| `token_id` | Decoded | Currently not used to isolate history or responses |
| `daily_budget` | Hero, global border, exhaustion, history | Earlier docs describe scopes differently; verify whether totals aggregate credentials |
| `daily_budget.spend_date` | Gateway billing-day label | Must not be confused with response receipt time or the Mac's local calendar date |
| `daily_budget.model_budgets[]` | Most urgent cap, pill dot, cooldown text | All caps arrive, but only one is displayed; no authoritative crossing timestamp |
| `current_month` | Month projection | Current models-share calculation does not use its total |
| `top_models[]` | Month model rows | Completeness, truncation, and token/user scope need a current contract |
| `today` / `today_models[]` | New working-tree support for direct daily model data | Optional fields currently collapse absence into zero/empty |

The application does **not** currently call `/v1/models`. Its `$/M` column is observed blended cost divided by all reported tokens, not a catalog price or a quality score. Its forecasts are arithmetic, not predictive models. The daily forecast currently uses total spend divided by elapsed UTC day, not the burn sparkline.

Public internet research cannot establish the private gateway's present contract. This assessment used the local source, tests, fixtures, and historical design records; it did not read the user's Keychain, query live personal usage, or access backend source. WP-00 makes unresolved contract questions explicit without blocking unrelated work.

### 1.4 Released code versus this working tree

- `Info.plist` still reports `1.0.4`; HEAD introduced nested model budgets.
- The working tree replaces `ModelSnapshots` and `TodayModelSplit` with direct `today_models` rendering in `TodayModelRows.swift`.
- Some deletions are staged; other modifications, deletions, and new files are unstaged/untracked. A branch made only from HEAD will miss material app behavior assessed here.
- README still describes daily differencing, a delayed week strip, ad-hoc-only signing, and 285 tests. Current code uses direct daily data, shows sparse weeks when fresh, supports a stable local signing certificate, and the observed test run reports 251 tests.
- Historical specs contain superseded SwiftUI, animation, API-key-copy, and architecture proposals. They are historical context, not instructions to restore old behavior.
- The dated nested-budget spec contains useful previously approved semantics. In particular, do not silently reverse its border/dot meanings or cooldown rules while restyling.

## 2. Architecture and file map

### 2.1 Current data flow

```text
AppDelegate (main.swift)
  ├─ KeychainStore → AIHubClient → UsagePoller (60s, wake, open)
  │                                └─ PollStateMachine
  │                                     ├─ last good response / failure count
  │                                     ├─ BurnBuffer (memory only)
  │                                     └─ HistoryStore (hourly JSON)
  ├─ StatusItemController ← PollState + BurnBuffer
  ├─ PopoverPanel → FirstRunView OR PopoverView
  │                              ├─ PaceEngine / ModelBudgetSignal
  │                              ├─ CurveView / CurveScrub
  │                              ├─ TodayModelRows / ModelShare
  │                              ├─ DayStripView / DayStrip
  │                              └─ PeriodSwitcher / footer
  └─ UpdateChecker → ReleaseChecker / VersionCheck
                      └─ UpdateBellView + VersionBulletView / WhatsNew
```

Successful polls update the state machine, record observations, render the pill, save history, and rebuild the detail view if open. Failed polls retain the last good response. The UI is main-actor isolated. HTTP completion is dispatched to main and then wrapped in another main-actor task. History encoding and writes occur on that same UI path.

### 2.2 Complete production-source inventory

Current production Swift source totals **7,195 lines including comments**, across 31 files. Size alone is not a performance measurement.

| File under `Sources/` | Responsibility | V2 disposition |
|---|---|---|
| `App/main.swift` | App lifecycle, auth recovery, panel selection, poll/render wiring | Retain entry; extract coordinator and credential lifecycle |
| `App/AIHubClient.swift` | Request construction, token lookup, HTTP decode | Inject transport/credential access; validate responses and classify errors |
| `App/UsagePoller.swift` | Timer, in-flight boolean, unauthorized callback | Cancellable, time-aware scheduler with request generations |
| `App/KeychainStore.swift` | Security framework wrapper | Preserve; propagate absence versus denial/lock/error |
| `App/StatusItemController.swift` | Pill geometry, bitmap drawing, size menu, utility actions | Preserve signature; narrow display-key invalidation and safe formatting |
| `App/PopoverPanel.swift` | Window anchoring, material, show/dismiss animation, event monitors | Preserve native behavior; stable geometry, explicit presentation lifecycle |
| `App/PopoverView.swift` | 1,206-line layout/render/controller mixture | Extract sections and a presenter, retain a small composition root |
| `App/FirstRunView.swift` | Token-entry controls | Add candidate validation, errors, cancellation, field cleanup |
| `App/CurveView.swift` | Chart drawing, scrubber, child readout, reveal/ring | Timestamp-aware segments; stable hover; accessible alternative |
| `App/DayStripView.swift` | Week cells and hover window | Persistent selection and drill-down into history |
| `App/PeriodSwitcher.swift` | Custom tabs and indicator | Persistent control; immediate data response; keyboard semantics |
| `App/UpdateChecker.swift` | Defaults, release scheduling/cache | Explicit checked/unknown/failed/skipped/current states |
| `App/UpdateBellView.swift` | Update status/card/commands | Accessible control; stable card; no replayed attention motion |
| `App/VersionBulletView.swift` | Changelog hover card | Accessible click/keyboard route; share secondary panel treatment |
| `VelaCore/Models.swift` | Codable wire types; ISO parsing and day labels | Keep wire layer; add validated domain conversion and availability |
| `VelaCore/AIHubClientProtocol.swift` | Callback protocol and fetch error enum | Move to cancellable transport contract; preserve fake-client seam |
| `VelaCore/PollStateMachine.swift` | Fresh/stale transitions, history/burn aggregation | Explicit freshness/auth scope; pure state transitions |
| `VelaCore/HistoryStore.swift` | Day/hour storage, migration, filtering, atomic saves | Versioned timestamp-aware storage; separate I/O actor |
| `VelaCore/GatewayDay.swift` | Normalized billing-day identity | Central calendar helpers; strict validation |
| `VelaCore/BurnBuffer.swift` | Difference cumulative reads into up to 60 slots | Timestamped interval deltas; gaps and day changes explicit |
| `VelaCore/PaceEngine.swift` | Forecast, exhaustion wording, medians, month estimate | Evidence-aware forecasts; no false reassurance |
| `VelaCore/ModelBudgetSignal.swift` | Model cap states, urgency, display names, narrative | Retain semantics; expose all applicable caps and headroom |
| `VelaCore/TodayModelRows.swift` | First four named rows plus residual | Validate sums and distinguish data availability/scope |
| `VelaCore/ModelShare.swift` | Safe percentage arithmetic | Reuse safe arithmetic with correct period denominator |
| `VelaCore/BorderDash.swift` | Border perimeter, fraction, warning thresholds | Preserve and regression-test the visual language |
| `VelaCore/CurveScrub.swift` | Nearest observation, x-coordinate, local-hour text | Add actual date/time/precision; guard invalid geometry |
| `VelaCore/DayStrip.swift` | Monday–Sunday frame, totals, intensity | Label observed totals and coverage; no implied complete days |
| `VelaCore/FooterLayout.swift` | Measured footer and budget-row geometry | Simplify footer after settings move; reuse useful geometry rules |
| `VelaCore/ReleaseChecker.swift` | Six-hour policy plus GitHub network request | Separate transport outcome from display decision |
| `VelaCore/VersionCheck.swift` | Version comparison and release JSON | Validate usable releases and allowed destination URLs |
| `VelaCore/WhatsNew.swift` | Bundled changelog parsing/filtering | Keep, test actual build output |

### 2.3 Build, tests, persistence, and distribution

- `Package.swift`: Foundation library and `VelaCoreTests` only; AppKit application code is outside the package test graph.
- `Makefile`: test framework paths for Command Line Tools, build/run/release, README version/test badge rewriting.
- `build.sh`: bare optimized `swiftc`, one combined App/Core module, arm64 macOS 14 target, bundle resources, signing. It removes the existing build app before rebuilding; use a scratch destination during non-destructive audits.
- `Info.plist`: version, bundle identity `com.nsxbet.velaishtar`, accessory-app flag, platform floor.
- `Tools/snapshot_main.swift`: synthetic rendering utility; writes some assets into `docs/assets`, so it needs an explicit output directory for safe automated use.
- `Tests/VelaCoreTests`: 17 current suites covering arithmetic, DTOs, history, state, row folding, releases, and layout helpers. There is no checked-in automated app-lifecycle/UI suite or performance gate.
- `history.json`: `~/Library/Application Support/VelaIshtar/`; at most 90 day records after recording/pruning. Each record has 24 optional cumulative values, one limit, and optional observed exhaustion time. No per-sample timestamp, scope identifier, completion guarantee, or persistent per-model timeline.
- UserDefaults: pill size and update metadata. Keychain: one gateway token. No application telemetry or backend owned by this repo.
- `docs/`, README, changelog: product history and developer instructions. `.claude/worktrees`, `.pi-subagents`, `.superpowers`: local agent/worktree artifacts, not application runtime components. `build/`, `.build/`, and ZIP files are generated artifacts, not architectural dependencies.
- Distribution is manual release packaging plus a separate private Homebrew tap. Stable local signing helps identity continuity; it is not Developer ID notarization.

### 2.4 Existing work worth preserving

The bitmap-based pill and removal of appearance-observer feedback solved a documented CPU/memory spiral. Hover equality guards reduce redundant redraws. UTC label normalization, model-cap validation, zero-limit semantics, disabled-limit handling in core calculations, bounded history, atomic writes, and deterministic selectors are valuable foundations. V2 should protect these with integration coverage, rather than rewrite everything.

## 3. Assessment, bugs, and evidence

### 3.1 Verification performed

- Read all current production source files, build configuration, relevant tests, historical specs, changelog, current diff, and snapshot tooling; inspected existing visual assets. Existing README popover images represent older states and are not a fresh live screenshot.
- Ran `make test`: **251 tests in 17 suites passed**. Initial sandbox cache failures disappeared when the same test command could access compiler caches; they were not treated as project test failures.
- Compiled the complete app with its production optimization, target, and frameworks into `/tmp/vela-v2-audit/VelaIshtar`: **exit 0**, with a concurrency warning in `PopoverPanel.swift:324` about `dismissGeneration` in a Sendable completion closure.
- Ran a temporary Foundation probe against the actual source for the midnight seam, scope mixing, stale/early forecasts, row over-attribution, irregular sampling, and large numeric payload acceptance. Reproducible examples are preserved in section 12.
- Ran an offline AppKit view harness using synthetic data: reproduced the disabled-limit hero contradiction, obsolete daily-breakdown fallback, and incorrect Month shares (60%/40% for $300/$200 out of $1,000). The harness rendered view state without opening a production session or reading credentials.
- Did not install or run the production app against personal credentials, conduct a multi-hour resource profile, verify a live gateway contract, validate release access, or test every hardware/accessibility configuration. Passing unit tests cannot prove those behaviors.

### 3.2 Severity definitions

**P0 critical:** demonstrated broad credential compromise, destructive remote behavior, or unavoidable failure for normal use. **None established by this assessment.**

**P1 major:** data loss, scope isolation failure, or a reachable process crash under specified inputs. **P2:** incorrect information, impaired recovery/accessibility, responsiveness defects, or material engineering risks. **P3:** lower-impact presentation/documentation issues.

“Reproduced” means an executable probe or existing test demonstrated the behavior. “Source-confirmed” means a concrete code path establishes it, with end-to-end validation still required. “Conditional” identifies an external/input condition not demonstrated in a live deployment.

### 3.3 Findings register

| ID | Priority / evidence | Trigger, result, and cause | Package |
|---|---|---|---|
| B01 | **P1, reproduced** | Gateway day remains Aug 1 after UTC midnight; spend grows 120 → 160 → 165. `HistoryStore.record` writes 165 into hour 0 before hours 22/23. `load` sees a chronological decrease in array order and deletes the entire day. The existing seam test only covers a downward/reset reading, not valid growth. See `HistoryStore.swift:84–125,222–253`. | WP-02 |
| B02 | **P1, reproduced core; lifecycle source-confirmed** | Feed token A's $100 then token B's $20 into the same machine: UI response becomes B while history still contains A and rejects B as a downward restatement. `tokenId` never partitions history; token replacement never resets the machine. An old in-flight response can also arrive after replacement because requests have no credential generation/cancellation. See `PollStateMachine.swift:130–139`, `main.swift:217`, `UsagePoller.swift:77–100`. | WP-03 |
| B03 | **P1 conditional crash; input acceptance reproduced** | Valid JSON `used_percent: 1e100` decodes successfully. Pill accessibility/copy executes `Int(budget.usedPercent.rounded())`; chart ceiling similarly converts `limit`. Finite values outside Int range trap. No live malformed gateway response was observed. ModelShare's safe conversion does not protect these paths. See `StatusItemController.swift:177,249`, `CurveView.swift:226`. | WP-01 |
| B04 | **P2, reproduced** | Stale $200/$400 and first-30-seconds $399/$400 both produce “On pace to stay under budget today.” Unavailable projection is encoded as an ETA at midnight, which sentence generation treats as a safe forecast. See `PaceEngine.swift:65–80,132`. | WP-04 |
| B05 | **P2, source-confirmed** | Errors before the first success leave `.neverFetched`; normal UI stays Connecting indefinitely. Freshness otherwise depends on failure count rather than elapsed age; sleeping/hung requests can retain a “fresh” old reading until failures accumulate. Errors are reduced to generic unreachable copy. See `PollStateMachine.swift:142`, `main.swift:72`, `PopoverView.swift:120`. | WP-03, WP-04 |
| B06 | **P2, source-confirmed** | Unauthorized callback opens and activates token entry, which immediately rearms its own latch. A dead token can reopen the prompt each timer cycle, including after Cancel. No explicit recovery acknowledgment state exists. `KeychainStore.readStatus` can distinguish errors, but app callers use `read() == nil` and treat errors as absence. | WP-03 |
| B07 | **P2, reproduced** | Today model costs $80+$70 with daily total $100 render $150 of named rows. Negative residual is merely omitted. Missing daily fields become empty/zero, and fallback still says “Per-model breakdown is monthly only,” even with the new API support. See `TodayModelRows.swift:54–75`, `Models.swift:72–78`, `PopoverView.swift:800`. | WP-01, WP-07 |
| B08 | **P2, reproduced in AppKit harness** | Month shares divide by the sum of `top_models`, not `current_month.totalCostUSD`. When rows are truncated, displayed shares overstate their contribution. Example: top models $300+$200 of $1,000 show 60%/40% instead of 30%/20%. Hero remains daily, so the month total has no matching headline. See `PopoverView.swift:311`. | WP-01, WP-07 |
| B09 | **P2, reproduced** | A $10 delta over one minute and over eight hours produce equal `BurnBuffer`s: the `date` argument is unused. Opening detail also polls, so frequent opens compress the supposed hour. Downward restatements can cause later increases to double-count apparent burn. See `BurnBuffer.swift:35–50`. | WP-04 |
| B10 | **P2, source-confirmed** | Every detail update removes/recreates its controls and ancillary cards. Period changes deliberately wait 210ms. Curve removal sets `pendingScrubRestoreX`, then `clearScrub()` immediately erases it, defeating intended hover restoration. Polls can close the update card and replay its animation. See `PopoverView.swift:102,1181`, `CurveView.swift:464–491`. | WP-06, WP-07 |
| B11 | **P2, hero reproduced in AppKit; chart source-confirmed** | No-limit hero still shows “of $400 today” and chart still draws the configured $400 ceiling because `limitEnabled` is not passed into those renderers. Core verdict/border correctly know the budget is disabled, yielding contradictory surfaces. | WP-01, WP-07 |
| B12 | **P2, source-confirmed; deployment condition unresolved** | Any nil `pendingRelease` produces “up to date,” including never checked, failed fetch, or skipped newer version. Historical docs call the repo private, while release checks are unauthenticated. If still private, ordinary clients cannot obtain releases from this endpoint. See `UpdateChecker.swift:49–58`, `UpdateBellView.swift:209–225`. | WP-11 |
| B13 | **P2, source-confirmed** | History load/save errors are discarded. A corrupt file can appear as no history; later saves can overwrite it. File work runs in the main-actor state callback and at launch. First-file saves and ordinary round trips do pass existing tests; do not invent a first-save failure. | WP-02, WP-06 |
| B14 | **P2, source-confirmed accessibility gap** | Chart/week details are mouse-driven; bell/version custom NSViews advertise button roles but provide no explicit accessibility press implementation. Pill accessibility/copy omit stale state and unlimited semantics. Precise keyboard/VoiceOver failure impact requires UI testing. | WP-07, WP-10 |
| B15 | **P2 accuracy gap, source-confirmed** | Curve joins all non-nil samples and starts from an artificial zero; it visually bridges observation gaps. A week “total” is just the last observation, possibly hours before day end. Exhaustion time is first observed, not exact. Hourly cached age uses slot start, not actual receipt time. | WP-02, WP-04, WP-09 |
| B16 | **P2 engineering risk, warning observed** | Core uses SwiftPM's Swift 6 language mode; bare app build does not explicitly select that mode. Complete app compilation emits an actor-isolation warning. Pure-core tests cannot detect app integration warnings, credential races, or window lifecycle faults. | WP-00, WP-06, WP-12 |
| B17 | **P3, source-confirmed** | README/version assets and comments contradict current behavior. The latest changelog lacks the expected summary paragraph; the extraction script can ship the first Markdown bullet as its one-line note. Tiny 7–9pt chart/status text and dense footer constrain legibility. | WP-07, WP-11, WP-12 |

### 3.4 Explicit investigation items, not established bugs

- Automatic pill sizing uses `window.isVisible`, not actual notch intersection. Test on hardware before claiming the current implementation solves or fails every notch case; avoid continuous screen polling as a fix.
- Background/hidden window retention and child panels need Instruments measurement. Whole-view reconstruction is observable, but an unbounded memory leak was not demonstrated here.
- Cooldown expires according to wall time only when a render happens. A single scheduled expiry invalidation can improve accuracy; do not add a one-second timer.
- `medianSpend` and `ghostCurve` choose recent stored records, exclude only equality with today, and can include future records. Scope/date validation should reject future/inconsistent history and distinguish 14 recorded days from 14 calendar days.
- A mid-day cap override makes the one `exhaustedAt` timestamp ambiguous. Preserve policy context and use observed wording; do not present it as an authoritative gateway event.
- Existing time labels force a 12-hour clock and “resets at midnight” is ambiguous outside UTC. Correct explicit reset-local-time wording belongs in v2.

## 4. V2 product direction

### 4.1 Alternatives considered

| Approach | Strength | Cost/risk | Decision |
|---|---|---|---|
| Refine the native instrument, reveal depth on demand | Keeps immediate recognition and low idle cost; substantial usability gains | Requires disciplined information hierarchy and reliable data semantics | **Recommended** |
| Always-visible analytics cockpit | More information without navigating | More visual noise, more controls, greater chance to duplicate the dashboard | Keep deeper inspection in an on-demand history surface |
| Team/admin platform or AI advice layer | Larger apparent feature set | Needs new authorization/backend scope; undermines personal trust and lightweight operation | Exclude from v2.0 |

**Product promise:** “See your spend, understand the budget that matters, and inspect what changed — instantly.”

Premium means confident typography, readable information, predictable focus, stable geometry, honest states, and immediate feedback. It does not require elaborate animation. The ambitious improvement is that the app becomes trustworthy enough to rely on throughout a workday.

### 4.2 Recommended signature features

#### F01 — Budget headroom, with all applicable caps

The summary retains global dollars and the most urgent model signal. Clicking the budget row opens a compact detail surface listing every returned model cap: observed spend, cap, remaining room, enforcement/cooldown state, and the billing reset in local time with UTC available in detail.

Where both constraints are enabled and current, model headroom is `max(0, min(globalRemaining, modelRemaining))`. During an active model cooldown, use global room while explicitly marking the model cap as temporarily relaxed. A blocked model has zero model room; a disabled global limit contributes no bound. Validate negative/invalid figures before computing.

This answers a real confusion: a global $400 budget can have plenty left while one $20 model cap is exhausted. Do not promise “this model is available” from budget data alone, recommend unspecified alternatives, treat headroom as a guaranteed number of requests, or offer cooldown activation without a verified write contract. Use “Budget room” and “Other limits may apply” in detail when necessary to explain the value, not a recurring warning banner.

**Distinctiveness:** useful explanation of nested policy, with no network cost beyond existing reads. **Owner:** WP-08.

#### F02 — Spend since a marker

“Start a marker” captures a fresh cumulative reading. The user can optionally name it, for example “Refactor experiment.” Subsequent accepted readings show the delta and elapsed wall time; “Finish” creates a small local receipt with start/end observation times, scope, amount, and coverage caveats.

This is deliberately **all observed spend in that scope during the interval**. It cannot attribute costs to an editor, project, prompt, or selected application. Background usage contributes too. A marker has no extra polling loop or request interception.

For v2.0, a billing-day change, credential change, material downward correction, or unavailable comparable baseline ends comparability: show a partial receipt or request a fresh start, not a guessed cross-boundary delta. Offline intervals can retain a day-cumulative delta after recovery within the same scope/day, but cannot claim a per-minute activity breakdown. Starting/finishing while stale requires a successful read or an explicitly labeled last-observed boundary.

**Distinctiveness:** makes experiments legible without pretending to be a cost profiler. **Owner:** WP-09.

#### F03 — An honest local history explorer

Click a week cell or “History” to open a lazily created native utility window. Show a selectable 30-day calendar within retained 90-day history, one selected day curve, last-observed amount, first/last observation, and coverage quality. Distinguish zero, no observation, partial day, legacy hour precision, and current in-progress day.

Allow exporting a selected range as CSV containing billing day, observation time, precision, amount, and coverage. Missing values stay empty, never zero. Export contains no token identifier or credential. Older data remains available under its explicit scope, without automatically combining accounts.

No permanent secondary process, polling loop, aggregate “savings score,” or pretend complete monthly accounting. The authoritative current-month total and incomplete local history remain visibly different sources.

**Distinctiveness:** useful retrospective inspection that tells the truth about what the laptop actually observed. **Owner:** WP-09.

### 4.3 Quality-of-life features included

- A single secondary settings surface: credential connection status, start-at-login state, pill size, launch behavior, and data/export controls.
- Local keyboard commands while the app has focus: Escape closes, Today/Month selection, refresh, copy with freshness context, and History. Do not install a global key monitor by default.
- Explicit refresh feedback with coalescing; opening the panel should not issue a redundant request immediately after a successful poll.
- “Observed blended $/M” explanation on demand; long model IDs available by tooltip/accessibility or copy, without clipping the cost.
- A precise connection-status disclosure: last successful observation, checking/retrying, expired credentials, denied Keychain access, unsupported response, persistence problem.
- Update status that admits “not checked” or “couldn't check,” and clean update instructions appropriate to the install channel.

### 4.4 Ranked follow-up ideas; do not implement automatically

| Idea | Value / cost | Why defer or reject |
|---|---|---|
| Hide dollar amounts for screen sharing | Useful, low cost | Optional v2.1; must cover pill, popover, accessibility, copy, and export consistently. Minimal pill mode already exists and is not a new feature |
| User-selected global shortcut | Useful, medium integration cost | Validate shortcut conflicts and OS approach; no continuous key observation |
| Personal soft spending target | Useful to some, medium semantics cost | Separate from enforced limits; validate demand first |
| Opt-in threshold notification | Potentially useful, medium policy/lifecycle cost | Silent product default; needs deduplication, permission, and stale-data rules |
| Compare two selected days | Useful after timestamp-aware history | Add after basic history accuracy/coverage is proven |
| Model catalog / actual route pricing | Useful with verified API | Extra endpoint/cache lifecycle; observed blended costs cannot substitute for list pricing |
| Automatic model recommendations | Low trust with current data | Costs alone say nothing about task quality, context limits, or authorization; reject |
| Native cooldown activation | Potential convenience; sensitive write | Backend contract and explicit product choice required; reject for core read-only v2 |
| Team leaderboard / manager reporting | Conflicts with personal instrument | Requires admin authorization, new backend access, and separate product scope |
| Widgets, cloud sync, multi-provider support | Larger maintenance/resource surface | Separate later projects; not needed to deliver this v2 |

## 5. Premium experience specification

### 5.1 Visual language

Retain the pill silhouette and border. Use SF system typography, tabular monetary digits, consistent baselines, generous but purposeful spacing, semantic system colors, a subtle native material, and one consistent secondary-panel treatment. No decorative gradients, moving backgrounds, glows, ornamental charts, fake depth, mascot, or AI-sparkle branding.

Proposed tokens for the design fixture: summary width **360pt**, content inset **20pt**, spacing scale **4/8/12/16/24pt**, hero **30pt semibold tabular**, body **13pt**, secondary information **11–12pt**, section labels **11pt medium**, controls at least **24pt high**. Use 32pt rows where practical. Essential status/error text must never be 8pt. These are design defaults; WP-05 validates long-content fixtures before freezing them.

Hairlines use the hosting window's backing scale. Dynamic `NSColor` values must be re-resolved when appearance changes, including layer-backed colors. Provide an opaque material fallback under Reduce Transparency and stronger separators/text under Increase Contrast. Validate actual contrast on both surfaces rather than multiplying every child by 0.55 indiscriminately.

### 5.2 Summary structure

```text
┌──────────────────────────────────────────────┐
│ TODAY                              Settings  │
│ $54.51                                      │
│ $345.49 remaining of $400                    │
│ Latest observation · 12:31                   │
│                                              │
│ Opus 5 · $1.20 budget room               ›   │
│──────────────────────────────────────────────│
│ TODAY'S OBSERVATIONS                          │
│ [observed curve; gaps remain visible]         │
│ Comparison available only with enough history │
│──────────────────────────────────────────────│
│ MODELS                        Today  Month   │
│ Scope + period total                         │
│ Name                      Cost    Share      │
│ [up to five stable rows / honest empty state] │
│──────────────────────────────────────────────│
│ M     T     W     T     F     S     S         │
│ History       Start a marker     Dashboard ↗ │
└──────────────────────────────────────────────┘
```

This is a hierarchy sketch, not a pixel-approved mockup. Exact live costs are fixtures. The view model supplies truthful state-specific wording; do not hardcode the example's model or values.

Keep the daily hero daily. Place the selected models period's total directly in the models section. Cost and share remain visible; move the poorly explained blended $/M metric into row detail when three compact columns compromise legibility. Display names use one shared formatter; provider/route IDs remain accessible on demand.

### 5.3 State and interaction requirements

- Loading, live, stale, retrying, authentication-required, Keychain-blocked, no-limit, no-spend, missing-model-data, and invalid-response states each have distinct copy and an appropriate next action.
- Ordinary polls, tab changes, row-count changes, freshness changes, and cap presence changes keep the summary's outer geometry stable. Use reserved status/cap slots with meaningful neutral content, not unexplained blank holes. On small visible frames, constrain height and scroll the content region.
- The first cached paint must not call old data live. Legacy hour precision should read “Observed during 12:00–12:59,” not an invented exact age.
- Standard mouse opening remains nonactivating. Keyboard invocation explicitly grants keyboard focus; returning to the prior app and Escape behavior must be tested.
- Tab content updates immediately; a 120–160ms indicator animation can follow independently. Remove the intentional 210ms wait before displaying data.
- Opening uses at most a short opacity/translation transition. Do not animate the window's width/height or redraw its entire hierarchy for each animation frame.
- Charts remain still between meaningful changes. Remove the sonar introduction; show interaction through a subtle hover/focus state. No repeated bell animation on each poll or hover exit.
- Open model detail, history selection, chart hover, update card, and keyboard focus survive background refreshes when their underlying identity still exists. If an item disappears, move focus predictably and explain the state.
- “Reset” shows the next documented billing reset as local date/time, with UTC in detail. A stale or inconsistent day does not receive a confident live forecast.

### 5.4 Craft review fixtures

Validate fresh/empty/cached/stale/auth/error states in light, dark, high contrast, reduced transparency, and reduced motion. Include no-limit, zero model cap, multiple simultaneous blocked/relaxed caps, $9,999.99 and larger values, very long model routes, one/five/missing model rows, month tail, unavailable breakdown, old billing day, and 1x/2x displays. Real window tests cover the notch, display reconnect, Spaces/fullscreen, first click, fast reopen, mouse hover through a poll, and keyboard-only navigation.

## 6. Performance and resource contract

The first optimization is fewer unnecessary operations, not a faster animation. Current costs to investigate are synchronous Keychain reads on UI entry/poll, JSON work on main, full detail rebuilding, repeated date formatting/derived calculations, unchanged-input pill redraws, and window-frame animation. Do not micro-optimize tiny arrays without measurement.

Apple recommends limiting main-thread work, reducing timers, and measuring energy usage. These support the approach; the numeric budgets below are this project's proposed targets, not Apple's guarantees. See [Apple's energy best practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html).

### 6.1 Proposed release targets

| Measurement | Target and method |
|---|---|
| Idle app CPU | Mean ≤0.2% of one CPU core during a 15-minute warm idle run, summary closed, 60s polling, release build; report network environment and spikes separately |
| Closed warm physical footprint | ≤60 MiB after two-minute warm-up; use the same physical-footprint metric across comparisons, not an RSS/footprint mixture |
| Summary + history footprint | ≤90 MiB for the standard 90-day fixture; no continuing slope after repeated use |
| Retention after interaction | After 500 open/close and tab/hover cycles and 60s settling, footprint within 5 MiB of post-warm baseline, with stable app-owned window/observer/timer counts |
| Warm summary response | p95 first useful paint ≤100ms from click across 100 opens; any animation must not delay useful content |
| Cached cold paint | p95 ≤250ms from application launch callback to cached content/status ready, excluding an OS credential prompt |
| Tab response | p95 new model content ≤50ms after action; no forced animation delay |
| Main-thread work | Per-poll presentation application ≤8ms p95 on baseline hardware; zero synchronous Keychain/disk/network I/O on the interaction path |
| Rendering at rest | No app-driven repeating animation/display link; no view work while hidden except discrete pill/status changes |
| Background network | One usage request per 60s ±5s in healthy normal mode; one in flight; update check no more than every six hours unless explicitly requested |
| Error/backoff network | Network/5xx retries 60/120/240/300s capped, respecting Retry-After; 401/403 pause normal polling until explicit recovery |
| Local data | 90 billing days, ≤1 MiB normal history fixture; ≤2 MiB hard serialized-store budget with bounded observations; at most 100 marker receipts |

Record baseline hardware, OS, build mode, fixture, display scale, polling/network condition, and measurement tool. Run benchmarks with the same fixture and machine before/after. Profile app and WindowServer activity; report OS-wide display overhead separately. Never “pass” by disabling the feature under test or silently lowering freshness. If a target is infeasible on supported systems, the orchestrator records evidence and proposes a revised budget; agents cannot unilaterally inflate it.

### 6.2 Scheduling policy

- Retain normal 60-second polling; no extra polling for markers or open history.
- Coalesce requests on launch/open/wake. An open within 15 seconds of a success paints cached fresh state without another request. Explicit Refresh can request again, bounded by a five-second action debounce and one in-flight operation.
- Suspend normal polling during actual system sleep. On wake immediately mark old observations by age and request once. Screen lock/display sleep/Low Power Mode are measured policy inputs, not permission to silently lose all workday history.
- Optional relaxed cadence after prolonged unchanged usage is a later experiment; do not ship it before confirming alert latency and explicitly representing coarser observations.
- Schedule cooldown expiry as a one-shot invalidation. While visible, age text updates only when its displayed minute changes; cancel that display timer on close. No hidden per-second countdown.
- A stalled/backed-off request must not delay the 90-second freshness expiry. The coordinator schedules the earliest next poll, freshness boundary, or policy expiry, coalescing deadlines where possible rather than adding one timer per cap.
- I/O actor coalesces history writes, at most one ordinary write per accepted poll, with bounded flush on termination. An in-progress write must not overwrite a newer revision.

## 7. Target architecture and shared contracts

### 7.1 Boundaries

```text
CredentialController → UsageTransport → PollCoordinator
                                           │
                                  validated UsageSnapshot
                                           │
                           ObservationStore (pure domain)
                              │                    │
                        HistoryRepository     Budget/Pace/Marker engines
                         (I/O actor)                │
                              └────────────── SummaryPresenter
                                                  │
                                    immutable display state
                                  ┌───────────────┴───────────────┐
                            bitmap pill                    persistent AppKit UI
```

Keep the system proportionate. Do not create an event bus, plugin framework, generalized dependency injection container, or protocol for every label. Protocols belong at side-effect boundaries needed for deterministic tests.

### 7.2 Data contracts to freeze in WP-00

These names and semantic rules are the coordination boundary. WP-00 writes their concrete Swift declarations and fixture examples before dependent agents start; producers own definitions and consumers do not rename them independently.

| Contract | Required fields / behavior | Producer |
|---|---|---|
| `UsageScope` | Opaque non-secret local identifier, scope kind (`credential` or verified `account`), gateway origin. Never persist the token as identity. Without an account ID, isolate by returned token ID through an opaque mapping | WP-00/WP-03 |
| `UsageSnapshot` | Validated response, scope, receivedAt, `GatewayDay`, model-data availability, schema warnings. Raw DTO defaults cannot masquerade as domain facts | WP-01 |
| `ModelBreakdownState` | `available(rows, total, scope)`, `empty`, `unavailable(reason)`, `inconsistent(reason)`; raw field absence survives decoding | WP-01 |
| `Observation` | Stable ID, scope, gateway day, receivedAt, cumulative amount, enabled-limit/policy context, precision (`exactReceipt` or `legacyHour`); receivedAt is observation time, not transaction time | WP-02 |
| `HistoryEnvelope` | Schema version 2, revision, scoped day records, bounded observations, coverage metadata; version 1 backup retained during migration | WP-02 |
| `ConnectionState` | `noCredential`, `keychainBlocked`, `connecting`, `live`, `retrying`, `stale`, `authenticationRequired`, `invalidResponse`; retains last good snapshot separately | WP-03 |
| `Freshness` | Derive from receipt age, explicit invalidation, and request result; fresh for at most 90s, then stale; authentication errors immediately invalidate current trust | WP-04 |
| `BudgetOverview` | Global policy, deterministically sorted model signals, per-model budget headroom, reset description, freshness; no unsupported availability promise | WP-08 |
| `SummaryDisplayState` | Equatable section states, stable row IDs, selected model period and its scoped total, freshness/accessibility text; no Keychain/network reads while constructing/applying | WP-06 |
| `MarkerReceipt` | ID, optional ≤80-character name, scope, start/end day and observation, delta or explicit unavailable reason, precision/coverage | WP-09 |

Suggested transport shape for the contract-owning agent:

```swift
public protocol UsageTransport: Sendable {
    func fetchUsage(token: String) async throws -> UsageResponse
}

public enum RefreshReason: Sendable {
    case launch, scheduled, opened, manual, wake, credentialChanged
}

// Main-actor coordinator public surface:
// start(); stop(); refresh(reason: RefreshReason)
// setCredentialGeneration(_ generation: UInt64)
// Every request captures generation; only matching results may commit.
```

Token parameters remain in memory only. No token inside display states, errors, history, OSLog interpolation, or task names. Cancellation plus generation checks are both necessary: cancellation is cooperative and cannot alone protect against late callbacks.

### 7.3 History migration policy

- Read the legacy dictionary without changing it; make a byte-preserving backup before writing schema 2. Validate bounds before allocating or indexing.
- Legacy hourly values retain hour-level precision; do not fabricate exact receipt timestamps. Preserve questionable records in a quarantined/legacy section with an explanation, not irreversible deletion.
- Without a proven legacy account identity, keep legacy history as an unassigned archive. Do not silently attach it to the next credential or include it in personal comparisons. A later explicit user association can be added separately.
- For new reads, keep gateway day and actual receipt time independently. Chart order follows observation time within the declared billing day; an after-midnight observation must not overwrite that day's earliest hour.
- Bound storage by retaining the latest ordinary observation per five-minute bucket plus necessary first/last, policy-change, and marker boundary observations; cap each day at 320 observations and retain at most 90 days per active history policy within the overall serialized limit. If multiple archived scopes exceed the global limit, prune oldest records globally while preserving an explicit export opportunity in data controls; never allow silent unbounded growth.
- Store shared scope/day metadata once, and policy context by reference within a day, rather than duplicating a large object per sample. Check encoded size before commit; coarsen the oldest ordinary observations before removing complete old records, preserving marker boundaries and honest coverage metadata. The 2 MiB limit covers active version-2 history; keep at most one separate byte-preserving legacy migration backup and report its size in data controls. If exceptional marker/policy boundaries exceed a day's cap, preserve them in bounded receipt/policy records and report the reduced chart resolution.
- Keep a separate bounded in-memory buffer of all accepted readings from the last 60 minutes (maximum 800 readings under the five-second manual-refresh debounce) for recent-rate calculation. Five-minute on-disk coalescing must not silently reduce an active session's forecast samples. After relaunch, projections remain unavailable until the restored and new samples meet the same coverage gates.
- On a late old-day response, store it under that day and mark its timing; the UI must not call it current-day live data. On a downward correction, mark a discontinuity and reset comparable burn/marker baselines; do not invent a negative burn or erase the day.
- Load failures retain the original file and produce a recoverable storage status. Atomic saves use a serial writer with revisions. Startup can show a lightweight connecting state while loading, then apply the cache.

### 7.4 Forecast and coverage policy

Freshness and confidence are independent. A successfully fetched total can still be insufficient for a forecast. Use a separate `insufficientEvidence` result, not a fake midnight ETA.

For v2.0's optional recent-pace sentence, require same scope/day, fresh observations, at least ten minutes of continuous coverage and six readings, no gap over 150 seconds, and no correction in the selected 30-minute window. Compute the observed rate over the actual elapsed interval and explicitly qualify it as “At the recent pace.” Suppress the sentence after long gaps, on day mismatch, when idle, or when the estimate would exceed the billing reset. In the latter case show factual remaining room, not a guarantee of safety.

Medians use eligible past billing days in the previous 14 **calendar** days, at least five with comparable time coverage. Never use future, unassigned legacy, or different-scope records. An incomplete history must not imply a complete month. Preserve the authoritative month amount; any projection is labeled an estimate and omitted when period boundaries/scope are uncertain.

## 8. Orchestrator execution rules

### 8.1 Starting safely

1. Read this entire document and inspect the live working tree. This plan is tied to the assessment baseline, not a guarantee the folder has remained unchanged.
2. Preserve staged/unstaged/untracked changes and record a recoverable checkpoint with the user's normal source-control workflow. Do not create implementation worktrees from HEAD alone and lose the direct-daily-data work.
3. Start with WP-00. Its unresolved backend questions receive safe fallback behavior; backend research must not hold up source-confirmed fixes or fixture-driven design.
4. Use an integration branch such as `codex/vela-v2`. Each agent gets the accepted baseline, its dependency artifacts, and exclusive edit ownership for a reviewable task.
5. Split implementation into the task units below. Commit/review each coherent deliverable; do not create one enormous “v2 rewrite” diff.

### 8.2 Dependencies and safe parallelism

| Wave | Packages | Coordination rule |
|---|---|---|
| 0 | WP-00 | Orchestrator owns contracts, baseline and test harness |
| 1 | WP-01, WP-02, WP-05 | Domain validation, storage, and design fixtures can run independently after contract freeze |
| 2 | WP-03, WP-04, WP-11 | Credential/poll lifecycle, pure analytics, and update policy; serialize shared error/state declarations |
| 3 | WP-06 | Integrate state/persistence pipeline and instrument performance before redesigning live UI |
| 4 | WP-07, WP-08 | Summary UI and pure budget detail model; budget UI integration follows summary contract |
| 5 | WP-09, WP-10 | Feature domain/storage and accessibility/settings work; orchestrator serializes shell integration |
| 6 | WP-12 | Full verification, profiling, migration trial, docs and release readiness |

Strict dependency list: WP-01←00; WP-02←00; WP-03←00,01,02; WP-04←01,02; WP-05←00; WP-06←02,03,04,05; WP-07←01,05,06; WP-08←01,04,06 and 07 for its UI; WP-09←02,04,07; WP-10←03,07,08 and 09 for final feature access checks; WP-11←00 and 07 for UI integration; WP-12←all.

`main.swift`, `Package.swift`, `Makefile`, `build.sh`, shared contract files, and `PopoverView.swift` are integration hot spots. Never assign overlapping edits concurrently. Pure model agents deliver domain files/tests first; the shell owner wires them after review. Each agent may propose a contract change, but only the orchestrator accepts and propagates it before consumers proceed.

### 8.3 Review and completion rules

- A testable unit is a behavioral deliverable, not a batch of unrelated files. Write targeted regression tests for data/race fixes; do not inflate test counts with assertions mirroring implementation.
- AppKit geometry and lifecycle get an app harness, not a claim that Foundation tests prove pixels or focus.
- Agent completion requires changed files, tests and outcomes, screenshots when relevant, perf evidence when relevant, limitations, and residual risks.
- The orchestrator verifies the diff and runs integration checks at each wave. A passed agent report alone is insufficient.
- P1 failures block all release candidates. P2 data truth, recovery, and accessibility findings require resolution or a narrow, explicit documented deferral before release.
- Core v2 scope includes the three signature features. If resources force a feature cut, record a product scope change; do not silently call a cosmetic pass the completed v2.

## 9. Implementation work packages

All paths below are repository-relative for portability to isolated worktrees. Each package consumes the global constraints and section 7 contracts. New paths are intentional planned files, not files claimed to exist today. The named tests are the concrete deliverables; test implementation should use the frozen contracts rather than invent parallel types.

### WP-00 — Establish baseline, contracts, and integration testing

**Owner:** orchestrator/platform agent. **Size:** M. **Dependencies:** none. **Output:** reproducible baseline and shared API contract. **Risk:** accepting outdated assumptions as gateway facts.

Size labels indicate relative coordination complexity, not delivery estimates: M is one subsystem with several review units; L spans domain/UI or migration/lifecycle boundaries. Estimate actual effort after the baseline and contract work; do not promise a calendar date from these labels.

**Files:** modify `Package.swift`, `Makefile`, `build.sh`, `Tools/snapshot_main.swift`; create `docs/v2/API_CONTRACT.md`, `docs/v2/BASELINE.md`, `Sources/VelaCore/UsageContracts.swift`, `Tests/VelaAppTests/TestSupport.swift`, `Tests/Fixtures/usage/` and `Tools/performance_main.swift`.

- [ ] **00.1 Baseline checkpoint:** inventory current changes, record toolchain/OS/version/test count, preserve the direct-daily-data migration, capture fresh light/dark fixture images to a dedicated output directory. Record cold/warm launch, closed idle, and repeated interaction resource measurements.
- [ ] **00.2 Freeze wire/domain contracts:** document required/optional/null fields, totals scope, model-list completeness/order, reset semantics, cooldown/zero-limit shapes, Retry-After, and error statuses. Use sanitized fixtures from approved sources or backend code when available. Unverified fields get safe unavailable behavior and an owner, not invented semantics.
- [ ] **00.3 Add app integration testability:** make AppKit sources except `main.swift` buildable by a macOS test target/harness. If using separate SwiftPM targets, update app imports and bare build module strategy together; do not accidentally compile two incompatible module layouts. Add injected clock, fake transport, fake credential store, isolated defaults, and temporary storage helpers.
- [ ] **00.4 Pin build modes:** explicitly align intended Swift language/concurrency mode in app/core builds. Run a strict app build, fix actor issues at boundaries, and make snapshot output configurable without rewriting README assets by default.

**Acceptance:** `make test` still passes; app harness builds; full app build uses documented language mode; fixtures contain no live credentials; baseline report includes actual metrics or clearly identified measurement blockers; contract fallback examples cover missing `today_models` and differing token/user totals.

### WP-01 — Validate financial data and model breakdowns

**Owner:** domain/data agent. **Size:** M. **Dependencies:** WP-00. **Produces:** `UsageSnapshot`, `ModelBreakdownState`, shared safe money/share formatting. **Findings:** B03, B07, B08, B11.

**Files:** modify `Sources/VelaCore/Models.swift`, `TodayModelRows.swift`, `ModelShare.swift`; create `Sources/VelaCore/UsageValidation.swift`, `MoneyFormat.swift`; tests `UsageValidationTests.swift`, `TodayModelRowsTests.swift`, `ModelsTests.swift`, `MoneyFormatTests.swift` in `Tests/VelaCoreTests/`.

- [ ] **01.1 Preserve availability:** distinguish absent/null daily fields, explicitly empty model arrays, zero totals, and malformed data. Decode raw JSON separately from validated display-ready values.
- [ ] **01.2 Safe numeric boundary:** reject negative/non-finite monetary values and invalid counts/dates; bound or safely format huge finite values before any integer conversion. Percentages can exceed 100 in the domain, while drawing clamps safely. Do not impose an arbitrary low account budget maximum just to avoid layout work.
- [ ] **01.3 Reconcile rows:** validate duplicates, deterministic cost order, scope, and sum before folding. If named costs exceed their comparable total by more than $0.01, return inconsistent/total-only. Within tolerance, retain factual rows with documented rounding; do not rescale spend. Keep omitted model tail separate in wording from other-credential/unattributed residual where the contract permits distinguishing them.
- [ ] **01.4 Month denominator and unlimited display:** use the authoritative comparable period total, include a residual when supported, or explicitly say “share of listed models” if scope prevents comparison. Expose limit-enabled policy to hero/chart/pill/copy through display contracts. Move observed blended $/M formatting into a pure helper with a truthful label.

**Regression cases:** `used_percent=1e100`; huge limit; negative costs/tokens; missing/null/empty daily fields; $80+$70 versus $100; $300+$200 versus month $1,000; sub-cent residual; duplicate models; zero limit enabled/disabled; unknown model IDs. **Acceptance:** no invalid numeric value reaches an unsafe cast; inconsistent rows never masquerade as a reconciled breakdown; all period denominators and fallback labels are testable.

### WP-02 — Correct, version, and isolate observation history

**Owner:** storage agent. **Size:** L. **Dependencies:** WP-00. **Produces:** `Observation`, `HistoryEnvelope`, `HistoryRepository` actor, coverage/migration results. **Findings:** B01, B13, B15.

**Files:** modify `Sources/VelaCore/HistoryStore.swift`, `GatewayDay.swift`; create `Sources/VelaCore/Observation.swift`, `HistoryMigration.swift`, `HistoryRepository.swift`; create `Tests/VelaCoreTests/HistoryMigrationTests.swift`, `HistoryRepositoryTests.swift`; extend `HistoryStoreTests.swift`; fixtures `Tests/Fixtures/history/`.

- [ ] **02.1 Reproduce the real seam:** add the ascending post-midnight sequence from section 12. Preserve the last $165 observation and the entire day across save/load; never write the late value into the day's earliest slot.
- [ ] **02.2 Timestamp-aware model:** implement section 7 retention, actual receipt-time ordering, precision, scope, policy changes, discontinuities, and partial-day status. Five-minute coalescing must preserve marker/policy boundaries within bounds.
- [ ] **02.3 Loss-preserving migration:** migrate bare/ISO keys, malformed arrays, corrupt JSON, duplicate keys, and legacy precision. Retain a readable backup; quarantine uncertain data; keep legacy identity unassigned. The migration is idempotent and restarting after interruption does not destroy the only good file.
- [ ] **02.4 Serial atomic persistence:** move load/encode/save into an actor, enforce revision ordering, coalesce writes, surface errors, recover from missing directory/read-only destination/full-disk simulation, and avoid orphaned temp files. Use an injected filesystem seam for deterministic failure tests.

**Acceptance:** ascending lagging-day data survives; no scope contamination; version-1 fixture can be recovered unchanged; no main-actor file I/O; oldest records prune deterministically; corrupt history remains recoverable; two rapid save revisions cannot regress disk state; no false exact timestamp for legacy samples. Existing ordinary first-save tests remain passing.

### WP-03 — Credential lifecycle and resilient polling

**Owner:** lifecycle/network agent. **Size:** L. **Dependencies:** WP-01, WP-02. **Produces:** `CredentialController`, `PollCoordinator`, explicit `ConnectionState`. **Findings:** B02, B05, B06.

**Files:** modify `Sources/App/AIHubClient.swift`, `KeychainStore.swift`, `UsagePoller.swift`, `FirstRunView.swift`; create `Sources/App/CredentialController.swift`, `PollCoordinator.swift`; modify `Sources/VelaCore/AIHubClientProtocol.swift`, `PollStateMachine.swift`; create `Tests/VelaAppTests/CredentialLifecycleTests.swift`, `PollCoordinatorTests.swift`, `AIHubClientTests.swift`. Shell edits go through orchestrator.

- [ ] **03.1 Distinct credential states:** missing, available, denied, locked/unavailable, invalid, validation-in-progress. Read Keychain off the interactive path; preserve the raw status for a safe user-facing mapping. Only genuine absence triggers first-run behavior.
- [ ] **03.2 Transactional replacement:** validate a candidate using the same read-only usage endpoint before replacing a working saved token. Cancel/epoch-guard older requests. On accepted replacement, clear old visible trust immediately, switch history scope, and commit only the new-generation response. If validation or Keychain writing fails, retain the previous saved credential and explain the failure. Clear secure field/error state on successful completion and cancellation.
- [ ] **03.3 Recovery without interruption loops:** 401/403 transitions once to authentication-required; pause retries until explicit retry/replacement. Show a stable actionable status instead of activating a token panel every minute. Cancel dismisses recovery and remains dismissed until the user requests it again.
- [ ] **03.4 Scheduler:** implement section 6 coalescing, deadlines, bounded timeout/cancellation, backoff/Retry-After, stop semantics, system sleep/wake, and request generation. Treat no-token/unauthorized separately from network/5xx/schema errors. Limit transport response size before unbounded decode/allocation according to the frozen payload contract.

**Tests:** A request starts → B accepted → A completes late; candidate invalid; Keychain Deny; locked then recovered; Cancel plus five timer ticks; repeated 401; overlapping open/wake/timer/manual triggers; hanging transport; stop before callback; Retry-After 120; malformed response; successful recovery. **Acceptance:** zero old-scope commits after replacement, max one ordinary usage request in flight, no repeated modal theft, deterministic scheduler tests without real sleeps or real Keychain items.

### WP-04 — Honest time, recent burn, and forecasts

**Owner:** analytics agent. **Size:** M. **Dependencies:** WP-01, WP-02. **Produces:** freshness/coverage helpers, timestamped burn, confidence-aware pace. **Findings:** B04, B05, B09, B15.

**Files:** modify `Sources/VelaCore/BurnBuffer.swift`, `PaceEngine.swift`, `CurveScrub.swift`, `DayStrip.swift`, `GatewayDay.swift`; create `Sources/VelaCore/Freshness.swift`, `ObservationCoverage.swift`; tests `BurnBufferTests.swift`, `PaceEngineTests.swift`, `CurveScrubTests.swift`, `DayStripTests.swift`, `FreshnessTests.swift`.

- [ ] **04.1 Age and billing context:** derive freshness from receipt time; handle clock rollback conservatively, older spend day, timezone/DST, and process wake. Distinguish exact receipt age from legacy hour precision. Add explicit insufficient-evidence verdicts and factual observed-exhaustion wording.
- [ ] **04.2 Time-correct pulse:** retain only actual intervals intersecting the last hour; irregular opens do not shift a fixed sample-count axis. Long unobserved intervals are gaps, not one-minute spikes. Day/scope resets and corrections establish a new baseline.
- [ ] **04.3 Forecast eligibility:** implement section 7.4 gates and rate formula; suppress stale, short, sparse, corrected, or mismatched data. One-shot policy/reset calculations must not imply request permission or an exact exhaustion event.
- [ ] **04.4 Comparisons and chart samples:** median/ghost use past same-scope calendar days and comparable coverage. Chart segments break on unsupported gaps; hover reports the observation's actual date/precision. Week day values say last observed unless completeness is established.

**Tests:** one minute versus eight hours; 10 repeated opens; sleep gap; midnight growth/reset; stale $200/$400; 30 seconds/$399; inactive recent window; 14-calendar-day cutoff; future history; DST transitions; legitimate negative correction; exactly 90-second freshness boundary; absent limit. **Acceptance:** no false “safe pace” fallback, no invented within-gap rate, no future/other-scope median contribution.

### WP-05 — Design system and state fixtures

**Owner:** native product-design agent. **Size:** M. **Dependencies:** WP-00. **Produces:** shared design tokens and reviewable state designs. **Consumes:** section 5 hierarchy and fixture contract.

**Files:** create `Sources/App/DesignTokens.swift`, `docs/v2/DESIGN.md`, `Tools/design_fixture_main.swift`; extend configurable snapshot fixture support. Snapshot outputs go to `build/v2-design/`, not over existing assets by default.

- [ ] **05.1 Design comparisons:** render the recommended 360pt summary, budget detail, marker receipt, history window, and settings in light/dark. Compare legibility with the current 320pt design using the same data. Document why every visible element exists.
- [ ] **05.2 Freeze tokens:** measure typography, money widths, spacing, row height, material and opaque fallback, focus/hover treatment, and status colors. Include very long model names and high amounts; permit semantic truncation with full accessible value.
- [ ] **05.3 State designs:** render loading/cache/stale/auth/error/unlimited/missing-data states and reduced-motion/contrast variants. Define stable summary height, scrolling on small screens, secondary view navigation, and keyboard entry behavior.

**Acceptance:** design document includes rendered fixtures, a state/copy matrix and concrete tokens; no essential tiny text, unexplained empty slot, contradictory period labels, inaccessible hover-only answer, or new continuously animated element. The orchestrator presents the concrete design for review before the live UI conversion; independently authorized reliability work can continue.

### WP-06 — Persistent presentation and efficient app integration

**Owner:** app-shell agent. **Size:** L. **Dependencies:** WP-02, WP-03, WP-04, WP-05. **Produces:** stable presentation pipeline and signposts. **Findings:** B10, B13, B16.

**Files:** modify `Sources/App/main.swift`, `PopoverView.swift`, `PopoverPanel.swift`, `StatusItemController.swift`; create `Sources/App/AppCoordinator.swift`, `SummaryPresenter.swift`, `Sources/VelaCore/SummaryDisplayState.swift`, `Sources/App/PerformanceSignposts.swift`; tests `Tests/VelaAppTests/PresentationLifecycleTests.swift`, `RenderInvalidationTests.swift`.

- [ ] **06.1 Centralize state application:** wire scoped snapshots, repository updates, and view state through `AppCoordinator`. Keep entry point small; make lifecycle transitions testable. Cache parsed dates/derived values at their correct scope rather than reparsing in every child view.
- [ ] **06.2 Preserve view identity:** build sections once, apply changed section states, update rows by stable ID, preserve focus/hover/detail selection, and keep the update card while unrelated usage changes. Loading→live and auth→live use explicit transitions, not accidental view reuse.
- [ ] **06.3 Narrow pill invalidation:** compare only visible amount, border state, relevant pulse geometry, cap alert, size, appearance, scale, and freshness. Retain baked bitmap rendering. Avoid serialization through TIFF when a directly rendered bitmap can be verified equivalent; this is optional if profiling shows no benefit. Never restore the appearance-observer loop.
- [ ] **06.4 Window lifecycle:** eliminate window-frame scaling and recursive layout rebuild; cancel animations/work items on dismissal; remove monitors on close; handle reopen races and hosting-screen changes. Fix the observed actor-isolation warning under the selected Swift mode.
- [ ] **06.5 Instrument:** signpost fetch/decode/persist/presenter/render/open intervals and count redraws, windows, timers, and observers in debug/benchmark mode. Logs contain no token or personal payload.

**Acceptance:** identical visible state produces no redundant section rebuild, tab changes have no 210ms data wait, no sync I/O in click handlers, chart focus survives a poll, no orphan child windows after 500 cycles, strict app build has no introduced concurrency warnings. Report baseline-versus-new measurements before claiming faster.

### WP-07 — Ship the premium summary, chart, and models experience

**Owner:** native UI agent. **Size:** L. **Dependencies:** WP-01, WP-05, WP-06. **Produces:** refined summary and stable secondary navigation. **Findings:** B07, B08, B10, B11, B15, B17.

**Files:** modify `Sources/App/PopoverView.swift`, `CurveView.swift`, `DayStripView.swift`, `PeriodSwitcher.swift`, `PopoverPanel.swift`; create `Sources/App/SummaryHeaderView.swift`, `ModelsSectionView.swift`, `ConnectionStatusView.swift`, `SecondaryPanelCoordinator.swift`; tests `Tests/VelaAppTests/SummaryStateTests.swift`, `ChartInteractionTests.swift`, `LayoutFixtureTests.swift`.

- [ ] **07.1 Summary shell:** apply frozen design tokens and stable layout. Factual daily hero + remaining room, no-limit variant, readable freshness/status region, and clear navigation. Critical status does not disappear into global low opacity.
- [ ] **07.2 Model section:** display selected period and its authoritative scoped total, reconciled rows, honest unavailable/empty/stale labels, long-name disclosure, and observed blended-rate detail. Update content immediately while indicator animation remains independent.
- [ ] **07.3 Chart/week:** draw segmented observed paths without an invented zero origin; implement meaningful hover/focus affordance, actual observation labels, “last observed” marker while stale, and persistent selected day. Keep sparse-week intensity rules legible and explain coverage in detail.
- [ ] **07.4 Secondary surfaces:** use one consistent native treatment and navigation model for budget detail, connection detail, settings and update information. Preserve open state across polls. Keep heavy history content lazy.

**Acceptance:** all section 5.4 fixtures visually inspected; stable summary geometry across every ordinary state change; unlimited state has no false ceiling; Today/Month scope is unambiguous; same-hour mouse jitter does not redraw continuously; visible text and accessible descriptions agree.

### WP-08 — Complete budget headroom and all-cap inspection

**Owner:** budget-domain agent, then UI owner for integration. **Size:** M. **Dependencies:** WP-01, WP-04, WP-06; WP-07 for UI. **Produces:** F01 `BudgetOverview` and detail surface.

**Files:** modify `Sources/VelaCore/ModelBudgetSignal.swift`; create `Sources/VelaCore/BudgetOverview.swift`, `Sources/App/BudgetDetailView.swift`; tests `Tests/VelaCoreTests/BudgetOverviewTests.swift`, `Tests/VelaAppTests/BudgetDetailTests.swift`; shell integration owned by WP-07 agent.

- [ ] **08.1 Budget rules:** derive global and nested room with explicit enabled/blocked/relaxed/invalid/stale states. Retain deterministic sorting and previously approved summary narrative semantics. Expose concurrent conditions in detail so one relaxed cap cannot hide a different blocked cap.
- [ ] **08.2 Detail UI:** show all returned caps, amounts, policy status, reset context and last observation. Identify that these are returned budget limits, not a complete model-availability catalog. Scroll bounded content if the list is long.
- [ ] **08.3 Expiry and a11y:** trigger one redraw when a known cooldown expires, avoid hidden repeating timers, and expose the complete state to assistive technology. Unknown/old policy remains visibly last observed.

**Fixtures:** global remaining 40/model remaining 5→5; global 2/model 5→2; global disabled/model 5→5; active cooldown/global 40→40 with relaxed qualifier; zero model cap→blocked; multiple blocked/relaxed; removed cap; failed refresh at expiry; no model caps. **Acceptance:** border remains global; no hardcoded model name/$20/$5 grace; room never implies a request guarantee; no new endpoint or mutation.

### WP-09 — Markers and local history explorer

**Owner:** feature agent; shell changes through orchestrator. **Size:** L, split into the three independent review units below. **Dependencies:** WP-02, WP-04, WP-07. **Produces:** F02/F03.

**Files:** create `Sources/VelaCore/SpendMarker.swift`, `MarkerReceipt.swift`, `HistoryExport.swift`, `Sources/App/MarkerView.swift`, `HistoryWindowController.swift`, `HistoryDayView.swift`; extend `HistoryRepository.swift` through its owner; tests `Tests/VelaCoreTests/SpendMarkerTests.swift`, `HistoryExportTests.swift`, `Tests/VelaAppTests/HistoryWindowTests.swift`, `MarkerFlowTests.swift`.

- [ ] **09.1 Marker engine + receipt:** start/finish from accepted observations, record optional bounded name, compute comparable cumulative delta, persist at most 100 receipts, and survive relaunch. Day/scope changes and corrections produce explicit partial/unavailable boundaries. No inferred project attribution. Test 10→25=$15; restart; invalid end; stale start/finish; same-day offline recovery; midnight and token replacement.
- [ ] **09.2 History explorer:** lazily create one native window, navigate retained days/scopes, show selected observations and coverage, and keep totals honest. Legacy unassigned data has its own archive presentation and never blends with live comparisons. Reopen restores selection within the same scope. Closing history stops its display-only work.
- [ ] **09.3 Export + data controls:** CSV from explicit selected range, dates/precision/coverage included, absent values empty, locale-independent decimal formatting, proper escaping of labels and formula-like strings if user names are exported. Export dialog is user initiated; delete/clear-history actions require an explicit UI confirmation and state the affected scope.

**Acceptance:** marker cost never claims project-level precision; no extra usage polling; history window stays within section 6 budgets; incomplete days cannot be confused with complete totals; export excludes tokens and token IDs; rows survive round-trip parsing; local data and receipts remain bounded. Each unit gets its own review before integration.

### WP-10 — Native usability, settings, and accessibility

**Owner:** platform/accessibility agent. **Size:** M. **Dependencies:** WP-03, WP-07, WP-08; final coverage after WP-09. **Produces:** complete keyboard/assistive-tech access and coherent settings. **Findings:** B06, B14.

**Files:** create `Sources/App/SettingsView.swift`, `AccessibilitySummary.swift`; modify `FirstRunView.swift`, `PeriodSwitcher.swift`, `StatusItemController.swift`, `PopoverPanel.swift`, custom detail controls; tests `Tests/VelaAppTests/AccessibilityTests.swift`, `SettingsFlowTests.swift`.

- [ ] **10.1 Keyboard/focus:** implement tab order, Escape, local refresh/copy/history commands, keyboard-open mode, and focus restoration. Prefer actual NSButtons or correct accessibility press behavior for custom controls. Normal mouse opening stays nonactivating.
- [ ] **10.2 Accessible data:** chart and week expose selectable observations and text summaries; model rows announce name/period/cost/share; pill announces stale/unlimited/blocked state. Full model names and budget states are available without pointer hover. Avoid announcing every silent poll as an interruption.
- [ ] **10.3 Settings and recovery:** consolidate pill size, login status, credential recovery, data controls, app version/update state. Represent ServiceManagement enabled/disabled/requires-approval/unavailable outcomes and provide the appropriate system-settings route; do not swallow errors into an inert checkmark.
- [ ] **10.4 Adaptive appearance:** verify full keyboard access, VoiceOver, Increase Contrast, Reduce Transparency/Motion, large text/zoom, screen-edge geometry, and display reconnect. Re-resolve layer colors and backing-scale rendering on discrete appearance/screen changes.

**Acceptance:** every mouse action has a keyboard/assistive-tech route; token entry accepts first click, Return and paste; no ambiguous invisible hit targets; Cancel remains cancelled; no password survives unnecessarily in reused field state; accessibility reading matches visible freshness and scope.

### WP-11 — Truthful updates and distribution readiness

**Owner:** release/platform agent. **Size:** M. **Dependencies:** WP-00, WP-07 for UI. **Produces:** explicit release status and reliable install instructions. **Findings:** B12, B17.

**Files:** modify `Sources/App/UpdateChecker.swift`, `UpdateBellView.swift`, `VersionBulletView.swift`, `Sources/VelaCore/ReleaseChecker.swift`, `VersionCheck.swift`, `WhatsNew.swift`, `build.sh`; tests `Tests/VelaCoreTests/ReleaseCheckerTests.swift`, `VersionCheckTests.swift`, `WhatsNewTests.swift`, `Tests/VelaAppTests/UpdateStateTests.swift`; update `docs/keychain-signing.md`.

- [ ] **11.1 Explicit update state:** never-checked/checking/checked-current/available/skipped/failed with last successful check. A skipped newer release is not “up to date.” Persist successful metadata separately from attempt throttle; clock rollback cannot suppress checks indefinitely.
- [ ] **11.2 Verify distribution contract:** test unauthenticated access to the configured release metadata using a non-secret request. If private/unavailable, ship honest manual check instructions and identify a platform-owned metadata solution separately. Do not put a PAT in the app or reuse the gateway token with GitHub. New hosting requires a product/platform decision.
- [ ] **11.3 Build metadata:** validate version/tag/changelog summary consistency, correct fallback wording, usable release URL restricted to the intended HTTPS destination, correct Homebrew versus direct-install guidance, stable signing identity, and a non-destructive snapshot command.
- [ ] **11.4 Signing path:** document Developer ID + notarization as the preferred polished distribution gate if the organization can provide an account/identity. Implement only using authorized signing material. Internal beta can retain the documented current signing path; broader premium release cannot claim a frictionless notarized install without verification.

**Acceptance:** offline/404/429 and skipped states never claim current; unrelated polls do not dismiss update detail; no secret used for public release metadata; generated What's New contains clean human summaries; install/update smoke test reflects the actual channel. No automatic downloader/installer is introduced.

### WP-12 — Integration, measured release gate, and documentation

**Owner:** orchestrator plus independent reviewer when implementation is executed. **Size:** M/L. **Dependencies:** all accepted packages. **Produces:** verified v2 candidate and evidence bundle.

**Files:** update `README.md`, `CHANGELOG.md`, `Info.plist`, `Makefile`, `build.sh`; create `docs/v2/VERIFICATION.md`, `docs/v2/PERFORMANCE.md`, `docs/v2/RELEASE_CHECKLIST.md`; add CI workflow if repository-hosted macOS execution is available and authorized.

- [ ] **12.1 Integration regression:** run all core/app tests, strict app compile, schema migration fixtures, UI matrix, and 500-cycle lifecycle harness. Replay the failure cases from section 3; original regression tests must fail against the affected baseline behavior and pass with the fix.
- [ ] **12.2 Profile:** measure every section 6 metric, including stationary/hovering/open history, stale/auth error, and wake cases. Use release builds and synthetic fixed data. Run a multi-hour idle/interaction soak and compare physical footprint, CPU, wakeups, WindowServer work, and allocations. Record failures with traces rather than replacing targets with adjectives.
- [ ] **12.3 User evaluation:** ask 3–5 intended users to find remaining global room, explain a model cap, identify stale data, inspect a partial day, start/finish a marker, and replace an invalid token. Target ≥4/5 successful without assistance, with no material misinterpretation of available budget or history completeness. Small-sample findings guide refinement, not statistical claims.
- [ ] **12.4 Docs and candidate:** update actual architecture/feature descriptions, data semantics, verified test count, privacy, retention, usage scope, build commands, screenshots and signing instructions. Bump version only for the actual release candidate; reconcile package/tag/ZIP/cask digests. Publishing remains a separate authorized release action.
- [ ] **12.5 Final review:** zero unresolved P1; every included feature verified; explicit dispositions for P2 findings; no unexplained performance regression or scope expansion. Record what was deferred and why. Preserve recovery files until migration has been demonstrated safe.

**Acceptance:** all section 10 gates have evidence; no implementation package silently omitted; source, artifact and documentation agree; internal-beta limitations are clearly separated from broader distribution readiness.

## 10. Release acceptance matrix

| Area | Required evidence |
|---|---|
| Build | Core and AppKit compile under declared Swift mode on supported macOS; no unexplained concurrency warnings |
| Correctness | B01–B11 regression coverage; rounding/scope/date/limit semantics match fixtures |
| Persistence | V1→V2 idempotent migration; intact backup; malformed file recovery; serial revision writes; bounded retention |
| Credentials | Late-result isolation, candidate validation, Keychain-denial recovery, no secret in data/log/export, no repeated focus theft |
| Network | Fake-server cases for 200/401/403/429/5xx/timeout/invalid payload/cancel; coalescing and backoff verified |
| Data truth | No unsupported zero, complete-day total, exact crossing time, current status, forecast, or project attribution |
| Visual | Current fixture gallery light/dark/accessibility variants, supported screens and long-value cases reviewed |
| Interaction | Immediate tabs; hover/detail/focus survive polls; no window-size animation; click/dismiss/reopen cases pass |
| Accessibility | Keyboard-only and VoiceOver inspection of all primary and signature features; no color-only state |
| F01 | All returned caps and correct nested headroom; cooldown expiry; no request-permission promise |
| F02 | Accurate comparable marker deltas, explicit partial boundaries, persistence and retention |
| F03 | Selectable local history, coverage/legacy precision, clean scoped CSV, lazy window lifecycle |
| Performance | Recorded baseline and candidate measurements for every section 6 target; no sustained growth in soak |
| Distribution | Actual release access, truthful update state, clean metadata, tested install channel; notarization verified if advertised |
| Documentation | README/changelog/screenshots/test count agree with the candidate, with known limitations documented |

## 11. Agent handoff templates

### Orchestrator launch prompt

```text
Implement Vela Ishtar v2 using V2_IMPLEMENTATION_PLAN.md.
First inspect the working tree and preserve all existing changes. The plan was
assessed against HEAD 241ee4a plus uncommitted direct daily model data support.
Run WP-00 before dispatching dependent packages. Freeze contracts and produce
the baseline report. Maintain a package/task checklist and exclusive file
ownership. Dispatch only ready tasks with accepted dependencies and their
regression fixtures; keep shared-file integration serial.

Preserve the native AppKit, read-only, zero-dependency product and resource
budgets. Prioritize data-loss, credential-scope and numeric-crash fixes. Present
the concrete WP-05 design before live UI conversion. Include all three core
features unless a product scope change is explicitly accepted. Verify each
agent's diff and evidence; do not accept a passing core suite as UI validation.
Do not deploy, publish, change gateway policy, or invent API capabilities.
```

### Per-agent assignment prompt

```text
Assigned package/task: [orchestrator inserts the exact WP/task ID and title].
Read V2_IMPLEMENTATION_PLAN.md global constraints, section 7 contracts,
the assigned package, and the accepted dependency artifacts supplied here.
Work only within the supplied file ownership. If a shared contract must change,
send the exact proposed declaration and its consumer impact to the orchestrator
before changing it. Do not add unrelated features or restore retired systems.

Reproduce the specified regression with deterministic fixtures. Implement the
smallest complete behavioral unit and run its named tests. For UI changes,
provide current rendered fixtures and lifecycle/accessibility checks; for
performance changes, provide measurements under the agreed fixture and metric.
Return: changed files; behavior before/after; tests and exact outcomes; evidence
paths; contract changes; remaining limitations; review-ready commit/diff.
Do not mark the whole package complete if only one task was assigned.
```

### Progress record

For each package record: state (`not started / running / review / accepted / blocked`), current owner, accepted base revision, task IDs complete, produced contracts, test evidence, metric evidence, known risks, and next dependency. “Blocked” names a specific missing input and safe work that can proceed meanwhile. Do not equate waiting for a design/backend decision with abandoning the rest of the plan.

## 12. Reproduction examples and references

### 12.1 Reproduced midnight data loss

This sequence compiled against the assessment source writes an ascending total into slot 0, then loses the day after reload. Convert it to a permanent regression in WP-02. Use a fresh temporary directory.

```swift
var store = HistoryStore(directory: temporaryDirectory)
store.record(spentToday: 120, limit: 400,
             at: ISODate.parse("2026-08-01T22:10:00Z")!, spendDate: "2026-08-01")
store.record(spentToday: 160, limit: 400,
             at: ISODate.parse("2026-08-01T23:50:00Z")!, spendDate: "2026-08-01")
store.record(spentToday: 165, limit: 400,
             at: ISODate.parse("2026-08-02T00:30:00Z")!, spendDate: "2026-08-01")
try store.save()
var restored = HistoryStore(directory: temporaryDirectory)
try restored.load()
// Current observed result: nil. Required: preserved day with last observed 165.
let preserved = restored.day(spendDate: "2026-08-01")
```

The existing test `audit4LaggingSeamLeavesDayClean` checks 160.42→2.74 after midnight; its downward guard passes. It does not refute the ascending case above.

### 12.2 Other probe results

```text
Token A $100 at 12:00, token B $20 at 13:00, same billing day:
  Current response B; history still has A's $100; B's lower amount not recorded.

PaceEngine, stale $200/$400 at 15:00:
  "On pace to stay under budget today."
PaceEngine, fresh $399/$400 at 00:00:30:
  "On pace to stay under budget today."

TodayModelRows, named costs [80, 70], dayTotal 100:
  Displayed named sum = 150.

BurnBuffer, 10→20 over one minute versus 10→20 over eight hours:
  Buffers compare equal.

DailyBudget JSON, used_percent 1e100:
  Decodes; Int(exactly:) returns nil.
  Unchecked Int(...) casts in the App layer require a safety fix.

AppKit, disabled $400 global limit:
  Hero: "$100.00" + " of $400 today"
  Pace: "No daily limit on your account."

AppKit, missing daily model fields:
  "Per-model breakdown is monthly only"

AppKit, Month total $1,000, rows $300 and $200:
  "alpha · 60%" and "beta · 40%"
```

### 12.3 Verification commands used

```sh
make test

# Compile without changing/signing/installing the normal build app:
swiftc -O -target arm64-apple-macos14.0 \
  Sources/VelaCore/*.swift Sources/App/*.swift \
  -o /tmp/vela-v2-audit/VelaIshtar \
  -framework Cocoa -framework ServiceManagement \
  -framework Security -framework QuartzCore
```

The temporary audit executables/logs are not required inputs to future implementation. The behaviors, cases, and results above are the durable handoff. Re-run against the executor's actual starting revision.

### 12.4 Primary references

- Local: `README.md`, `CHANGELOG.md`, `Package.swift`, `build.sh`, `Makefile`, all production `Sources/`, related `Tests/`, `Tools/snapshot_main.swift`, and `docs/keychain-signing.md`.
- Local product history: `docs/superpowers/specs/2026-08-01-vela-ishtar-design.md`, `docs/superpowers/specs/2026-08-28-model-budget-design.md`, `docs/BRAINSTORM.md`. Treat old implementation statements as dated evidence.
- [Apple — Energy efficiency best practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html): main-thread work, timers, measuring energy. Archived guidance; use current Instruments for measurement.
- [Apple — App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html): background scheduling behavior; do not promise exact timer execution through sleep.
- [Apple — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/): native interaction and accessibility principles. The specific v2 geometry and visual choices in this document are product proposals.
- [GitHub — REST release endpoints](https://docs.github.com/en/rest/releases/releases#get-the-latest-release): release metadata and authentication behavior. Unauthenticated release access is suitable for public resources; validate this private/internal distribution case explicitly.

**Success means:** users can trust every number, understand a restrictive model cap before it surprises them, inspect a work interval and past observations without opening the dashboard, and forget the app is running until they need it. The implementation earns that result through behavior and measurements, not a larger feature count.
