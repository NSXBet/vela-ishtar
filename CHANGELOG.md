# Changelog

All notable changes to Vela Ishtar, newest first. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
semantic versioning.

## [0.4.0] — 2026-08-07

Motion release: the curve, the tabs, and the card itself now move at 60fps.

### Changed

- **The spend curve sweeps on at a true 60fps.** It used to step its
  draw-on progress through 14 `DispatchQueue` timers, which weren't locked
  to the display's refresh and visibly dropped frames when the main thread
  was busy. Now the curve renders once and a GPU-composited mask reveals it
  left-to-right over half a second — vsync-locked, so the sweep is smooth
  even while a poll lands mid-animation.
- **The Today / Month switcher slides.** Replaced the stock segmented
  control with a custom tab pair: a hairline indicator glides to the tab
  you tap. The indicator is positioned (not re-slid) on the 60s poll
  refresh, so it only ever moves when you actually touch it.
- **The popover's height settles instead of snapping.** When content grows
  or shrinks (a stale banner appearing, the models list filling in), the
  card used to jump to its new height and let every row slide into place.
  Now the current content freezes as a top-anchored snapshot while the card
  eases to its new height underneath, then the live content fades back in —
  the top edge you were reading never moves.
- **All three respect Reduce Motion.** With macOS's Reduce Motion enabled,
  the curve draws fully-formed, the indicator snaps, and the card resizes
  without animation — nothing moves that shouldn't.

## [0.3.4] — 2026-08-07

Cold-open fix: the last reading shows instantly instead of a blank spinner.

### Fixed

- **Cold-open shows the last reading instantly.** On a cold start (or the
  first open after launch) the popover used to render a bare spinner with
  no cost for the 0.5–1s until the first fetch landed. Now, if today's
  local history holds a reading, the popover rehydrates from it: the hero
  number and curve render immediately in the dimmed stale treatment with a
  "Last reading · Nm ago" caption, then the live poll brightens them in
  place — a brightness change, not a numbers jump. It never shows
  yesterday's figures as today's; a true first run still shows the spinner.
- **Popover re-opens at the right size.** `PopoverPanel.panelSize` was a
  frozen `let` captured at init, so after the panel resized itself live the
  next open snapped back to the stale 480pt height before settling. It now
  reads the panel's live frame, so a re-open starts from the correct size.
- **"Start at login" checkmark tells the truth.** Toggling it called
  `needsDisplay`, which redraws pixels but doesn't rebuild the button title
  the checkmark is baked into — so the glyph lagged the real status until
  the next poll. The toggle now re-renders through the same path the period
  switcher uses, so the checkmark always reflects `SMAppService` status.

### Changed

- **What's-new list is generated from the changelog at build time.** The
  version bullet's notes were a hand-kept array in the view that drifted
  from the shipped release more than once. `build.sh` now extracts the top
  three changelog sections into the app bundle, so the bullet can never
  drift ahead of (or behind) the binary. Falls back to a built-in list when
  running outside a packaged build.
- **README syncs itself.** A `make readme-version` target derives the
  version and test count from their sources of truth (`Info.plist`, the
  test suite) and rewrites the README's badge and install URL, wired into
  `make release` — no more hand-edited drift.

## [0.3.3] — 2026-08-07

The version bullet's tooltip now actually shows.

### Fixed

- **Version bullet tooltip works on the nonactivating panel.** The popover
  is a borderless NSPanel that never becomes key, and AppKit's native
  `toolTip` only resolves through the key window — so hovering the dot
  silently showed nothing in 0.3.2. The tip is now a custom floating card:
  a 400ms discoverability delay, placed beside the popover (never over the
  hero numbers, flipping left on a right-anchored menu bar), with a quick
  fade in and a snappier fade out. Respects Reduce Motion. The bullet also
  shows before the first poll lands, so an offline first run can still
  answer "what am I running".

## [0.3.2] — 2026-08-07

Legibility patch: the strip reads as a week, and the app can tell you what
it is.

### Added

- **Version bullet** — a 6pt dot in the popover's top-right corner. Hover
  shows the running version plus a minimal what's-new list, without a trip
  to GitHub.

### Fixed

- **The 7-day strip reads as a week now.** A hairline baseline ties the
  seven columns together, and a real-but-small day ($13 next to $160) gets
  a 2pt floor instead of a sub-pixel smudge. Previously a sparse history
  rendered as floating ticks with no grid to read against.
- **The strip hides until 4 of 7 days have data.** A 3-day history showed
  disconnected marks that read as UI debris; silence beats noise, same law
  as the ghost curve.

## [0.3.1] — 2026-08-07

Trust patch: the full v0.3.0 dual review folded back into the app.

### Fixed

