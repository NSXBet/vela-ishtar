# Vela Ishtar — Design Doc

Date: 2026-08-01
Status: approved direction, pre-implementation
Repo: `NSXBet/vela-ishtar` (private; tested internally first, shared later)

## What it is

A premium macOS menu bar app that shows your personal AI Hub (LLM gateway)
spend at a glance. Your AI spend, in the corner of your eye — never in
your face. An instrument, not a scoreboard: no leaderboards, no
competition, no micromanagement vibe.

Name: **Vela Ishtar** — "Vela" (Portuguese: candle; also "look!",
imperative of *ver*) is the product; Ishtar (the gateway's internal
codename) is its house. Icon concept: the candle carried by the star.

## Why it exists

NSX moved all LLM usage off direct Anthropic subscriptions onto the
internal AI Hub gateway. Every colleague's spend now flows through one
place with per-user tokens and daily budgets — but the only window into
it is a web dashboard you have to remember to open. Vela Ishtar makes
spend ambient: always visible, zero effort. It also makes the AI Hub
feel like a real product — a small, beautiful gift to the team.

Emotional core: **calm assurance**. The app answers "am I fine?" before
you think to ask. Facts, plainly stated, then silence.

## Data source (verified against NSXBet/aihub-gateway)

One endpoint, self-serve, no admin rights:

```
GET https://ai-llm-gateway.fbr.land/v1/me/usage
Authorization: Bearer gt_<the user's existing gateway token>
```

Response:

```json
{
  "token_id": "...",
  "daily_budget":  { "limit_usd": 400, "spent_usd": 6.79,
                     "remaining_usd": 393.21, "used_percent": 2,
                     "limit_enabled": true, "spend_date": "..." },
  "current_month": { "total_cost_usd": 6.79, "total_tokens": 8560000,
                     "requests": 73 },
  "top_models":    [ { "model": "kimi-k3", "total_cost_usd": 4.90,
                       "total_tokens": 3790000, "requests": 51 } ]
}
```

Key facts confirmed in the gateway repo:

- The same `gt_` token used for inference works for this call. Response
  is scoped to the caller's credential only.
- **Budget reset: midnight UTC** (`spend_date` is "dia UTC" per
  `docs/llm-gateway-usage-journeys.md`). That is 21:00 São Paulo —
  the pace sentence and countdowns must use the UTC day boundary.
- **Per-user limits**: effective daily limit = global default +
  per-user override (`gateway_user_overrides.daily_spend_limit_extra_usd`).
  `limit_usd` in the response is already the caller's effective limit,
  so all UI auto-scales per user ($400 vs $100 vs $200 — no config).
- Polling every 60s matches the web UI's own cadence.

Open items to verify during build (non-blocking):

- Whether `/v1/me/usage` returns full month stats for `gt_` tokens
  (spec ambiguity; needs one live curl).
- Whether a `/healthz` exists for a cheaper liveness ping.
- Rate limits on polling (none documented; 60s is conservative).

## The menu bar presence (locked)

A single pill: **gradient pulse sparkline + dollar amount, with the
pill's own border tracing the daily budget.**

- **The pulse**: ~40pt sparkline of the last ~60 minutes of burn
  (derived client-side from successive polls; smooths between polls).
  The stroke fades with age — old minutes quiet, current minute full
  ink. A soft area fill grounds it. The leading dot breathes slowly
  (2.4s) while you're actively spending.
- **The border IS the budget**: the pill's rounded-rect outline traces
  clockwise from top-center as `used_percent` grows. A full border =
  budget exhausted. Past ~85% the trace warms toward amber; at 100% the
  loop closes and flips to system red, contents dim — the only red in
  the entire app.
- **The number**: today's spend in tabular figures (`$6.79`), SF Pro
  medium, `monospacedDigitSystemFont` so it never nudges neighbors.
- Light/dark: monochrome adaptive palette (template-style rendering
  with a controlled palette, `isTemplate=false` + dynamic colors per
  appearance so the gradient survives).

Implementation: one offscreen `NSImage` per state change
(`NSImage(size:flipped:false){}` closure drawing, 2x backing, hairline
offsets). Border = one `NSBezierPath` rounded rect stroked with
`lineDashPattern` driven by `used_percent`. No live NSView in the
button.

## The popover (locked)

One panel, 320pt wide, `.menuBarExtraStyle(.window)` + vibrancy. No
tabs, no cards — hairlines and whitespace only.

1. **Hero**: `$6.79 of $400 today` (30pt semibold, tabular) + one
   computed sentence: *"At this pace you'll reach budget around 9:40
   pm."* — derived from burn rate since midnight UTC. When idle:
   *"No spend yet today."* When exhausted: *"Budget reached at 8:52
   pm. Resets at midnight UTC."*
2. **Today's curve**: cumulative spend today, hour by hour, one ink,
   area fill. Budget ceiling as a dotted hairline labeled `$400`.
   "now" marker. No gridlines, no other axis labels.
   **v1.1 — The Ghost**: your median day (last 30 days, computed
   locally from stored history) drawn as a dashed second line behind
   today's curve. Legend: solid = today, dashed = your median day.
