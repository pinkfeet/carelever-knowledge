# Monitor → Assessment: Cycle Grouping Review & Proposed v2 Logic

Review of `build_cycles` in
`carelever_assessment/script/migrate-monitor/referrals/referrals_import.rb`
(`:371-503`) — how one Monitor referral is split into N Assessment
cycle-referrals — and a proposed replacement algorithm.

> Background: [cycle-referral-grouping-data-model.md](../monitoring/cycle-referral-grouping-data-model.md)
> (entity graph), [`referral-grouping.md`](../../carelever_assessment/script/migrate-monitor/specs/referral-grouping.md)
> (current spec), [monitor-referral-migration-review.md](monitor-referral-migration-review.md)
> (general import review — notes `build_cycles` has **no spec coverage**).

---

## 0. Baseline update (2026-07-06) — read before implementing v2

The import changed substantially after this review was written (remediation
series `292f97ca..7ed7be53`; see the general review §0). Line refs below are
stale, and v2 must preserve/incorporate the following **new baseline
behaviours**:

1. **Cancelled requests are a third cycle status.** `build_cycles` now
   partitions each RA cluster's RTIAs into live/cancelled, drops "husk" TIRRs
   (unresulted, referenced only by cancelled requests), and emits
   fully-cancelled clusters as **cancelled cycles**
   (`cancelled_at` = max RTIA `cancelled_at`, `cancellation_notes` from the
   per-request audit). v2's atom model therefore needs **three atom statuses —
   open / resulted / cancelled** — with the status barrier applying to all
   three (a cancelled atom never merges into live or resulted work).
   Downstream already depends on it: `main_cycle_key`, `next_test_holder_key`
   and `chain_cycle_referrals!` all **exclude cancelled cycles**.
2. **Cycles now carry fields the emitter depends on.** Each cycle hash exposes
   `:program` (consumed by `chain_cycle_referrals!` for per-program
   `previous_referral_id` chaining), `:requested_by_id` (per-cycle
   `created_by_id`), and `:cancelled_at`/`:cancellation_notes`. v2's step-4
   emission must keep populating all of them per merged component (program is
   shared within a component by construction; `requested_by_id` = first
   resolvable across member RAs; a component is cancelled only if **all** its
   atoms are).
3. **A new definitive signal exists: `requested_test_item_appointments`**
   (booking-time RA↔appointment links, exported since `a98ce103` and consumed
   via `tirr_appointment_ids`). This strengthens §3/§4: rule (a) "shared
   appointment" can now fire for **open** atoms too (an open RA's booked
   appointment is reachable via RTIApp even though no AIR row exists), and an
   open atom's window can include the booked appointment's `scheduled_at`.
   Note the status barrier still governs: shared booking between an open and a
   resulted atom does not merge them.
4. **`appointment_lookup` was already rewritten** (info hashes keyed three
   ways: items / appointments / tirr_appointments) — §7's "extend
   appointment_lookup" note is partially done. The **status filter is still
   missing** (all statuses index, incl. cancelled — general review §0.2 N3 and
   original §5), so v2's step-2 "attended/completed only" fix still applies.
5. **Zero-TIRR open atoms are real and currently emit service-less referrals**
   (general review **§0.2 N1** — Monitor creates TIRRs only at result entry,
   so booked-but-unresulted cycles have RAs/RTIAs/RTIApp links but no TIRR →
   no services → their appointment is dropped). v2 step 4 is the natural place
   to fix this: synthesize in-progress services from live RTIAs
   (`test_item_detail_id` resolves through the same catalog map), which also
   lets the RTIApp path link the booked appointment. Treat as part of the
   grouping change.
6. **In-progress cycles now seed `processing_mode: fully_automated`** (not
   `attention_required`) per the field map; §4 has been updated to match.
   Cancelled components emit cancelled history (`fully_automated` +
   `cancelled_at`), not in-progress.
7. **Key-stability check for v2 unchanged**: fallback keys still use the
   date-bucket form (`result:{ref}:{program}:{date}`), so the §4 key change to
   `result:{ref}:{min_tirr_id}` still requires purge + re-import (never upsert
   v2 over v1). The RA-key form (`requested_assessment:{min_ra_id}`) is
   unchanged and remains stable under v2 — but note cancelled-cycle keys are
   also RA-keys, and a v2 regroup that moves a cancelled RTIA set between
   clusters changes which key carries the cancellation.

---

## 1. Current logic (recap)

Two passes, per Monitor referral bundle:

