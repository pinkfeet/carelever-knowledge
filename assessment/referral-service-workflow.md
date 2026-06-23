# Assessment — Referral, Service, Appointment & Results

## Overview

The core screening workflow in `carelever_assessment` is built around four concepts:

| Code term | Business term | Role |
|---|---|---|
| `Referral` | Request | One candidate screening case (e.g. pre-employment medical) |
| `Service` | Assessment | One test or component on that referral (Drug Screen, Audiometry, etc.) |
| `ServiceItem` | Assessment Component | Catalog definition for what can be ordered |
| `Appointment` | Booking slot | A calendar event at a clinic — can cover one or many services |

**Results** are not a standalone model. They are a workflow phase tracked via timestamps on `Service`, assessor `FormSession`s, and uploaded `CandidateDocument`s.

Repo: [`carelever_assessment`](../../carelever_assessment/)

---

## Entity relationships

```
Referral
  ├── has_many :services
  ├── has_many :appointment_services, through: :services
  ├── has_many :appointments, through: :appointment_services
  └── doctor_outcome / referral_completed_at  (rollup fitness-for-work)

Service
  ├── belongs_to :referral
  ├── belongs_to :service_item (catalog)
  ├── belongs_to :service_variation (optional)
  ├── has_many :supplier_assignments → Supplier (clinic)
  ├── has_many :appointment_services → Appointment
  ├── has_many :form_sessions
  └── canonical timestamps (booked → attended → results → doctor sign-off → completed)

Appointment
  ├── has_many :appointment_services
  ├── has_many :services, through: :appointment_services
  ├── belongs_to :supplier, :practitioner, :shift
  └── status enum (pending, confirmed, attended, cancelled, no_show, …)
```

### Appointment ↔ Service is many-to-many

Historically an appointment belonged to a single service. Assessment uses a join table:

| Table | Purpose |
|---|---|
| `appointment_services` | Links one appointment to one or more services |

This supports:

- **Multi-service visits** — smart scheduling groups several assessments into one KINNECT clinic slot
- **Reschedules** — a service can accumulate multiple appointments over time; `Service#appointment` returns the latest

Migration: `carelever_assessment/db/migrate/20260423000001_create_appointment_services.rb`

---

## Referral — the container

A `Referral` holds:

- Candidate details (name, DOB, contact, OTP access)
- Employer context (`company`, `site`, `position`, `person`)
- Billing and payment state
- Doctor review rollup (`doctor_outcome`, `doctor_outcome_finalised_at`)
- Completion (`referral_completed_at`)

Contact routing uses `ReferralRelationship` with types including `referrer`, `updates_to`, `results_to`, and `invoicee`.

When all services finish, `Referral#check_all_services_completed!` sets the referral-level outcome and completion timestamp, then marks services as billed.

---

## Service — the unit of work

Each row in `services` is one assessment on a referral. Progress is **timestamp-driven** — not a configurable workflow graph (contrast with legacy Screen; see [Screen workflow engine](../screen/workflow-engine.md)).

### Service stages

Derived from `Service#current_stage` and `STAGE_ORDER`:

| Stage | Key timestamps |
|---|---|
| Created | `service_created_at` |
| Booked | `appointment_intent_recorded_at`, `appointment_booked_at` |
| Attended | `appointment_attended_at` |
| Doctor sign-off | `doctor_outcome_finalised_at` |
| Completed | `service_completed_at` |

Other important timestamps:

| Timestamp | Meaning |
|---|---|
| `assessment_form_submitted_at` | Candidate/employer forms submitted |
| `results_received_at` | Results are in — ready for doctor review |
| `matrix_evaluated_at` | Medical matrix rules evaluated |
| `external_dependency_resolved_at` | External lab/clinic dependency cleared |

### Service hierarchy and bundles

Services can be structured as:

- **Bundle parent** — `ServiceItem#is_bundle`; child rows via `bundle_service_id`
- **Nested component** — `parent_service_id` for sub-components
- **Added mid-assessment** — `added_during_assessment` flag

### Clinic assignment

`SupplierAssignment` links a service to a `Supplier` (KINNECT internal clinic or affiliate external clinic). Status: `pending`, `in_progress`, `completed`, `cancelled`.

### Fulfilment modes

`appointment_fulfilment_mode` on the service controls how booking works:

| Mode | Typical use |
|---|---|
| `booked_only` | Standard scheduled appointment |
| `walk_in_only` | Walk-in clinic; no fixed start time required |
| `booked_or_walk_in` | Either path |
| `manual_scheduling` | KINNECT ops books manually from availability windows |
| `affiliate_scheduling` | External clinic manages the slot |

### Processing and billing

- `processing_mode` — derived (`fully_automated`, `attention_required`, `blocked_external`, `completed`) via `ProcessingModes::DeriveService`
- `billing_status` — `unbilled` → `pending` → `billed` (or `cancelled`)
- `requires_external_results` — results expected from an external lab; may block doctor review until resolved

---

## Appointment — scheduling

An `Appointment` is a time slot at a clinic:

- `appointment_date`, `start_time`, `end_time`
- `supplier_id` — which clinic
- `practitioner_id` — which assessor
- `shift_id` — roster shift (KINNECT internal)
- `status` — lifecycle of the slot itself
- `booking_reference` — human-readable ref (e.g. `APT-XXXXXXXX`)

Creating a booking typically goes through the service:

```ruby
service.create_appointment!(supplier: clinic, appointment_date: date, …)
# → creates Appointment + appointment_services row + notification
```

