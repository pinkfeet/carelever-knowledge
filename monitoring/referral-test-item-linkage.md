# Monitor: Referral → Test Item Linkage

How a referral connects to the specific test items it covers. There are **two
parallel chains**: a *catalog* chain (what the worker is enrolled to do) and an
*execution* chain (what was actually performed and resulted).

See also [data-model.md](data-model.md) (item hierarchy + tenancy override) and
[referral-enrolled-item.md](referral-enrolled-item.md) (referral lifecycle / re-referral).

## Catalog chain — what's enrolled

```
Referral → EnrolledItem → MonitoringItem → TestItem
```

| Hop | Association | FK | Source |
|---|---|---|---|
| Referral → EnrolledItem | `has_many :enrolled_items, dependent: :destroy` | `enrolled_items.referral_id` | `app/models/referral.rb:83` |
| EnrolledItem → MonitoringItem | `belongs_to :monitoring_item` | `enrolled_items.monitoring_item_id` | `app/models/enrolled_item.rb:53` |
| EnrolledItem → TestItem (shortcut) | `has_many :test_items, through: :monitoring_item` | — | `app/models/enrolled_item.rb:57` |
| MonitoringItem → TestItem | `has_many :test_items` | `test_items.monitoring_item_id` | `app/models/monitoring_item.rb:30` |

One `EnrolledItem` per monitoring program the worker is enrolled in; each
`MonitoringItem` owns the set of `TestItem`s that program comprises.

## Execution chain — what was performed

```
Referral → Appointment → AppointmentItem ─(polymorphic)→ Evaluation → Result
                                              ↘ enrolled_item_id (back-link)
                              Evaluation ─→ TestItemDetail   (modern, canonical)
                              Evaluation ─→ TestItem         (legacy fallback only)
```

| Hop | Association | FK | Source |
|---|---|---|---|
| Referral → Appointment | `has_many :appointments, dependent: :destroy` | `appointments.referral_id` | `app/models/referral.rb:81` |
| Appointment → AppointmentItem | `has_many :appointment_items` | `appointment_items.appointment_id` | `app/models/appointment.rb:48` |
| AppointmentItem → Evaluation | `belongs_to :item, polymorphic: true` (class `Evaluation`) | `appointment_items.item_id` + `item_type='Evaluation'` | `app/models/appointment_item.rb:40-41` |
| AppointmentItem → EnrolledItem | (optional back-link) | `appointment_items.enrolled_item_id` | schema |
| **Evaluation → TestItemDetail** (modern) | `belongs_to :test_item_detail, class_name: 'TestItemDetail', foreign_key: :tenancy_test_item_detail_id` | `evaluations.tenancy_test_item_detail_id` | `app/models/evaluation.rb:34` |
| Evaluation → TestItem (legacy) | `belongs_to :test_item` | `evaluations.test_item_id` (zero UUID on modern rows) | `app/models/evaluation.rb:33` |
| Evaluation → Result | `has_one :result, dependent: :destroy` | `results.evaluation_id` | `app/models/evaluation.rb:38` |

`Evaluation` is the row that directly binds a referral to a specific test item at
execution time — it carries `referral_id` plus the test reference.
`AppointmentItem.item_type` is also `'Fee'` for non-test line items.

### ⚠️ `evaluations.test_item_id` is a dead FK on modern records

On modern records `test_item_id` is the zero UUID
`00000000-0000-0000-0000-000000000000` — hardcoded as `ApplicationRecord::DEFAULT_ID`
when the evaluation is created (`app/forms/v3/appointments/create_form.rb:56`). The
real test reference is **`tenancy_test_item_detail_id`** → `TestItemDetail`, with
`cascaded_test_item_detail_name` denormalized onto the row.

The `belongs_to :test_item` association (`evaluation.rb:33`) is **legacy only**, kept
for pre-2020 records. Migration path: `test_item_id` made nullable (2020) →
`tenancy_test_item_detail_id` FK added (2020) → cascade name/description columns
added (2021).

