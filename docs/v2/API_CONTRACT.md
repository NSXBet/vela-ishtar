# Vela Ishtar 2.0 — API Contract

WP-00 item 00.2. This document is the frozen coordination boundary for the
v2.0 work packages: the §7.2 contract names and the gateway payload facts
every producer and consumer shares. Producers own definitions; consumers
never rename these independently. Contract changes route through the
coordinator and land as edits to this file plus
`Sources/VelaCore/UsageContracts.swift`.

Base revision: `6a765c2` (v2.0 baseline checkpoint).

## 1. Frozen Swift contract names

All declared in `Sources/VelaCore/UsageContracts.swift` (Sendable, Equatable
where sensible). WP-00 ships them as concrete type skeletons; producers
 flesh out derived logic in their own WPs.

| Contract | Producer | Semantics (from plan §7.2) |
|---|---|---|
| `UsageScope` | WP-00/WP-03 | Opaque non-secret local identifier; scope kind `credential` or verified `account`; gateway origin. Never persist the token as identity. Without an account ID, isolate by returned token ID through an opaque mapping. |
| `UsageSnapshot` | WP-01 | Validated response, scope, receivedAt, `GatewayDay`, model-data availability, schema warnings. Raw DTO defaults cannot masquerade as domain facts. |
| `ModelBreakdownState` | WP-01 | `available(rows, total, scope)`, `empty`, `unavailable(reason)`, `inconsistent(reason)`; raw field absence survives decoding. |
| `Observation` | WP-02 | Stable ID, scope, gateway day, receivedAt, cumulative amount, enabled-limit/policy context, precision (`exactReceipt` or `legacyHour`); receivedAt is observation time, not transaction time. |
| `HistoryEnvelope` | WP-02 | Schema version 2, revision, scoped day records, bounded observations, coverage metadata; version 1 backup retained during migration. |
| `ConnectionState` | WP-03 | `noCredential`, `keychainBlocked`, `connecting`, `live`, `retrying`, `stale`, `authenticationRequired`, `invalidResponse`; retains last good snapshot separately. |
| `Freshness` | WP-04 | Derive from receipt age, explicit invalidation, and request result; fresh for at most 90s, then stale; authentication errors immediately invalidate current trust. |
| `BudgetOverview` | WP-08 | Global policy, deterministically sorted model signals, per-model budget headroom, reset description, freshness; no unsupported availability promise. |
| `SummaryDisplayState` | WP-06 | Equatable section states, stable row IDs, selected model period and its scoped total, freshness/accessibility text; no Keychain/network reads while constructing/applying. |
| `MarkerReceipt` | WP-09 | ID, optional ≤80-character name, scope, start/end day and observation, delta or explicit unavailable reason, precision/coverage. |
| `UsageTransport` | WP-00/WP-03 | `func fetchUsage(token: String) async throws -> UsageResponse`. Token parameters remain in memory only; no conforming type logs, persists, or embeds the token. |
| `RefreshReason` | WP-00/WP-03 | `launch, scheduled, opened, manual, wake, credentialChanged`. |

Main-actor coordinator surface (WP-03): `start()`, `stop()`,
`refresh(reason:)`, `setCredentialGeneration(_:)`. Every request captures
the credential generation; only matching results may commit. Cancellation
plus generation checks are both necessary: cancellation is cooperative and
cannot alone protect against late callbacks.

## 2. Gateway wire contract — `GET /v1/me/usage`

Facts below are read from `Sources/VelaCore/Models.swift` (the wire layer)
and its captured-payload tests. All names snake_case on the wire.

### 2.1 Response envelope (`UsageResponse`)

| Field | Type | Required | Notes |
|---|---|---|---|
| `token_id` | string | yes | Token identifier. Never persisted as identity; `UsageScope.opaqueID` is locally generated. |
| `daily_budget` | object | yes | See 2.2. |
| `current_month` | object | yes | See 2.3. |
| `top_models` | array | yes | Top models for the CURRENT MONTH. Order: as returned by the gateway (spend-descending in observed payloads); consumers must not assume completeness (see 2.5). |
| `today` | object | optional | Absent on older gateway builds → decodes as zeroed `MonthStats`. The ABSENCE is a schema fact: `UsageSnapshot.modelData` records `.unavailable`, and UI shows the honest fallback ("Per-model breakdown is monthly only"), never fabricated zeroes. |
| `today_models` | array | optional | Absent on older gateway builds → decodes as `[]`. Same rule: absence recorded, not masked. |

### 2.2 `daily_budget` (`DailyBudget`)

| Field | Type | Required | Notes |
|---|---|---|---|
| `limit_usd` | number | yes | Global daily limit. Authoritative per poll; never hardcoded client-side. |
| `spent_usd` | number | yes | Cumulative spend for the declared spend day. |
| `remaining_usd` | number | yes | `limit - spent` as computed by the gateway. |
| `used_percent` | number | yes | Fraction ×100. KNOWN HAZARD: a pathological value (e.g. `1e100`) decodes fine as Double but `Int(exactly:)` fails — App-layer unchecked casts require a safety fix (WP-01, finding B11). |
| `limit_enabled` | bool | yes | `false` means UNLIMITED — not zero. A model cap of `limit_usd == 0` means BLOCKED — not unlimited. These two semantics are different and both preserved. |
| `spend_date` | string | yes | The gateway's billing-day label. Two observed shapes: bare `yyyy-MM-dd` and full ISO timestamp. Interpret ONLY through `GatewayDay`/`ISODate.dayKey` (label, not instant) — never re-parse as UTC datetime. |
| `model_budgets` | array of `model_budget` | optional (absent = `[]`) | Nested per-model daily caps. Absent and null both mean "no caps", never a decode failure. |