| Pass | Input | Grouping rule | Cycle key |
|---|---|---|---|
| 1 — primary | `requested_assessments` | Same program, **single-linkage on RA `created_at` within 3 days** (`RA_WINDOW_DAYS`, `referrals_import.rb:374,485-498`) | `requested_assessment:{min_ra_id}` |
| 2 — fallback | Resulted TIRRs not consumed by pass 1 | **Exact calendar day** of `result_date` per program (`:418-429`, `date_bucket :560`) | `result:{ref_id}:{program}:{date}` |

Key property: **the two passes never talk to each other.** Pass 1 clusters on
*request* dates only; pass 2 buckets on *result* dates only; a TIRR either has an
RTIA link into pass 1 or it doesn't.

---

## 2. Problems

### P1 — RA merge is blind to result windows (false merge)

Pass 1 merges two same-program RAs created ≤3 days apart **regardless of when
their tests were actually performed/resulted**. `created_at` is a *request*
date; the visit can lag it by weeks (booking lead time), and two requests made
the same week can resolve into visits months apart (deferral, no-show →
rebook, one test failed and redone later).

```
RA #301 created Mon        → audiometry  resulted 2025-03-10
RA #302 created Wed (+2d)  → spirometry  resulted 2025-06-20   (rebooked)

today:  ONE cycle  requested_assessment:301
        services resulted 3 months apart; cycle_date = 2025-03-10;
        the June work never appears as its own referral
```

Consequences: the Assessment referral misrepresents one visit as containing
work from two; `referral_completed_at`, `results_received_at`, history-log
routing windows (`cycle_time_window`) and the per-cycle billing safeguard all
straddle both events; year-view timelines under-count cycles.

The converse false-*split* also exists: two RAs for the **same visit** created
4+ days apart (test added to an existing booking a week later) split into two
referrals even when their TIRRs share one appointment.

### P2 — Non-RA TIRRs never join an RA cycle (duplicate referrals per visit)

A resulted TIRR with no RTIA back-link (manual "Edit Results" entry, Screen
import, unlinked appointment, RTIA whose `test_item_referral_result_id` was
never filled) always falls to pass 2 and becomes **its own referral** — even
when it was performed at the same visit as a pass-1 cycle:

```
RA cycle (program X) — audiometry resulted 2025-03-10
manual TIRR (program X) — chest X-ray resulted 2025-03-10, no RA link

today:  TWO Assessment referrals for one physical visit
        (the appointment, if linked to both TIRRs, attaches services on
         both referrals — the import already tolerates this at :332-335)
```

### P3 — Fallback bucketing is an exact calendar day (fragile splits)

Pass 2 groups by `result_date.to_date`. Two results from one visit entered on
consecutive days (data entry lag, timezone shift across midnight — export dates
are UTC, clinics are AEST/AWST) split into two referrals. Conversely all
**undated** resulted TIRRs of a program collapse into one `"undated"` cycle no
matter how many years they span.

### P4 — Cycle key of fallback cycles is window-dependent

`result:{ref}:{program}:{date}` embeds the bucket date. Any tuning of the
bucketing (P3) or adoption of TIRRs into RA cycles (P2) moves keys → re-import
over an existing import orphans/duplicates rows. Keys should be derived from
**member row ids**, not from the grouping parameters.

---

## 3. Signal inventory

What the export bundle carries, ranked by strength as "same visit" evidence:

| Signal | Where | Strength |
|---|---|---|
| **Shared appointment** | TIRR → `appointment_item_results[]` → `appointment_item_id` → `appointments[]` (export includes both) | **Definitive** — one visit is one appointment |
| Appointment `scheduled_at` | `appointments[]` (attended=0 / completed=6 only) | Strong — actual visit date |
| TIRR `result_date` | Set from `appointment.scheduled_at` when linked (`appointment_item_result` callback), else manual date | Strong proxy for the performed date |
| RA `created_at` | `requested_assessments[]` | **Weak** — request date, not visit date; only proxy available for in-progress cycles |

The current algorithm leads with the weakest signal (RA `created_at`) and never
consults the strongest two for merging. That inversion is the root cause of
P1 and P2.

---

## 4. Proposed v2 algorithm

### Design principles

1. **An RA is atomic.** One explicit request never splits, even if its own
   TIRRs straggle — the operator asked for those tests together. (Splitting
   *within* an RA is out of scope; it did not come up as a real case.)
2. **Cycle identity is the visit, not the request.** Merge on
   appointment/result evidence first; request dates are corroborating
   evidence, not the primary key.
3. **Both RA-backed and result-only TIRRs are peers** in one clustering pass —
   no ordered pass-1/pass-2 with a "consumed" set.
