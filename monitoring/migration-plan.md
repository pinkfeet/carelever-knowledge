# Monitor → Assessment Migration Plan

Full field-level mapping is in `carelever_assessment/docs/monitor_to_assessment_migration_mapping.xlsx`.

## Status Key

| Symbol | Meaning                                            |
| ------ | -------------------------------------------------- |
| ✅     | Direct map — rename or copy                        |
| ⚠️     | Partial match — data transform or loss of fidelity |
| ❌     | No equivalent — new design or exclude              |
| 🆕     | New field required in assessment                   |

---

## 1. Core Catalog

### monitoring_item_details → service_items (`is_health_monitoring: true`)

| Monitor Field                        | Assessment Field                        | Status | Decision / Notes                                     |
| ------------------------------------ | --------------------------------------- | ------ | ---------------------------------------------------- |
| `name`                               | `name`                                  | ✅     |                                                      |
| `description`                        | `description`                           | ✅     |                                                      |
| `company_id / site_id / position_id` | `assessment_matrix_configs`             | ⚠️     | Tenancy scoping moves to `assessment_matrix_configs` |
| `seg_id`                             | —                                       | ❌     | SEG not modelled in assessment — decision needed     |
| `tenancy_monitoring_item_detail_id`  | `parent_id` (self-ref on service_items) | ⚠️     | Assessment uses flat hierarchy via `parent_id`       |
| `is_default`                         | `service_defaults.service_item_ids`     | ⚠️     |                                                      |
| `is_hidden`                          | —                                       | ❌     | No hidden concept in assessment catalog              |
| `default_tag_id`                     | `tag_id` (integer, legacy)              | ⚠️     | Tag system differs — decision needed                 |
| `default_outcome_id`                 | `default_outcome_option_id`             | ⚠️     | Maps after outcome_details are migrated              |
| `monitoring_item_id` (parent)        | `parent_id`                             | ⚠️     |                                                      |
| —                                    | `code` (unique)                         | 🆕     | Generate from name slug                              |
| —                                    | `is_health_monitoring: true`            | 🆕     | Set on all migrated records                          |
| —                                    | `monitor_uuid`                          | 🆕     | Store original monitor ID for traceability           |

### test_item_details → service_variations (`monitor_enabled: true`)

| Monitor Field                        | Assessment Field                 | Status | Decision / Notes                                    |
| ------------------------------------ | -------------------------------- | ------ | --------------------------------------------------- |
| `name`                               | `name`                           | ✅     |                                                     |
| `description`                        | `description`                    | ✅     |                                                     |
| `duration_in_minutes`                | `duration_minutes`               | ✅     | Rename                                              |
| `item_code`                          | `code` (unique)                  | ⚠️     | Ensure uniqueness across all variations             |
| `slug`                               | —                                | ❌     | Discard — not used in assessment                    |
| `category`                           | —                                | ⚠️     | Consider `item_type` on parent service_item         |
| `outcome_processor`                  | —                                | ❌     | Internal tag — decision needed                      |
| `internal_price`                     | `service_prices.kinnect_price`   | ⚠️     | Via service_prices join                             |
| `external_price`                     | `service_prices.affiliate_price` | ⚠️     | Via service_prices join                             |
| `external_cutoff_cost`               | —                                | ❌     | Not modelled in assessment                          |
| `has_summary_report`                 | —                                | ❌     | Not modelled in assessment                          |
| `is_for_forms`                       | —                                | ⚠️     | Derived from `form_template_service_links` presence |
| `is_result_required`                 | —                                | ❌     | Not modelled in assessment                          |
| `company_id / site_id / position_id` | `assessment_matrix_configs`      | ⚠️     | Same tenancy pattern as monitoring items            |
| `monitoring_item_id`                 | `service_item_id`                | ✅     | Parent service_item after migration                 |
| `default_outcome_id`                 | `default_outcome_option_id`      | ⚠️     | After outcomes migrated                             |
| —                                    | `monitor_enabled: true`          | 🆕     | Set on all migrated records                         |
| —                                    | `monitor_uuid`                   | 🆕     | Store original monitor ID                           |

