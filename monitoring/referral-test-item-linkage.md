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
