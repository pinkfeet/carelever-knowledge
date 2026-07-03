# Monitor → Assessment referral migration — code review (export + import)

Independent review of the CT-4461 referral migration scripts, done directly from
the code (not from the earlier `monitor-referral-migration-review.md`, which was
deliberately ignored). Focus per request: appointment / service **booking** data,
and any other gotchas.

**Files reviewed**
- `script/migrate-monitor/referrals/referrals_export.rb` (445 lines)
- `script/migrate-monitor/referrals/referrals_import.rb` (2001 lines)
- Specs: `referrals-field-mapping.md`, `related-data.md`, grouping specs
- Cross-checked live behaviour in `app/` (Service model, ProcessingModes::Derive,
  booking commands, serializers) and the Monitor data model in
  `carelever-knowledge/monitoring/*`.

---

## TL;DR on your specific worry: `service.appointment_booked_for`

**It is covered, and it is correct.** It's set in `booking_timestamps_for`
(`referrals_import.rb:1033`), added by commit `73a6e254`, and applied in **both**
the in-progress and completed branches (`:1227`, `:1246`).

It stores Monitor's `scheduled_at` (a UTC instant). That is the right
representation: the live app writes `appointment_booked_for` via
`tz.local(...)` (`internal/appointments/create.rb:275-280`,
`candidate/booking/confirm.rb:143`), which Rails persists as the true UTC
instant, and all readers treat it as an instant (`candidate/dashboard/load.rb`
ordering/comparisons). So no timezone conversion is needed here (unlike
`Appointment.start_time`, which *is* a naive wall-clock and *is* correctly
converted at `:1128-1137`). No bug.