### test_item_unit_details → component_variants

| Monitor Field                                 | Assessment Field  | Status | Decision / Notes                                     |
| --------------------------------------------- | ----------------- | ------ | ---------------------------------------------------- |
| `name`                                        | `name`            | ✅     |                                                      |
| `duration_in_minutes`                         | —                 | ❌     | component_variants has no duration — decision needed |
| `company_id / site_id / position_id / seg_id` | —                 | ❌     | component_variants are global in assessment          |
| `category / form_tag / item_code`             | —                 | ❌     | Not in component_variants                            |
| —                                             | `code`            | 🆕     | Generate from name slug                              |
| —                                             | `service_item_id` | 🆕     | Link to parent service_item                          |

---

## 2. Tenancy Scoping (Detail/Set Pattern → assessment_matrix_configs)

Monitor uses a two-tier override pattern (`_details` = tenancy base, `_sets` = company/site/pos override). Assessment collapses this into `assessment_matrix_configs`.

| Monitor Tables                                                           | Assessment Target                           | Status | Notes                                     |
| ------------------------------------------------------------------------ | ------------------------------------------- | ------ | ----------------------------------------- |
| `monitoring_item_sets` (company/site/pos/seg per monitoring_item_detail) | `assessment_matrix_configs`                 | ⚠️     | `seg_id` lost — decision needed           |
| `test_item_sets` (company/site/pos per test_item_detail)                 | `assessment_matrix_configs.variant_id`      | ⚠️     | Maps variation to matrix config           |
| `monitoring_item_set_test_item_details`                                  | `assessment_matrix_configs` (repeated rows) | ⚠️     | One row per service_item+company+site+pos |
| `monitoring_item_preferences.is_default`                                 | `service_defaults.service_item_ids`         | ⚠️     |                                           |
| `monitoring_item_preferences.is_hidden`                                  | —                                           | ❌     | No hidden concept                         |

**Open Decision:** SEG (`similar_exposure_groups`) is used extensively in monitor scoping. Assessment has no equivalent. Options:

1. Drop SEG — lose per-SEG overrides, use position-level only
2. Add SEG to assessment — new table + FK on relevant tables

---

## 3. Enrolled Items (No Assessment Equivalent)

`enrolled_items` is the central enrolment record linking a worker (referral) to a monitoring program with ongoing status tracking. **Assessment has no equivalent.**

**Options (decision required):**

| Option | Description                                             | Effort                               |
| ------ | ------------------------------------------------------- | ------------------------------------ |
| A      | New `enrolled_items` table in assessment                | High                                 |
| B      | Extend `referrals` with enrolment fields                | Medium — loses multi-program support |
| C      | Use `referrals.next_test_date` + `next_test_rules` only | Low — loses full enrolment history   |

Fields that need a home regardless of option chosen:

| Monitor Field                     | Notes                                                        |
| --------------------------------- | ------------------------------------------------------------ |
| `status`                          | pending / overdue / complete etc.                            |
| `due_date`                        | Maps to `referrals.next_test_date` in option C               |
| `result_due_date`                 | No equivalent — new field needed                             |
| `cascaded_frequency_type / value` | Derived from `test_item_frequency_details` at enrolment time |
| `cascaded_has_health_risk`        | Health risk flag — no equivalent in assessment               |
| `cascaded_outcome_detail_name`    | Last known outcome — no equivalent                           |
| `tag_id`                          | Monitor tags — no equivalent in assessment                   |

---

## 4. Outcomes

### outcome_details → service_outcome_options

