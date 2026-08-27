# Nested model budgets in Vela Ishtar

Date: 2026-08-28
Status: APPROVED 2026-08-28

Decisions locked by the user:
1. 4pt pill dot accepted for v1 — shown only when an enforced cap is >=90% or
   blocked, suppressed during active cooldown. The outer border stays
   exclusively global.
2. The sentence slot yields when a model is blocked/exhausted, with no invented
   crossing time. Global exhaustion takes priority.
3. Cooldown is decoded and shown as "Opus 5 limit relaxed until ..."; spend/limit
   context is retained while blocked/alarm semantics are suppressed until
   expiry.

Independently signed off by the Codex reviewer (vela-review) on the same three
points, after it verified the baseline at 246 tests / 16 suites green.

## The policy

The AI Hub gateway caps higher-cost models at a daily dollar amount per user —
currently `aihub/claude-opus-5` at $20/day. Admins can raise or remove it.

The cap is **nested inside** the global daily budget, not a separate wallet.
Opus dollars count toward both. Confirmed three independent ways:

1. 60-sample / 12-minute live sampling: global +5.9318 vs Opus +4.7951
   (ratio 0.81 — Opus was ~81% of spend, the remainder other models). Global
   rising *more* than Opus is the nested signature.
2. Gateway source (`internal/usecases/gateway_spend_limit.go`): the global
   reservation is taken first, then the model reservation; if the model
   reservation fails the global one is released; on finalization both
   aggregates are written in one transaction.
3. The AI Hub dashboard renders "Model budgets" as a nested subsection under
   "Daily budget".

**Consequence that drives the whole design:** $20 is 5% of $400, so the model
cap is almost always the *binding* constraint. Observed live during design:
Opus at 73.8% while the global budget sat at 31.5%. Under today's UI nothing
on screen says so.

## What the API already gives us

`GET /v1/me/usage` → `daily_budget.model_budgets[]`, each entry:
`model`, `spent_usd`, `limit_usd`, `remaining_usd`, `percent_used`,
`cooldown_eligible`, `cooldown`.

The app currently **decodes this away** — `DailyBudget` has no such field.

Verified facts:

- `spent_usd` is TODAY's per-model spend, delivered authoritatively. No
  derivation, so none of `TodayModelSplit`'s `.unavailable` failure modes.
- `remaining_usd == limit_usd - spent_usd` and
  `percent_used == spent_usd/limit_usd*100`, exactly.
- Effective limit = route limit + per-user admin override, **additive**. The
  cap is not a constant; read `limit_usd` every poll and never hardcode $20.
- `limit_usd == 0` means the model is **BLOCKED**; NULL means no limit.
- Grace (`dailySpendGraceUSD = 5.0`, hence `maximum_daily_spend_usd: 405`) is
  **global-only**. The per-model reservation adds no grace, so a model limit is
  a hard ceiling.
- **`cooldown` does NOT rewrite `limit_usd`/`remaining_usd`/`percent_used`.**
  The gateway assembles those from spend/limit arithmetic, then attaches the
  cooldown object; enforcement bypasses the model reservation separately.
  Rendering the limit as binding during an active cooldown would be factually
  wrong.
- There is **no per-model crossing timestamp** anywhere in the payload
  (verified: zero time-ish keys on a model budget).
- `model_budgets` is an **array**; the gateway supports multiple caps.
- The documented home, `GET /v1/me/daily-budget`, 404s on our host; the
  deployed `/v1/me/usage` carries the field even though the checked-in OpenAPI
  spec omits it. No new endpoint, no admin auth, no second HTTP call.

## Rejected: a second line on the curve

The curve's y-axis is `yMax = max(limit, peak, 1) * 1.08` in a 92pt lane with a
13pt gutter (79pt of plot). At limit $400 a $20 ceiling lands ~3.7pt above the
plot floor — inside the gradient fill, colliding with the $0 baseline.

Worse than cramped, it would be **dishonest**: on the $400 axis Opus reads as a
trivial 5% sliver when it is the wall you actually hit at ~30% global.
Percent-of-its-own-limit is the truthful frame.

## Rejected: a twin Opus curve

Needs per-model *hourly* history, which does not exist — `DayRecord.hourly` is
total-only and `ModelSnapshots` is one-per-day. That means a second
`HistoryStore` (monotonic guards, key migration, contamination filtering,
retention) to draw a 44pt sparkline. And a curve answers "how did we get here"
when the question is "where do I stand".

## The design

### 1. The row (popover)

One row placed **after** the global pace/runway lines and **before** the
hairline that opens the curve section — so the hierarchy reads: global
headline → narrative → nested enforced constraint → global history. It does not
go in the curve section, which would imply a shared axis and an hourly series
it does not have.

Contents: the model's human display name, a 2pt track filling to its fraction,
and `$14.75 of $20` right-aligned in monospaced digits.

- Achromatic in repose. It borrows the existing pill ramp
  (`BorderDash` 0.50 / 0.75 / 0.90 → systemYellow / systemOrange / systemRed)
  only as it approaches the wall — no new hue, no second colour channel.
- **Label:** human copy — "Opus 5", never the route slug `opus-5`. The models
  table already strips provider prefixes; a kebab-cased route ID would read as
  implementation leakage. Derivation must be deterministic and must not require
  a network request to render.