**Branch on `test_item_detail.present?`, not on `test_item_id`.** Read `test_item`
*only* as the fallback when `test_item_detail` is blank (legacy records); for modern
records ignore it entirely. Canonical example: `app/models/result.rb:55-58`
(`monitoring_item_name`).

## Tenancy override layer (Detail / Set)

Instance rows reference tenant-level templates via `tenancy_*_detail_id` FKs:

- `enrolled_items.tenancy_monitoring_item_detail_id` → `MonitoringItemDetail`
- `evaluations.tenancy_test_item_detail_id` → `TestItemDetail`

Company/site/position-specific overrides live in the `*_sets` tables. See
[data-model.md](data-model.md) §"Tenancy Override Pattern" — and note the warning
that the settings-UI "monitoring item" reads the `MonitoringItemDetail` cluster,
**not** the `monitoring_items` table.

## Key instance columns

- **enrolled_items**: `referral_id`, `monitoring_item_id`, `status`
  (on_hold / ongoing / stopped / completed / requested / not_commenced / under_way),
  `due_date`, `result_due_date`, `tenancy_monitoring_item_detail_id`,
  `suggested_tenancy_test_item_detail_id`, cascaded name/description.
- **evaluations**: `referral_id`, `test_item_id`, `tenancy_test_item_detail_id`,
  `tenancy_monitoring_item_detail_id`, `completed_at`, `cost`, `affiliate_cost`,
  `duration_in_minutes`, cascaded name/description.
- **appointment_items**: `appointment_id`, `referral_id`, `enrolled_item_id`,
  `item_id` + `item_type`, denormalized test_item_detail name/description.

## Results (migration target)

⚠️ **There are TWO result models** — same legacy-vs-modern split as `test_item`:

| | Legacy | Modern (canonical) |
|---|---|---|
| Model | `Result` | `TestItemReferralResult` (TIRR) |
| Table | `results` | `test_item_referral_results` |
| Anchored on | `evaluation_id` (per appointment) | `referral_id` + `tenancy_monitoring_item_detail_id` (per program, per cycle) |
| Test ref | via `evaluation.test_item` | `tenancy_test_item_detail_id` |
| Outcome | `outcome_id` → `Outcome` | `cascaded_outcome_detail_name` + `OutcomeDetail` cascade |

**Migrate `TestItemReferralResult` as the primary historical results table.** `Result`
is the older per-evaluation row; TIRR is the per-cycle history the client portal and
next-test logic read from (see [referral-enrolled-item.md](referral-enrolled-item.md)
§"How Results are Queried").

### TestItemReferralResult — key columns

`app/models/test_item_referral_result.rb`. Table `test_item_referral_results`:

- **Identity**: `referral_id`, `tenancy_monitoring_item_detail_id` (which program),
  `tenancy_test_item_detail_id` (which test).
- **Result payload**: `data` (jsonb — test-specific values), `test_item_specific_data`
  (jsonb), `config` (json — audio/spirometry), `screen_outcome`, `additional_note`,
  `recommendations` (string[]).
- **Outcome**: `cascaded_outcome_detail_name` (denormalized; resolve via `OutcomeDetail`
  cascade, `tenancy_outcome_detail_id`).
- **Lifecycle**: `result_date`, `completed_at`, `is_final_result` (true = end of cycle),
  `is_using_standard_next_test`, `from_screen`.
- **Links**: `result_id` (→ legacy `Result`, optional), `result_evaluation_id`
  (→ `ResultEvaluation`, optional), `attachment_ids` (uuid[]).
- `*_old`/`old_config` columns are legacy — skip.

### Multi-cycle (year-over-year)

A referral is long-lived, so the **same program repeats yearly** on the same
`(referral_id, tenancy_monitoring_item_detail_id, tenancy_test_item_detail_id)`.

- **Each cycle = a NEW TIRR row** — rows accumulate, never updated in place
  (`app/commands/test_item_referral_results/create.rb:17` always builds a fresh UUID row).
