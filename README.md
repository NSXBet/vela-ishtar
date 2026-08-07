<div align="center">

# Vela Ishtar

**Your AI Hub spend, in the corner of your eye — never in your face.**

A premium macOS menu bar app that shows your personal AI Hub (LLM gateway)
usage at a glance. An instrument, not a scoreboard.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20(Apple%20Silicon)-000000?style=flat-square&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift%206-AppKit%20%C2%B7%20zero%20deps-F05138?style=flat-square&logo=swift&logoColor=white)
![Tests](https://img.shields.io/badge/tests-137%20passing-30d158?style=flat-square)
![License](https://img.shields.io/badge/internal-NSX-8a8a8e?style=flat-square)
[![Changelog](https://img.shields.io/badge/changelog-Keep%20a%20Changelog-blue?style=flat-square)](CHANGELOG.md)

<img src="docs/assets/popover-dark.png" width="340" alt="Vela Ishtar popover">

</div>

## The menu bar

One pill. Three instruments.

<img src="docs/assets/pill-dark.png" alt="The pill: burn sparkline + amount + budget border">

- **The pulse** — a live sparkline of your last hour of burn
- **The amount** — today's spend in dollars
- **The border IS the budget** — the pill's own outline traces your daily
  budget as it fills. Amber past 85%, a closed red loop at 100% (the only
  red in the app):

<img src="docs/assets/pill-amber-dark.png" alt="Amber past 85%"> <img src="docs/assets/pill-exhausted-dark.png" alt="Red closed loop at 100%"> <img src="docs/assets/pill-stale-dark.png" alt="Dimmed when the gateway is unreachable">

## The popover

Click the pill. One panel, no tabs — hairlines and whitespace only.

- **$54.51 of $400 today**, plus one computed sentence:
  *"At this pace you'll reach budget around 9:40 pm."*
- **Today's curve** — cumulative spend hour by hour, against the ceiling
- **Models** — ranked by cost, with a Today / Month switcher
- **● AI Hub** — a health dot that goes amber and dims everything when
  the gateway is unreachable (your data is never silently stale)
- **Loading state** — on first open you get a calm "Connecting to AI Hub…"
  panel that swaps to real data the moment the first poll lands

<img src="docs/assets/popover-light.png" width="340" alt="Popover, light appearance">

## Install

**Direct download (recommended):**

```bash
curl -LO https://github.com/NSXBet/vela-ishtar/releases/download/v0.1.1/VelaIshtar-0.1.1.zip
unzip VelaIshtar-0.1.1.zip -d /Applications/
open -a "Vela Ishtar"
```

**Homebrew** (once the tap is public):

```bash
brew tap NSXBet/tap
brew install --cask vela-ishtar
open -a "Vela Ishtar"
```

The app is ad-hoc signed, so on first launch macOS may ask you to
right-click → Open (or run `xattr -cr "/Applications/Vela Ishtar.app"`).
That's expected — we don't have an Apple Developer account yet.

**After launching:** there is no window — Vela Ishtar is a menu bar app.
Look top-right, next to the clock: a small pill showing today's spend.
Click it for the full popover. If you don't see the pill, your menu bar
may be full (common on notched MacBooks) — quit a few other menu bar
apps and relaunch.

**From source** (no Xcode needed, Command Line Tools only):

```bash
git clone https://github.com/NSXBet/vela-ishtar.git
cd vela-ishtar
./build.sh
open "build/Vela Ishtar.app"
```

On first launch the popover asks for your AI Hub token (the same `gt_…`
token you use for the gateway). It's stored in your macOS Keychain and
never leaves your Mac except to the AI Hub gateway. macOS asks once to
authorize the Keychain item — that's normal.

Optional: toggle **Start at login** in the popover footer.

## How it works

- Polls `GET https://ai-llm-gateway.fbr.land/v1/me/usage` every 60s with
  your token. The response is scoped to you only.
- Your daily budget resets at **midnight UTC** — that's how the gateway
  buckets spend. The pace sentence uses that boundary.
- Your personal limit comes from the API, so the UI auto-scales whether
  your budget is $100, $400, or anything else.
- Hourly spend history is cached locally in
  `~/Library/Application Support/VelaIshtar/history.json` — it powers
  the curve and gets richer the longer you run the app.

**Models period switcher:** Today derives a per-model split by
differencing the gateway's month-cumulative figures against a locally
stored snapshot of yesterday — reconciled against your real daily total,
so the rows always tie (any truncation residue lands in an explicit
"Other" row). The split unlocks after the app has observed one midnight
UTC; before that, Today shows your real daily total from the API. Month
ranks models by current-month cost. A Week segment was removed for now —
the gateway's `/v1/me/usage` has no weekly per-model endpoint.

**Comparison surfaces** (the ghost curve behind today's, the median-day
sentence, and the 7-day strip) switch on after ~5 days of clean local
history — the app prefers silence over a confident number computed from
thin data.

**Rebuilding from source:** each `./build.sh` changes the ad-hoc signature,
so macOS may ask once for Keychain access on the first run of a new build.
One prompt per rebuild; one-time for a build you keep. Apple Silicon only
(arm64) for now.

## Design principles

Calm assurance. Facts, plainly stated, then silence. No leaderboards, no
notifications, no "AI insights", no celebration mechanics. Monochrome
everywhere except one amber warning and one red alarm. The fewer pixels
that move, the more each one means.

## Tech

Pure AppKit + Swift, zero dependencies, ~1,400 LOC. Builds with bare
`swiftc` into an ad-hoc-signed `.app` — no Xcode. SwiftPM runs the
`VelaCore` unit tests.

```bash
make test     # 137 unit tests (pace math, burn buffer, border dash, history)
./build.sh    # compile + bundle + ad-hoc sign into build/Vela Ishtar.app
```

## Privacy

Reads only your own usage. Stores only your token (Keychain) and your
spend history (a local file). No analytics, no telemetry, no third-party
network calls — the only host it ever talks to is the AI Hub gateway.
