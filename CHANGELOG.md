# Changelog

All notable changes to Vela Ishtar, newest first. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
semantic versioning.

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

[0.3.2]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.3.2
[0.3.1]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.3.1
[0.3.0]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.3.0
[0.2.1]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.2.1
[0.2.0]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.2.0
[0.1.2]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.1.2
[0.1.1]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.1.1
[0.1.0]: https://github.com/NSXBet/vela-ishtar/releases/tag/v0.1.0
