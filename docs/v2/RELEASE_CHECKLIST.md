# docs/v2/RELEASE_CHECKLIST.md

<!-- WP-12 (12.3, 12.4): what remains between this verified candidate and an
     actual release. Everything here needs either a human at a desktop
     session or an authorized release action — none of it is executable by
     the WP-12 gate agent, and none of it is silently skipped.
     RELEVANT FILES: V2_IMPLEMENTATION_PLAN.md (§12.3/12.4), docs/v2/VERIFICATION.md,
     docs/v2/PERFORMANCE.md, README.md -->

# Vela Ishtar 2.0 — Release checklist

Candidate: `wp12-gate` @ `3b32fa3` (merge-target of `v2.0` @ `f1af8a5`).
Gate evidence: docs/v2/VERIFICATION.md. Performance record:
docs/v2/PERFORMANCE.md. Info.plist remains **1.0.4** — the version bump is
part of step 5 below, executed only at the authorized release moment.

## 1. Pending coordinator action — §12.3 user evaluation protocol

Ask 3–5 intended users to complete six tasks with the packaged app,
unassisted. Target: ≥4/5 successful, with no material misinterpretation of
available budget or history completeness (small-sample — guides refinement,
not statistics).

| # | Task | Success signal |
|---|---|---|
| 1 | Find how much room is left in the global budget | Opens popover (and/or budget detail) and states the remaining dollar amount correctly |
| 2 | Explain what a model cap means for them | Correctly states that hitting a nested cap blocks that model even while global budget remains |
| 3 | Identify when the data is stale | Points at the dimmed pill / "data is N minutes old" line rather than reading stale numbers as current |
| 4 | Inspect a partial day in the history explorer | Opens History explorer, selects a day, recognizes PARTIAL coverage / gaps instead of expecting a full curve |
| 5 | Start and finish a spend marker | Starts a marker from the explorer, finishes it, and reads the measured delta (or its explicit unavailable reason) |
| 6 | Replace an invalid token | Uses the API-key flow after a rejected token; states that the old history stays separate |

Record per-task outcomes verbatim; feed any misinterpretation back to the
coordinator as refinement input (not scope-free expansion).

## 2. Pending measurement run — §12.2 app-level soak

On a logged-in desktop session with Instruments, against the packaged app
(`make release` artifact) with synthetic fixed data:

1. Cold launch → cached-content-ready timing (target p95 ≤250 ms, 100 launches).
2. Warm open p95 ≤100 ms across 100 popover opens; tab p95 ≤50 ms.
3. 15-minute closed warm idle at 60 s polling → mean CPU ≤0.2% of one core.
4. Footprints: closed warm ≤60 MiB; summary+history (90-day fixture) ≤90 MiB.
5. 500 open/close + tab/hover cycle soak → footprint within 5 MiB of
   post-warm baseline; window/observer/timer counts stable (the WP-12
   subview-tree proxy already passed — see PERFORMANCE.md).
6. Per-poll main-thread p95 ≤8 ms via `PerformanceSignposts` capture.
7. Wake/sleep case: mark-stale-on-wake + single refresh request.
Record network environment, display scale, and WindowServer overhead separately.

## 3. Pending visual/accessibility sign-off

- Human review of the 46-fixture live-state matrix (paths in VERIFICATION.md)
  against DESIGN.md §5.3 copy and layout tokens.
- Keyboard-only + VoiceOver walkthrough of: pill menu, popover (both tabs,
  curve hover, budget detail, settings, bell, version dot), history explorer
  (day list, marker start/finish, export, clear).

## 4. Pending distribution checks (§10 "Distribution" row)

- Verify release access with the real private/hosting configuration — the
  unauthenticated endpoint returned HTTP 200/PUBLIC in WP-11's check; re-verify
  at release time.
- Test the actual install channel (Homebrew cask update + direct ZIP) with the
  release artifact.
- Notarization: only if advertised; the app is currently ad-hoc signed — keep
  claims in README truthful on this point.

## 5. Authorized release sequence (12.4 — coordinator + owner only)

1. Bump both `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist` (→ 2.0.0, or the owner's chosen number).
2. Move CHANGELOG's `## [Unreleased] — 2.0` to `## [x.y.z] — <date>`; confirm its first line works as the what's-new one-liner (WhatsNewTests pins the sanitization).
3. `make test` — all green at the bumped version.
4. `make release` — syncs README version/badge, rebuilds, zips with SHA256.
5. Verify the 3-way match: tag commit == release asset digest == cask sha256 == live download.
6. Tag `vx.y.z`, `gh release create`, bump the cask in `NSXBet/homebrew-tap`.
7. Post-release: reconcile README screenshots if the popover changed visually (2.0 is a layout change — 1.x screenshots do not match).

## Known limitations at candidate state (truthful, not blockers)

- App-level §6.1 numbers are pending (section 2 above); core-path and
  lifecycle-proxy numbers are recorded in PERFORMANCE.md.
- 4 cosmetic strict-build warnings (VERIFICATION.md P2 item 4).
- The what's-new list is generated from CHANGELOG.md at build time; the 2.0
  entry's one-liner must be release-edited only via the changelog (B17 rule).