| Monitor Field                                 | Assessment Field                       | Status | Notes                                                                                            |
| --------------------------------------------- | -------------------------------------- | ------ | ------------------------------------------------------------------------------------------------ |
| `name`                                        | `name`                                 | ✅     |                                                                                                  |
| `has_health_risk`                             | —                                      | ❌     | Not in assessment — may need to add                                                              |
| `company_id / site_id / position_id / seg_id` | —                                      | ❌     | `service_outcome_options` are **global** in assessment — tenant-scoped outcome variants are lost |
| `tenancy_outcome_detail_id`                   | —                                      | ❌     | Global model in assessment                                                                       |
| `slug` (outcomes)                             | —                                      | ❌     | Discard                                                                                          |
| `duration_in_days` (outcomes)                 | `next_test_rules.next_test_value/unit` | ⚠️     | Frequency moves to next_test_rules                                                               |
| `tag_id` (outcomes)                           | —                                      | ❌     | Tags not in assessment                                                                           |
| —                                             | `color`                                | 🆕     | Assign per outcome type                                                                          |
| —                                             | `active`                               | 🆕     | Default true                                                                                     |

**Key Loss:** Monitor supports per-company outcome variants (different outcome names or health_risk values per company). Assessment outcomes are global — all companies share the same outcome options.

---

## 5. Frequency / Next Test Rules

### test_item_frequency_details → next_test_rules

| Monitor Field                                 | Assessment Field            | Status | Notes                                                                      |
| --------------------------------------------- | --------------------------- | ------ | -------------------------------------------------------------------------- |
| `frequency_value`                             | `next_test_value`           | ✅     | Rename                                                                     |
| `frequency_type`                              | `next_test_unit`            | ✅     | Rename + normalise values                                                  |
| `tenancy_test_item_detail_id`                 | `service_variation_id`      | ⚠️     | After variations migrated                                                  |
| `tenancy_monitoring_item_detail_id`           | `service_item_id`           | ⚠️     | After service_items migrated                                               |
| `tenancy_outcome_detail_id`                   | `service_outcome_option_id` | ⚠️     | After outcomes migrated — **required FK**                                  |
| `company_id / site_id / position_id / seg_id` | —                           | ❌     | `next_test_rules` are **global** — per-tenant frequency overrides are lost |
| —                                             | `gender`                    | 🆕     | Default `'any'`                                                            |
| —                                             | `min_age / max_age`         | 🆕     | Default 0–99                                                               |

---

## 6. Referrals

Large overlap but assessment referral is significantly richer (billing, AI clearance, doctor review, further info, onboarding). Only monitoring-relevant fields:

| Monitor Field                       | Assessment Field                 | Status | Notes                                                     |
| ----------------------------------- | -------------------------------- | ------ | --------------------------------------------------------- |
| `person_id`                         | `person_id`                      | ✅     |                                                           |
| `reference_id`                      | `reference_number`               | ✅     | Rename                                                    |
| `purchase_order_number`             | `purchase_order_number`          | ✅     |                                                           |
| `cost_centre`                       | `cost_centre`                    | ✅     |                                                           |
| `comments`                          | `notes`                          | ✅     | Rename                                                    |
| `notification_mode`                 | `preferred_notification_channel` | ⚠️     | Normalise values                                          |
| `employment_status`                 | `employee_type`                  | ⚠️     | Normalise values                                          |
| `custom_data` (jsonb)               | `custom_field_values` (jsonb)    | ⚠️     | Key mapping required                                      |
| `doctor_id`                         | `assigned_doctor_id`             | ⚠️     | After doctors migrated                                    |
| `ch_id`                             | —                                | ❌     | Legacy import ID — discard (see below)                    |
| `referral_type`                     | —                                | ❌     | Not in assessment — decision needed                       |
| `is_preferred`                      | —                                | ❌     | Not in assessment                                         |
| `assigned_to_id / assigned_to_name` | —                                | ❌     | Not in assessment                                         |
| `availability_*`                    | —                                | ❌     | Candidate availability model differs                      |
| —                                   | `company_id`                     | 🆕     | **Required** — referrals are company-scoped in assessment |
| —                                   | `site_id`                        | 🆕     | Set from person's site                                    |
| —                                   | `next_test_date`                 | 🆕     | Populate from `enrolled_items.due_date`                   |