- **"Current" is not stored** — it's `COALESCE(result_date, created_at) DESC`, newest first.
  `is_last_record` is computed at query time (`index.rb:24-30`), and
  `UpdateRelatedEnrolledItem` reads the latest completed row via
  `completed_recent_result_in_monitoring_item` (`test_item_referral_results_helper.rb:6`,
  `.order(result_date: :desc).first`).
- **`is_final_result` ≠ end of a cycle** — it marks end of the whole enrolment (worker
  exits the program): `enrolled_item` → `completed`, due_date/next-test cleared
  (`reset_status.rb:57-58`, `update_related_enrolled_item.rb:28-34`).
- **One year's visit is grouped by `RequestedAssessment` → `RequestedTestItemAssessment`**,
  which links to the cycle's TIRR rows via `test_item_referral_result_id`
  (`requested_test_item_assessment.rb:26`).

**`result_date` lifecycle** (the field that orders cycles): nullable; set only when the
test is resulted — `appointment.scheduled_at` on appointment link
(`appointment_item_result.rb:45`), `result_appointment_date` on screen import
(`create_form.rb:93`), or a manual date (`update.rb:34`, `save_data.rb:15`). Holds the
**date the test was performed**, and is **cleared to NULL** if the appointment is unlinked
(`update_linking.rb:16`). Distinct from `completed_at` (evaluated/finished) and
`created_at` (row creation) — hence the `COALESCE` ordering.

**Migration:** split accumulating TIRR rows into separate Assessment referrals per cycle —
group by `RequestedAssessment` (or bucket by `result_date`). Newest cycle → the active
referral; older cycles → historical result records. Rows with `result_date = NULL` are
requested-but-unresulted and should not be treated as completed history.

## Building Assessment referrals from one monitoring item

Goal: for one monitoring item (`tenancy_monitoring_item_detail_id = X`), turn its
appointments + results into Assessment referrals.

**Granularity: one referral per cycle, NOT per enrolment.** Two cycles of the same item
→ two referrals. The cycle boundary is `RequestedAssessment` (one per request/visit for
that program); each `RequestedAssessment` → its `RequestedTestItemAssessment`s →
`test_item_referral_result_id` enumerates the TIRR rows + appointments of that cycle
(`requested_test_item_assessment.rb:26`). Fallback when a cycle has no
`RequestedAssessment`: bucket by `result_date` (+ the linked appointments).

### Scoping conditions

**(A) Results for the program** — completeness is `is_completed?`
(`test_item_referral_result.rb:132-134`), *not* `result_date`:

```sql
test_item_referral_results.tenancy_monitoring_item_detail_id = X
  AND (result_evaluation_id IS NOT NULL OR cascaded_outcome_detail_name IS NOT NULL)
```

**(B) Appointments for the program** — `evaluations` carries
`tenancy_monitoring_item_detail_id` directly (`schema.rb:773`); join appointment →
appointment_items (`item_type = 'Evaluation'`) → evaluations, keep only ones that
happened:

```sql
appointments.status IN (0, 6)   -- attended, completed (enum: appointment.rb:42)
  AND evaluations.tenancy_monitoring_item_detail_id = X
```

`appointments.status` enum: `attended(0) cancelled(1) confirmed(2) no_show(3)
rescheduled(4) unconfirmed(5) completed(6) late_cancelled(7)`.

**(C) Split A+B by cycle** (group by `RequestedAssessment`, else `result_date` bucket) →
emit one referral each.

### Cautions

- **Do not filter by `enrolled_items.status`** for a *history* migration. Status is the
  *current* enrolment state (`on_hold ongoing stopped completed requested not_commenced
  under_way incomplete_result_modal`, `enrolled_item.rb:77`); filtering to active statuses
  drops `completed`/`stopped` programs whose past cycles you still want. Drive the
  migration off TIRR rows + appointments, not enrolment status.
