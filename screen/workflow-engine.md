# Screen Workflow Engine

## Overview

Screen uses a configurable graph-based workflow engine to track referral progress, rather than hardcoded status fields. The workflow is defined per-tenant via admin settings.

## Architecture

```
Activity (node) ──Edge (transition)──> Activity (node)
                   │
                   └── criteria (conditions to follow this edge)
```

Three models work together:

### Activity (workflow step)

Each activity is a node in the workflow graph.

- `master_stage` — high-level grouping (pre_booking, booking, results, complete, etc.)
- `performance_stage` — granular step within the workflow
- `classification` — type of activity (get_availability, schedule_bookings, add_result, sign_off, etc.)
- `data` — JSON defining the UI elements for this step
- `sort_order` — display ordering

### Edge (transition)

Connects two activities with conditional criteria.

- `from_activity_id` → `to_activity_id`
- `criteria` — JSON conditions evaluated to decide if this edge should be followed
- `evaluation_order` — priority when multiple edges exist

Edge criteria can match on:
- Screening item
- Company tier
- Company / Site / Position
- Switch value (boolean)
- Purchase order / prepaid order number
- Pre-approval tag
- Notification mode
- Availability provided
- Has applicant/employer forms
- Is prepaid referral

### WorkflowTrigger (automation)

Automation rules attached to activities that fire when a referral activity changes.

- `activity_id` — the activity this trigger belongs to
- `column` — what field change to watch (e.g. `status`)
- `value` — what value triggers execution
- `target` — polymorphic reference to the action to execute
- `screening_item_ids` — optional filter by screening items
- `company_id`, `site_id`, `position_id` — optional scope filters

## Referral Status

The referral itself has a simple status:

```ruby
enum status: %i[active cancelled]
```

The real workflow state is tracked via denormalised fields from the latest `ReferralActivity`:

- `latest_activity_master_stage`
- `latest_activity_performance_stage`
- `latest_activity_name`
- `latest_activity_sort_order`
- `latest_activity_type`
- `latest_activity_created_at`
- `performance_stage_duration_in_minutes`

## Master Stages

High-level workflow position:

| Stage | Meaning |
|---|---|
| `pre_booking` | Referral created, not yet booking |
| `booking` | Booking in progress |
| `awaiting_appointment` | Appointment booked, waiting for date |
| `results` | Appointment attended, awaiting/processing results |
| `on_hold` | On hold (internal) |
| `on_hold_employer` | On hold by employer |
| `medical_clearance` | Awaiting medical clearance |
| `further_review` | Needs further review |
| `dr_sign_off` | Awaiting doctor sign-off |
| `awaiting_availability` | Awaiting candidate availability |
| `closed` | Closed (not completed) |
| `complete` | Fully completed |

Constants:
- `FINAL_MASTER_STAGES = %w[complete closed]`
- `INACTIVE_MASTER_STAGES = %w[closed awaiting_availability on_hold on_hold_employer complete]`

## Performance Stages

Granular step within the workflow:

| Stage | Value |
|---|---|
| `awaiting_availability` | 0 |
| `pre_booking` | 1 |
| `schedule_booking` | 2 |
| `reschedule_booking` | 3 |
| `awaiting_appointment` | 4 |
| `medical_clearance` | 5 |
| `further_review` | 6 |
| `awaiting_applicant` | 7 |
| `awaiting_employer` | 8 |
| `get_results` | 9 |
| `awaiting_diagnostics` | 10 |
| `process_results` | 11 |
| `doctor_signoff` | 12 |
| `send_results` | 13 |
| `completed` | 14 |
| `cancelled` | 15 |
| `received` | 16 |

## Execution Flow

1. Referral is created → first `ReferralActivity` created, linked to the initial `Activity`
2. `after_create` callback denormalises the stage onto the referral (`latest_activity_master_stage`, etc.)
3. When the activity is completed → `WorkflowTrigger` fires → evaluates `Edge` criteria → `Referrals::TriggerAutomation` creates the next `ReferralActivity`
4. Cascades through the graph until a final stage (`complete` or `closed`)

### ReferralActivity

Each step creates a `ReferralActivity` record:

- `referral_id` — the referral
- `activity_id` — which workflow step
- `status` — `current` (0) or `completed` (1)
- `data` — JSON form data captured at this step
- `previous_referral_activity_id` — linked list of steps
- `completed_at`, `completed_by_id` — when/who completed
- `duration` — time spent on this step
- `activity_outcome` — outcome of this step
- `lock_version` — optimistic locking

## Other Trigger Types

Beyond workflow triggers, screen has specialised trigger types:

- `ApplicantSelfBookingTriggers` — candidate self-booking automation
- `ActionButtonTriggers` — UI button actions
- `FormGenerationTriggers` — auto-generate forms
- `FormSubmissionTriggers` — react to form submissions
- `SendFormLinksTriggers` — send form links to candidates
- `DoctorAssignedTriggers` — react to doctor assignment
- `FirstAppointmentTriggers` — first appointment events
- `ConfirmedAppointmentDurationTriggers` — appointment confirmation timing
- `ReferralComplianceGenerationTriggers` — compliance document generation
- `ReferralComplianceEvaluationTriggers` — compliance evaluation
- `WorkflowDurationTriggers` — time-based triggers (SLA/escalation)

## Comparison with Assessment

| | Screen | Assessment |
|---|---|---|
| Workflow | Configurable graph (Activities + Edges + Triggers) | Timestamp-based columns (`appointment_booked_at`, `results_received_at`, etc.) |
| Stage tracking | Denormalised from latest `ReferralActivity` | Derived from which timestamps are set |
| Transitions | Edge criteria + trigger evaluation | Code-driven in `status_transitions.rb` |
| Configurability | Per-tenant via admin settings UI | Hardcoded in application logic |
| Trigger system | Multiple specialised trigger types | Exception signals + automation rules |

Screen's approach is more flexible (can configure different workflows per company/screening item) but more complex. Assessment replaced this with a simpler, explicit timestamp model.