---

## 7. People & Org

| Monitor                                                             | Assessment                       | Status | Notes                                                |
| ------------------------------------------------------------------- | -------------------------------- | ------ | ---------------------------------------------------- |
| `people.birthdate`                                                  | `people.date_of_birth`           | ✅     | Rename                                               |
| `people.sex`                                                        | `people.gender`                  | ⚠️     | Normalise values                                     |
| `people.email`                                                      | `people.normalized_email`        | ⚠️     | Normalise on write                                   |
| `people.mobile`                                                     | `people.phone`                   | ⚠️     | Prefer mobile; discard landline                      |
| `people.salutation / country_id / suburb_id / division_id / seg_id` | —                                | ❌     | Not in assessment people                             |
| `companies.name / tier`                                             | `companies.name / tier`          | ✅     | Review tier value alignment                          |
| `companies.billing_preference`                                      | —                                | ❌     | Different billing model                              |
| `companies.discarded_at`                                            | `companies.active`               | ⚠️     | Soft delete → active flag                            |
| `sites.purchase_order_number`                                       | `sites.default_purchase_order`   | ✅     | Rename                                               |
| `positions.title`                                                   | `positions.name`                 | ✅     | Rename                                               |
| —                                                                   | `positions.code`                 | 🆕     | Generate from title slug                             |
| —                                                                   | `positions.monitor_active: true` | 🆕     | Set on all migrated positions                        |
| `organisations`                                                     | `parent_accounts`                | ⚠️     | Top-level tenant — map fields                        |
| `divisions`                                                         | —                                | ❌     | No equivalent — decision needed                      |
| `similar_exposure_groups`                                           | —                                | ❌     | No equivalent — major gap if SEG scoping is required |

---

## 8. Tables Requiring New Design in Assessment

These monitor tables have no assessment equivalent and represent significant scope:

| Table(s)                                                      | Domain                            | Effort | Recommendation                                              |
| ------------------------------------------------------------- | --------------------------------- | ------ | ----------------------------------------------------------- |
| `enrolled_items` + related                                    | Ongoing worker enrolment          | High   | New table — see §3 above                                    |
| `evaluations`                                                 | Per-test-item result record       | High   | New table or extend appointment_services                    |
| `results` + `sub_results`                                     | Result outcome tree               | High   | New design — `outcome_events` only covers top-level         |
| `test_item_referral_results`                                  | Raw result data per test          | High   | New table with form integration                             |
| `criteria` / `result_evaluations` / `test_item_criteria_sets` | Automated result scoring          | High   | New design — partially covered by `outcome_approval_rules`  |
| `tags`                                                        | Monitoring frequency/outcome tags | High   | New table — drives enrolled item frequency                  |
| `similar_exposure_groups`                                     | SEG scoping                       | High   | New table if SEG scoping required                           |
| `next_tests`                                                  | Scheduled next test per result    | High   | Extend `referrals.next_test_date` or new table              |
| `locations`                                                   | Clinic locations with geo data    | High   | Map to suppliers or new table                               |
| `tasks`                                                       | Task management per referral      | Medium | New table                                                   |
| `sales_orders` / `line_items` / billing pipeline              | NetSuite billing                  | High   | Separate billing migration — out of scope for v1            |
| Trigger tables (~15 tables)                                   | Automation engine                 | High   | Map to `automation_rules` — requires rule-by-rule migration |

---

## 9. Open Decisions