So the specific field you flagged is fine — but the instinct behind it ("we
missed some service booking data") is correct. See Finding 1.

---

## Findings (ranked)

### 1. [HIGH] Booked-but-not-yet-resulted appointments are dropped — in-flight services get no booking timestamps

There are **two** appointment↔test linkages in Monitor
(`monitoring/cycle-referral-grouping-data-model.md:260-262`):

- **Path B — `appointment_item_results`** (AppointmentItem → TIRR). Created at
  *result* time (its `after_create_commit` writes `result_date`). **This is the
  only path the migration uses.**
- **Path A — `requested_test_item_appointments`** (RequestedTestItemAssessment
  `has_many :appointments`). This is the **booking** link and exists *before*
  results. **It is never exported and never consumed.**

The export `PRELOAD` (`referrals_export.rb:88-100`) pulls
`requested_test_item_assessments` but not `requested_test_item_appointments`,
and `appointment_lookup` / `import_appointments!` associate appointments to
services purely through `appointment_item_results`
(`referrals_import.rb:990-1004`, `1098-1117`).

**Consequence** for a cycle that is booked but not yet attended/resulted (a
genuine in-flight referral):
- The appointment *is* in the bundle (`referral.appointments` is exported), but
  has no `appointment_item_results` row → `import_appointments!` skips it with
  `"no items map to a migrated service"` (`:1114-1117`).
- `booking_timestamps_for` returns `{}` (`:1027`) → the service gets **no**
  `appointment_intent_recorded_at` / `appointment_booked_at` /
  `appointment_booked_for`.
- On create, `evaluate_signals` then sees an unbooked service and can fabricate
  the exact **"appointment not booked"** signal the booking-timestamp commits
  were written to prevent; the referral shows in the awaiting-booking KPI / list
  even though Monitor had it booked.

This is the real "missed service booking" gap. Severity depends on how many
in-flight (booked, unattended) referrals are in the migration set — for a mostly
historical/completed dataset it's small, but it is a correctness gap for exactly
the live subset. Possible remediations: export path A
(`requested_test_item_appointments`), or match `appointment_items` to a cycle's
services by `tenancy_test_item_detail_id` when no `appointment_item_results`
exists.

### 2. [MED] `processing_mode = "attention_required"` for in-progress cycles is off-spec and non-durable

`upsert_referral!` hard-sets `processing_mode = "attention_required"` for
in-progress cycles (`referrals_import.rb:736`). Two problems:

- **Contradicts the field map**, which says an active in-flight cycle should be
  `fully_automated` (`referrals-field-mapping.md:66`).
- **Not derivable, so it won't survive.** `ProcessingModes::Derive`
  (`app/services/processing_modes/derive.rb:13-17`) returns
  `attention_required` **only if unresolved exception signals exist**, else
  `fully_automated`. The import deliberately suppresses signals (terminal create
  for completed; booking timestamps in the create attrs for in-progress). So the
  first `update_processing_mode!` triggered afterwards (sign-off, appointment
  status change, signal resolution) flips these referrals to `fully_automated`.

Net: the value is both wrong per spec and unstable. Decide whether in-flight
migrated referrals should be `fully_automated` (per spec) or should carry a real
unresolved signal that justifies `attention_required`.

### 3. [MED] TIRR `additional_note` is silently dropped

`related-data.md` (§1 Results-tab mapping) maps TIRR `additional_note` →
`referral_notes` or a service note. The import never reads `additional_note`
anywhere (confirmed by grep across `referrals_import.rb`). `result_data` /
`result_config` / `test_item_specific_data` are folded in
(`result_data_for`, `:1268-1272`), but the free-text result note is lost.

### 4. [LOW / confirm scope] Doctor-review detail not migrated

Only `cascaded_outcome_detail_name` → `service.doctor_outcome` (+ `OutcomeEvent`)
is carried. `service.doctor_notes`, `doctor_recommendations`,
`doctor_restrictions`, `doctor_medical_considerations` are left nil. Confirm
Monitor genuinely has no per-result equivalents (i.e. the outcome name is the
whole story), otherwise doctor rationale/restrictions are lost on migrated
services.

### 5. [LOW / edge] `appointment_booked_at` can land *after* `appointment_booked_for`

`booking_timestamps_for` clamps `booked_at` up to `created_ts`
(`:1029`) but leaves `booked_for` as the raw scheduled instant (`:1033`). For a
back-dated Monitor appointment (row `created_at` after `scheduled_at`, or a
service whose derived `created_ts` post-dates the appointment), you get
`booked_at > booked_for`. Turnaround "request→booked" / "booked→attended" spans
(`concerns/turnaround_calculator.rb`) then go negative for those rows. Rare, but
worth a clamp if turnaround analytics matter on migrated data.

### 6. [LOW] `appointment_confirmed_at` never set

Declared canonical on the model (`app/models/service.rb:198`). `appointment_confirmed?`
falls back to `appointment_booked_at` (`service.rb:400`), so stage/serializer
logic is fine, but verify no report/serializer reads `appointment_confirmed_at`
directly before relying on it staying nil.

### 7. [LOW / known TODO] Component (per-unit) services not created

Acknowledged in-code (`build_service!` note `:1261-1263`; `resolve_catalog!`
note `:1293-1296`): the unit→component breakdown isn't carried per result, so
bundle/component sub-services aren't reconstructed. Fine as a known follow-up —
just flagging it belongs on the gap list.

---

## Verified OK (spot-checks that held up)

- **`appointment_booked_for`** — set and correct (see TL;DR).
- **Appointment wall-clock** — UTC `scheduled_at` correctly converted to clinic
  tz for `appointment_date`/`start_time`/`end_time` (`:1128-1137`), with the
  `"Brisbane"` fallback matching Monitor.
- **Re-import idempotency** — `monitor_cycle_key` upsert +
  `purge_migrated_children!` (`:794-823`); `supplier_assignments` cascade on
  `service.destroy!` (`app/models/service.rb:136` `dependent: :destroy`), so
  RESET/re-import won't trip FK or duplicate.
- **Signal suppression on completed cycles** — terminal create (`billed` +
  `service_completed_at`) makes `evaluate_signals` short-circuit (`:1232-1258`).
- **Reference-number uniqueness** — verbatim on main cycle, deterministic SHA
  suffix on historical, with `demote_stale_verbatim_references!` freeing the
  verbatim value when the main cycle shifts (`:689-701`).
- **Booking-timestamp storage semantics** — instant, consistent with live
  `tz.local` writers; no double-conversion.

---

## Suggested priority

1. Decide on Finding 1 (booked-unresulted appointments) — it's the one that
   matches your "missed service booking" hunch and affects the live in-flight
   subset.
2. Reconcile Finding 2 (`processing_mode`) with the field map.
3. Finding 3 (`additional_note`) — small, spec'd, easy to add.
4. 4–7 are confirm-scope / low-risk.
