# Monitor: Referral & Enrolled Item Design

## Core Concept

A referral in Monitor is **permanent** — it is the long-lived record of a worker's monitoring enrolment, not a per-visit record. The same referral ID stays with the worker for their entire employment.

## Structure

```
referral (worker: John Smith, company: Acme Mining)
  ├── enrolled_item A — "Health Surveillance - Coal Mining"   due: 2026-06-01
  ├── enrolled_item B — "Drug & Alcohol"                      due: 2026-03-01
  └── enrolled_item C — "Audiometry"                          due: 2026-12-01
```

One `enrolled_item` per monitoring program the worker is enrolled in. Each tracks independently:

| Field | Purpose |
|---|---|
| `status` | on_hold / ongoing / stopped / completed / requested / not_commenced / under_way |
| `due_date` | when the next assessment is due for this program |
| `result_due_date` | when the result must be received by |
| `tenancy_monitoring_item_detail_id` | which monitoring program |
| `suggested_tenancy_test_item_detail_id` | which specific test to do next |
| `cascaded_outcome_detail_name` | last known outcome for this program |
| `cascaded_frequency_type / value` | how often this program recurs |
| `tag_id` | monitoring tag (drives frequency/outcome routing) |

## Re-Referral

Re-referring does **not** create a new referral. It creates a `RequestedAssessment` on the **same referral and enrolled_item**:

```
enrolled_item.due_date approaches
  → user clicks "Request Assessment" on that enrolled_item
  → RequestedAssessment created (same referral_id, same enrolled_item_id)
  → RequestedTestItemAssessment records created (one per test item, tracks SLAs)
  → appointment booked → tests done
  → TestItemReferralResult saved per test item
  → enrolled_item.due_date updated to next cycle date
  → repeat indefinitely
```

`RequestedAssessment` holds:
- `referral_id` — same referral throughout
- `enrolled_item_id` — same enrolled item
- `test_item_details` — which specific tests are being requested this cycle

## How Next Test Date / Suggested Test Item is Set

When a `TestItemReferralResult` is saved with `next_tests`:

1. `next_tests` are grouped by date — earliest date becomes `enrolled_item.due_date`
2. `enrolled_item.next_cascaded_test_item_description` is set from the tests due on that date
3. `enrolled_item.suggested_tenancy_test_item_detail_id` is set from `Result.suggested_test_item_detail_id` — derived from outcome evaluation against `test_item_frequency_details`
4. `enrolled_item.cascaded_outcome_detail_name` is updated to the latest outcome name

Each enrolled item's `due_date` is updated **independently** — Drug & Alcohol can be due in 3 months while Audiometry is due in 12 months.

## How Results are Queried per Enrolled Item

`GET /v1/monitor/test_item_referral_results?enrolled_item_id=<id>`

```
enrolled_item_id
  → enrolled_item.referral_id + enrolled_item.tenancy_monitoring_item_detail_id
  → TestItemReferralResult.where(referral_id:, tenancy_monitoring_item_detail_id:)
  → ordered by result_date DESC (newest first)
  → first record flagged as is_last_record: true
```

Returns all historical test results for that monitoring program on that referral.

## Monitoring List (Client Portal)

The client monitoring list queries `referrals` directly — no enrolled_items involved. It shows referrals where:
- `processing_mode: completed`
- `next_test_date` is not null
- `cancelled_at` is null
- deduplicated by candidate (latest referral per person)

Urgency bands:
- **Overdue** — `next_test_date < today`
- **Due in 30 days** — `next_test_date <= today + 30`
- **Due in 90 days** — `next_test_date <= today + 90`
- **Compliant** — `next_test_date > today + 90`

Note: In Monitor, `next_test_date` on the referral is not the primary tracking field — `enrolled_item.due_date` per program is. The Replit monitoring list is a simplified view.

## Key Design Difference vs Assessment

| | Monitor | Assessment |
|---|---|---|
| Referral lifecycle | Permanent per worker | One per visit |
| Enrolled items | Multiple per referral (one per program) | No equivalent |
| Re-refer | `RequestedAssessment` on same referral | New referral created |
| Next test tracking | Per `enrolled_item.due_date` independently | Single `referrals.next_test_date` |
| Multiple programs | Each tracked separately with own due date | Collapsed into one date |
| Result history | `TestItemReferralResult` per test per cycle | Doctor outcome on referral |

## Migration Implication

Monitor's single long-lived referral maps to **multiple short-lived referrals** in Assessment (one per assessment cycle per monitoring program). When migrating:

- `enrolled_item.due_date` → `referrals.next_test_date` (one referral per enrolled item per cycle)
- `enrolled_item.tenancy_monitoring_item_detail_id` → `referrals.next_test_service_item_id`
- `enrolled_item.suggested_tenancy_test_item_detail_id` → `referrals.next_test_service_variation_id`
- Historical `TestItemReferralResults` → need new table in assessment (no equivalent)

See [migration-plan.md](migration-plan.md) §3 (Enrolled Items) and §8 (Tables Requiring New Design) for full decisions.
