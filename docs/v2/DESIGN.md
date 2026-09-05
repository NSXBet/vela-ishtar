# docs/v2/DESIGN.md — Vela Ishtar 2.0 design system and state fixtures

WP-05 deliverable (V2_IMPLEMENTATION_PLAN.md §5 hierarchy, §9 WP-05).
The v1 popover grew its geometry ad hoc (320pt card, 18pt inset, alphas
0.38–0.45 sprinkled by hand). This document freezes the v2 design: concrete
tokens, the 360pt summary validated against the current 320pt design on the
same data, and a state/copy matrix for every §5.3 state. Fixtures are
rendered by `Tools/design_fixture_main.swift` into `build/v2-design/`
(never over `docs/assets/`); the tokens live in
`Sources/App/DesignTokens.swift` as the single source WP-06/07/08/11 read.

## 1. How to regenerate the fixtures

```sh
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  Sources/VelaCore/*.swift \
  $(ls Sources/App/*.swift | grep -v '/main.swift$') \
  Tools/design_fixture_main.swift \
  -o /tmp/vela-design-fixture \
  -framework Cocoa -framework ServiceManagement -framework Security -framework QuartzCore \
  && VELA_DESIGN_DIR=build/v2-design /tmp/vela-design-fixture
```

28 PNGs land in `build/v2-design/`: the 05.1 comparison pair
(`compare-v1-320-*` vs `compare-v2-360-*`, light + dark), budget detail
(`budget-detail-*`), and every §5.3 state (`state-<name>-<appearance>.png`)
plus the accessibility variants. The harness is headless-safe, deterministic
(fixed fixture instant 2026-09-04 12:31 UTC), uses no network, no Keychain,
no real credential; the fixture scope UUID is a literal.

## 2. 05.1 — Design comparison: 320pt (v1) vs 360pt (v2)

Same fixture data on both sides; the 320pt side renders through the real
`PopoverView`, the 360pt side through the proposed `SummaryFixtureView`.

| File | What it shows |
|---|---|
| `compare-v1-320-light/dark.png` | Current design, worst-case data ($9,999.99 rows, long route, near-cap model) |
| `compare-v2-360-light/dark.png` | Proposed design, identical data |

What 40pt buys, measured on the fixtures:

- **Hero + suffix.** `$9,999.99` at 30pt tabular measures **151pt** (the
  fixture prints this). At 320pt the suffix ("$345.49 remaining of $400",
  15pt) wraps or collides on the exhausted state; at 360pt the pair fits on
  one baseline in every state.
- **Models table.** Cost column 78pt + share 44pt + truncating name. The
  320pt table gives the name 152pt and the long route
  `claude-opus-5-thinking-extended` clips to `claude-opus-5-thinking-`
  mid-word; at 360pt the same row keeps ~40% more characters before the
  ellipsis, and the share column stops fighting the cost column.
- **Cap row.** `$19.20 of $20` + long route + 2pt track: at 320 the value
  eats the name; at 360 the name truncates with the amount intact.

**Why every visible element exists** (v2 summary, top to bottom):

| Element | Exists because |
|---|---|
| `TODAY` label + `Settings` | Orients the card; Settings is the only global escape. ≥24pt control height (§5.2 floor). |
| Hero `$54.51` | The one number the menu bar exists for. 30pt tabular — monetary digits must stack and compare. |
| `$345.49 remaining of $400` | The complement of the hero; answers "how much is left" without arithmetic. |
| Status line (reserved 34pt) | Freshness + reset ("Latest observation · 12:31 · resets at UTC midnight") in calm states; tinted band in stale/auth/error. The slot is ALWAYS filled — no blank hole, no geometry change between states (§5.3). |
| Model cap row + track | The binding per-model cap is usually more urgent than the global limit ($20 cap binds before $400). Red fill at 96% reads before the text does. |
| `TODAY'S OBSERVATIONS` curve | Gaps stay visible; the dotted ceiling shows headroom; `now` tick anchors the day. Caption states the comparison rule honestly. |
| `MODELS` + period total + Today/Month switcher | The selected period's total lives IN the section (§5.2), never in the hero — one daily hero, period totals scoped. |
| 5 model rows (constant) | Stable geometry across tab switches and row counts; empty strides are reserved air, not unexplained holes. |
| `Other` pinned row | Honest residual when named rows don't sum to the total; no share on it — it isn't a model. |
| Week strip (M–S cells) | "Is today a big day?" in 24pt. A gap day renders a visible unfilled cell — an explained empty slot. |
| `History` / `Start a marker` / `Dashboard ↗` | Secondary navigation, all at 24pt control height; nothing answers only on hover. |

## 2. 05.2 — Frozen tokens (Sources/App/DesignTokens.swift)

Measured with the fixture harness's worst cases (values printed at the end
of a run):