3. **Models · this month**: ranked list, hairline proportional bars,
   cost primary (right-aligned tabular), tokens secondary (11pt, 40%
   opacity). From `top_models`.
4. **Footer**: `Dashboard ↗` (opens the AI Hub web UI), `API key`
   (copies the token), then right-aligned: **● AI Hub · 12:38:04** —
   a 7px health dot (slow 4s breathe when green) + label + sync
   timestamp, read as one unit.

### Health states

- **Green**: last fetch succeeded. Quiet, breathing.
- **Amber**: 2+ consecutive fetch failures. Content dims to ~55%,
  timestamp becomes `stale 12:24:11`, one honest note appears above
  the footer: *"AI Hub unreachable — retrying. Data is 14 min old."*
  Last good numbers stay visible but clearly stale.
- **Gray**: never fetched (first launch / no token yet).

## Motion & craft rules

- Popover opens with a 180ms scale+fade from the status item. No slide.
- The curve draws on once per popover-open via a spring
  (`response: 0.4, dampingFraction: 0.8`), then updates silently.
- Number changes use `.contentTransition(.numericText())`.
- Between 60s polls: zero rendering. Premium = transitions, not a
  running ticker. One sub-second animation per poll, then rest.
- Honor Reduce Motion; pause timers on display sleep; App Nap friendly
  (DispatchSourceTimer with leeway).
- Silent always. No sounds, no haptics, no notifications in v1.

## Anti-slop manifesto (binding)

No gradients-as-decoration (the pulse gradient encodes *time*, that's
allowed). No glows except the health dot's 6px halo. No cards-in-cards.
No emoji. No AI-sparkle iconography. No moralizing color on spend
(red exists exactly once: closed budget border). No auto-generated
"insights". No celebration mechanics. No donut charts. No leaderboards.

## Architecture

SwiftUI `MenuBarExtra` (`.window` style), `LSUIElement = YES` (no dock
icon). ~500-700 LOC, zero external dependencies. macOS 13+ target
(14+ preferred for MenuBarExtra maturity).

```
VelaIshtar/
├── VelaIshtarApp.swift        # @main, MenuBarExtra scene
├── StatusItemController.swift # offscreen NSImage rendering: pulse + border + amount
├── UsageStore.swift           # 60s poll, state machine (fresh/stale/down), history cache
├── AIHubClient.swift          # GET /v1/me/usage, token from Keychain
├── PopoverView.swift          # hero, pace sentence, curve, models, footer
├── PaceEngine.swift           # burn rate → "reach budget around 9:40 pm"
├── BurnHistory.swift          # rolling 60-min pulse buffer + daily snapshots (feeds Ghost in v1.1)
└── SettingsView.swift         # token field (first run), launch-at-login
```

- **Token storage**: macOS Keychain. First run: one text field, done.
- **Polling**: `DispatchSourceTimer`, 60s, 5s leeway, utility QoS.
- **History**: JSON file in `~/Library/Application Support/VelaIshtar/`
  — hourly spend snapshots. Powers the pulse and (v1.1) the Ghost.
- **Build**: checked-in Xcode project or XcodeGen; `xcodebuild` from
  CLI. `make build`, `make install` (copies to /Applications).
- **Distribution**: private repo `NSXBet/vela-ishtar`. Test internally
  first; share the repo + signed build later. v1: zip/DMG by direct
  link; Sparkle/Homebrew cask deferred.

## v1 scope (ships)

Pulse + budget border + amount in the bar. Popover: hero, pace
sentence, today's curve, models list, footer with health dot. 60s
polling, Keychain token, launch-at-login toggle. Light/dark adaptive.

## Cut from v1 (explicit)

The Ghost (v1.1, needs 30 days local history). Team leaderboard (v2,
needs platform team: admin API public URL + Okta flow — parked).
Notifications (the pace sentence covers 90% of the need). Runway-hours
menu bar mode (configurable alternative, later). Sparkle auto-updates.
Homebrew cask. `/healthz` fast ping (only if the endpoint exists).

## Error handling

- Token missing/invalid → popover shows the token field inline with a
  one-line explanation; gray dot.
- Fetch failure → amber state as above; exponential backoff capped at
  5 min; recover silently.
- `limit_enabled: false` → border trace hidden; hero shows spend only.
- Clock skew / UTC day boundary → all day math in UTC, displayed in
  local time; reset moment labeled "midnight UTC" once in the UI.

## Testing

- Unit: PaceEngine (pace → clock time, edge cases: zero spend,
  exhausted, post-midnight-UTC crossover), burn buffer math, dash
  pattern from `used_percent`.
- Snapshot: popover states (fresh, stale, no-token, exhausted,
  light/dark).
- Manual: run against the real gateway with a personal `gt_` token;
  verify month stats return (the open API question above).

## Success criteria

Install it on our own Macs for two weeks. If nobody opens the web
dashboard to check spend anymore, it worked.
