# Vela Ishtar — next steps

Where things stand and exactly what to do, in order. Written so you can pick
this up cold.

---

## Current state (as of 2026-08-08)

- **Shipped:** v0.5.0 and **v0.5.1** are both live. v0.5.1 (curve hover
  scrubber) is tagged (`v0.5.1`, commit `21ccb6e`), released on GitHub, cask
  bumped, 3-way verify green, and installed on your Mac.
- **Still open — the readout truncation.** The hover readout card shows
  `3 pm ·` but the money (`$35.00`) is cut off. Layout is provably correct
  (offscreen renders show the full text), so it's environmental — top suspect
  is the **60s rebuild firing mid-hover** and leaving the floating readout
  panel stale/clipped. This fix now lands in **v0.5.2** alongside the update
  bell.

### What shipped in v0.5.1 (committed at `21ccb6e`)
- `Sources/VelaCore/CurveScrub.swift` — seam math (hour snap, gaps-stay-gaps,
  readout text). TDD'd, 13 tests.
- `Sources/App/CurveView.swift` — crosshair + dot, floating readout NSPanel,
  one-shot sonar ring (Reduce-Motion gated), rebuild-safe scrub re-derive,
  midnight-rollover stale-card fix, label width slack.
- `Sources/VelaCore/WhatsNew.swift` — changelog card now LEADS with the running
  version's note (your screenshot catch). Confirmed working on your screen.
- `Sources/App/PopoverView.swift` — one-line wire-up (`rearmScrubRing()`).

Review (kimi k3, deep-reasoner) verdict was **ship**; both its findings were
fixed before release.

---

## Immediate next step (do this FIRST)

**Fix the readout truncation with real data, not mocks.** Stop rendering
offscreen probes — they look fine and don't reproduce it. Instrument the real
app to log the panel frame + label state *while hovering*, so we catch the
truncation in the act:

1. Add temporary `NSLog`/`print` in `CurveView.updateReadout()` (around line
   409-477) logging: `scrub.hour`, `text`, `textSize`, `cardWidth`,
   `panel.frame`, `label.frame`, `label.fittingSize`, and whether a rebuild
   (`configure()`) just ran.
2. Also log in `PopoverView.update()` (line 90) each time the 60s rebuild
   fires, so we can see if it lands mid-hover.
3. Build, install, hover the curve, read the log (`log show --last 2m` or
   Console.app).
4. Find the mismatch, fix it, remove the logging.

Only after the readout shows the full `3 pm · $35.00` on YOUR screen is this
bug actually closed. Fold the fix into the v0.5.2 release below.

---

## v0.5.2 — readout truncation fix + update bell (last of the five features)

**Part 1 — the truncation fix** (from the step above): whatever the logging
reveals, fix it, add a VelaCore regression test if the logic is testable, and
confirm on your screen.

**Part 2 — the update bell:** the bell near the changelog dot that shows "a new
version is available", pulls from GitHub, and gives an easy install.

- `Sources/VelaCore/VersionCheck.swift` — `isNewer(_:than:)` semver compare +
  a `GitHubRelease` DTO. TDD (~8 tests).
- `Sources/VelaCore/ReleaseChecker.swift` — hits
  `api.github.com/repos/NSXBet/vela-ishtar/releases/latest`, sets a User-Agent
  header, 6h throttle, silent when offline.
- UI: SF Symbol bell to the LEFT of the version dot, visible only when a newer
  release exists. Click → card with: Copy-command button
  (`brew update && brew upgrade --cask vela-ishtar && xattr -cr
  "/Applications/Vela Ishtar.app"`), a GitHub releases link, and "Skip this
  version" (stored in UserDefaults).

**v0.5.2 release pipeline (same as always):** tests → `./build.sh` → CHANGELOG
`## [0.5.2]` entry → bump BOTH Info.plist keys to 0.5.2 → `make readme-version`
→ commit → you push branch + tag (`!`) → `gh release create v0.5.2` + upload
zip (canonical filename) → cask bump (`gh api -X PUT`, base64 + current blob
sha) → 3-way verify (tag commit == asset digest == cask sha256 == live
download) → kimi k3 review.

---

## Standing constraints (don't forget)

- **I never push.** You run all `git push` with the `!` prefix (guard hook
  blocks me).
- **No AI attribution** in anything that ships — no `Co-Authored-By`, no
  "Generated with" footers, no mention of any AI as author/reviewer. First-person
  voice.
- **TDD at VelaCore seams** — every bugfix gets a regression test that fails
  without the fix; test behavior not implementation; no sleeps. AppKit view code
  stays untested by design.
- **Bump BOTH Info.plist keys** every release.
- **`gh release upload` names the asset after the file's basename** — stage the
  zip under its canonical name before uploading.
- **kimi k3 review after each version** — dispatch via `subagent_type:
  "deep-reasoner"` with NO `model` override (the model frontmatter pins kimi-k3;
  passing `model: "kimi-k3"` throws a validation error).
- 80/20 simplicity; files under ~300 LOC; never delete header comments.

---

## Reference

- Repo: `/Users/nsx001215/Desktop/Projects/aihub-menu-bar` (NSXBet/vela-ishtar)
- Review brief used for v0.5.1: `/tmp/vela-v051-review-brief.md`
- v0.5.1 shipped as commit `21ccb6e`, tag `v0.5.1`, zip sha256
  `53b25cf8b1c804b0da9c8f4fd0d1e8b7f9a037cffd353acfcbbf0058cc313832`, cask
  commit `64d1370`.
- Install/update for users: `brew update && brew upgrade --cask vela-ishtar &&
  xattr -cr "/Applications/Vela Ishtar.app"`