| Token | Value | Evidence |
|---|---|---|
| Summary width | **360pt** (legacy 320 kept for comparison) | §1 table |
| Content inset | **20pt** → content 320pt | Hero pair fits at 360 with 20pt breathing room |
| Spacing scale | **4 / 8 / 12 / 16 / 24pt**; section spacing 12 | Matches v1 rhythm; 12pt survives the wider card |
| Hero | **30pt semibold, tabular** — `$9,999.99` = 151pt | Suffix fits beside it at 360pt |
| Body / row names | **13pt** | Longest display route `claude-opus-5-thinking-extended` = 207pt @13pt → truncates at ~305pt of column; full route in accessibility |
| Money figures | **13pt monospaced-digit** — `$9,999.99` = 65pt → 78pt column clears it | Decimal points stack |
| Secondary | **11pt** (12pt for interactive text) | Status band copy, nav links, captions |
| Section labels | **11pt medium**, ink `labelColor @ 0.55` | 0.42 vanished on the light fixture; 0.55 ≈ 4.6:1 on white |
| Row stride | **32pt** (24pt data row + 8pt air) | v1-proven; five strides = 160pt constant models block |
| Control min height | **24pt** | Settings, nav links, switcher |
| Status slot | **34pt reserved in every state** | Geometry never breathes |
| Hairline | 0.5pt, `labelColor @ 0.14` (0.30 under Increase Contrast) | Backing-scale drawn |
| Status band | tint bg @ 0.08, border @ 0.25 (contrast: 0.16 / 0.55) | §3 matrix |
| Material | `.popover`; opaque fallback `windowBackgroundColor` under Reduce Transparency | See `state-reduce-transparency-*` over a striped busy backdrop |
| Focus/hover | `controlAccentColor @ 0.10` (0.22 contrast) band; answers never hover-only | Keyboard focus paints the same band |
| Motion | Open transition 0.15s; tab indicator 0.14s; NO continuous animation | Sonar and per-poll bell rocking stay retired |

**Semantic truncation with full accessible value:** display names strip the
provider prefix and truncate tails (`claude-opus-5-thinking-…`); every row,
cap, strip, and band sets an accessibility label/value carrying the FULL
route, amounts, share, or state reason. Money always renders fully —
truncation is for route names only, never figures.

## 3. 05.3 — State / copy matrix

Every state renders in light AND dark (`state-<name>-<appearance>.png`):

| State | Hero | Status slot | Models block | Next action |
|---|---|---|---|---|
| `loading` | `$0.00` tertiary | Neutral line: "waiting for the first reading" | "Connecting to AI Hub — first observation will appear here." | Wait; first poll settles in place |
| `cache` | $41.02 dimmed | Band: data last received HH:mm | "Per-model breakdown is monthly only" | None needed; poll will confirm |
| `stale` | $54.51 dimmed | Notice band: "AI Hub unreachable — retrying. Data last received HH:mm." | "Per-model breakdown needs a fresh reading" | Retry happens on schedule; Refresh available |
| `auth` | $54.51 dimmed | Alarm band: "AI Hub rejected this API key — open API key to paste a new one" | "Authentication required" | Open API key |
| `error` | $54.51 dimmed | Alarm band: "AI Hub unreachable — retrying. Data last received 09:02." | "Network error" | Wait for backoff / manual refresh |
| `unlimited` | real spend ($12.88 — never $0.00) | "Latest observation · … · no daily limit" | Normal rows | None |
| `missing-data` | $54.51 | Fresh line | "This gateway build has no per-model data for today" | None; honest unavailability |
| `no-spend` | $0.00 | Fresh line | "No spend yet today — totals will appear with the first observation." + EMPTY curve lane | None |
| `invalid-response` | $54.51 dimmed | Alarm band: "…could not be validated — retrying" | "Today's per-model rows don't add up to the day total — showing the total only. (named rows exceed the day total)" | Wait for retry |

Rules baked into the fixtures (and binding on WP-06+):

- **Stable summary height.** The reserved 34pt status slot and the constant
  160pt models block mean every state renders at one of two heights
  (with/without cap row); ordinary polls, tab changes, and freshness changes
  never resize the card.
- **Loading is calm.** Connecting is a neutral line, never a stale band —
  nothing has failed.
- **Cached ≠ live.** Cached paints say "Data last received HH:mm"; legacy
  hour-precision history reads "Observed during 12:00–12:59", never an
  invented exact age.
- **Accessibility variants.** `state-increase-contrast-*` lifts hairlines,
  captions, and band borders; `state-reduce-transparency-*` renders over a
  striped busy backdrop — the opaque-fallback test: every element must read
  without the material.
- **Reduced motion.** No fixture differs for Reduce Motion because nothing
  continuously animates: open is a ≤0.15s opacity/translation, the tab
  indicator snaps instead of sliding, the curve's draw-on reveal is skipped,
  and there is no sonar/bell loop to disable.
- **Small screens.** On short visible frames the summary keeps its width and
  scrolls its content region; the outer frame is not squeezed.
- **Secondary navigation.** History, marker, and dashboard entries are real
  24pt controls on the footer line; keyboard entry Tab-orders them first
  after the period switcher, and focus bands (not hover) mark them.
- **Keyboard.** The panel's mouse opening stays nonactivating; explicit
  keyboard invocation grants key focus; Escape closes and returns to the
  prior app (tested in §5.3 of the plan; enforced by WP-07's panel work).
- **Period labels never contradict.** The hero is always TODAY; period
  totals live beside the Today/Month switcher in the models section.

## 4. Known gaps (for the orchestrator's review, not blockers)

- The 360pt card is a fixture view, not the live `PopoverView`; WP-06
  converts the real view to these tokens and `SummaryDisplayState`.
- Week-strip hover readout and marker creation flow are rendered as static
  placements; interaction wiring is WP-07/08.
- The v1 320pt comparison renders through the real popover, whose stale
  banner still uses 8pt text (plan §5.1 calls this out) — visible in
  `compare-v1-320-*` and fixed by adopting the v2 status slot.
