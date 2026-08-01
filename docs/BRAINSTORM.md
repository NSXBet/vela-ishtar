# AI Hub Menu Bar App — Brainstorm

Status: **brainstorming** (no code yet — design gets discussed and approved first).

## The idea in one line

A premium macOS menu bar app for NSX colleagues that shows your AI Hub
(LLM gateway) usage and spend at a glance — cost per model, spent vs
available budget — right next to the wifi icon.

## Why it exists

NSX moved off direct Anthropic subscriptions onto the internal **AI Hub**
gateway. Everyone's LLM spend now flows through one place with per-user
API tokens and daily budgets. The only window into that spend today is
the web dashboard (screenshot below) — you have to remember to open it.

A menu bar app makes spend *ambient*: always visible, zero effort.
And it's a gift to the team — a small, beautiful internal tool that
makes the AI Hub feel like a real product.

## What the current web dashboard shows (screenshot, 2026-08-01)

- Daily budget bar: `$6.79 / $400` (2% used) in the sidebar
- Time ranges: Today, 7d, 15d, This month, Last month
- Total cost: `$6.79` (73 requests), total tokens: `8.56M`
- Split: user credentials vs service credentials
- Top models: kimi-k3 `$4.90` (3.79M tok), claude-haiku-4.5 `$1.89` (4.77M tok)
- Top clients: Claude Code `$6.79`
- Top credentials: `daniel-tok` (user)
- 39 models available through the gateway (Auto, Balanced routing modes)

## AI Hub repo landscape (GitHub org NSXBet)

| Repo | What it is |
|---|---|
| `NSXBet/aihub` | Hub repo (orientation, submodules) |
| `NSXBet/aihub-gateway` | The gateway itself (Go) — **the API we need** |
| `NSXBet/ishtar` | "The LLM API Gateway for Flutter Brazil and AI Hub" (Go) |
| `NSXBet/aihub-ui` | The web dashboard (TypeScript) |
| `NSXBet/aihub-user-docs` | User docs (MDX) |
| `NSXBet/aigateway` | Newer self-hosted AI gateway w/ usage analytics (Go) |

Open question the research agents are answering: **exactly which HTTP
endpoints expose per-user usage/cost data, and with what auth.**

## Design bar (user's words)

> PREMIUM, HIGH END, fancy, minimalist.
> We don't need to copy slop from the internet and have same slop
> different packaging.

## Process

1. ✅ Folder created, context gathered
2. ✅ Parallel research done (4 agents) — findings below
3. ⬜ Pick direction → write design doc → implementation plan

---

# RESEARCH FINDINGS (2026-08-01)

## 1. Feasibility — the API exists and it's good

**Self-serve (any employee, no admin rights):**

`GET https://ai-llm-gateway.fbr.land/v1/me/usage` with your own
`gt_` token (the same token used for inference — Bearer or x-api-key).

Returns everything the app needs:

```json
{
  "token_id": "...",
  "daily_budget":  { "limit_usd": 400, "spent_usd": 6.79,
                     "remaining_usd": 393.21, "used_percent": 2,
                     "limit_enabled": true, "spend_date": "..." },
  "current_month": { "total_cost_usd": 6.79, "total_tokens": 8560000,
                     "requests": 73, "period_start": "...", "period_end": "..." },
  "top_models":    [ { "model": "kimi-k3", "total_cost_usd": 4.90,
                       "total_tokens": 3790000, "requests": 51 } ]
}
```

Also `GET /v1/models` → full model catalog with per-token pricing.

**Team leaderboard (admins only):** `/spend/user-summaries`,
`/spend/users`, `/spend/report` on a separate admin server —
requires an **Okta JWT** in groups FBRP_AIHUB_Owner / Dev_Team / FBRA_AIHUB.
The admin server's public URL is NOT documented (the web UI proxies it
server-side). No public OAuth client exists for third-party apps.

