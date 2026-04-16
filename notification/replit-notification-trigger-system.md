# Notification Trigger System — Replit App

> **Source**: `carelever-replit-reimagined` codebase  
> **Last updated**: 2026-04-10

---

## Table of Contents

1. [Overview](#overview)
2. [Data Model](#data-model)
3. [Delivery Channels](#delivery-channels)
4. [Full Flow: Event → Delivery](#full-flow-event--delivery)
5. [All Defined Events](#all-defined-events)
6. [All Trigger Call Sites](#all-trigger-call-sites)
7. [Gaps & Inconsistencies](#gaps--inconsistencies)
8. [Conditions System](#conditions-system)
9. [Outcome Approval Interception](#outcome-approval-interception)
10. [Key Files](#key-files)

---

## Overview

All notifications are driven by `NotificationTrigger` records in the database. Each record maps an event to a recipient type, message template, and delivery channels. When an event fires, `NotificationService.trigger` fetches matching active triggers, evaluates conditions, resolves recipients, renders templates, and delivers via email/SMS/in-app.

This means notifications are **configurable in the admin UI** — no code change is needed to add or modify notification rules for most events.

---

## Data Model

### NotificationTrigger

| Field | Type | Description |
|---|---|---|
| `trigger_event` | string | Must be a key in `TRIGGER_EVENTS` (validated) |
| `recipient_type` | enum | `candidate`, `employer`, `clinic`, `assessor`, `referrer`, `updates_to`, `results_to`, `invoicee`, `affiliate` |
| `message_template_id` | bigint | FK — the template to render |
| `send_email` | boolean | Whether to send email |
| `send_sms` | boolean | Whether to send SMS |
| `active` | boolean | Only active triggers are evaluated |
| `conditions` | jsonb | Optional conditions (see [Conditions System](#conditions-system)) |
| `company_id` | bigint | Scope to specific company (optional) |
| `service_item_id` | bigint | Scope to specific service item (optional) |

Multiple companies and service items can be scoped via join tables:
- `notification_trigger_companies`
- `notification_trigger_service_items`

### NotificationLog

Full audit trail of every notification sent:

| Field | Description |
|---|---|
| `event` | The trigger event name |
| `channel` | `email` or `sms` |
| `recipient_email` / `recipient_phone` | Delivery target |
| `subject`, `body` | Rendered content |
| `status` | `pending`, `sent`, `failed`, `dev_mode_skipped` |
| `context_data` | jsonb of merge field values used |

### InAppNotification

Created for employer users (client portal) for 6 events only:
`referral_created`, `appointment_booked`, `results_received`, `doctor_review_completed`, `referral_completed`, `outcome_approval_required`

---

## Delivery Channels

### Email — Azure Communication Services

- **Service**: `AzureEmail::Send`
- **API**: Azure Communication Email REST API (v2023-03-31)
- **Auth**: HMAC-SHA256 signed requests
- **Credentials**: `AZURE_COMMUNICATION_ENDPOINT`, `AZURE_COMMUNICATION_KEY` (SystemSetting or ENV)
- **Default sender**: `noreply@carelever.com`
- **Dev mode**: Logs to Rails logger, marks status as `dev_mode_skipped` — no actual send

### SMS — DirectSMS Australia

- **Service**: `DirectSMS::Send`
- **API**: `https://api.directsms.com.au`
- **Auth**: Bearer token
- **Credential**: `DIRECTSMS_API_KEY` (SystemSetting or ENV)
- **Phone formatting**: Auto-converts to `+61` format
- **Dev mode**: Logs to Rails logger only

### In-App

- Created via `InAppNotification.create!`
- Only for employer users with `client` role
- Respects per-user notification preferences
- Event-specific icons, colours, and titles

---

## Full Flow: Event → Delivery

```
1. EVENT OCCURS
   e.g. Appointment created → after_create callback
   → NotificationService.trigger(event: 'appointment_booked', referral:, service:)

2. FETCH TRIGGERS
   NotificationTrigger.active.for_event('appointment_booked')

3. EVALUATE CONDITIONS
   trigger.applies_to?(referral:, service:)
   - Check company scope
   - Check service item scope
   - Check conditions jsonb (appointment_scheduled, company, service_item, etc.)
   - Skip internal services for events in INTERNAL_EXCLUDED_EVENTS

4. RESOLVE RECIPIENTS
   Based on recipient_type:
   - candidate      → referral.candidate_email / candidate_phone
   - employer       → users from company with 'client' role
   - clinic         → supplier from service
   - assessor       → practitioner user
   - affiliate      → affiliate supplier
   - referrer       → referral contact
   - updates_to     → referral_relationships contact
   - results_to     → referral_relationships contact
   - invoicee       → invoicing contact

5. RENDER TEMPLATE
   MergeFields::Render.call(template, context)
   Context includes: candidate name/email/phone, appointment date/time/location,
   clinic/practitioner, reschedule URLs, referral reference number, etc.

6. LOG NOTIFICATION
   NotificationLog.create!(status: 'pending', ...)

7. DELIVER
   Email → AzureEmail::Send.call
   SMS   → DirectSMS::Send.call
   → Update NotificationLog status to 'sent' or 'failed'

8. IN-APP NOTIFICATION
   If event in InAppNotification::EVENT_TYPES AND recipient is employer user:
   InAppNotification.create!

9. LOG ACTIVITY
   ReferralActivity.log(activity_type: 'email_sent' / 'sms_sent', ...)

10. RECURSIVE TRIGGER (results only)
    If results sent to employer/results_to:
    → NotificationService.trigger('results_sent_to_employer')
```

---

## All Defined Events

Events defined in `NotificationTrigger::TRIGGER_EVENTS` (these are the only ones that can be configured via admin UI):

| Event | Description | Status |
|---|---|---|
| `referral_created` | New referral submitted | ✅ Triggered |
| `referral_cancelled` | Referral cancelled | ✅ Triggered |
| `appointment_booked` | Appointment confirmed | ✅ Triggered |
| `appointment_cancelled` | Appointment cancelled | ✅ Triggered |
| `appointment_attended` | Appointment marked attended | ✅ Triggered |
| `appointment_rescheduled` | Appointment rescheduled | ✅ Triggered |
| `appointment_reminder_24h` | 24h before appointment | ⚠️ Not yet triggered (needs scheduled job) |
| `appointment_reminder_2h` | 2h before appointment | ⚠️ Not yet triggered (needs scheduled job) |
| `booking_reminder` | Reminder to book appointment | ⚠️ Not yet triggered (needs scheduled job) |
| `form_reminder` | Reminder to complete forms | ⚠️ Not yet triggered (needs scheduled job) |
| `affiliate_request_created` | New affiliate booking request | ✅ Triggered |
| `affiliate_request_reminder` | Reminder for affiliate to respond | ⚠️ Not yet triggered (needs scheduled job) |
| `affiliate_accepted` | Affiliate accepted booking | ✅ Triggered |
| `affiliate_rejected` | Affiliate rejected booking | ✅ Triggered |
| `counter_offer_sent` | Affiliate sent counter-offer | ✅ Triggered |
| `counter_offer_accepted` | Candidate accepted counter-offer | ✅ Triggered |
| `counter_offer_rejected` | Candidate rejected counter-offer | ✅ Triggered |
| `reschedule_requested` | Candidate requested reschedule | ✅ Triggered |
| `medical_clearance_required` | Medical clearance flag raised | ✅ Triggered |
| `medical_clearance_uploaded` | Medical clearance docs uploaded | ✅ Triggered |
| `further_info_approved` | Client approved further info request | ✅ Triggered |
| `further_info_declined` | Client declined further info request | ✅ Triggered |
| `slot_released` | Appointment slot released | ⚠️ Not yet triggered |
| `results_received` | Assessment results received | ✅ Triggered |
| `doctor_review_completed` | Doctor finalised outcome | ✅ Triggered |
| `referral_completed` | Referral completed | ✅ Triggered |
| `outcome_approval_required` | Outcome held pending approval | ✅ Triggered (via OutcomeApprovalService) |
| `outcome_approval_pending_updatee` | Notification to updatee contacts | ✅ Triggered (via OutcomeApprovalService) |
| `outcome_approved` | Held outcome approved | ✅ Triggered |
| `employer_forms_incomplete` | Employer forms not yet completed | ✅ Triggered |
| `employer_forms_completed` | All employer forms submitted | ✅ Triggered |
| `results_sent_to_employer` | Results sent to employer (cascade) | ✅ Triggered (recursive) |

---

## All Trigger Call Sites

| Event | Where Called | Context |
|---|---|---|
| `referral_created` | `models/referral.rb` | `after_save` callback on create |
| `referral_cancelled` | `services/referrals/cancel.rb` | After cancellation completes |
| `referral_completed` | `models/referral.rb` | When `processing_mode` → `completed` |
| `appointment_booked` | `models/appointment.rb` | `after_create` callback |
| `appointment_attended` | `models/appointment.rb` | When status → `completed` |
| `appointment_cancelled` | `models/appointment.rb` | When status → `cancelled` |
| `appointment_rescheduled` | `controllers/candidate/reschedule_controller.rb` | Immediate Kinnect reschedule |
| `results_received` | `models/service.rb` | When `results_received_at` set |
| `doctor_review_completed` | `models/service.rb` | When `doctor_outcome_finalised_at` set on service |
| `affiliate_request_created` | `models/appointment_request.rb` | `after_create` callback |
| `affiliate_accepted` | `models/appointment_request.rb` | `after_save` on status change |
| `affiliate_rejected` | `models/appointment_request.rb` | `after_save` on status change |
| `counter_offer_sent` | `models/appointment_request.rb` | `after_save` on status change |
| `counter_offer_accepted` | `models/appointment_request.rb` | `after_save` on status change |
| `counter_offer_rejected` | `models/appointment_request.rb` | `after_save` on status change |
| `medical_clearance_required` | `models/referral.rb` | When `requires_medical_clearance` → true |
| `medical_clearance_uploaded` | `models/referral.rb` | When `medical_clearance_received_at` set |
| `further_info_approved` | `controllers/client/referrals_controller.rb` (×2) | Client portal approval + re-review |
| `further_info_approved` | `controllers/doctor/reviews_controller.rb` | Auto-approve on doctor submission |
| `further_info_declined` | `controllers/client/referrals_controller.rb` | Client portal decline |
| `outcome_approved` | `services/outcome_approval_service.rb` | When admin approves held outcome |
| `employer_forms_incomplete` | `controllers/internal/referral_wizard_controller.rb` | Referral wizard completion |
| `employer_forms_incomplete` | `controllers/client/referral_wizard_controller.rb` | Client wizard with incomplete forms |
| `employer_forms_completed` | `controllers/client/employer_form_sessions_controller.rb` | All employer forms submitted |
| `reschedule_requested` | `controllers/candidate/reschedule_controller.rb` | Affiliate reschedule path |
| `results_sent_to_employer` | `services/notification_service.rb` | Recursive after results delivered |

---

## Gaps & Inconsistencies

### Events triggered in code but NOT in `TRIGGER_EVENTS` definition

These calls execute but produce **no notifications** — no `NotificationTrigger` records can be created for them because the model validates against `TRIGGER_EVENTS`:

| Event | Called From |
|---|---|
| `reschedule_approval_requested` | `candidate/reschedule_controller.rb` (lines 298, 422) |
| `reschedule_approved` | `models/reschedule_request.rb` |
| `reschedule_rejected` | `models/reschedule_request.rb` |
| `candidate_reminder` | `controllers/referrals_controller.rb` (manual reminder action) |
| `doctor_outcome_finalised` | `models/referral.rb` |
| `telehealth_requested` | `services/telehealth_service.rb` |
| `telehealth_scheduled` | `controllers/telehealth_bookings_controller.rb`, `candidate/telehealth_controller.rb` |

**Fix needed**: Add these 7 events to `NotificationTrigger::TRIGGER_EVENTS`.

### Events defined but never triggered (missing scheduled jobs)

| Event | What needs to happen |
|---|---|
| `appointment_reminder_24h` | Scheduled job checking appointments 24h ahead |
| `appointment_reminder_2h` | Scheduled job checking appointments 2h ahead |
| `booking_reminder` | Scheduled job for referrals without a booking |
| `form_reminder` | Scheduled job for incomplete forms |
| `affiliate_request_reminder` | Scheduled job for unanswered affiliate requests |
| `slot_released` | Trigger when appointment hold expires or booking cancelled |

---

## Conditions System

`NotificationTrigger.conditions` (jsonb) allows triggers to be conditional. Evaluated in `applies_to?`:

| Condition Key | Description |
|---|---|
| `appointment_scheduled` | Only if referral has a scheduled appointment |
| `no_show_to_appointment` | Only if appointment was a no-show |
| `rescheduled_appointment` | Only if this is a rescheduled appointment |
| `availability_submitted` | Only if candidate has submitted availability |
| `assessment` | Filter by assessment/service item type |
| `company` | Filter to specific company (also enforced via `company_id` FK) |
| `service_item` | Filter to specific service item |
| `assessment_variant` | Filter by service variation |

Internal services are excluded from certain events via `INTERNAL_EXCLUDED_EVENTS` — stops internal-only referrals from generating external notifications.

---

## Outcome Approval Interception

A special pre-delivery hook for `results_received` and `referral_completed` events:

1. `OutcomeApprovalService.check_and_intercept` evaluates rules against the referral
2. If a matching rule exists: creates a pending `OutcomeApproval` record, **skips** delivery to `results_to` recipients
3. Notifies approvers via `outcome_approval_required` and `outcome_approval_pending_updatee`
4. When the approver approves: `outcome_approved` fires and the held results are delivered

This means results can be held and reviewed before reaching the employer/client.

---

## Key Files

| Purpose | File |
|---|---|
| Trigger model & event definitions | `app/models/notification_trigger.rb` |
| Notification orchestrator | `app/services/notification_service.rb` |
| Email delivery | `app/services/azure_email/send.rb` |
| SMS delivery | `app/services/direct_sms/send.rb` |
| In-app notifications | `app/models/in_app_notification.rb` |
| Template rendering | `app/services/merge_fields/render.rb` |
| Notification log | `app/models/notification_log.rb` |
| Outcome approval interception | `app/services/outcome_approval_service.rb` |
| Admin trigger management | `app/controllers/admin/notification_triggers_controller.rb` |
