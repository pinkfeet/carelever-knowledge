# Referral History Tab — Replit App

> **Source**: `carelever-replit-reimagined`  
> **Last updated**: 2026-06-17  
> **Related**: [`notification/replit-notification-trigger-system.md`](../notification/replit-notification-trigger-system.md)

How the referral **History** tab builds its unified activity feed and how **email/SMS** entries show summary vs full message content.

---

## Overview

The History tab (`history` on referral show) is a server-rendered ERB partial — not a separate API. It merges four data sources into one chronological table (newest first, capped at 50 rows per source).

| Source | Controller ivar | Row type | Filter key |
|---|---|---|---|
| Timeline events | `@timeline_entries` | `:timeline` | `system` |
| Referral activities | `@activities` | `:activity` | `activity` / `voice_call` |
| Notes (unpinned) | `@unpinned_notes` | `:note` | `note` |
| **Notification logs** | `@notification_logs` | `:communication` | `communication` |

Pinned notes render in a separate section above the table (`@pinned_notes`).

**Internal portal**: `app/views/referrals/_tab_history.html.erb`  
**Client portal**: `app/views/client/referrals/_tab_history.html.erb` (same modal pattern, timeline layout differs)

---

## Data loading

When the user selects the History tab, `ReferralsController#load_show_history_data` runs:

```ruby
@timeline_entries = ReferralTimelineService.new(@referral).call
@activities       = @referral.referral_activities.includes(:user).recent.limit(50)
@pinned_notes     = @referral.referral_notes.includes(:user).pinned
@unpinned_notes   = @referral.referral_notes.includes(:user).unpinned.limit(50)
@notification_logs = @referral.notification_logs.recent.limit(50)
```

The partial builds `all_items` by appending each source with a `time` key, then `sort_by { |i| i[:time] }.reverse!`.

Exclusions:

- Timeline entries titled `"Appointment Intent Recorded"` are hidden.
- Activities with `activity_type == 'referral_created'` are excluded from the feed.

---

## Email/SMS data model

Each notification is stored in `notification_logs` when `NotificationService` sends (or skips in dev):

| Column | Purpose |
|---|---|
| `channel` | `email` or `sms` |
| `trigger_event` | Event key (e.g. `appointment_booked`) |
| `recipient_type` | `candidate`, `employer`, `clinic`, etc. |
| `recipient_name`, `recipient_email`, `recipient_phone` | Delivery target |
| `subject` | Email subject (usually blank for SMS) |
| `rendered_body` | **Full message text after merge-field rendering** |
| `status` | `pending`, `sent`, `failed`, `dev_mode_skipped` |
| `error_message` | Set when delivery fails |
| `context_data` | jsonb merge context used at send time |

The body is rendered once at send time via `MergeFields::Render` and persisted — the History tab does **not** re-render templates on page load.

See [`notification/replit-notification-trigger-system.md`](../notification/replit-notification-trigger-system.md) for the full send pipeline.

---

## List row (summary)

Communication rows (`entry[:type] == :communication`) display:

| Column | Content |
|---|---|
| **Type** | `Email` (purple) or `SMS` (green) badge + icon |
| **Description** | `trigger_event_label` + `" — #{subject}"` if subject present; status badge below (`Sent`, `Pending`, `Failed`, `Development Mode (Not Sent)`) |
| **User** | `"#{recipient_type_label} · #{recipient_name \|\| recipient_email \|\| recipient_phone}"` |
| **Date** | `created_at` formatted as `1 Jan 2026 at 3:45 PM` |

Label helpers live on `NotificationLog`:

- `trigger_event_label` → human name from `NotificationTrigger::TRIGGER_EVENTS`
- `recipient_type_label` → from `NotificationTrigger::RECIPIENT_TYPE_LABELS`
- `status_label` / `status_color` → mapped from `status`

Rows are **clickable** (`cursor-pointer`) and call `openNotificationModal(index)`.

---

## Detail modal (full content)

Full email/SMS content is **not** inline in the table. Clicking a communication row opens a modal populated from JSON embedded in the page:

```javascript
var notificationData = [ /* one object per @notification_log */ {
  event, status, statusColor, channel, channelType,
  recipientType, recipientName, recipientEmail, recipientPhone,
  subject, body,  // body = log.rendered_body
  error, date
} ];
```

Modal sections:

| Section | Shown when | Source |
|---|---|---|
| Header | Always | Event label + status |
| Recipient / Channel / Sent To / Date | Always | Recipient type, channel label, email or phone, formatted date |
| Subject | `subject` present | Email only in practice |
| Message Content | `body` present | `rendered_body` via `textContent` (plain text, not HTML) |
| Error Details | `error_message` present | Failed sends |

Modal index is `@notification_logs.index(entry[:item])` — index into the **notification_logs collection**, not the unified `all_items` list.

---

## Duplicate activity rows

`NotificationService` also writes a `ReferralActivity` after a successful send:

- `activity_type`: `email_sent` or `sms_sent`
- `description`: e.g. `"Email sent to Jane Doe — Appointment Booked (Template Name)"`
- `metadata`: includes `notification_log_id`, `channel`, `trigger_event`, recipient contact

This appears as a separate **Activity** row in the same feed. Only the **Communication** row (from `notification_logs`) is clickable and shows the full message in the modal.

---

## Other entry types (brief)

| Type | Expandable detail |
|---|---|
| **Note** | Rich text in table; pin/unpin actions (internal only) |
| **System Event** | `"Request Created"` has inline expandable request metadata |
| **Activity — voice call** | Expandable collected data + transcript from `VoiceCallLog` |
| **Activity — availability** | Renders `shared/availability_window_details` partial |

---

## Port status — `carelever_assessment` / UI

As of 2026-06-17, the ported Angular History tab (`carelever_assessment_ui` → `history-tab.component`) loads **referral activities only** via API. It does not yet:

- Merge notes, timeline events, or `notification_logs`
- Expose type `communication` or filter for it
- Provide a detail modal/panel for full email/SMS body

To port Replit behaviour, the backend needs a notification-log (or unified history) endpoint returning at minimum:

`id`, `channel`, `trigger_event` (or label), `recipient_type`, `recipient_name`, `recipient_email`, `recipient_phone`, `subject`, `rendered_body`, `status`, `error_message`, `created_at`

---

## Key files

| Purpose | File |
|---|---|
| History tab partial (internal) | `app/views/referrals/_tab_history.html.erb` |
| History tab partial (client) | `app/views/client/referrals/_tab_history.html.erb` |
| Tab data loader | `app/controllers/referrals_controller.rb` → `load_show_history_data` |
| Notification log model | `app/models/notification_log.rb` |
| Log creation + delivery | `app/services/notification_service.rb` |
| Activity side-effect of send | `NotificationService#log_notification_activity` |