Appointment status changes can trigger attendance notifications and billing side effects. Reverting from `attended`/`completed` back to `pending`/`confirmed` is blocked once billing is finalised.

---

## Results — what “result” means

There is no `Result` model. **Results are a phase** signaled primarily by `services.results_received_at`.

See also: [Referral Results Tab — Where the Data Comes From](../results-tab-overview.md) for UI-oriented detail.

### Path 1 — Assessor form completion (in-clinic / affiliate)

Assessor `FormSession`s hold the structured test data (readings, observations). When the last open assessor session for a service completes **and** the service has `appointment_attended_at`:

1. `V1::Internal::FormSessions::Complete` sets `results_received_at`
2. `Notifications::Dispatch.results_received` fires
3. Audit log: `AuditActions::Services::RESULTS_RECORDED`

Affiliate clinics submit all assessor forms atomically via `V1::Affiliate::Appointments::SubmitAssessment` (attendance is stamped before completion so the cascade runs correctly).

### Path 2 — Result document upload (internal portal)

Staff upload PDF/JPG/PNG per service via `V1::Internal::Referrals::ResultDocuments::Create`:

1. Creates `CandidateDocument` with `document_type: 'result_document'`
2. Optionally runs AI extraction (`Ai::ResultDocumentExtractor` via Bedrock)
3. Sets `results_received_at` if not already set
4. User can review extracted values and apply to form fields

This bridges paper-based and digital workflows.

### FormSession roles

| session_type | Who | Purpose |
|---|---|---|
| `candidate` | Person being assessed | Pre-assessment questionnaire |
| `employer` | Employer / client | Employer-provided info |
| `assessor` | Clinic staff | Records test results |
| `doctor` | Reviewing doctor | Doctor review and outcome |

Chain: `Referral → Service → FormSession → FormFieldResponse`

---

## Doctor review and outcomes

Once `results_received_at` is set, services requiring doctor review enter the doctor portal queue (`ServiceItem#requires_doctor_review`).

| Level | Fields | Meaning |
|---|---|---|
| **Service** | `doctor_outcome`, `matrix_outcome`, `doctor_notes` | Per-assessment fitness determination |
| **Referral** | `doctor_outcome`, `doctor_outcome_finalised_at` | Rollup fitness-for-work for the whole case |

The **medical matrix** (`MedicalMatrixRule`) can auto-evaluate rules and set `matrix_outcome`. When rules allow, `Service#auto_complete_without_review!` can finalise without manual doctor sign-off.

`OutcomeEvent` records an audit trail of outcome changes at referral or service level.

`OutcomeApproval` can block completion when employer approval is required.

---

## End-to-end flow (typical case)

```
1. Create Referral
   → candidate + company + ordered ServiceItems become Service rows

2. Assign clinics
   → SupplierAssignment per service

3. Book appointment(s)
   → appointment_services links slot ↔ services
   → service.appointment_booked_at / appointment_intent_recorded_at set

4. Attend
   → appointment status → attended
   → service.appointment_attended_at set

5. Capture results
   → assessor forms submitted OR result documents uploaded
   → service.results_received_at set

6. Doctor review
   → doctor_outcome on service (or matrix auto-complete)

7. Complete
   → service.service_completed_at
   → referral.check_all_services_completed! → referral_completed_at

8. Bill
   → billing_status advances (unbilled → pending → billed)
```

---

## Exception signals

`ExceptionSignal` records are immutable deviation flags generated by `IssueDefinition` rules. They drive the **Awaiting Action** workflow when timestamps or business rules deviate (e.g. overdue results, missing forms, billing anomalies).

Evaluated when service timestamps change (`Service#evaluate_signals` after save).

---

## Comparison with legacy Screen

| | Screen (`carelever_screen`) | Assessment (`carelever_assessment`) |
|---|---|---|
| Workflow | Configurable graph (`Activity`, `Edge`, `WorkflowTrigger`) | Timestamp columns on `Service` |
| Stage tracking | Denormalised from latest `ReferralActivity` | Derived from which timestamps are set |
| Transitions | Edge criteria + trigger evaluation | Code in commands and model callbacks |
| Configurability | Per-tenant via admin settings | Hardcoded application logic |
| Deviation handling | Workflow triggers | Exception signals + automation rules |

Screen's graph maps to the same real-world stages; Assessment replaces it with explicit, query-friendly timestamps.

---

## Key files (Assessment repo)

| Area | Path |
|---|---|
| Models | `app/models/referral.rb`, `service.rb`, `appointment.rb`, `appointment_service.rb` |
| Form completion / results cascade | `app/commands/v1/internal/form_sessions/complete.rb` |
| Result document upload | `app/commands/v1/internal/referrals/result_documents/create.rb` |
| Affiliate assessment submit | `app/commands/v1/affiliate/appointments/submit_assessment.rb` |
| Doctor review update | `app/commands/v1/internal/doctor_reviews/update.rb` |
| Domain glossary | `DOMAIN_GLOSSARY.md` |
| DB schema | `db/schema.rb` — tables `referrals`, `services`, `appointments`, `appointment_services` |

---

## Related KB docs

- [Referral Results Tab — Where the Data Comes From](../results-tab-overview.md)
- [Screen Workflow Engine](../screen/workflow-engine.md) — legacy graph model and Assessment comparison
- [Medical Matrix Data Model](../screen/medical-matrix-data-model.md)
- [Initial Data Migration](../migration/initial-data-migration.md) — tenant/auth/company seeding (not referral workflow data)
- [Assessment initial migration runbook](../../carelever_assessment/docs/data-sync/initial-migration.md) — export/import scripts in the Assessment repo