- **Absent cap: collapse the row.** Do not reserve blank air. The existing
  fixed slots exist to stop a Today/Month *switch* from moving the card; no
  interaction requires an absent policy row to hold height, and a mysterious
  22pt hole on servers without the field is worse. `PopoverView` already allows
  rare content-driven resizing (loading, stale banner).
- **Never hardcode Opus.** The wire shape is an array. v1 renders one row,
  defined as the **most urgent enforced cap**: rank blocked / exhausted / alarm
  before lower bands, then fraction, with a stable model-ID tie-break.
  Otherwise a second cap could silently hide the binding one.
- **Geometry:** measure the value label the way the models/footer code already
  does, give the name a truncating region, and let the track take the remainder
  with a minimum width. A fixed 120pt track breaks under a large admin override
  or a longer model name.

### 2. The pill

**The border keeps tracing the global budget.** It is not switched to
`max(global, model)`, not even in the red band. `StatusItemController`'s own
copy says "the border literally IS the budget gauge", and the amount inside the
same shape is global spend — a red loop around a 31% global day would assert
something false about the global instrument. Switching referents only at 90%
makes the break harder to learn, not easier.

Instead: a **4pt fixed-position model-limit dot**, shown when an enforced cap is
at/above the alarm threshold or blocked. The border keeps saying "global"; the
dot says "another enforced constraint needs attention". VoiceOver carries the
meaning ("Opus 5 limit nearly reached") since hue alone is insufficient.

Rules: a zero limit lights the dot even though its fraction is 0; an active
cooldown suppresses it; multiple caps use the deterministic most-urgent signal;
stale dims it with the rest of the pill.

Explicitly not doing: swapping or recolouring the amount, or closing the global
loop — each silently redefines an existing instrument.

### 3. The narrative slot

When the global budget still has room but an enforced cap is blocked/exhausted,
the sentence slot yields — that is the more actionable sentence at that moment.

**`PaceEngine` does not learn about model budgets.** It stays global spend +
limit + clock in, global verdict out. A separate pure module composes a
`PaceVerdict` with a derived model signal and picks the one sentence. The view
holds no priority rules.

Priority: global exhausted → active cooldown ("Opus 5 limit relaxed until …")
→ model blocked/exhausted ("Opus 5 limit reached · other models available") →
the existing global sentence.

**No "reached at 3:12 pm" in v1** — the payload has no per-model crossing
timestamp and the app has no per-model history; the poll that notices a
crossing is not the crossing. Inventing that time would also quietly break the
"no new persistence" property.

Avoid "other models still under budget" unless the selector has verified that
is true; "other models available" is safer for the one-cap case.

## Testing

`make test` only — bare `swift test` cannot import `Testing` on this CLT-only
toolchain (documented in the Makefile header). Baseline independently confirmed
green by two parties: **246 tests in 16 suites**. Require 246 + N after.

Pure-`VelaCore` unit tests, written test-first:

1. Decoding back-compat: missing `model_budgets` and explicit `[]` both yield
   `[]`. `DailyBudget`'s initializer takes `modelBudgets: []` as a default so
   the existing fixture surface needs no churn.
2. Full DTO shape: captured payload, `cooldown: null`, an active cooldown
   object, `cooldown_eligible`, an admin-overridden `limit_usd`.
3. `limit_usd == 0` classifies as blocked — never 0%, never a divide-by-zero.
4. Threshold boundaries: just below/at 0.50, 0.75, 0.90, 1.00, and above; the
   drawing fraction clamps to 1.0 while the spent/limit copy stays honest.
5. Negative spend never produces a backwards fill.
6. Non-finite spend/limit: no fraction, no `Int()` trap (copy
   `ModelShare.percent`'s existing guard).
7. Cooldown boundary: before, exactly at, and after `relaxed_until`; active
   suppresses alarm/exhausted messaging, expiry restores it. A stale non-null
   cooldown object is not trusted forever.
8. Multiple caps: deterministic most-urgent selection, tie behaviour,
   blocked-vs-high-fraction ordering, active-cooldown exclusion.
9. Composition priority: global exhausted beats model state; model exhausted
   beats an ordinary global sentence; no cap preserves every existing sentence.
10. Policy removal/update: non-empty → empty removes row and pill dot; a
    changed `limit_usd` is reflected with no hardcoded $20.
11. Stale: no invented projection; row and dot follow existing dimming.
12. Accessibility copy: model name, amount/limit, blocked and cooldown state
    exposed without relying on hue.
13. Copy width: a pure wording/width assertion like the existing pace-sentence
    fit test, including large amounts and the longest supported name.

**Layout cannot be unit-tested** — AppKit is not a SwiftPM target. The repo's
existing adapter is `Tools/snapshot_main.swift`, which renders both pill and
popover. Extend it with fixtures for: quiet cap, 90% alarm at calm global
spend, zero-limit blocked, active cooldown, no cap, and a large override.
Render light and dark, and Full / Compact / Minimal pill states. Inspect the
PNGs and run `make build` as well as `make test`. Layout is never claimed
verified from VelaCore tests alone.

## Out of scope for v1

Global grace ($5 admission cushion; does not alter the declared $400 or any
cap). Cooldown *activation* — this app is read-only and cannot trigger it;
`cooldown_eligible` is decoded for wire completeness only.
