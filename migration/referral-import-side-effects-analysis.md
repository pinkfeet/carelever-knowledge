# Findings Report: Referral Import — Side Effects Analysis

**Date:** 2026-07-01
**Repo:** `carelever_assessment`
**Script:** `script/migrate-monitor/referrals/referrals_import.rb`
**Scope:** What ActiveRecord callbacks / side effects fire during a referral import, and whether the import script triggers or blocks each.

> Companion doc: [`monitor-referral-migration-side-effects.md`](./monitor-referral-migration-side-effects.md) covers the *post-migration* cron email flood (`EvaluateNudgesJob`). This report covers the *synchronous save path during the import run itself*.

---

## 1. Referral creation callbacks

**File:** `app/models/referral.rb`

| Callback | Line | Effect | Triggered by import? |
|----------|------|--------|----------------------|
| `before_validation :set_referral_created_at` | 310 | Sets `referral_created_at` timestamp | **Yes** — runs on `.save!` |
| `before_validation :generate_reference_number` | 311 | Generates `reference_number` if absent | **Yes** but skipped — import pre-computes it |
| `after_create :link_to_person` | 312 | **No-op** — intentionally empty (`referral.rb:1189`) | **Yes** but harmless |

Script usage: `referral.save!(validate: false)` (`referrals_import.rb:788`). `save!` still runs
`before_validation` hooks even with `validate: false`, but the pre-computed reference number makes
`generate_reference_number` a no-op and `link_to_person` is empty by design.

---

## 2. Service creation callbacks (most critical)

**File:** `app/models/service.rb` (lines 159–166)

| Callback | Line | Effect | Triggered by import? |
|----------|------|--------|----------------------|
| `before_save :ensure_appointment_intent_recorded_when_booked` | 161 | Records intent timestamp | Yes |
| **`after_save :evaluate_signals`** | **162** | **Evaluates `IssueDefinition` rules → creates `ExceptionSignal` rows** | **Conditionally — fires** |
| `after_save :advance_billing_status_on_attendance` | 163 | Billing status transition (unbilled→pending) | Yes but guarded |
| `after_save :advance_billing_status_on_completion` | 164 | Billing status transition (unbilled→pending) | Yes but guarded |
| `after_save :record_billed_at_timestamp` | 165 | Records `billed_at` timestamp | Yes but guarded |
| **`after_save :evaluate_affiliate_fee`** | **166** | **Creates affiliate `UnbilledLineItem`** | **Blocked** |

**`evaluate_signals`** — fires when `saved_change_to_timestamps?` is true (any `*_at` column changed; def at `service.rb:583`).
- In-progress services (`referrals_import.rb:1148`): `Service.create!` sets `service_created_at` → **fires**, and may create `ExceptionSignal` rows if rules are violated.
- Completed services (`referrals_import.rb:1163`): fires but short-circuits — `evaluate_service.rb:31` returns/auto-resolves for `@service.completed?`, so no stale signals.

**`evaluate_affiliate_fee`** — fires on `saved_change_to_appointment_attended_at?`. **Blocked**: the import
sets `appointment_attended_at` via `service.update_columns(...)` (`referrals_import.rb:1171`) *after*
creation, bypassing `after_save`.

---

## 3. Appointment creation callbacks

**File:** `app/models/appointment.rb` (lines 113–116)

| Callback | Line | Effect | Triggered by import? |
|----------|------|--------|----------------------|
| `before_create :generate_booking_reference` | 113 | Generates booking reference | Yes (harmless) |
| `after_create :record_appointment_intent` | 114 | Records intent timestamp (currently no-op) | Yes |
| **`after_save :record_attendance`** | **115** | **Dispatches `Notifications::Dispatch.appointment_attended` (email/SMS)** | **Blocked** |
| `after_save :handle_clinic_unavailable` | 116 | Sets `clinic_unavailable_override` on services | **Blocked** |

`record_attendance` fires only on status transition into a post-event status (attended/completed).
**Blocked**: the import creates appointments in `confirmed` status (`referrals_import.rb:1088`), then
sets the real status via `appt.update_columns(status: ...)` (`referrals_import.rb:1089`), bypassing
`after_save`.

---

## 4. Signal / exception evaluation

**File:** `app/services/signals/evaluate_service.rb` — triggered by `Service` `after_save` (`service.rb:162`).

- Iterates active `IssueDefinition` records, evaluates `Signals::Rules::DynamicRule` per definition.
- Creates `ExceptionSignal` rows on violations (`evaluate_service.rb:62`); `ExceptionSignalActivity` on auto-resolution (`:87`).
- In-progress migrated services: fires and may create signals. Completed services: short-circuits at `:31` (avoids stale signals).
- **In-app only — no mailer/SMS.** May be intended, since these referrals are `attention_required`. Surface separately if the "Awaiting Action" list looks noisy.

---

## 5. Mailers / SMS / notifications

- **No mailer is called directly** from `Referral#save`, `Service#save`, or `Appointment#save`.
- `Notifications::Dispatch` is documented to be called from commands after commit, **not from model callbacks** (`dispatch.rb:5-6`) — e.g. `referral_created` fires from `V1::Shared::Referrals::Create`, never during import.
- The one callback-driven dispatch (`Appointment#record_attendance`) is **blocked** by the `update_columns` tactic above.
- **No SMS** on the referral/service save paths.

---

## 6. Sidekiq jobs

| Job | Triggered by | Import impact |
|-----|-------------|---------------|
| `Referrals::RunMedicalClearanceReviewJob` | `enqueue_ai_clearance_review!` — an explicit method, **not a callback** (`referral.rb:914`) | Not triggered by import |

No Sidekiq jobs are enqueued by Referral/Service/Appointment creation callbacks.

---

## 7. Billing callbacks

| Callback | Trigger | Script handling |
|----------|---------|-----------------|
| `advance_billing_status_on_attendance` | `saved_change_to_appointment_attended_at?` | **Blocked** — `update_columns` |
| `advance_billing_status_on_completion` | `saved_change_to_service_completed_at?` | **Handled** — completed services created with `billing_status: "billed"`, so callback early-returns |
| `record_billed_at_timestamp` | `saved_change_to_billing_status?` | **Handled** — same as above |

---

## Summary

**Unavoidable (callbacks fire, harmless):**
1. Referral `before_validation` — set timestamps / reference number (pre-computed).
2. Referral `after_create :link_to_person` — no-op.
3. **`Service after_save :evaluate_signals`** — in-progress services may create `ExceptionSignal` rows (in-app only); completed services auto-resolve.
4. Appointment `before_create :generate_booking_reference`, `after_create :record_appointment_intent`.

**Deliberately blocked (via `update_columns` / terminal status):**
1. Appointment attendance notifications (`record_attendance`).
2. Affiliate fee creation (`evaluate_affiliate_fee`).
3. Clinic-unavailable handling (`handle_clinic_unavailable`).
4. Billing status transitions on attendance.

**Never triggered:** email/SMS mailers, referral creation notifications, Sidekiq jobs (except unrelated medical clearance), person-creation side effects.

**Conclusion:** The import is carefully designed to trigger only safe callbacks. It blocks communications, billing transitions, and state-change notifications via three tactics:
1. Pre-computing immutable values (`reference_number`).
2. Setting terminal states upfront (`service_completed_at`, `billing_status: "billed"`).
3. Using `update_columns` to bypass callbacks for post-creation state adjustments.

The only live side effect is **exception-signal evaluation for in-progress services**, which is intended behavior.
