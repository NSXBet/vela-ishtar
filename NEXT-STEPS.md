# Vela Ishtar — next steps

Where things stand and exactly what to do, in order. Written so you can pick
this up cold.

---

## Current state (as of 2026-08-08)

- **v1.0.0 is staged in the working tree, not yet committed or tagged.**
  Everything below is done: `./build.sh` clean, `make test` green at **210
  tests**, Info.plist bumped on BOTH keys, CHANGELOG `## [1.0.0]` written,
  `make readme-version` run, README + this file updated.
- **What v1.0.0 gathers up.** The whole five-feature line, released as one:
  the update bell + one-line install, the curve hover scrubber, the models
  table polish, the GitHub-style day strip — now a true **Monday–Sunday
  calendar week with per-day cost on hover** — and the round-3/4 fixes (bell
  layer drift via `anchorPoint`, Cancel's first click, footer overlap moved
  into the tested `FooterLayout` seam, strip relocated off the curve).
- **Landed in this pass:**
  - `Sources/VelaCore/DayStrip.swift` — `week()` is now a Monday-anchored
    calendar week; days after today come back nil (a future day must never
    join the week's max). New `hoverText(total:)` seam for the cost card.
  - `Tests/VelaCoreTests/DayStripTests.swift` — rewritten week half: Monday
    ordering, today mid-week, future-days-nil, month AND year boundary
    crossings, and the `>=4` gate proven un-gameable by future days. 9 of
    them fail against the old rolling window (verified by reverting just the
    arithmetic).
  - `Sources/App/DayStripView.swift` — static `M T W T F S S` letters, hover
    highlight ring, floating cost card (a non-activating `NSPanel`, same
    idiom as the curve readout — native tooltips still don't fire on this
    panel).
  - `Sources/App/CurveView.swift` — 13pt `nowLabelGutter` at the bottom of
    the lane. The "now" label wasn't misplaced; the plot floor was sitting on
    top of it. Before/after offscreen renders show the stroke and the glyphs
    sharing a row previously, three rows apart now.

### Before tagging

- **Clear the fake-release seed.** There's a local `defaults write` on this Mac
  pinning `updateCheck.cachedTag` to a phantom high version, so the bell stays
  visible for testing. It's UserDefaults only — verified absent from the repo,
  the bundle, and the binary — but clear it once you've eyeballed the real bell
  behaviour, or the shipped 1.0.0 will keep announcing a release that doesn't
  exist on your own machine:
  ```
  defaults delete com.nsxbet.velaishtar updateCheck.cachedTag
  defaults delete com.nsxbet.velaishtar updateCheck.cachedURL
  defaults delete com.nsxbet.velaishtar updateCheck.lastCheck
  ```
  (Dropping `lastCheck` too lets the next launch re-check immediately instead
  of waiting out the 6h throttle, so you see the true state right away.)
- Then the usual pipeline: commit → you push branch + tag (`!`) →
  `gh release create v1.0.0` + upload zip under its canonical name → cask bump
  → 3-way verify → review.

---

## History

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

The readout truncation that was open at v0.5.1 is closed — the fix was sizing
the card from the label's own `fittingSize` rather than the attributed string's
tight glyph box (commit `7059ecc`).

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