| #   | Decision                                                                                                           | Options                                                                                        | Impact                                      |
| --- | ------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- | ------------------------------------------- |
| D1  | **Enrolled items** — new table or extend referrals?                                                                | A) New table, B) Extend referrals, C) Simplified (next_test_date only)                         | Core to monitoring functionality            |
| D2  | **SEG (Similar Exposure Groups)** — support in assessment?                                                         | Add new table + FK, or drop and use position-level only                                        | Affects scoping fidelity                    |
| D3  | **Tags** — migrate monitor tag system?                                                                             | New table mirroring monitor tags, or replace with outcome-driven next_test_rules               | Drives monitoring frequency                 |
| D4  | **Tenant-scoped outcomes** — global or per-company?                                                                | Keep assessment global model (data loss), or add company scope to service_outcome_options      | Affects companies with custom outcome names |
| D5  | **Tenant-scoped next_test_rules** — global or per-company?                                                         | Keep assessment global model, or add company/site/pos scope                                    | Affects companies with custom frequencies   |
| D6  | **ch_id** — discard or preserve?                                                                                   | Discard (default), or store in a `legacy_id` / `monitor_uuid` field                            | Low impact — traceability only              |
| D7  | **Billing pipeline** — in scope for v1?                                                                            | Migrate monitor billing tables, or defer                                                       | High effort — recommend defer               |
| D8  | **Trigger/automation system** — full port or rebuild?                                                              | Map each monitor trigger type to `automation_rules`, or rebuild from scratch                   | High effort — recommend incremental         |
| D9  | **Specific test records** (audiometry, spirometry, DAS etc.) — keep dedicated tables or migrate to form responses? | Keep structured tables (easier querying), or fold into `form_field_responses` (simpler schema) | Affects result querying                     |

---

## 10. Suggested Migration Order

1. **Org structure** — organisations → parent_accounts, companies, sites, positions, people
2. **Service catalog** — monitoring_item_details → service_items, test_item_details → service_variations, test_item_unit_details → component_variants
3. **Outcomes** — outcome_details → service_outcome_options
4. **Frequencies** — test_item_frequency_details → next_test_rules
5. **Tenancy scoping** — monitoring_item_sets + test_item_sets → assessment_matrix_configs
6. **Pricing** — test_item_pricing_details → company_service_prices / service_prices
7. **Referrals + people** — referrals, contacts
8. **Enrolled items** — depends on D1 decision
9. **Results** — depends on new design decisions
10. **Automations / triggers** — last, after core data is stable

---

## Appendix A: ch_id

Legacy integer ID from the original CH (Carelever Health) system, used when data was imported into Monitor via CSV (`company_referral_importer.rb`). Most records have `ch_id: 0` (not imported from CH). Safe to discard for assessment migration — store in `monitor_uuid` / notes if traceability is needed.

---

## Appendix B: Referral & Enrolled Item Lifecycle

See full detail in [referral-enrolled-item.md](referral-enrolled-item.md). Key points for migration:

### A referral in Monitor is permanent (not per-visit)

One referral per worker, persisting for the duration of their employment. Multiple `enrolled_items` hang off it — one per monitoring program.

### Re-refer = RequestedAssessment on the same referral

No new referral is created. `V3::EnrolledItems::RequestedAssessments::Create` creates a `RequestedAssessment` record against the existing `referral_id` and `enrolled_item_id`. The workflow re-enters via `HealthAssessmentTriggers::Execute`.

### Initial referral also creates referral_activity rows

`CreateReferral` calls `ReferralCreationTriggers::Execute` after save. This fires configured `ReferralCreationTrigger` records for the tenant → `Referrals::TriggerAutomation` → `ReferralActivities::Create`. So both initial creation and re-refer go through the same trigger/activity system — the difference is which trigger type fires.

### Dashboard pre-bookings count

The dashboard (`V3::Dashboards::Counters`) counts in-progress `referral_activity` rows grouped by `performance_stage`:

```ruby
ReferralActivity
  .joins(:activity)
  .where(completed_at: nil, referrals: { referral_type: ONGOING_REFERRAL_TYPES })
  .group(:performance_stage).count
```

**Pre-Bookings (stage 16)** is one bucket — referrals sit here when a `RequestedAssessment` has been created but no appointment booked yet. The same referral re-enters this count each new assessment cycle via the trigger system.