**Consequence: v1 = personal instrument (your own usage) — one HTTPS
GET + your existing token, zero backend work. Team leaderboard is a v2
question that needs the platform team (admin URL + Okta flow).**

Open items to verify live: does /v1/me/usage work with gt_ tokens for
month stats (spec is ambiguous); is there rate limiting on polling.

## 2. Similar apps — what to steal, what to avoid

**Steal:**
- **Pacing, not progress** — "used 62% of budget with 45% of the day
  elapsed" + projected time-to-budget. The most actionable element in
  every cost app studied (ccusage, Rocket Money, Claude quota trackers).
- **Two-number hero** — "MTD spend · forecast", delta arrow vs yesterday.
- **Ranked model list with hairline proportional bars** — not a donut.
- **Countdown framing** — "$393 remaining · resets at midnight".
- **Honest stale state** — gray hero + "stale · 12m ago" beats a spinner.

**Avoid (the slop list):** purple gradient SaaS cards, neon-glow dark
charts, 6-8 competing stat cards, 3D donuts, zebra tables with pill
badges, rainbow stacked areas, decorative count-up animations,
"AI insights" sidebars that restate the chart in prose.

## 3. Premium macOS craft — the recipe

- **Icon**: monochrome template image only (macOS auto-inverts for
  light/dark/Tahoe Liquid Glass). Color lives inside the popover, never
  in the bar.
- **Popover**: `.menuBarExtraStyle(.window)` + vibrancy, 12-16pt radius,
  hairline separators, no cards-in-cards.
- **Type**: SF Pro, hero number semibold + `monospacedDigit()` (no
  jitter), secondary text in `.callout`/secondary color.
- **Color**: system grays + ONE semantic accent. Green/amber/red only
  as status, never decoration.
- **Motion**: 180ms scale+fade open from the status item; chart draws
  once with a spring; `contentTransition(.numericText())` on number
  changes; silent afterwards. No sound.
- **States**: empty/offline/loading designed as first-class citizens.

**Tech call: SwiftUI MenuBarExtra + hand-drawn Canvas charts.**
~500-700 LOC, zero deps, builds from CLI with xcodebuild, native
vibrancy/dark-mode/Liquid Glass free. Electron/Tauri would hand-roll
all of that and still look slightly off. Mac-only internal tool →
SwiftUI is strictly less code and more premium.

Exemplars: CleanShot X (zero chrome), Tailscale (icon encodes state),
iStat Menus 7 (dense tabular discipline), Ice (open-source proof that
restraint reads premium).

## 4. Second-model brainstorm (Sol 5.6 Max) — highlights

- **Name: "Meter"** — your AI spend, in the corner of your eye,
  never in your face. Emotional core: **calm assurance**, not a
  scoreboard. (Leaderboard deliberately rejected for v1 — a betting
  company doesn't need more adrenaline in its tooling.)
- **Menu bar**: three options — (A) ring + number [safe, boring],
  (B) a 22px live burn-rate sparkline "pulse" [original, glanceable],
  (C) "runway" hours remaining [radical, needs smoothing].
  Pick: B for v1, C as configurable alternative.
- **Popover**: one panel ~320px, no tabs. Headline "$6.79 of $400" +
  one computed sentence ("At this pace you'll reach budget around
  9:40 pm") + today's cumulative curve + ranked model list + quiet
  footer. Tokens banished from the headline — cost is the company's
  language.
- **Signature feature — "The Ghost"**: your median day from the last
  30 days drawn as a faint second line behind today's curve. Anomaly
  detection by the human eye in <1s, zero ML, zero "AI insights" copy.
  Gets more accurate the longer you use it. (v1.1 — needs local history.)
- **Anti-slop manifesto**: no gradients, no glows, no cards-in-cards,
  no emoji, no AI-sparkle iconography, no moralizing red/green on
  spend, no auto-generated insights, no celebration mechanics.

