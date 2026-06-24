# Monitor Referral Migration — Background-Job Side Effects (Email Flood)

**Date:** 2026-06-24
**Status:** Implemented (code + tests). Items 1 & 3 in code; item 2 is a one-off script to run at cutover.
**Repo:** `carelever_assessment`
**Branch context:** `feat/CT-5383-Migration-from-Monitor-to-Assessments-*`

## Problem

After bulk-migrating Monitor referrals into Assessment, candidates received a flood of
**"Book Your Appointment - Carelever Screen"** emails.

## Root cause

The import itself sends **no** emails — it deliberately suppresses ActiveRecord callbacks
(`update_columns`, `save!(validate: false)`, completed cycles created already-terminal/billed).
The emails come from a **scheduled cron job afterward**.

Chain:

1. `EvaluateNudgesJob` runs every 15 min (`config/sidekiq_schedule.yml`) → calls
   `Nudges::EvaluateAndSchedule` for every `nudge_eligible` referral.
2. `nudge_eligible` scope = `cancelled_at: nil` AND `processing_mode != completed`
   (`app/models/referral.rb:381`).
   - **Completed** migrated cycles are safe (they are `processing_mode: completed` + terminal/billed).
   - **In-progress** migrated cycles are `attention_required` with `billing_status: unbilled` → eligible.
3. `needs_booking_reminder?` (`app/commands/nudges/evaluate_and_schedule.rb:76-82`) fires because:
   - `requires_appointment_booking?` → true (service_item booking_type is `requires_booking`, not
     `internal`, so the line-22 `booking_internal?` gate doesn't catch it),
   - `appointment_intent_recorded_at` is blank (import never sets it),
   - `service_created_at` is **back-dated** to historical Monitor dates → instantly "> 48h old".
4. → `:booking_reminder` nudge scheduled → `ProcessDueNudgesJob` delivers →
   `NudgeMailer` sends "Book Your Appointment - Carelever Screen" (`app/mailers/nudge_mailer.rb:30`).

Because every migrated in-progress service has a historical creation date, they all look overdue
at once → the flood.

## Fix plan (scoped with product)

Decision: **disable only the stale "please book" nudge for migrated referrals**; real
post-migration activity (e.g. adding an appointment) still notifies normally.

1. **Suppress booking reminder for migrated referrals** — `app/commands/nudges/evaluate_and_schedule.rb`,
   top of `needs_booking_reminder?`:
   ```ruby
   return false if @referral.monitor_referral_id.present?
   ```
   Surgical: only `booking_reminder` is affected. `appointment_reminder` / `form_reminder` are
   independent and gated on post-migration fields (`appointment_booked_for`, `form_started_at`)
   that the import leaves nil — so adding a real appointment later (internal
   `appointments/create.rb:201-202` or candidate `booking/confirm.rb:143`) sets
   `appointment_booked_for` and `appointment_reminder` fires normally.
2. **One-off cleanup** of already-queued pending `booking_reminder` nudges for referrals with
   `monitor_referral_id IS NOT NULL` (rake/console `Nudge.where(...).delete_all`, same pattern the
   import uses at `referrals_import.rb:777`).
3. **Specs** under `spec/commands/nudges/`:
   - migrated referral, back-dated unbooked service → schedules no booking reminder;
   - migrated referral with `appointment_booked_for` in near future → `appointment_reminder` still schedules;
   - native referral → booking reminder unchanged (regression guard).

**Net behavior:** migrated snapshot is silent; a genuine later change resumes notifications.
**Edge case:** a migrated in-progress referral that never gets an appointment will now never get a
"please book" reminder — accepted, since these are ported historical cycles.

## Full background-job audit (all `config/sidekiq_schedule.yml` cron jobs + async paths)

**Only one email/SMS source touches migrated data: the `booking_reminder` nudge above.**
All others are safe for migrated records:

| Job | Verdict | Why |
|---|---|---|
| `evaluate_nudges` / `process_due_nudges` | **FIX** | the booking-reminder flood (see fix) |
| `affiliate_response_reminder` | SAFE | import creates no `AppointmentRequest` rows |
| `bill_non_attended_action_fees` | SAFE | callbacks bypassed → no `UnbilledLineItem` rows created |
| `reconcile_stuck_result_extractions` (CT-5382) | SAFE | migrated docs have `ai_extraction_status = NULL`; scope wants `'pending'` |
| `grace_period_expiring_notification` | SAFE | per-referral enqueue only on doctor submit; migrated rows bail early |
| `flag_overdue_confirmed_appointments` | SAFE | filters on `services.appointment_booked_for`, which the import **never sets** (nil); also only flags, never emails |
| `clinic_calendar_dashboard_refresh`, `operations_dashboard_refresh` | SAFE | read-only aggregation, no notifications |
| `appointment_hold_cleanup` | SAFE | no holds created by import |
| `auto_finalize_doctor_outcome` | SAFE | enqueued only on doctor submission; migrated services already have `doctor_outcome_finalised_at` |
| automation rules (`app/jobs/automation/*`) | SAFE | enqueued on form completion, not on record create; import suppresses callbacks |

### Non-email note: ExceptionSignal "Awaiting Action" flags

In-progress migrated services **do** fire `evaluate_signals` on `Service.create!`
(`app/models/service.rb:162`) and can create `ExceptionSignal` records
(`app/services/signals/evaluate_service.rb:62`). Completed cycles short-circuit (terminal);
in-progress ones do not. This path is **in-app only — no mailer/SMS** — and may be intended
since those referrals are `attention_required`. Not part of the email problem; surface separately
if the "Awaiting Action" list looks noisy.

## Key references

- `app/commands/nudges/evaluate_and_schedule.rb:76-82` — `needs_booking_reminder?`
- `app/models/referral.rb:381` — `nudge_eligible` scope
- `app/mailers/nudge_mailer.rb:30` — "Book Your Appointment" subject
- `config/sidekiq_schedule.yml` — all cron jobs
- `script/migrate-monitor/referrals/referrals_import.rb` — import (callback suppression, status, nudge cleanup at :777)
