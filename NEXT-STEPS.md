# Vela Ishtar — next steps

Where things stand and exactly what to do, in order. Written so you can pick
this up cold.

---

## Current state (as of 2026-08-08)

- **Shipped:** v0.5.0 is live (tag `v0.5.0`, commit `6db4f06`, cask updated,
  installed on your Mac via brew).
- **In progress:** v0.5.1 — the curve hover scrubber. **Code is done and all
  168 tests pass**, but it is **NOT released yet**. The changes sit uncommitted
  in the working tree (`git status` shows them as modified/untracked).
- **Blocked on one bug:** the hover readout card shows `3 pm ·` but the money
  (`$35.00`) is cut off. Layout is provably correct (offscreen renders show the
  full text), so it's environmental — top suspect is the **60s rebuild firing
  mid-hover** and leaving the floating readout panel stale/clipped.

### v0.5.1 already done (in the working tree, uncommitted)
- `Sources/VelaCore/CurveScrub.swift` — the seam math (hour snap, gaps-stay-gaps,
  readout text). TDD'd.
- `Tests/VelaCoreTests/CurveScrubTests.swift` — 13 tests.
- `Sources/App/CurveView.swift` — crosshair + dot, floating readout NSPanel,
  one-shot sonar ring (Reduce-Motion gated), rebuild-safe scrub re-derive,
  midnight-rollover stale-card fix, label width slack.
- `Sources/VelaCore/WhatsNew.swift` + `Tests/.../WhatsNewTests.swift` —
  changelog card now LEADS with the running version's note instead of dropping
  it (your screenshot catch). 4 tests updated/added.
- `Sources/App/PopoverView.swift` — one-line wire-up (`rearmScrubRing()`).

Review (kimi k3, deep-reasoner) verdict was **ship**; its two findings are
already fixed above.

---

## Immediate next step (do this FIRST tomorrow)

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

Only after the readout shows the full `3 pm · $35.00` on YOUR screen do we
release v0.5.1.

---

## v0.5.1 release pipeline (once truncation is confirmed fixed)

1. `make test` — all green (168).
2. `./build.sh` — clean.
3. CHANGELOG: prepend `## [0.5.1] — <date>` entry (curve hover scrubber:
   crosshair + snapping dot + floating readout + one-shot sonar ring; changelog
   card now leads with the running version's note).
4. Info.plist: bump BOTH `CFBundleShortVersionString` and `CFBundleVersion` to
   `0.5.1`.
5. README: `make readme-version` to sync badge (168 tests) + version.
6. Commit the working tree (it's currently uncommitted — this is the whole
   v0.5.1 diff).
7. Push branch + tag (**you run pushes with `!`** — the guard hook blocks me).
8. `gh release create v0.5.1` + upload `VelaIshtar-0.5.1.zip`.
9. Cask bump in `NSXBet/homebrew-tap` (`gh api -X PUT
   .../Casks/vela-ishtar.rb`, base64 + current blob sha).
10. 3-way verify: tag commit == release asset digest == cask sha256 == live
    download hash.
11. kimi k3 review on the shipped diff (already done pre-release; re-run if the
    truncation fix touches real logic).

---

## v0.5.2 — update bell (last of the five features)

The bell near the changelog dot that shows "a new version is available", pulls
from GitHub, and gives an easy install.

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
- Same pipeline: tests → build → CHANGELOG → plist → README → commit → you push
  → release → cask → 3-way verify → kimi k3 review.

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
- Staged v0.5.1 diff snapshot: `/tmp/vela-v051.diff` (stale — the working tree
  has since moved with the review fixes + changelog fix)
- Install/update for users: `brew update && brew upgrade --cask vela-ishtar &&
  xattr -cr "/Applications/Vela Ishtar.app"`