- **`spend_date` is a calendar label, never a UTC instant.** A numeric-offset
  timestamp like `2026-08-07T00:00:00+03:00` used to be reformatted in UTC and
  land on `2026-08-06`, silently splitting one billing day across two history
  keys. Day keys are now the label's `yyyy-MM-dd` prefix, with a regression
  test covering every observed wire shape.
- **Pill condensation re-evaluates on every render.** The width update moved
  ahead of the unchanged-state early return, and an absent button window now
  reports clipped (narrow is the safe failure). A notch-clipped pill no longer
  stays wide just because overnight polls were identical.
- **The ghost curve always feeds the y-scale.** Only its stroke hides when
  data is stale — the scale no longer visibly jumps on fresh/stale flaps.
- **Ghost gaps stay gaps.** Under-sampled hours used to be skipped by the
  drawing code, drawing a confident straight line across them. The stroke now
  lifts at every gap; each contiguous run is its own segment.
- **The Today breakdown can never drop its Other row.** Five named models
  plus a residual produced six rows but only five rendered, so the visible
  split stopped tying to the day total. Display now keeps at most four named
  rows and folds the tail into a pinned fifth Other.
- **The median-day sentence and the ghost share one window** (14 most recent
  clean days), so the two can never disagree about what "a typical day" is.

### Changed

- When the per-model split is unavailable because the app wasn't running at
  yesterday's close, the note now says so ("needs one full day of the app
  running") instead of reading as a permanent error. It self-heals from
  tomorrow's baseline.

## [0.3.0] — 2026-08-07

The memory release: the app gets richer the longer it runs.

### Added

- **Ghost curve** — the median of your ≤14 most recent clean days drawn
  behind today's curve at 20% opacity. No legend, no label; the shape is the
  sentence. Appears after ~5 clean days.
- **7-day strip** — hairline bars under the curve, one per gateway day ending
  at today, with a red scar tick on days that hit budget.
- **Per-model Today** — today's spend split by model, derived by differencing
  month-cumulative snapshots and reconciled against the authoritative daily
  total with an explicit Other row. Never shows a split that doesn't tie;
  unlocks after the app observes one midnight UTC.
- **Pill condensation ladder** — full (88pt) → compact (52pt) → hairline
  (26pt), chosen in the right-click menu or automatically when the notch
  clips the status item.

### Fixed

- History keys normalize to the gateway's `spend_date` on load, merging any
  pre-normalization duplicates (per-hour max wins).

## [0.2.1] — 2026-08-07

Review-fix patch over 0.2.0.

### Fixed

- Popover dismiss race (generation counter could restore alpha on a panel
  that a newer show had already reused).
- Running-max guard on history recording: restatements larger than
  max(1% of peak, $0.50) are rejected instead of recorded.
- Median-day and month-runway lines only render on fresh data.

## [0.2.0] — 2026-08-07

The sentence that always says something, plus unit economics.

### Added

- **Median-day benchmark** — when the pace verdict is the inert "on pace to
  stay under budget," the hero line instead compares today against your
  median day by this hour ("Typical day by now: $34 — you're at $12").
  Requires ≥5 clean days; silence beats a noisy baseline.
- **$/Mtok on model rows** — the models list now shows unit price
  ($1.29/Mtok) instead of raw token volume.
- **Month runway** — "On track for ~$X this month" on the Month view,
  suppressed during the first 6 days of a month.
- **Popover choreography** — panel fades in while translating down from the
  pill; the curve draw starts 60ms later. Respects Reduce Motion.

## [0.1.2] — 2026-08-07

The trust release: nothing the app shows may be a lie.

### Fixed

- **Day-boundary bug** — history is keyed by the gateway's `spend_date`, not
  the local clock's UTC date. The two disagree around midnight, which used to
  file yesterday's total under today and make the curve visibly decrease
  within a day.
- **Contaminated days are filtered on load** — days whose hourly readings
  regress beyond tolerance (leftovers of the old keying) are dropped with a
  log line, so they can't poison medians and ghosts.

### Added

- **Right-click menu** on the pill: Copy today's spend, Open history folder,
  Quit.
- **VoiceOver** label and live value on the status item.

## [0.1.1] — 2026-08-06

### Fixed

- Token field accepts paste (⌘V) on first run.
- First-launch panel positions correctly.

## [0.1.0] — 2026-08-05

First public release.

### Added

- Menu bar pill with live spend, burn-rate buffer, and border dash at budget.
- Popover with the day's cumulative curve, pace verdict + sentence, models
  list, and Today/Month switcher.
- Token entry (AI Hub `gt_` key), 60s polling, stale-data banner, spend
  history persisted across launches.

[0.4.0]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.4.0
[0.3.4]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.3.4
[0.3.3]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.3.3
[0.3.2]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.3.2
[0.3.1]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.3.1
[0.3.0]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.3.0
[0.2.1]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.2.1
[0.2.0]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.2.0
[0.1.2]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.1.2
[0.1.1]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.1.1
[0.1.0]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.1.0