4. **Keys derive from member ids**, never from dates or thresholds.
5. **Status fidelity to Monitor.** A migrated cycle is in-progress **iff**
   Monitor still has open work behind it. Grouping must never flip a status:
   no Monitor-open request may be swallowed into a completed referral, and no
   in-progress referral may exist without open Monitor work. (See §"Cycle
   status" — this constrains both the completion rule and which atoms may
   merge.)

### Constants

| Constant | Proposed default | Meaning |
|---|---|---|
| `REQUEST_GAP_DAYS` | **3** (unchanged) | Max RA `created_at` gap for request-affinity merge |
| `RESULT_GAP_DAYS` | **7** | Max gap between result/visit windows to merge on result affinity (covers cross-midnight, entry lag, multi-day clinic visits) |
| `SPLIT_GUARD_DAYS` | **30** | Request-affinity merge is vetoed when both sides are resulted and their windows are further apart than this |
| `MAX_CYCLE_SPAN_DAYS` | **45** | Sanity cap on a merged cycle's window span (guards single-linkage chaining on high-frequency programs, e.g. monthly D&A screens) |

Defaults are starting points — §6 gives the pre-flight queries to tune them
against real tenancy data before the bulk run. **The §6 cadence + P2 queries
are a mandatory gate for `RESULT_GAP_DAYS`, not advisory**: 7d can merge
unrelated same-program manual/result-only events entered within a week of
each other on one permanent referral, and nothing else in the algorithm
protects against that below the span cap. If the production distribution is
inconclusive, land with a tighter value (3d — covers the cross-midnight and
entry-lag cases that motivated rule (c)) and widen only with data.

### Algorithm (per program — `ra_program_key` / TIRR program, unchanged)

**Step 1 — build atoms**

- one atom per `RequestedAssessment` = `{ ras: [ra], tirrs: linked TIRRs }`
- one atom per leftover **resulted** TIRR = `{ ras: [], tirrs: [tirr] }`
  (unresulted leftovers stay excluded, as today)

**Step 2 — compute per atom**

- `appointment_ids` — union of two link paths (§0.3):
  - `appointment_item_results` → `appointment_items` → appointment,
    **attended/completed only** (result-time evidence; the current code
    ignores this status filter — fix here, §0.4);
  - `requested_test_item_appointments` (booking-time RA↔appointment links),
    **non-cancelled statuses** (exclude cancelled / late_cancelled /
    no_show) — this is what lets rule (a) fire for **open** atoms, whose
    booked appointment has no AIR row yet.
    ⚠️ **Requires a NEW index keyed by `requested_test_item_assessment_id`**,
    attached to the owning RA atom. Do **not** reuse the importer's existing
    `tirr_appointment_ids` helper: it routes RTIApp → RTIA → TIRR and drops
    every RTIA whose `test_item_referral_result_id` is nil — which is exactly
    the open/zero-TIRR population this signal exists for.
- `window` = `[min, max]` over: attended/completed appointment
  `scheduled_at` ∪ resulted TIRR `result_date`s ∪ (open atoms only) booked
  non-cancelled appointment `scheduled_at` via RTIApp. `nil` when no dated
  evidence exists. Open-atom windows exist **only** to power the rule-(b)
  veto and the span cap — they do not make rule (c) applicable (below).
- `request_dates` = RA `created_at`s (empty for result-only atoms)
- `status` = open / resulted / cancelled — see §"Cycle status"

**Step 3 — merge (union-find over atoms of the same program)**

Merge atoms A, B when **any** rule fires, subject to the span cap **and the
status barrier** (atoms of different status — open / resulted / cancelled —
never merge; see §"Cycle status"):

| # | Rule | Fires when | Solves |
|---|---|---|---|
| a | **Shared appointment or shared TIRR** | `A.appointment_ids ∩ B.appointment_ids ≠ ∅` (AIR or RTIApp path — so it also fires between two open atoms booked into one visit), **or** A and B link the same TIRR via live RTIAs (cross-RA links to one result row are definitive same-work evidence) | P2, false-split side of P1 |
| b | **Request affinity + split guard** | min gap between `request_dates` ≤ `REQUEST_GAP_DAYS`, **unless** both windows present and `gap(A.window, B.window) > SPLIT_GUARD_DAYS` | keeps today's behaviour, adds the P1 veto |
| c | **Result affinity** | **both atoms resulted**, both windows present, and `gap(A.window, B.window) ≤ RESULT_GAP_DAYS` | P2, P3 |
| d | **Undated bucket** | both atoms **resulted result-only with no window** (undated), same program | parity with today's `"undated"` bucket — see below |

- `gap([a1,a2],[b1,b2])` = 0 when overlapping, else distance between the
  nearer edges.
