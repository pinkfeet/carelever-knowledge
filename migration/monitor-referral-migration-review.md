# Review: Monitor → Assessment Referral Migration (Export/Import) — Gaps & Gotchas

**Date:** 2026-07-02
**Repo:** `carelever_assessment`
**Scripts:** `script/migrate-monitor/referrals/referrals_export.rb`, `referrals_import.rb` (+ specs in `script/migrate-monitor/specs/`)
**Scope:** Whole-migration review — missed fields, silently dropped source data, logic gotchas, idempotency, spec/code drift. **Review only; no code changed.**

> Companion docs: [`monitor-referral-migration-side-effects.md`](./monitor-referral-migration-side-effects.md) (nudge email flood), [`referral-import-side-effects-analysis.md`](./referral-import-side-effects-analysis.md) (callback side effects during import). This doc covers **data coverage**, not side effects.

All findings verified against code (file:line refs are to `carelever_assessment` unless prefixed `monitor:` = `carelever_monitoring`).

---

## TL;DR — ranked findings

| # | Finding | Severity |
|---|---------|----------|
| 1 | Services never get `appointment_booked_at` / `appointment_booked_for` / `appointment_intent_recorded_at` — candidate double-booking, wrong stages, blank key dates, dead reminders, inflated KPIs | **HIGH** |
| 2 | TIRR doctor commentary (`additional_note`, `recommendations`) dropped entirely — spec promised `additional_note` | **HIGH** |
| 3 | Person matching by email alone merges different humans; referral candidate_* then stamped from the wrong Person | **HIGH** |
| 4 | `next_test_service_item_id`/`next_test_service_variation_id` never set → monitoring list shows "Standard Assessment"; `is_final_result` ignored → exited workers re-enter monitoring | **HIGH** |
| 5 | Unit → component services unimplemented; units mapping 0/58 filled | **HIGH** |
| 6 | Azure `referral_documents` land with unfetchable `file_path` (no byte-copy/convert step exists) | **HIGH** |
| 7 | Person with in-flight newest cycle vanishes from client monitoring list (`next_test_date` only set on completed active cycle) | **MEDIUM** |
| 8 | Cancelled test requests resurrected as active in-progress referrals; cancelled/no-show appointments can stamp `appointment_attended_at`; `unconfirmed` → `completed` status mapping | **MEDIUM** |
| 9 | Delta export (`UPDATED_SINCE`) blind to Person, TIRR-level attachment, NextTest, AppointmentItemResult, InvoicingEntity changes | **MEDIUM** |
| 10 | Re-import gotchas: duplicate Contacts via phone normalization mismatch; `\|\|=` fields frozen; doctor unassignment not cleared | **MEDIUM** |
| 11 | RESET crashes on referrals with post-import `BillingAttempt`/`LineItem`/chat rows (purge script handles them; RESET doesn't) | **MEDIUM** |
| 12 | `cached_billing_total_cents` nil → client "Total spend" shows $0 for migrated history | **MEDIUM** |
| 13 | `appointment_fulfilment_mode` left `booked_only` for walk-in items; no `SupplierAssignment` rows | **MEDIUM** |
| 14 | Archived Monitor attachments (`is_archived`) resurface as visible documents | **MEDIUM** |
| 15 | Spec/doc drift + stale artifacts (`placeholder_keys.txt`, README shell behaviour, `processing_mode` spec) | **LOW–MEDIUM** |

---

## 1. Service booking timestamps never set (the `appointment_booked_for` gap) — HIGH

`import_appointments!` creates `Appointment` + `AppointmentService` rows (`referrals_import.rb:1041-1093`) but never stamps the linked services, and `build_service!` (`:1125-1175`) sets none of: `appointment_booked_at`, `appointment_booked_for`, `appointment_intent_recorded_at`. Every live booking path sets all three (`app/commands/v1/internal/appointments/create.rb:275-282`, `app/commands/v1/candidate/booking/confirm.rb:139-145`, `app/services/referrals/create_appointments.rb:84-85`, reschedule/appointment-request models). The migrated state (blocking appointment + nil intent) is **unreachable through the live app**, so nothing downstream expects it.

**Consequences for in-progress migrated cycles with a live appointment:**

- **Candidate double-booking**: `V1::Candidate::Booking::Eligibility` treats `appointment_intent_recorded_at IS NULL` as bookable (`eligibility.rb:69-86`); candidate `Booking::Confirm` has no blocking-appointment guard (unlike internal `Create#unbookable?`, `create.rb:101-107`). A candidate can book a second appointment for an already-booked service.
- **Wrong stage/bucket**: `referral_stage_deriver.rb:92-102` falls to `awaiting_appointment` ("Booking Required") instead of `appointment_scheduled`; mirrored in client dashboard summary (`v1/client/dashboards/summary.rb:73-79`) and `referral_stage_resolver.rb:147-173`.
- **Contradictory internal UI**: quick actions say "Book appointments for X" (`detail_serializer.rb:491,507-509`) while the Add Appointment modal correctly hides the service (`:568-578` uses the appointments association) and Create would 422. Status pill shows "Assessment Not Started" instead of "Appointment Booked" (`:793-803`).
- **Candidate dashboard**: "Book appointment" pending action shown despite booking; upcoming-appointment card never renders (`v1/candidate/dashboard/load.rb:102-107, 231-258`).
- **Nudges**: 24h/2h `appointment_reminder` never fires (`nudges/evaluate_and_schedule.rb:98-113` requires `appointment_booked_for`).
- **False exception signals**: in-progress `Service.create!` fires `evaluate_signals`; dynamic booking rules keyed on back-dated `service_created_at` with stop-condition `appointment_intent_recorded_at` violate immediately → false "not booked" signals for services that *do* have appointments (`issue_definition.rb:101-128`, `signals/rules/dynamic_rule.rb:71-78,102-113`). Conversely `Signals::ConfirmedAppointmentOverdue` is dead for migrated data (filters `services.appointment_booked_for < ?`, NULL excluded — `confirmed_appointment_overdue.rb:32-39`).

**Consequences even for completed/historical cycles:**

- **Client insights KPI inflated**: `services_awaiting_booking = …where(appointment_booked_at: nil)` has no completed-exclusion (`v1/client/insights/compute.rb:103`) — every migrated service counts as "awaiting booking" forever.
- **Turnaround analytics** silently exclude the request→booked leg (`turnaround_calculator.rb:76-77`), feeding ops dashboard + client insights.
- **Key Dates "Appointment booked" blank** on internal (`detail_serializer.rb:145-146`), client (`show_serializer.rb:157`), doctor portal (`doctor_reviews/detail_serializer.rb:204`). Internal timeline shows "Booking: pending" on referrals whose attendance/results/completed steps are done (`detail_serializer.rb:321-347`, `service.rb:399-405`).
- **Progress bar caps ~82%** — booked step never counts (`referral.rb:486`).

**Suggested fix shape** (when implemented): in `import_appointments!`, stamp `appointment_intent_recorded_at` + `appointment_booked_at` (proxy: Monitor appointment `created_at`, else `scheduled_at`) and `appointment_booked_for` (the tz-local instant already computed at `:1071`) on all linked services via `update_columns` — including completed ones.

### Related service-level gaps (MEDIUM)

- **`appointment_fulfilment_mode`** left at DB default `booked_only`; live creation paths set it from the catalog item (`v1/shared/referrals/create.rb:247`, `create_bundle_components.rb:40`). Monitor items mapped to walk-in-only catalog items migrate bookable: shown in candidate booking wizard (`eligibility.rb:82-86` only excludes `walk_in_only`), internal unbooked list, wrong pill. (Booking signals are rescued by the `booking_walk_in_only?` fallback at `dynamic_rule.rb:121-125`.)
- **No `SupplierAssignment` rows** (live paths: `internal/appointments/create.rb:262`, `candidate/booking/confirm.rb:151-153`). Client insights "Top Clinics" excludes all migrated work (`insights/compute.rb:115-121`); supplier display fallback and supplier-scoped issue definitions degrade; `Appointment#clinic_unavailable_only_for_internal` misclassifies migrated appointments as internal (`appointment.rb:225-231`).
- **No `shift_id`**, `practitioner_id` only when resolvable — pre-event migrated appointments invisible to slot-conflict/shift-utilisation queries (LOW).

---

## 2. Referral-level field gaps

### 2.1 Doctor commentary dropped — HIGH

Monitor TIRR `additional_note` (monitor:`db/schema.rb:2671`) and `recommendations` (string array, `:2665`) are exported via `.attributes` but the import references neither (grep: zero hits). `related-data.md:41` explicitly promises `additional_note` → "referral_notes or service note"; `recommendations` isn't documented anywhere. Referral-level `doctor_notes`/`doctor_recommendations`/`doctor_restrictions`/`doctor_medical_considerations` stay nil. Readers rendering empty: doctor portal review (`doctor_reviews/detail_serializer.rb:25-28`), Health Monitoring report PDF (`health_monitoring_report_service.rb:181-187,240-243`), Fitness-for-Work report (`fitness_for_work_report_service.rb:130-138`), AI context providers. **Outcome renders with no commentary anywhere, and the text isn't preserved even as a note.**

### 2.2 Next-test identity and monitoring-list correctness — HIGH

- `next_test_service_item_id` / `next_test_service_variation_id` never set (import sets only `next_test_date`, `referrals_import.rb:747, 974-977`) despite `related-data.md` §2 mapping both. Client monitoring list falls back to **"Standard Assessment"** for every migrated row (`v1/client/health_monitoring/index.rb:107-109`); doctor HS panel and FFW report also read them.
- **`is_final_result` ignored** (monitor:`schema.rb:2674`): `related-data.md` §2 says final result ⇒ leave next-test fields null (worker exited program). Import takes min `next_tests.date` regardless — an exited worker re-enters the client monitoring list with a future due date.
- **In-flight newest cycle ⇒ person vanishes from monitoring list** (MEDIUM): `next_test_date` is assigned only in the completed branch for the active cycle (`:747` sits in the `else`); `V1::Client::HealthMonitoring::Query` requires `processing_mode: completed` + `next_test_date NOT NULL` (`query.rb:39-64`). Until the migrated in-flight cycle completes in Assessment, that person is absent from the employer monitoring list. Spec flags the query dependency but doesn't resolve this.
- `next_tests` per-row detail (per-test-item due dates, `classification` additional/previous_result/evaluation, offsets) reduced to a single min date (LOW–MEDIUM, partially a documented decision).

### 2.3 Other referral columns

- **`cached_billing_total_cents` nil** (MEDIUM): client insights total/monthly spend excludes nil (`v1/client/insights/compute.rb:233-243`) → **$0 spend for the entire migrated history** although services are `billed`. Consistent with no-rebilling, but undocumented in `billing-migration.md`.
- **`previous_referral_id` never chained** across a person's cycle-referrals (LOW): comparative insights (spirometry/audiometry baselines) and re-refer prefill read it — migrated multi-cycle history won't drive cross-cycle comparisons.
- `overall_determination`, `doctor_outcome_submitted_at`, `doctor_review_started_at` nil (LOW–MEDIUM): HS report determination line + doctor-review key date blank; no functional breakage (timeline and doctor-portal access key off `doctor_outcome_finalised_at`, which is set; `AutoFinalizeDoctorOutcomeJob` guarded by `submitted_at` so it never fires on migrated rows).
- **`positions` resolution is silent** (LOW): `position_title_for` returns nil without a WARN when the Position id doesn't resolve (`referrals_import.rb:893-898`), unlike other unresolved lookups. Depends on Phase 0/1 `positions_import.rb` having run.
- `referrals.type_date` (monitor: when a referral was archived/on-hold) not migrated and not in the documented skip table — archived shells lose "when monitoring ceased" (LOW–MEDIUM).

### 2.4 `processing_mode` for in-progress cycles is not what the script sets

The hardcoded `"attention_required"` (`referrals_import.rb:736`) is **overwritten during the import itself**: each in-progress `Service.create!` fires `evaluate_signals` → `update_processing_mode!` → `ProcessingModes::Derive`, which returns `attention_required` only if an unresolved ExceptionSignal exists, else `fully_automated` (`signals/evaluate_service.rb:17-18`, `derive.rb:13-39`). So the persisted mode depends on which IssueDefinitions are active in the target DB. It also diverges from the spec (`referrals-field-mapping.md:66` says in-flight = `fully_automated`). `completed` **is** stable (checked before signals; `billing_completed_at` + terminal services hold it). Shell edge: an active shell stays `attention_required` forever with nothing actionable; a completed archived shell would derive `fully_automated` if anything ever re-derived it (nothing does today) — fragile but latent.

---

## 3. Monitor source data silently dropped (not documented as skips)

| Item | Source | What's lost | Severity |
|------|--------|-------------|----------|
| TIRR `additional_note`, `recommendations` | monitor:`schema.rb:2665,2671` | Doctor/result commentary (see §2.1) | HIGH |
| `requested_test_item_assessments` cancellation fields (`cancelled_at/by`, `cancellation_reason`, `booking_delay_reason`, `result_delay_reason`, `status`) | monitor:`schema.rb:1976-1999` | (a) cancellation audit gone; (b) **behavioral**: an RA whose test requests were all cancelled has no resulted TIRR → imports as an *in-progress* `attention_required` cycle — cancelled work resurrected as live | MEDIUM–HIGH |
| Appointment statuses `attended`, `unconfirmed` missing from `APPOINTMENT_STATUS_MAP` (`referrals_import.rb:1011-1021`) | monitor:`app/models/appointment.rb:42` | Both default to `"completed"`. `attended→completed` defensible; `unconfirmed→completed` wrong for booked-but-future appointments on in-progress cycles (should be pending/confirmed). Map keys `pending/scheduled/clinic_unavailable` are values Monitor never emits — dead keys masking this | MEDIUM–HIGH |
| `appointments.comments` (non-cancelled) | monitor:`schema.rb:268` | Used only as `cancellation_notes`; booking comments otherwise lost. Same bucket: `is_walk_in`, appointment-level `notification_mode`, `status_last_updated_by_user_name` (appointment sub-spec is a declared future PR, but these are exported-and-dropped today) | MEDIUM |
| `attachments.is_archived` not honoured | monitor:`schema.rb:293` | Archived (hidden) Monitor attachments become fully visible `candidate_documents` — deleted-in-spirit data resurfaces | MEDIUM |
| `attachments.notes` → `candidate_documents.notes` | monitor:`schema.rb:294` | Column exists on target and spec §4a lists it; `import_candidate_document!` never writes it | MEDIUM |
| `people.seg_id` (Similar Exposure Group), `people.division_id` | monitor:`schema.rb:1453,1464-1465` | Core HS exposure-group context; no landing spot and no documented decision | MEDIUM |
| `referral_activities` bundle section | export `:326` | **Entirely unused by the import** (only `logs` drive history). Monitor workflow/stage timeline deferral is implicit at best; dead weight in every bundle | MEDIUM |
| `invoicing_entities.invoicing_name`, `recipient_emails[1..]` | monitor:`schema.rb:946-948` | Formal invoicing name unused (`name` used); only first billing recipient email kept | MEDIUM–LOW |
| TIRR `screen_outcome` / `from_screen` | monitor:`schema.rb:2669-2670` | Screen provenance of results lost | LOW–MEDIUM |
| `requested_assessments.requested_by_id/name` | monitor:`schema.rb:1955-1956` | Per-cycle requester attribution collapsed to shell `created_by_id` | LOW–MEDIUM |
| `requested_test_item_appointments` (not exported at all) | monitor:`schema.rb:1963-1974` | Booked/ended timestamps of the RA↔appointment link (linkage itself survives via `appointment_item_results`) | LOW–MEDIUM |
| `logs.is_private` ignored | monitor:`schema.rb:1065` | A `client_note` flagged private imports as client-visible (`:1723` derives visibility from category alone) | LOW |
| `referral_documents` `creator_name/email`; version chains flattened (all versions imported, not latest-only per spec §4b) | monitor:`schema.rb:1832-1834` | No author on migrated docs; superseded versions duplicated | LOW |

Verified **documented** skips (not gaps): legacy `evaluations`/`results` (pure pre-TIRR files skipped), `result_evaluations` scoring, billing line items/sales orders (`billing-migration.md` defers; import correctly marks terminal `billed` and creates nothing), logs category `log`, `availability_*`, `latest_log_*`, `home_address`, forms. Enum index orderings in the import (`MONITOR_RELATIONSHIP_NAMES`, `MONITOR_LOG_CATEGORIES`, `MONITOR_REFERRAL_TYPES`, sex map) all verified correct against Monitor models.

---

## 4. Person resolution can merge different humans — HIGH

`resolve_person!` uses `Person.find_or_initialize_by(normalized_email:)` and `||=` for name/DOB/phone (`referrals_import.rb:572-584`) — first bundle wins, conflicts silently ignored. The spec claims this "mirrors `V1::Shared::Referrals::Create`", but the app's `PersonMatchingService` additionally requires a name match and rejects DOB/gender conflicts (`person_matching_service.rb:42-55`). Compounding it, `upsert_referral!` stamps `candidate_first_name/last_name/email/phone/date_of_birth` **from the Person record, not the bundle** (`:711-715`) — two Monitor people sharing an email (spouse, admin proxy address) merge into one Person and the second person's referrals carry the **first** person's name/DOB/phone (while `assigned_sex_at_birth` still comes from their own bundle). Also merges `latest_referral` and monitoring-list grouping.

Secondary: `rec.save!` runs full Person validations — disposable-domain email or blank first/last name fails the **whole file** (loud in ledger, but a known trip-hazard).

---

## 5. Cycle/appointment logic gotchas

- **`appointment_attended_at` can come from a cancelled/no-show appointment**: `appointment_lookup` indexes every appointment regardless of status (`:984-992`); `attended_ts = appt_ts || result_ts` (`:1161`). Spec `referral-grouping.md:50-56` limits enrichment to statuses attended/completed — the code ignores that filter. A rescheduled-then-attended chain also picks the **earliest** (possibly cancelled) `scheduled_at`.
- **Shell-cycle appointments never migrate**: shell cycles have no TIRRs → no `tirr_service` mapping → all appointments skipped with log (acceptable, but means archived/unresulted referrals lose appointment history entirely).
- **`cycle_time_window` clamp inconsistency** (LOW): windows sort by `cycle_start_at` (falls through created/ra_created/cycle dates) but the next-cycle clamp reads only `sorted[idx+1][:created_date]` (`:1661-1663`) — a next cycle with nil `created_date` but a set `ra_created_date` won't clamp the previous window; log routing may double-bucket toward the older cycle.
- **History routing adds an undocumented 4th branch**: classified-but-unresolvable dated logs go to `nearest_cycle_key` (`:1598-1603`) — not in `history-migration.md` precedence.
- **History `action_by` never resolved to a real `user_id`** — all notes authored as `SYSTEM_USER_ID`; the spec's "resolve when a migrated user name matches" half is unimplemented (name survives in content/actor_name).

---

## 6. Idempotency / re-import gotchas

- **Duplicate Contacts on re-import** (MEDIUM): `import_relationships!` dedups via `Contact.find_or_create_by!(owner:, email:, phone:)` with the raw `"+61…"` phone (`:1266-1271`), but Contact's `normalizes_phone` folds `+61`→`0…` on save (`contact.rb:42`). First import stores `04…`; re-import queries `+614…` → creates a duplicate Contact + ReferralRelationship. `purge_migrated_children!` purges services/history only, **not** contacts (`:794-823`).
- **`||=` fields frozen after first import** (won't pick up Monitor-side corrections without RESET): `referral_completed_at`, `billing_completed_at`, `doctor_outcome`, `doctor_outcome_finalised_at`, `invoicing_contact_id`, `payment_method`, `created_by_id` (`:740-787`). Spec documents write-once only for `referral_created_at`.
- **Doctor unassignment not honoured on re-import**: `assign_doctor!` early-returns when `doctor_unassigned_at` present (`:902-909`) — leaves a previously imported `assigned_doctor_id/at` in place; spec requires clear-to-NULL. No `doctor_unassigned` activity emitted (spec: optional).
- **Stale `next_test_date` on demoted cycles**: only the archived branch clears it (`:758-763`); a previously-active completed cycle demoted on re-import keeps its `next_test_date` and stays on the client monitoring list.
- **`create_invoicing_contact!` uses `save!(validate: false)`** on a model whose phone/email normalization is `before_validation` — imported InvoicingContacts store unfolded `+61…` phones (LOW).
- Referral `save!(validate: false)` itself is fine: Referral has no `normalizes_*` on candidate fields (values arrive pre-normalized via the validated Person save); reference-number uniqueness is enforced by the DB index (fails the file loudly on a genuine collision).

---

## 7. Delta export (`UPDATED_SINCE`) blindness — MEDIUM

`DELTA_CHILD_CLASSES` (`referrals_export.rb:104-108`) + the attachment sweep (`:172-175`, `attached_to_type: "Referral"` only) never re-export a referral when only these changed:

- **Person** (email/name/DOB corrections — structural: delta plucks `referral_id`, Person has none)
- **TIRR-level attachments** (the common result-PDF case)
- **NextTest**, **AppointmentItemResult**
- **InvoicingEntity**, **Upload**, Location timezone

`specs/README.md:258-266` promises watermarks on `next_tests`/`attachments` etc. — not delivered. Any delta-based cutover plan must account for this (or re-export affected ranges fully).

Also: `SKIP_DEMO=true` silently excludes referrals with `person_id: nil` from export (the `IN` subquery drops NULLs, `:159-161`) — import would SkipFile them anyway, but export counts won't reconcile against raw Monitor counts.

---

## 8. Ops: RESET vs purge script asymmetry — MEDIUM

`referrals_purge_migrated.rb` clears post-import blockers before destroy (`purge_referral_blockers!`, `:212-239`): `BillingAttempt`, `LineItem`, `UnbilledLineItem`, `referral_discounts`, `InAppNotification`, `ChatMessage/Conversation`, `ComparativeInsightResult.previous_referral_id`, onsite-project rows. The import's `RESET=true` path (`referrals_import.rb:267-301`) clears none of these — `has_many :billing_attempts, dependent: :restrict_with_exception` (`referral.rb:279`) means **RESET raises** on any referral that accrued billing/chat rows after import; other tables fail on FK. The BULK-MIGRATION runbook's re-trial section doesn't say to fall back to the purge script. Orphans both paths intentionally leave: `Person` (reused on re-import) and `InvoicingContact` (permanent company-level residue).

Azure documents (HIGH, from §TL;DR #6): `related-data.md` §4 promises flatten/convert-to-PDF for `referral_documents`; no copy/convert step exists in export or import — migrated Azure docs are `candidate_documents` whose `file_path` is an MS-Graph document id that **cannot be downloaded**. S3 attachments are fine only while Assessment shares Monitor's bucket.

---

## 9. Spec/doc drift & stale artifacts

- `catalog_mapping.json`: test_items **472/472 mapped** (no SkipFile risk today); `units` **0/58 mapped** — blocks unit→component work. `catalog_mapping.placeholder_keys.txt` (271 keys) is **stale** — all now mapped; delete/regenerate.
- `specs/README.md:114-115` + `TESTING-REFERRALS.md` Case 2b-iii still say archived-but-unresulted "imports nothing"; actual behaviour is one completed shell referral (`shell_cycle`, correctly documented in BULK-MIGRATION.md).
- `referrals-field-mapping.md:52` (candidate_gender "copy sex value") vs code's `ASSIGNED_SEX_TO_GENDER` map (deliberate, better); `:53` position lookup "export side" vs actual import-side resolve; `related-data.md:120` outcome `actor_id` "migrated submitter where known" vs hardcoded nil; relationship notify flags/`is_primary`/`preferred_channel` promised in §3, not set.
- Parallel import / SKIP LOCKED / per-file timeout promised in README §Import driver — driver is sequential (disclosed in BULK-MIGRATION.md).
- Spec test coverage: `spec/script/migrate_monitor/` covers helpers, shell/skip paths, purge scoping — **not** cycle grouping (`build_cycles`/RA windowing), history routing, or the full happy path (manual suite in TESTING-REFERRALS.md carries those).
- All four backfill scripts (`backfill_notification_history`, `backfill_note_html`, `backfill_employee_type`, `cleanup_migrated_booking_nudges`) are folded into the current import/app — fresh imports don't need them; they remain for data imported before their fixes.

---

## 10. Verified non-issues (checked, no action)

- **Appointment wall-clock convention matches** the live app exactly (`Time.utc(2000,1,1,h,m)` + local date; import even converts UTC→clinic tz first, which live paths assume).
- **Rebook-after-scheduling (cf006dc6)** is safe: guard + modal key off the appointments association and `appointment_attended_at`, both set.
- `appointment_confirmed_at`: zero writers/readers in the app — not a real gap. `booking_reference` auto-generates under `save!(validate: false)`.
- Billing: import matches `billing-migration.md` exactly (terminal `billed`, no line items — spec says that's correct).
- `processing_mode: completed` is stable across re-derives (checked before signals; `billing_completed_at` set).
- `ama_selected`, clearance fields, candidate-onboarding timestamps, `results_delivered_at`, `is_retest`, `card_payment_status`, service prices (`kinnect_price`/`affiliate_price` — display-only for terminal billed rows), `form_responses`: nil/default is benign for migrated data.
- `AppointmentService` join carries no extra attributes. `duration`/`referral_id` don't exist on Assessment appointments (derived/via services — matches live schema).

---

## Suggested priority order (if/when fixing)

1. Stamp `appointment_intent_recorded_at`/`appointment_booked_at`/`appointment_booked_for` on linked services in `import_appointments!` (fixes double-booking, stages, key dates, KPIs in one change).
2. Preserve TIRR `additional_note` + `recommendations` (service note / referral_notes / doctor_* fields).
3. `next_test_service_item_id`/`variation_id` + honour `is_final_result`; decide monitoring-list behaviour for in-flight active cycles.
4. Tighten person matching (name/DOB corroboration, mirror `PersonMatchingService`) and stamp candidate_* from the bundle, not the merged Person.
5. Appointment status map: add `attended`, map `unconfirmed`→`confirmed`/`pending`; filter attendance enrichment to attended/completed statuses; skip fully-cancelled RAs from in-progress fan-out.
6. Azure `referral_documents` byte-copy/convert step (or mark them undownloadable explicitly).
7. Contact dedup: normalize phone before `find_or_create_by!`; add blockers-clearing to RESET (or point the runbook at the purge script).
8. Delta-export watermarks for Person/TIRR-attachments/NextTest, or document delta as unsupported for those changes.
9. `appointment_fulfilment_mode` from catalog; `SupplierAssignment` rows; `cached_billing_total_cents` backfill decision with product.
10. Doc hygiene: refresh stale specs, delete `placeholder_keys.txt`, fill `units` mapping when component services are wired.