The `performance_stage` is a property of the `Activity` DB record (workflow node config), not computed at runtime. Which node a referral lands in on creation/re-refer depends on what `ReferralCreationTrigger` / `HealthAssessmentTrigger` records are configured for that tenant.

### Migration implication

Monitor's single long-lived referral maps to **multiple short-lived referrals** in Assessment — one per assessment cycle per monitoring program. Assessment referrals naturally re-enter the pipeline as new records; no re-entry trigger logic needed.

| Monitor                                 | Assessment equivalent                            |
| --------------------------------------- | ------------------------------------------------ |
| 1 permanent referral + N enrolled_items | N referrals (one per program per cycle)          |
| RequestedAssessment on same referral    | New referral created                             |
| ReferralActivity workflow nodes         | Assessment referral status / processing_mode     |
| Pre-Bookings stage                      | `referrals.status = pending` (pre-booking state) |

---

## Appendix C: Migration Execution

> **Referral bulk runbook:** Per-referral JSON export/import (~50k files), sharding, resume, and cutover — see [monitor-referrals-bulk-migration.md](../migration/monitor-referrals-bulk-migration.md). The DB-to-DB approach below suits **catalog/settings** migration; referrals use the script pipeline in `carelever_assessment/script/migrate-monitor/`.

### Approach

Both Monitor and Assessment run on ECS with separate RDS databases accessible only within the VPC. No S3 needed — connect directly DB-to-DB from inside the VPC.

Add Monitor DB as a secondary connection in the Assessment Rails app:

```ruby
# config/database.yml
monitor:
  adapter: postgresql
  url: <%= ENV['MONITOR_DATABASE_URL'] %>
```

```ruby
# lib/tasks/migrate_from_monitor.rake
namespace :migrate_monitor do
  task service_items: :environment do
    MonitorRecord.establish_connection(:monitor)
    MonitoringItemDetail.find_each do |mid|
      ServiceItem.upsert(
        { monitor_uuid: mid.id, name: mid.name, ... },
        unique_by: :monitor_uuid
      )
    end
  end
end
```

Run via ECS Exec session into the running assessment container — no new task definition needed:

```bash
aws ecs execute-command \
  --cluster assessment-cluster \
  --task <task-id> \
  --container app \
  --interactive \
  --command "/bin/sh"

# inside container:
bundle exec rake migrate_monitor:service_items
```

### DB Password

**Recommended:** Add `MONITOR_DATABASE_URL` (full connection string with password) to Secrets Manager alongside the existing assessment DB secret. Wire it into the assessment task definition as an env var — available in the container with no shell history exposure. Remove after migration completes.

**Alternative:** Fetch inline during the session via `aws secretsmanager get-secret-value` — avoids hardcoding but still transient in session logs.

### Key migration properties

- **Idempotent** — use `upsert` with `unique_by: :monitor_uuid` so tasks can be re-run safely
- **Ordered** — follow the migration order in §10 (org → catalog → outcomes → referrals → enrolled items)
- **monitor_uuid** — always set `monitor_uuid` on migrated records to the original Monitor ID (e.g. `tenancy_monitoring_item_detail_id`), so Monitor can look up assessment records by its known IDs without a mapping table

--If by directly you mean typing the password or URL in the ECS console/command, there is always some leak risk from command history, session logging, process inspection, or accidental app logging.

Best-practice answer

Use Secrets Manager or SSM Parameter Store and inject at runtime.
That is the only approach that meaningfully reduces log exposure in ECS operations.
If you must do direct entry once (emergency only)

Open ECS exec shell.
Disable shell history in that session: unset HISTFILE.
Prompt silently instead of typing inline:
read -s MONITOR_DATABASE_URL
export MONITOR_DATABASE_URL
Run migration.
Immediately clear variable:
unset MONITOR_DATABASE_URL
Important caveats

This reduces accidental shell-history leaks, but does not eliminate all exposure paths.
If ECS Exec logging is enabled to CloudWatch/S3, session activity may still be captured.
App-level debug logging can still leak config if code prints env/config.