- A merge is skipped when the combined window span would exceed
  `MAX_CYCLE_SPAN_DAYS` **and** neither rule (a) applies (a genuinely shared
  appointment always wins).
- **Deterministic edge order** (required for key stability): the span cap
  makes merges conditional on the component's *current* window, so the result
  depends on processing order. Evaluate candidate pairs in a fixed order —
  all rule-(a) pairs first, then remaining pairs by window gap ascending,
  ties by `[min atom id, max atom id]` — so the same bundle always yields the
  same components (and therefore the same `min id` keys) on every run.
- **The rule-(b) veto is pairwise, not transitive**: A–B can be vetoed yet
  united through a middle atom C (A–C and C–B both fire). Accepted —
  `MAX_CYCLE_SPAN_DAYS` bounds the damage, and the §7 veto log line makes the
  file visible for spot-checking.
- **Never compare a request date to a result date** (rule b compares
  request-to-request, rule c result-to-result). An in-progress RA created the
  same day another test happened to be resulted is *not* evidence of the same
  visit — booking lead times make that comparison meaningless.
- **Undated resulted atoms need rule (d) explicitly** (outcome set,
  `result_date` NULL): rules (b)/(c) can never fire for them (no window), so
  without (d) a union-find leaves each undated leftover as its **own**
  referral — a regression vs today's single `"undated"` bucket. Rule (d)
  restores parity: undated result-only atoms of a program merge together
  **unless** rule (a) already pulled one into a dated visit (an atom claimed
  via shared appointment is no longer "undated" — its window comes from the
  appointment). Accepted coarseness, as today: no better signal exists.
- **Shared-TIRR ownership when the barrier blocks**: if two atoms of
  *different* status link the same TIRR (e.g. an open RA and a resulted RA
  both reference one result row), they stay split and the TIRR is emitted
  **only in the resulted component** — a result row must never produce two
  services. The open side keeps its unresulted RTIAs as outstanding work.

**Step 4 — emit cycles**

Per merged component:

- `key`:
  - any RA present → `requested_assessment:{min ra id}` (unchanged — adopted
    result-only TIRRs do not perturb the key)
  - result-only → `result:{monitor_referral_id}:{min tirr id}` ← **changed
    from the date-bucket key** (fixes P4; stable under any threshold tuning)
  - undated result-only bucket → `result:{monitor_referral_id}:{min tirr id}`
    likewise
- `in_progress` / completed / cancelled — see next subsection
- `cycle_date` = min result date, else min RA created (unchanged)
- `created_date` / `ra_created_date` = as today
- baseline fields (§0.2) — populated per merged component:
  - `program` — shared within a component by construction (grouping is
    per-program)
  - `requested_by_id` — first resolvable across member RAs
  - `cancelled_at` / `cancellation_notes` — cancelled components only
    (max member RTIA `cancelled_at`; aggregated per-request audit)
- **zero-TIRR open components** (§0.5): synthesize in-progress services from
  live RTIAs (`test_item_detail_id` through the catalog map) so the booked
  appointment attaches via the RTIApp path instead of being dropped

`main_cycle_key`, `next_test_holder_key`, `chain_cycle_referrals!` (all three
exclude cancelled cycles), shell/pre-TIRR handling, billing safeguard: all
unchanged.

### Cycle status — in-progress vs completed