- **No soft-delete columns** on `referrals`, `appointments`, `appointment_items`,
  `evaluations`, `enrolled_items`, or `test_item_referral_results` — no
  `discarded_at`/`deleted_at` filtering needed. Only `appointments.status` encodes
  cancellation.

### Associations to carry across

| Hop | Association | Source |
|---|---|---|
| TIRR → Referral | `belongs_to :referral` | `test_item_referral_result.rb:71` |
| TIRR → TestItemDetail | `belongs_to :tenancy_test_item_detail, class_name: 'TestItemDetail'` | `:63-65` |
| TIRR → MonitoringItemDetail | `belongs_to :tenancy_monitoring_item_detail, class_name: 'MonitoringItemDetail'` | `:67-69` |
| TIRR → NextTest | `has_many :next_tests, dependent: :destroy` | `:46` |
| TIRR → Attachment | `has_many :attachments, as: :attached_to` | `:44` |
| TIRR → criteria | `has_many :criterions, through: :test_item_referral_result_criterions` | `:57-58` |
| TIRR → legacy Result | `belongs_to :result` | `:61` |
| TIRR → ResultEvaluation | `belongs_to :result_evaluation` | `:60` |

### Satellite tables to migrate alongside TIRR

- **next_tests** (`app/models/next_test.rb`): the scheduled follow-up tests derived from
  this result. Columns: `test_item_referral_result_id`, `tenancy_test_item_detail_id`,
  `date`, `classification` (additional / previous_result / evaluation), `offset_unit`,
  `offset_value`. **This is the source of `enrolled_item.due_date`.**
- **attachments** (`app/models/attachment.rb`): polymorphic via `attached_to_id/_type`;
  points to an `Upload` (`upload_id`) for the actual file (CarrierWave/S3). Classified by
  `ReferralAttachmentClassification`. TIRR also denormalizes `attachment_ids` (uuid[]).
- **test_item_referral_result_criterions** + **criterions**: the evaluation criteria that
  produced the outcome (carries `outcome`, `outcome_detail_id`, `recommendations[]`).
- **outcome_details** (`OutcomeDetail`): the cascaded outcome catalog (CSSP), self-ref via
  `tenancy_outcome_detail_id`. Resolve `cascaded_outcome_detail_name` against this.

### Next-test write-back flow (don't re-implement — migrate end state)

On TIRR `after_update_commit`, `TestItemReferralResults::UpdateRelatedEnrolledItem`
(`app/commands/test_item_referral_results/update_related_enrolled_item.rb`) pushes the
latest completed result back onto the enrolled item:

- earliest `upcoming_next_tests.date` → `enrolled_item.due_date` (`:37`)
- joined test descriptions → `next_cascaded_test_item_description` (`:38`)
- earliest next-test offset → `cascaded_frequency_type` / `cascaded_frequency_value` (`:39-40`)
- outcome name → `cascaded_outcome_detail_name` (`:20`); health risk → `cascaded_has_health_risk` (`:24`)
- if `is_final_result` → clears due_date / next test / frequency (`:28-34`)

For Assessment, the relevant fields map onto the referral (per
[referral-enrolled-item.md](referral-enrolled-item.md) §"Migration Implication"):
`due_date` → `referrals.next_test_date`, `tenancy_monitoring_item_detail_id` →
`referrals.next_test_service_item_id`, suggested test → `referrals.next_test_service_variation_id`.
Migrate the **computed end state**, not the trigger chain.

### Legacy Result — pre-TIRR history (Assessment migration)

**Cutover decision (dev tenant):** TIRR-only migration. Pre-TIRR `Result` rows without
TIRR are not exported (~14 pure pre-TIRR referrals on dev — invisible in Monitor UI).
See
[`TESTING-REFERRALS.md`](../../carelever_assessment/script/migrate-monitor/TESTING-REFERRALS.md)
and
[`legacy-results-migration.md`](../../carelever_assessment/script/migrate-monitor/specs/legacy-results-migration.md)
for bucket counts and inspector paste block.
