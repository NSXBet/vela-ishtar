# Vela Ishtar

Your AI Hub spend, in the corner of your eye — never in your face.

A premium macOS menu bar app that shows your personal AI Hub (LLM gateway)
usage at a glance: today's spend against your daily budget, your burn-rate
pulse, and the models you're burning through. An instrument, not a
scoreboard.

## What it shows

**In the menu bar** — a single pill:

- A live sparkline of your last hour of burn (the "pulse")
- Today's spend in dollars
- The pill's own border traces your daily budget as it fills — a full
  border means budget exhausted (and it's the only red in the app)

**In the popover** (click the pill):

- **$54.51 of $400 today** — the headline, plus one computed sentence:
  *"At this pace you'll reach budget around 9:40 pm."*
- **Today's curve** — cumulative spend hour by hour, against the budget
  ceiling
- **Models · this month** — ranked by cost
- **● AI Hub** — a health dot that goes amber and dims everything when
  the gateway is unreachable (your data is never silently stale)

## Install

Build from source (no Xcode needed — Command Line Tools only):

```bash
git clone <this repo>
cd aihub-menu-bar
./build.sh
open "build/Vela Ishtar.app"
```

On first launch the popover asks for your AI Hub token (the same `gt_…`
token you use for the gateway). It's stored in your macOS Keychain and
never leaves your Mac except to the AI Hub gateway. macOS will ask once
to authorize the Keychain item — that's normal.

Optional: toggle **Start at login** in the popover footer.

**Notes for teammates who rebuild from source:** each `./build.sh` changes the
ad-hoc signature, so macOS may ask once for Keychain access on the first run
of a new build — that's expected (the app needs its token back). One prompt
per rebuild, one-time for a build you keep. The app is Apple-Silicon-only
(arm64) for now.

**Models period switcher:** the Today / Week / Month control in the popover
switches the models list window. Today and Week currently show the month's
model breakdown — the gateway's `/v1/me/usage` only exposes current-month
per-model data, so per-day model splits aren't available yet (a platform
endpoint would unlock true per-period numbers).

## How it works

- Polls `GET https://ai-llm-gateway.fbr.land/v1/me/usage` every 60s with
  your token. The response is scoped to you only — no one else's data.
- Your daily budget resets at **midnight UTC** (that's how the gateway
  buckets spend). The pace sentence and countdowns use that boundary.
- Your personal limit comes from the API, so the UI auto-scales whether
  your budget is $100, $400, or anything else.
- Hourly spend history is cached locally in
  `~/Library/Application Support/VelaIshtar/history.json` — it powers
  the curve and gets richer the longer you run the app.

## Design principles

Calm assurance. Facts, plainly stated, then silence. No leaderboards, no
notifications, no "AI insights", no celebration mechanics. Monochrome
everywhere except one amber warning and one red alarm. The fewer pixels
that move, the more each one means.

## Tech

Pure AppKit + Swift, zero dependencies, ~1,300 LOC. Builds with bare
`swiftc` into an ad-hoc-signed `.app` — no Xcode, no SwiftPM for the app
itself (SwiftPM runs the `VelaCore` unit tests via `make test`).

```
make test     # 49 unit tests (VelaCore: pace math, burn buffer, border dash, history)
./build.sh    # compile + bundle + ad-hoc sign into build/Vela Ishtar.app
```

## Roadmap

- **The Ghost** (v1.1): your median day drawn faintly behind today's
  curve, computed locally from your own history — anomaly detection by
  the human eye, zero ML.
- Team leaderboard (v2, opt-in): needs the AI Hub platform team to expose
  a team-summary endpoint.

## Privacy

Reads only your own usage. Stores only your token (Keychain) and your
spend history (local file). No analytics, no telemetry, no third-party
network calls — the only host it ever talks to is the AI Hub gateway.