**Requirement (principle 5):** mimic Monitor's in-progress population exactly.
Every Monitor referral with open work must own ≥1 in-progress Assessment
cycle-referral covering that open work; no Assessment referral may be
in-progress without open Monitor work behind it; no Monitor-open request may
land inside a completed referral. Counts are not 1:1 (one Monitor referral
fans out to N cycle-referrals, and one visit's several RAs collapse into one),
so the invariant is **per Monitor referral / per open request**, verified by
the §6 reconciliation — not by comparing two grand totals.

**Atom status** (computed in step 2 — **three** statuses, incorporating §0.1):

- **RA atom — open**: ≥1 **live** (non-cancelled) RTIA whose TIRR is missing
  or unresulted (`resulted?` false: no outcome, no evaluation). Cancelled
  RTIAs are **not** outstanding work — an RA whose only unresulted requests
  were all cancelled must not be open, or fidelity breaks in the reverse
  direction (in-progress in Assessment with no open Monitor work). An RA with
  zero RTIAs at all is open (bare request — the §0.5 zero-TIRR case).
- **RA atom — resulted**: every live RTIA has a resulted TIRR, and ≥1 member
  TIRR is resulted. A resulted TIRR referenced only by a *cancelled* RTIA
  still counts (work performed, then the request cancelled) — matches the
  baseline, where a cluster with any surviving TIRR is never a cancelled
  cycle.
- **RA atom — cancelled**: no resulted TIRR, no live RTIA, ≥1 cancelled RTIA
  (the baseline's fully-cancelled cluster, §0.1). Husk TIRRs (unresulted,
  referenced only by cancelled RTIAs) are dropped from the atom and marked
  consumed, as in the baseline.
- **Result-only atom — always resulted** (unresulted leftovers stay excluded;
  no RTIA means it can never be cancelled).

**Status barrier (new in v2):** rules (a)/(b)/(c) only merge atoms of the
**same status** — open↔open, resulted↔resulted, cancelled↔cancelled. Every
merged component is therefore homogeneous:

> open component → **in-progress** · resulted component → **completed** ·
> cancelled component → **cancelled cycle** (emitted with
> `cancelled_at` = max member RTIA `cancelled_at`, aggregated
> `cancellation_notes` — §0.2)

One baseline behaviour this changes: today a fully-cancelled RA created within
3 days of a **live** same-program RA joins that cluster, and its cancellation
is silently swallowed by the live cycle. Under the barrier it stays a separate
cancelled cycle — more faithful (the cancelled request is visible as cancelled
history, the live request stays open) but a delta to spot-check.

This deliberately changes two behaviours — one of which ships in v1 today —
because both leak Monitor-open work into completed referrals:

| Leak | Where it exists | Effect |
|---|---|---|
| "Any resulted" completion | **today's v1** (`referrals_import.rb:448,459`) — completed when *any* member TIRR is resulted | Partially resulted RA (2 tests requested, 1 resulted) — still an outstanding request in Monitor — imports as completed |
| Cross-status merge | today's pass-1 rule-(b), and the earlier draft of this doc ("promotion") | Open RA merged with a resulted RA/TIRR (3-day window / shared appointment / result affinity) disappears into a completed referral while Monitor still shows the open request |

v2 closes both: **"all RTIAs resulted" replaces "any TIRR resulted"**, and the
barrier applies to every rule — including rule (a). A genuinely same-visit
pair where one test's result was never entered stays as **two** referrals
(one completed, one in-progress). That split is the honest picture of
Monitor's state, and it self-heals: once the open side is resulted in Monitor,
both atoms are resulted and the next purge+re-import merges them normally.

Status by component composition:

| Component | Status | vs today |
|---|---|---|
| open RA atom(s), nothing resulted | **in-progress** | unchanged |
| open RA atom(s), partially resulted | **in-progress** | **changed** — today completed via "any resulted" |
| resulted RA atom(s) ± adopted result-only atoms | **completed** | unchanged |
| result-only atom(s) | **completed** | unchanged |
| cancelled RA atom(s) | **cancelled cycle** | mostly unchanged (§0.1); delta: no longer absorbed into a live cluster ≤3d away (barrier) |
| shell (no atoms at all) | in-progress unless source archived | unchanged (`shell_cycle`) |

What status drives downstream (mechanics unchanged — listed because the two
fixes above move cycles between the branches):

- **in-progress** → `processing_mode = "fully_automated"` (§0.6); services
  `unbilled` with booking timestamps (billing advances naturally in
  Assessment); no `referral_completed_at`; wins the clean reference number in
  `main_cycle_key` (in-progress always beats completed).
- **completed** → `processing_mode = "completed"`; `referral_completed_at` /
  `billing_completed_at` = `cycle_date`; referral `doctor_outcome` / notes /
  recommendations from member TIRRs; services `billed`; only completed cycles
  are next-test-holder eligible.
- **cancelled** → cancelled history (`fully_automated` + `cancelled_at`,
  §0.6); excluded from `main_cycle_key` / `next_test_holder_key` /
  `chain_cycle_referrals!`.
- **Archived Monitor referrals drop in-progress cycles** — consistent with
  fidelity: archived = monitoring ceased, Monitor no longer counts that work
  as open.

  ⚠️ **BLOCKER DECISION before implementation — archived × strict status
  loses real history.** Strict status makes partially resulted RAs
  *in-progress*, and the archived rule drops in-progress cycles — so an
  archived referral's **already-resulted TIRRs inside a partially resulted
  cycle would be discarded** (today's "any resulted" rule imports them as a
  completed cycle). This must be decided, not defaulted. Options:
  1. **(Recommended) Archived carve-out by decomposition**: for archived
     referrals only, treat open RTIAs as abandoned work (archived ⇒ nothing
     is open) — the component's resulted TIRRs emit as a **completed** cycle;
     drop only truly-unresulted remainder. Fidelity holds (an archived
     referral has no open Monitor work by definition) and no resulted history
     is lost.
  2. Archived carve-out to v1 "any resulted": same import outcome as option 1
     for resulted TIRRs, but marks the whole partially-resulted cycle
     completed (unresulted RTIAs silently swallowed). Simpler, less honest
     audit trail.
  3. No carve-out (pure strict status): resulted history inside archived
     partial cycles is dropped — only acceptable if the §6 count of archived
     partially-resulted RAs is ~zero. Verify before choosing.

Consequences of strict status to resolve before implementation:

1. **Partially resulted in-progress cycles carry already-resulted services —
   design, not a note.** `build_service!` currently branches per *cycle*;
   under strict status the branch moves **per TIRR**:

   | TIRR in an in-progress component | Service attrs |
   |---|---|
   | **Resulted** | Reuse the existing completed-branch stamps: `results_received_at` / `doctor_outcome` / `doctor_outcome_finalised_at` = result_ts, `service_completed_at` = completed_ts, `doctor_notes`/`doctor_recommendations`, **`billing_status: "billed"` + `billed_at`** (terminal), `appointment_attended_at` via `update_columns` |
   | **Unresulted** | Today's in-progress attrs: `service_created_at`, `billing_status: "unbilled"`, booking timestamps in the create attrs |

   Two hazards force the terminal-billed choice for the resulted side (not
   "resulted but `unbilled`"):
   - `after_save :advance_billing_status_on_completion` fires when
     `service_completed_at` is present on an `unbilled` row → the migrated
     result enters Assessment's billing pipeline → **re-bills work Monitor
     already handled**, violating the billing-migration.md safeguard.
   - Leaving `service_completed_at` nil instead (to dodge the callback) makes
     the UI/signals treat a genuinely resulted test as not resulted —
     `evaluate_signals` no longer takes the `completed?` short-circuit and can
     fabricate stale signals against a back-dated resulted service.

   The **referral-level** lifecycle stays in-progress (no
   `referral_completed_at`/`billing_completed_at`, no referral
   `doctor_outcome` rollup) — the outcome renders per-service, and the
   referral completes naturally in Assessment when the open services finish.
   Log a NOTE per mixed cycle for billing reconciliation (Monitor may or may
   not have invoiced the resulted visit yet).
2. **Stale open RAs stay in-progress forever** (request from years back whose
   last test was never entered). That *is* Monitor's state — fidelity says
   migrate it as-is — but if the §6 count is large, agree a business cutoff
   explicitly rather than silently completing them.
3. **Unresulted TIRRs with no RA remain excluded** (unchanged). If Monitor
   counts any of these as open work, they surface in the §6 reconciliation as
   Monitor-open-without-Assessment-in-progress — review that diff, don't
   assume it's zero.

### Why this shape (alternatives considered)

- **Appointment-only grouping** — fails for the large result-only population
  (manual/Screen entries have no appointment at all).
- **Pure result-date clustering, ignore RAs** — loses the only date for
  in-progress cycles and splits single RAs with straggling results (violates
  principle 1).
- **Keep pass 1/pass 2 and only add an "adoption" pass for leftovers** —
  fixes P2 but not P1, and keeps the ordered-pass complexity plus a third
  pass. The unified atom clustering is less code, not more: it replaces
  `cluster_ras_by_window` + the leftover loop with one union-find (~40 lines).

### Trade-offs / accepted risks

- **Two-threshold asymmetry** (30d veto vs 7d adoption) is intentional:
  request affinity is prior evidence of one visit, so it tolerates lab
  turnaround variance; a bare result-date coincidence needs to be tight before
  we claim same-visit.
- **High-frequency programs** (cadence ≤ `RESULT_GAP_DAYS`) could chain-merge
  distinct events. `MAX_CYCLE_SPAN_DAYS` bounds the damage; if pre-flight
  shows programs with sub-weekly cadence, add a per-program window override
  (map keyed by `tenancy_monitoring_item_detail_id`).
- **Cross-status pairs never merge** (status barrier): one visit whose results
  were entered for only some of its RAs is emitted as two referrals until the
  open side results. Chosen deliberately — status fidelity to Monitor
  (principle 5) outranks visit-level dedup, and the split self-heals on
  re-import once both sides are resulted.
- **More in-progress referrals than v1** would have produced: partially
  resulted RAs and cross-status neighbours now land in-progress. This is the
  point (they are open in Monitor), but it grows the "Awaiting Action"
  workload in Assessment on day one — size it with §6 before the bulk run.

---

## 5. Worked examples (today vs v2)

| Scenario | Today | v2 | v2 status |
|---|---|---|---|
| RA Mon + RA Wed, resulted 2025-03-10 / 2025-06-20 (P1) | 1 cycle | **2 cycles** — rule (b) vetoed (102d > 30d), rule (c) fails | completed + completed |
| RA Mon + RA Wed, resulted 03-10 / 03-12 | 1 cycle | 1 cycle — rule (b) holds (2d ≤ 30d) | completed |
| RA cycle resulted 03-10 + manual TIRR (no RA) resulted 03-11, same program (P2) | 2 referrals | **1 cycle** — rule (c), key stays `requested_assessment:{id}` | completed |
| Fully resulted RA TIRR + non-RA TIRR on the **same appointment** | 2 referrals | 1 cycle — rule (a) | completed |
| Two fully resulted RAs 6 days apart, TIRRs share one appointment (false split) | 2 cycles | **1 cycle** — rule (a) | completed |
| Two manual TIRRs resulted 23:50 / next-day 00:30 UTC (P3) | 2 referrals | 1 cycle — rule (c) | completed |
| Two open RAs 2 days apart | 1 cycle | 1 cycle — rule (b), both open so barrier allows | **in-progress** |
| **Open** RA whose TIRR shares an attended appointment with a resulted manual TIRR | 2 referrals | **2 referrals — status barrier** (merges on re-import once the RA results) | in-progress + completed — mirrors Monitor |
| Resulted RA + open RA created 2 days apart, same program | **1 completed cycle** (open request hidden) | **2 cycles — status barrier** | completed + **in-progress** — mirrors Monitor |
| RA with 2 tests requested, 1 resulted, 1 outstanding | **1 completed referral** ("any resulted") | 1 cycle (RA atomic) | **in-progress** — strict "all RTIAs resulted" rule |
| Same program, RAs a year apart (annual re-test) | 2 cycles | 2 cycles — unchanged | per cycle: completed if fully resulted, else in-progress |
| Monthly D&A screens, manual entry, 30d cadence | 1 referral per day | 1 per event — 30d gap > 7d rule (c); span cap as backstop | completed |
| Fully-cancelled RA created 2 days from a live open RA, same program | 1 cluster — cancellation swallowed into the live cycle | **2 cycles — status barrier** | in-progress + **cancelled** — cancellation survives as history |
| Two open RAs 2 days apart, **booked** into visits 60 days apart (RTIApp windows) | 1 cycle | **2 cycles** — rule (b) veto now reaches open atoms via booking windows | in-progress + in-progress |

---

## 6. Pre-flight measurement (run on Monitor prod console before tuning)

Quantify each problem and pick thresholds from data, not intuition:

```ruby
# P1 prevalence — same-program RA pairs created ≤3d apart whose TIRR
# result dates are >30d apart (would have merged today, split under v2)
pairs = RequestedAssessment.joins(:test_item_referral_results)
  .where.not(test_item_referral_results: { result_date: nil })
  .group(:referral_id, :enrolled_item_id)   # proxy for program; refine via MID if needed
  .having("count(distinct requested_assessments.id) > 1")
# then per group: max(created_at gap) vs max(result_date gap) — export to CSV
# and eyeball the joint distribution; the 3d/30d corner is the P1 population.

# P2 prevalence — resulted TIRRs with no RTIA back-link but whose result_date
# lands within 7d of an RA-linked TIRR of the same referral+program
orphans = TestItemReferralResult
  .where.not(cascaded_outcome_detail_name: nil)
  .where.missing(:requested_test_item_assessments)
# join against linked TIRRs on (referral_id, tenancy_monitoring_item_detail_id)
# and bucket by |result_date delta| — counts at ≤1d / ≤3d / ≤7d set RESULT_GAP_DAYS.

# Cadence check — per monitoring item, median gap between consecutive resulted
# TIRRs of the same (referral, program): any program with median < 14d needs a
# per-program override before rule (c) is safe.

# Strict-status deltas — cycles that flip completed→in-progress under
# "all RTIAs resulted" (§4 Cycle status). Two sub-populations:
#   (i) partially resulted RAs (≥1 resulted TIRR AND ≥1 outstanding RTIA)
#  (ii) RAs with resulted TIRRs but RTIAs never linked to a TIRR at all
# If (ii) dominates and is data noise rather than real open work, refine
# "open" to require an *unresulted linked* TIRR.
partial = unlinked = 0
RequestedAssessment.includes(requested_test_item_assessments: :test_item_referral_result).find_each do |ra|
  live     = ra.requested_test_item_assessments.reject(&:cancelled_at) # cancelled RTIAs aren't outstanding work
  tirrs    = live.map(&:test_item_referral_result)
  resulted = tirrs.compact.count { |t| t.cascaded_outcome_detail_name.present? || t.result_evaluation_id.present? }
  next if resulted.zero? || resulted == live.size
  tirrs.any?(&:nil?) ? unlinked += 1 : partial += 1
end
# Also count how old the open side is (created_at histogram) — sizes the
# "stale open RA" population for the business-cutoff decision.
```

Also rerun the fallback-population counts from `referral-grouping.md`
§"Results without an appointment" — that's the population rule (c) acts on.

**Post-import reconciliation (fidelity check, run after every bulk import):**
the set of non-archived Monitor referral ids with ≥1 open RA (≥1 live RTIA
unresulted — cancelled RTIAs don't count) must equal the set of
`monitor_referral_id`s owning ≥1 migrated in-progress referral (in-flight
`processing_mode`, no `referral_completed_at`, no `cancelled_at`). Diff
**both directions**; every mismatch is either a fidelity bug or a documented
exclusion (archived referral, unresulted no-RA TIRR) — nothing else is
acceptable.

---

## 7. Implementation notes

- **Touch points** (`referrals_import.rb`): replace `build_cycles` internals
  and `cluster_ras_by_window` with atom build + union-find; extend
  `appointment_lookup` to also expose appointment **ids and statuses** —
  and add a **new RTIApp index keyed by `requested_test_item_assessment_id`**
  for RA atoms (the existing `tirr_appointment_ids` goes RTIApp → RTIA → TIRR
  and yields nothing for open RTIAs with nil `test_item_referral_result_id` —
  see step 2 ⚠️). The attended/completed status filter is still missing from
  the AIR path — fix both here. `ra_program_key`, `resulted?`, emission,
  purge, history routing: unchanged interfaces.
- **Key migration**: fallback keys change form (`result:{ref}:{program}:{date}`
  → `result:{ref}:{min_tirr_id}`), and P1/P2 regrouping moves rows between
  keys. Any environment already imported must be purged
  (`referrals_purge_migrated.rb` / `RESET=true`) and re-imported — do **not**
  upsert v2 over a v1 import.
- **Specs**: `build_cycles` currently has zero automated coverage (flagged in
  [monitor-referral-migration-review.md](monitor-referral-migration-review.md)
  §testing). v2 must land with unit specs over synthetic bundles covering
  every row of the §5 table — the logic is pure (bundle-hash in, cycles out),
  so this is cheap.
- **Docs to update on adoption**: `specs/referral-grouping.md` (granularity +
  fallback sections), `cycle-referral-grouping-data-model.md` §"Cycle boundary
  rules" + examples, `TESTING-REFERRALS.md` cases.
- **Log/observability**: emit an import log line whenever (i) rule (b)'s veto
  fires, (ii) the span cap blocks a merge, or (iii) the **status barrier**
  blocks a merge that another rule wanted (a cross-status same-visit pair kept
  split for fidelity) — these are exactly the ambiguous files a human should
  spot-check after the bulk run. Then run the §6 post-import reconciliation.
- **`build_service!` per-TIRR branch** — designed in §4 "Consequences" item 1
  (resulted TIRRs in an in-progress component land **terminal + billed** to
  dodge the `advance_billing_status_on_completion` re-billing hazard and the
  stale-signal hazard; unresulted siblings stay `unbilled`; NOTE-log mixed
  cycles for billing reconciliation).
- **Blocker decision before implementation**: archived × strict status
  (§4 "Archived" ⚠️) — pick option 1/2/3 with the §6 archived
  partially-resulted count in hand.

---

## 8. Recommendation summary

Adopt the v2 atom/union-find grouping: appointment identity first, result-date
proximity second, request-date affinity third with a result-window veto;
result-only TIRRs cluster as peers instead of a separate fallback pass; keys
from member ids. **Status fidelity is a hard constraint**: completed requires
*all* RTIAs resulted (not any TIRR), and the status barrier stops open atoms
merging with resulted ones — Monitor's in-progress population maps onto
Assessment's exactly, verified by the §6 reconciliation. **Gates before
implementation:** (i) the §6 cadence/P2 queries are mandatory for
`RESULT_GAP_DAYS` (start at 3d if inconclusive); (ii) the archived ×
strict-status blocker (§4 ⚠️ — recommended: decompose archived partial cycles
so resulted history imports as completed); (iii) the per-TIRR service branch
ships as designed in §4 (resulted-in-open-cycle services terminal + billed).
Land the change together with unit specs for `build_cycles` covering every §5
row.
