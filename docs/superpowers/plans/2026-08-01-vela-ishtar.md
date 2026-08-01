# Vela Ishtar — Implementation Plan

## Context

NSX moved all LLM usage onto the internal AI Hub gateway. The only window
into personal spend is a web dashboard nobody remembers to open. **Vela
Ishtar** is a premium macOS menu bar app that makes spend ambient: a pill
in the menu bar (burn sparkline + today's $ + budget-tracing border) and a
glass popover (hero, pace sentence, today's curve, model list, AI Hub
health dot). Design approved 2026-08-01; spec at
`docs/superpowers/specs/2026-08-01-vela-ishtar-design.md`.

Verified ground truth (no guesses in this plan):

- **API works**: `GET https://ai-llm-gateway.fbr.land/v1/me/usage` with
  the user's `gt_` token (available locally as `$AIHUB_TOKEN`) returns
  200 with `daily_budget{limit_usd,spent_usd,remaining_usd,used_percent,
  limit_enabled,spend_date}`, `current_month{total_cost_usd,total_tokens,
  requests}`, `top_models[]`. Budget day boundary = **midnight UTC**.
- **No Xcode** on this machine — Command Line Tools only, Swift 6.3.3,
  macOS 26.5.2 arm64. Build must be bare `swiftc` (proven pattern:
  m1ckc3s/claude-status-bar's build.sh).
- **Architecture**: pure AppKit (NSStatusItem + borderless NSPanel), no
  SwiftUI. SwiftPM targets `VelaCore` (pure, no AppKit) + `VelaCoreTests`
  for `swift test`; `build.sh` compiles `Sources/VelaCore` + `Sources/App`
  together into the .app binary.

**Goal:** v1 ships the pill + popover + 60s polling + Keychain token +
launch-at-login. Cut: Ghost median line (v1.1), leaderboard, notifications,
Sparkle, Homebrew, breathing dot animation (violates zero-render rule).

**Hard rules:** no AI attribution in commits/headers/PRs; header comments
in every file (location, what, why, relevant files); files < ~300 LOC.

## File structure

```
aihub-menu-bar/
├── Package.swift                 # VelaCore + VelaCoreTests only (swift test)
├── build.sh                      # swiftc → .app bundle → ad-hoc codesign
├── Info.plist                    # LSUIElement, com.nsxbet.velaishtar
├── Sources/
│   ├── VelaCore/                 # pure Foundation, unit tested
│   │   ├── Models.swift          # Codable DTOs for /v1/me/usage
│   │   ├── PaceEngine.swift      # pace verdict + sentence
│   │   ├── BurnBuffer.swift      # 60-slot rolling burn ring
│   │   ├── BorderDash.swift      # used_percent → dash pattern
│   │   └── HistoryStore.swift    # UTC-day hourly snapshots, atomic JSON I/O
│   └── App/                      # AppKit only
│       ├── main.swift            # NSApplication bootstrap (no @main)
│       ├── StatusItemController.swift  # status item + offscreen pill renderer
│       ├── UsagePoller.swift     # 60s DispatchSourceTimer + state machine
│       ├── AIHubClient.swift     # URLSession GET /v1/me/usage
│       ├── KeychainStore.swift   # SecItem CRUD for gt_ token
│       ├── PopoverPanel.swift    # NSPanel anchoring + 180ms open animation
│       └── PopoverView.swift     # hero, curve, models, footer
└── Tests/VelaCoreTests/          # PaceEngine, BurnBuffer, BorderDash, HistoryStore
```

Key interfaces (task implementers rely on these exact signatures):

- `PaceEngine.verdict(spent:limit:limitEnabled:now:) -> PaceVerdict`
  (.idle / .exhausted(reachedAt:) / .pace(eta:) / .cruisingNoLimit) and
  `PaceEngine.sentence(for:locale:) -> String`. ETA clamped at midnight UTC.
- `BurnBuffer.record(spentToday:at:)` (cumulative in, delta stored,
  negative delta clamped to 0 for midnight reset), `normalized() -> [Double]?`.
- `BorderDash.pattern(forFraction:perimeter:) -> (on:off:)?` — border path
  built as 4 explicit segments so perimeter = 2(w−2r)+2(h−2r)+2πr exactly.
- `HistoryStore(directory:)` with `record(spentToday:limit:at:)`,
  `day(utcDate:) -> DayRecord?`, atomic save (tmp + rename).
- `AIHubClient.fetchUsage(completion:)` → `Result<UsageResponse, UsageError>`;
  client behind a protocol so UsagePoller tests stub it.
- `UsagePoller` states: `.neverFetched / .fresh(UsageResponse) /
  .stale(UsageResponse, consecutiveFailures: Int)`; ≥2 failures → stale;
  single in-flight; pollNow() on popover open + didWake.
- `KeychainStore.read()/write(_:)/delete()` — generic password, service
  `com.nsxbet.velaishtar`, `kSecAttrAccessibleAfterFirstUnlock`.

## Tasks (TDD, commit per task)

1. **Scaffold** — Package.swift, .gitignore (build/, .build/), dirs.
2. **Models + fixture test** — decode the verified live JSON (saved as
   test fixture); tolerant ISO8601 (mixed `Z` / `-03:00` / fractional).
3. **BorderDash** — tests: fractions 0, 0.5, 0.85, 1.0 vs exact perimeter.
4. **BurnBuffer** — tests: deltas, midnight clamp, all-zero → nil.
5. **PaceEngine** — tests: idle, exhausted, ETA clamp at midnight UTC,
   limit disabled, elapsed < 60s.
6. **HistoryStore** — JSON round-trip in tmpdir; UTC-day keying (21:30
   São Paulo lands on correct UTC day).
7. **KeychainStore** — thin SecItem wrapper (manual verify; no unit test).
8. **AIHubClient** — error mapping (noToken/unauthorized/network/badStatus/
   decode); live curl-equivalence check with `$AIHUB_TOKEN`.
9. **UsagePoller** — unit-test transitions with stubbed client protocol.
10. **StatusItemController + pill renderer** — offscreen NSImage at 2x:
    border dash trace (amber >85%, red closed loop at 100%, contents dim),
    age-faded sparkline + area fill + leading dot, tabular amount.
    `isTemplate = false`, appearance-adaptive palettes (resolve colors
    under aqua/darkAqua). Dev trick: dump `tiffRepresentation` to /tmp
    to eyeball renders.
11. **PopoverPanel** — borderless nonactivating NSPanel, vibrancy
    (.popover material), anchored to `statusItem.button.window.frame`
    computed at click time, 180ms scale+fade (instant under Reduce
    Motion), global+local outside-click monitors.
12. **PopoverView** — 320pt: hero 30pt semibold tabular + pace sentence,
    CurveView (hourly cumulative from HistoryStore, dotted budget
    hairline, "now" tick), top-5 model rows (hairline bars, cost tabular,
    tokens 11pt/40%), footer: Dashboard ↗ (opens web UI), API key
    (copies token), `● AI Hub · 12:38:04` health unit.
13. **CurveView draw-on** — progress-mask 0→1 in the open animation
    context, once per open.
14. **Health states** — green/amber/gray dot, stale note row, content
    dim to 55%.
15. **First-run flow** — inline NSSecureTextField in popover → Keychain
    → pollNow.
16. **Launch-at-login** — SMAppService.mainApp toggle in footer
    (ad-hoc signing OK; toggle only after moving .app to /Applications).
17. **build.sh + Info.plist** — `swiftc -O -target arm64-apple-macos14.0
    Sources/VelaCore/*.swift Sources/App/*.swift -o ... -framework Cocoa
    -framework ServiceManagement -framework Security -framework
    QuartzCore`; Info.plist copy; `xattr -cr`; `codesign --force --sign -`.
18. **Live verification pass** — checklist below.

## Gotchas (baked into tasks)

- Swift 6 strict concurrency: mark App side `@MainActor` explicitly;
  VelaCore stays actor-free; URLSession completion hops via
  `DispatchQueue.main.async`.
- No `@main` attribute — explicit `NSApplication.shared.run()`.
- Borderless panel vibrancy: `cornerRadius` clipping on contentView +
  `hasShadow` — most likely visual bug; check both appearances.
- Keychain re-prompts on every ad-hoc rebuild (expected; document in
  README).
- Pill width budget < 120pt (notched Macs); v1 pill ≈ 76pt.
- Poll cadence 60s with 5s leeway, `.utility` QoS; zero rendering
  between polls — state changes only.

## Verification

- `swift test` green.
- `./build.sh && open "build/Vela Ishtar.app"` — no dock icon, pill
  appears, first-run token field works.
- Save real token → pill amount + hero match the web dashboard within
  60s; border trace matches `used_percent`.
- Airplane mode → amber + stale + dimmed after 2 missed polls; recovery
  silent on reconnect.
- Dark/light toggle adapts without relaunch; outside click dismisses;
  Reduce Motion honored; launch-at-login persists across reboot;
  `history.json` accumulates UTC-day entries.

## Execution

Subagent-driven development (fresh subagent per task, review between
tasks) — repo is greenfield and tasks are small and well-bounded.