### 2.3 `current_month` / `today` (`MonthStats`)

| Field | Type | Required | Notes |
|---|---|---|---|
| `total_cost_usd` | number | yes | |
| `total_tokens` | int | yes | |
| `requests` | int | yes | |
| `period_start` | string | optional | The app derives "today" from `spend_date`, NOT from these. |
| `period_end` | string | optional | |

### 2.4 `model_budget` (`ModelBudget`)

| Field | Type | Required | Notes |
|---|---|---|---|
| `model` | string | yes | Route slug, e.g. `aihub/claude-opus-5`. Display names derive per ModelBudgetSignal's rule; never hardcoded. |
| `spent_usd` | number | yes | |
| `limit_usd` | number | yes | Route limit + per-user admin override, computed server-side. `0` = BLOCKED. |
| `remaining_usd` | number | yes | |
| `percent_used` | number | yes | |
| `cooldown_eligible` | bool | yes | |
| `cooldown` | object | optional | See 2.4.1. |

#### 2.4.1 `cooldown` (`ModelCooldown`)

| Field | Type | Required | Notes |
|---|---|---|---|
| `created_at` | string | optional | ISO8601 (mixed Z/offset, ±fractional seconds — parse via `ISODate.parse` only). |
| `relaxed_until` | string | optional | Self-service bypass of the MODEL cap only, never the global one. The gateway computes spent/limit/remaining/percent_used WITHOUT regard to cooldown, so callers must consult `relaxedUntil` themselves before treating a cap as binding. |

### 2.5 `top_models` / `today_models` row (`ModelUsage`)

| Field | Type | Required | Notes |
|---|---|---|---|
| `model` | string | yes | |
| `total_cost_usd` | number | yes | |
| `total_tokens` | int | yes | |
| `requests` | int | yes | |

**Completeness and order:** the gateway returns a TOP-N list. It is not a
promise that named rows sum to the window total; the display layer pins an
"Other" row for the gap (and the popover caps named rows at four by
presentation policy). Order is gateway-provided; consumers sort
deterministically (spend descending, name ascending) when they need their
own order, as `BudgetOverview.modelSignals` requires.

**Totals scope:** `daily_budget` covers the whole spend day for the
credential's view; `today`/`today_models` are the same window sliced per
model. A token's view may differ from the account's totals (multi-token
accounts); the fixture `usage_token_vs_account_totals.json` encodes this
case — token-scoped daily spend is lower than the account month view.
Contract: totals are displayed for the scope that produced them; never mix
token-scoped and account-scoped numbers in one view.

**Reset semantics:** the day window resets at the gateway's billing-day
boundary. The app treats the boundary as the `spend_date` label change
(UTC-midnight semantics per `GatewayDay`); no other reset contract is
asserted. `period_start`/`period_end` on the month are informational only.

### 2.6 Errors and Retry-After

| Status | Meaning | Client mapping |
|---|---|---|
| 200 | Success | Decode via `UsageResponse`. |
| 401/403 | Credential rejected | `ConnectionState.authenticationRequired`; Freshness invalidated immediately. |
| 5xx / network failure | Transient | `ConnectionState.retrying(attempt:)` with backoff. |
| Malformed body | Shape/decode failure | `ConnectionState.invalidResponse`. |

**Retry-After header:** NOT VERIFIED. No captured evidence documents the
gateway sending it. Safe unavailable behavior: the client ignores it and
uses its own backoff schedule; if the header is later confirmed, WP-03 may
adopt it as an upper bound on backoff delay. Owner: WP-03.

**Rate-limit / cooldown shapes:** `model_budgets[].cooldown` is the only
documented cooldown shape. Any account-level rate-limit envelope is
UNVERIFIED — safe unavailable behavior: treat unknown top-level fields as
absent (tolerant decode already does) and surface no invented semantics.
Owner: WP-01 for payload-side, WP-03 for retry-side.

## 3. Fixtures

`Tests/Fixtures/usage/` (all synthetic; no real tokens or credentials):

| File | Covers |
|---|---|
| `usage_valid.json` | Representative full payload: day + month + `today` + `today_models` + `top_models`. |
| `usage_missing_today.json` | Older gateway shape: no `today`, no `today_models`. Must decode with zeroed `today` and empty `todayModels` and be recorded as `.unavailable`. |
| `usage_token_vs_account_totals.json` | Token-scoped day total differing from account month view. |
| `usage_nonfinite_percent.json` | `used_percent: 1e100` — decodes as Double, `Int(exactly:)` fails; guards against unchecked casts. |

## 4. Change control

Consumers never rename contract names independently. A contract change:
(1) proposal to the coordinator, (2) edit to this file + `UsageContracts.swift`
in the owning WP, (3) all consumers rebased onto the new revision before
their wave merges.
