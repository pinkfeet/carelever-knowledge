# Clinic Calendar & Live Booking — Detailed Rules and Flows

> **Source**: `carelever-replit-reimagined` codebase  
> **Last updated**: 2026-04-08

---

## Table of Contents

1. [Overview](#overview)
2. [Clinic Calendar](#clinic-calendar)
3. [Live Booking — Candidate Booking Wizard](#live-booking--candidate-booking-wizard)
4. [Smart Scheduling (Multi-Block Scheduler)](#smart-scheduling-multi-block-scheduler)
5. [Slot Generation](#slot-generation)
6. [Appointment Booking Service](#appointment-booking-service)
7. [Appointment Holds](#appointment-holds)
8. [Affiliate Booking Flow (Appointment Requests)](#affiliate-booking-flow-appointment-requests)
9. [Rescheduling](#rescheduling)
10. [Break Optimisation](#break-optimisation)
11. [Key Constants & Constraints Summary](#key-constants--constraints-summary)

---

## Overview

The system supports two distinct booking paths based on clinic type:

| Path                     | Clinic Type                | Mechanism                                                                              |
| ------------------------ | -------------------------- | -------------------------------------------------------------------------------------- |
| **Smart Scheduling**     | KINNECT internal clinics   | Multi-block scheduler optimises slot across categories and practitioners               |
| **Affiliate Scheduling** | External/affiliate clinics | Candidate provides availability windows; affiliate accepts, rejects, or counter-offers |

A third fallback exists — **Manual Scheduling** — for services that cannot be system-booked (e.g., missing tags, no capable clinic nearby).

---

## Clinic Calendar

**Controller**: `ClinicCalendarsController`  
**Views**: `app/views/clinic_calendars/` (day, week, month partials)

### Dashboard (`/clinic_calendars/dashboard`)

Displays all KINNECT suppliers with:

- **Next available appointment**: Scans up to 90 days ahead, skipping weekends and supplier-blocked dates. Finds the earliest open slot across all practitioners on shift.
- **Business-day urgency**:
  - `red` — next available > 2 business days away
  - `yellow` — next available > 1 business day away
  - `normal` — within 1 business day
  - `none` — no availability found
- **Utilisation metrics** (current week, next week, week-after-next):
  - Shift hours vs. appointment hours → percentage utilisation
  - Estimated weekly demand (4-week lookback average of appointment hours)
  - Gap analysis: `shift_hours - avg_weekly_demand` for upcoming weeks

### Calendar View (`/clinic_calendars/calendar`)

- **View modes**: Day, Week (Mon–Fri), Month
- **Slot granularity**: 15, 30, or 60 minutes (selectable)
- **Practitioner display**: Rostered practitioners (or all if `show_all=true`)
- **Overlap detection**: Flags when the same user has simultaneous shifts at multiple KINNECT suppliers on the same date
- **Shift task management**: Admins can add/remove fixed blocks (shift tasks) with a task type and duration

### Time Slot Generation for Calendar

- Time slots are derived from actual shift boundaries (earliest start → latest end across all practitioners)
- Default fallback: 08:00–17:00 if no shifts
- Slots are rounded to the configured granularity

---

## Live Booking — Candidate Booking Wizard

**Controller**: `Candidate::BookingWizardController`  
**Steps**: `location → clinics → confirm → slots → availability → manual_scheduling → confirmation`

### Step 1: Location (`/candidate/booking/location`)

- Candidate enters a suburb or postcode
- **Location suggestions** via `PostcodeGeocoder::AUSTRALIAN_POSTCODES` lookup
- Supports postcode match (4-digit) and suburb name partial match
- Returns up to 8 suggestions

### Step 2: Clinic Search & Selection (`/candidate/booking/clinics`)

**Clinic discovery flow**:

1. Geocode postcode → find suppliers within 300km radius via `PostcodeGeocoder.suppliers_with_distances`
2. For each supplier, check **service capability** using supplier_service_capabilities:
   - **Splittable assessment with components**: Check component-level tags — all components must be capable at the supplier
   - **Splittable assessment without components**: Fall back to assessment-level tag via variation `tag_id`
   - **Non-splittable assessment**: Check assessment-level supplier capability, with variant matching
   - Component capability also checked via parent bundle inclusion (`supplier_capable_of_component_via_bundle?`)

**Recommendation engine** (priority order):

1. Nearest KINNECT clinic that can do ALL services → single-clinic recommendation
2. Combination of KINNECT clinics within inter-clinic distance limit that covers all services
3. Nearest affiliate clinic that can do all services
4. Any combination of clinics within distance limit

**Auto-skip logic**: If every service has exactly one capable clinic, and all selected clinics are within the inter-clinic distance limit, skip clinic selection entirely.

**Multi-clinic distance constraint**: When multiple clinics are selected, all pairwise distances must be ≤ `ClosestSupplierFinder::MAX_INTER_CLINIC_DISTANCE_KM`. Services assigned to clinics outside this radius are rerouted to manual scheduling.

### Step 3: Slot Selection (`/candidate/booking/slots`) — KINNECT Only

- Date range: **tomorrow + 14 days**
- Uses `MultiBlockScheduler` to generate optimised slot options
- **Ideal time filtering**: Prefers slots at `09:00, 10:00, 11:00, 13:00, 14:00, 15:00`
- Falls back to first 3 available slots if no ideal times available
- Each slot includes block assignments (category, practitioner, start/end times)
- Candidate can select a slot or indicate "pending" with availability windows for manual follow-up

### Step 4: Availability (`/candidate/booking/availability`) — Affiliate Only

- Candidate provides availability windows (date + time range)
- For pre-selected affiliates (services already assigned to a non-bookable supplier), flows directly here

### Step 5: Manual Scheduling (`/candidate/booking/manual_scheduling`)

- For services that couldn't be system-booked
- **Minimum 3 availability windows** required
- **No weekend dates** allowed
- Each window: date + time preference (morning/afternoon/all day)
- Records `appointment_fulfilment_mode = 'manual_scheduling'` and triggers signal evaluation

### Step 6: Confirmation (`/candidate/booking/confirmation`)

- Shows booking summary
- Displays walk-in services separately
- Clears all wizard session state

### Booking Execution (`save_bookings_and_confirm`)

**For KINNECT clinics**:

1. Parse selected datetime
2. Re-derive block assignments via `MultiBlockScheduler` for the specific date/time
3. Create one `Appointment` per category block, linked to the practitioner and shift
4. Map blocks to services via `CategoryBlockBuilder.resolve_service_tag_components`
5. Create `SupplierAssignment` records
6. Mark services with `appointment_booked_at`, `appointment_booked_for`, `appointment_intent_recorded_at`
7. Uncovered services (not matching any block) get fallback per-service booking

**For affiliate clinics**:

- Creates `AppointmentRequest` with candidate's availability windows
- Sets `appointment_fulfilment_mode = 'affiliate_scheduling'`

---

## Smart Scheduling (Multi-Block Scheduler)

**Files**: `app/services/multi_block_scheduler.rb` + `app/services/multi_block_scheduler/` subdirectory

### Architecture

```
MultiBlockScheduler (orchestrator — generate_slots)
├── CategoryBlockBuilder        — groups tests into category blocks
├── StaffCombinationGenerator   — enumerates qualified staff combinations
├── BlockPermutationEvaluator   — branch-and-bound permutation search
├── GapScoreCalculator          — scores schedule efficiency
└── ScheduleBookingService      — converts chosen option into booked appointments
```

### Category Block Resolution (`CategoryBlockBuilder`)

**Purpose**: Convert service items into scheduling blocks grouped by test category.

**Valid categories**: `Audiometry`, `Functional`, `Medical`, `Nurse`, `Pathology`, `Urine`, `Spirometry`

**Tag-to-category mapping**:
| Tag Name | Category |
|----------|----------|
| Audiometry | Audiometry |
| Functional | Functional |
| Medical | Medical |
| Nurse Only | Nurse |
| Pathology | Pathology |
| Urine/DAS | Urine |
| Spirometry | Spirometry |

**Three-tier component resolution** (in order):

1. Variation-specific bundle items (`ServiceBundleItem` where `service_variation_id` matches)
2. Base bundle items (where `service_variation_id IS NULL`)
3. Tag-based components (via `ComponentTag` using variation's `tag_id`)

**Key rules**:

- **Same-category concurrency**: Tests in the same category run concurrently. Block duration = `max(component durations)`, NOT sum.
- **Duration rounding**: Raw max duration is rounded UP to the nearest `SLOT_INCREMENT` (15 min). E.g., 20 min → 30 min.
- **Pathology always last**: Pathology blocks are separated and appended after all non-pathology blocks.
- **Non-pathology ordering**: Sorted by `VALID_CATEGORIES` index (Audiometry first, Spirometry last before Pathology).

**Untagged items**: If any component or assessment lacks a scheduling tag, the entire scheduler returns empty (system booking unavailable). The `schedulable?` method reports this.

### Staff Combination Generation (`StaffCombinationGenerator`)

**Purpose**: Enumerate all possible practitioner assignments for each category block.

**Qualification check**:

- **KINNECT suppliers**: Uses `PractitionerServiceQualification` (PSQ) — practitioner must have explicit qualification for ALL component IDs in the block
- **Non-KINNECT suppliers**: Uses `qualified_for?` method on practitioner model

**Priority sorting** (lower = tried first):

1. Fewer total qualifications (specialists before generalists)
2. Fewer existing appointments on that date
3. Practitioner ID (tiebreaker)

**Rationale**: Specialists consume their specific slots first, keeping generalists available for other patients.

**Combination generation**:

- Cross-product: `K1 × K2 × ... × Kn` where Ki = qualified practitioners for block i
- **Capped at 200 combinations** to prevent performance issues
- Returns all combinations; simulation evaluates each

### Block Permutation Evaluation (`BlockPermutationEvaluator`)

**Purpose**: Try all orderings of non-pathology blocks to find the best schedule.

**Algorithm**: Branch-and-bound recursive search over all n! permutations of non-pathology blocks, with pathology appended at the end.

**Constraints checked at each placement**:
| Constraint | Value | Description |
|------------|-------|-------------|
| `MAX_PER_GAP_WAIT` | 15 min | Maximum wait between any two consecutive blocks |
| `MAX_CUMULATIVE_WAIT` | 15 min | Maximum total patient wait across all gaps |
| `TIMEOUT_SECONDS` | 5 sec | Hard timeout to prevent infinite search |

**Slot finding** (`find_free_minute`):

- For each block, find the earliest available minute ≥ `max(patient_free, practitioner_busy)`
- Respects practitioner free ranges (shift windows minus breaks and existing appointments)
- Respects patient-blocked times (existing appointments for the same referral on that date)
- Scans up to 20 iterations to skip past conflicts

**Early exit**: If gap score = 0 (optimal) is found, search terminates immediately.

### Gap Score Calculation (`GapScoreCalculator`)

**Purpose**: Measure schedule efficiency — how much practitioner idle time the arrangement creates.

**Gap score = external gaps + internal gaps** (in minutes)

- **External gap**: Time between practitioner's last existing appointment end and their first new block start
- **Internal gap**: Time between a practitioner's consecutive blocks in the new schedule

**Badge labels**:
| Score | Label | Type |
|-------|-------|------|
| 0 | "Optimal" | `:optimal` |
| > 0 | "{N} min idle" | `:idle` |

### Top-Level Orchestration (`MultiBlockScheduler.generate_slots`)

**Flow**:

1. `resolve_blocks` → build ScheduleBlock structs from services
2. For each date in range (default: today + 14 days):
   a. `build_practitioner_timelines` → load shifts, compute working windows, subtract breaks/fixed blocks/existing appointments
   b. `find_best_assignments` → enumerate staff combinations sorted by priority
   c. `generate_start_times` → every 15-min slot from shift boundaries, plus times aligned to existing appointment ends
   d. For each start time, try each assignment via `simulate_tetris`:
   - Generate all n! permutations of non-pathology blocks
   - Pre-sort: soonest-free staff member leads
   - Try each ordering via `try_ordering`
   - Keep best (lowest gap score) result per start time
3. Sort results by: `[date, gap_score, start_time, patient_wait, -practitioner_count, min_practitioner_id]`

**Start time generation**:

- Every `SLOT_INCREMENT` (15 min) from earliest shift start to latest shift end
- Plus times aligned to existing appointment ends (rounded to nearest 15 min)
- For today: exclude times already past
- Earliest start is rounded UP to next 15-min boundary

### Schedule Booking Service (`ScheduleBookingService`)

**Purpose**: Convert a selected schedule option into actual Appointment records.

**Validation before booking**:

1. All scheduled services must be available (not already booked/attended)
2. Practitioner belongs to the supplier
3. Shift belongs to the practitioner
4. **Pathology must be chronologically last**
5. **Per-gap wait ≤ 15 minutes**
6. **Cumulative wait ≤ 15 minutes**

**Booking process**:

1. Group blocks by practitioner into continuous sessions (consecutive blocks by same practitioner are merged into one appointment)
2. Create one `Appointment` per session
3. Create/update `SupplierAssignment` for each service
4. Mark services as booked (`appointment_booked_at`)
5. Run `BreakOptimisationService` to adjust flexible breaks around new appointments

---

## Slot Generation

**File**: `app/services/slot_generation_service.rb`

**Purpose**: Generate available time slots for a single service at a clinic (used for non-multi-block booking and as a building block for the scheduler).

### Slot Generation Flow

1. **Practitioner qualification check**: Verify practitioner is qualified for the service item
   - For assessments: check qualification against all component IDs (via bundle items or tag-based resolution)
   - Returns early (empty) if not qualified
2. **Calculate available windows**:
   - Start with working segments from the shift
   - If no working segments defined: use full shift time (start_time → end_time)
   - **Overnight shift handling**: If `shift.overnight?`, split into two segments (start→midnight, midnight→end)
   - Subtract flexible breaks (using `start_time || earliest_start`)
   - Subtract fixed blocks
3. **Generate slots per window**: Divide each available window into consecutive slots of `appointment_duration` minutes
4. **Aggregate across practitioners**: Group slots by `(date, start_time)`, count available practitioners, sort by qualification count (fewer = higher priority)
5. **Filter past slots**: For today's date, remove any slot that's already past

### Slot Duration

- Uses `service_item.appointment_duration` (default: 30 minutes)

---

## Appointment Booking Service

**File**: `app/services/appointment_booking_service.rb`

**Purpose**: Book a single service to a specific time slot (used for non-multi-block, per-service booking).

### Validation Checks

1. Shift exists for the date
2. Appointment not in the past
3. Practitioner is qualified for the service
4. Slot is available (no overlapping active appointments)
5. Can accommodate (no conflicts with fixed blocks or locked breaks)

### Booking Flow

1. Create `Appointment` (status: `:confirmed`)
2. Set `service.appointment_booked_at` (if not already set)
3. Run `BreakOptimisationService.shift_breaks_for_appointment` to adjust flexible breaks

---

## Appointment Holds

**Model**: `AppointmentHold`

**Purpose**: Temporary slot reservation during booking wizard to prevent double-booking.

### Rules

| Parameter     | Value                                        |
| ------------- | -------------------------------------------- |
| Hold duration | **10 minutes**                               |
| Statuses      | `active`, `released`, `expired`, `converted` |

### Behaviour

- **Creating a hold**: Releases all existing active holds for the same referral draft, then creates a new one
- **Slot held check**: `slot_held?` checks if an active (non-expired) hold exists for a given supplier/date/time combination. Can exclude a specific draft ID (so the user's own hold doesn't block them)
- **Expiry**: Holds auto-expire when `expires_at <= Time.current`. Batch cleanup via `cleanup_expired!`
- **Extension**: `extend_hold!` adds another `HOLD_DURATION` (10 min) from now
- **Conversion**: When booking completes, hold status → `converted`
- **Release**: User navigates away → hold status → `released`

---

## Affiliate Booking Flow (Appointment Requests)

**Model**: `AppointmentRequest`

### Status Machine

```
pending ──→ accepted      (affiliate accepts with date/time within availability window)
        ──→ rejected      (affiliate rejects with reason)
        ──→ counter_offered (affiliate proposes alternative date/time)
              ──→ counter_accepted  (candidate accepts counter-offer)
              ──→ counter_rejected  (candidate rejects counter-offer)
        ──→ expired       (72 hours pass without response)
```

### Expiry Rules

| State           | Expiry                               |
| --------------- | ------------------------------------ |
| Initial request | **72 hours** from creation           |
| Counter-offer   | **48 hours** from counter-offer time |

### Rejection Reasons

- `no_capacity`
- `service_unavailable`
- `outside_service_area`
- `equipment_unavailable`
- `other`

### Acceptance Rules

- Must select one of the candidate's availability windows
- Start time must be within the selected window's time range
- End time must be after start time and within the window
- Creates an `Appointment` (status: `:confirmed`) automatically on acceptance

### Counter-Offer Rules

- Affiliate proposes new date, start_time, end_time
- Optional message
- Resets expiry to 48 hours
- Candidate can accept (creates appointment) or reject

### Validation

- One request per service per supplier (unique constraint)
- At least one availability window required on creation

---

## Rescheduling

**Model**: `RescheduleRequest`

### Status Machine

```
pending ──→ approved  (admin/employer approves)
        ──→ rejected  (admin/employer rejects with reason)
        ──→ expired   (time passes)
```

### Requester Types

- `candidate`
- `employer`
- `affiliate`

### Approval Processing

When a reschedule request is approved with proposed slots:

1. **KINNECT supplier**: Creates a new appointment directly from the first proposed slot. Old appointment status → `rescheduled`.
2. **Affiliate supplier**: Expires any pending appointment requests, creates a new `AppointmentRequest` for the affiliate.

### Auto-Approval

Company settings can define `reschedule_auto_approve_limit` — reschedule requests within this limit are auto-approved.

---

## Break Optimisation

**File**: `app/services/break_optimisation_service.rb`

**Purpose**: Manage flexible breaks when appointments are booked, ensuring breaks don't conflict with appointment times.

### Break Types (via TimeSegment)

| Type             | Behaviour                                                      |
| ---------------- | -------------------------------------------------------------- |
| `working`        | Defines practitioner availability window                       |
| `flexible_break` | Can be shifted within `earliest_start` → `latest_start` window |
| `fixed_block`    | Cannot be moved (meetings, tasks, etc.)                        |

### Can Accommodate Check

Before booking, verifies:

1. No overlap with any fixed blocks (hard fail)
2. For each flexible break that overlaps: there must be an alternative time within the break's allowed window

### Break Shifting

When an appointment is booked that overlaps a flexible break:

1. Search for alternative break time from `earliest_start` to `latest_start` in **15-minute increments**
2. If found: move the break
3. If not found: **lock the break** (it becomes immovable — `locked: true`)

---

## Key Constants & Constraints Summary

| Constant                      | Value                                    | Location                                           |
| ----------------------------- | ---------------------------------------- | -------------------------------------------------- |
| `SLOT_INCREMENT`              | 15 min                                   | `MultiBlockScheduler`                              |
| `MAX_PER_GAP_WAIT`            | 15 min                                   | `MultiBlockScheduler`, `BlockPermutationEvaluator` |
| `MAX_CUMULATIVE_WAIT`         | 15 min                                   | `MultiBlockScheduler`, `BlockPermutationEvaluator` |
| `MAX_SPLIT_PRACTITIONERS`     | 2                                        | `MultiBlockScheduler`                              |
| `LOOKAHEAD_DAYS`              | 14 days                                  | `MultiBlockScheduler`                              |
| `MAX_COMBINATIONS`            | 200                                      | `StaffCombinationGenerator`                        |
| `TIMEOUT_SECONDS`             | 5 sec                                    | `BlockPermutationEvaluator`                        |
| `HOLD_DURATION`               | 10 min                                   | `AppointmentHold`                                  |
| `SLOT_STEP_MINUTES`           | 15 min                                   | `MultiBlockSchedulerService`                       |
| Request expiry                | 72 hours                                 | `AppointmentRequest`                               |
| Counter-offer expiry          | 48 hours                                 | `AppointmentRequest`                               |
| Manual scheduling min windows | 3                                        | `BookingWizardController`                          |
| Ideal booking times           | 09:00, 10:00, 11:00, 13:00, 14:00, 15:00 | `BookingWizardController`                          |
| Clinic search radius          | 300 km                                   | `BookingWizardController`                          |
| Dashboard scan range          | 90 days                                  | `ClinicCalendarsController`                        |
| Demand lookback               | 4 weeks                                  | `ClinicCalendarsController`                        |

### Immutable Business Rules

1. **Pathology is ALWAYS scheduled last** — no exceptions, validated at booking time
2. **Same-category tests run concurrently** — block duration = max(durations), not sum
3. **Patient cannot wait > 15 min between blocks** (per-gap cap)
4. **Patient cannot wait > 15 min total** (cumulative cap)
5. **Specialists are prioritised over generalists** — fewer qualifications = tried first
6. **Gap score 0 = early exit** — once an optimal schedule is found, stop searching
7. **No weekend dates** for manual scheduling availability windows
8. **Affiliate requests expire** — 72h for initial, 48h for counter-offers
9. **Appointment holds are exclusive** — creating a new hold releases all previous holds for the same draft
