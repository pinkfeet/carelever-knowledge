# Assessment — Background Jobs (Sidekiq)

All long-running or deferrable work in `carelever_assessment` runs through Sidekiq (ActiveJob adapter), per [`BUILD_RULES.md`](../../carelever_assessment/BUILD_RULES.md) §3–4. Jobs live in `app/jobs/`; scheduled jobs are registered via `sidekiq-cron` in `config/sidekiq_schedule.yml` (loaded from `config/initializers/sidekiq.rb`).

Repo: [`carelever_assessment`](../../carelever_assessment/)

---

## Queue setup (`config/sidekiq.yml`)

Single Sidekiq process, **5 threads**, queues processed in priority order:

| Queue | Purpose |
|---|---|
| `default` | All standard work — crons, exports, dashboards, notifications |
| `pdf_extraction` | Long-running AWS Bedrock calls (up to 480s per job, CT-4645). Carved out so PDF/AI work can't starve the 5-thread pool; the split is the prerequisite for a dedicated process (`sidekiq -q pdf_extraction -c 2`) once volume warrants |
| `mailers` | ActionMailer `deliver_later` |

`ApplicationJob` defines no base retry/discard behaviour — each job declares its own strategy.

---

## Cron schedule (`config/sidekiq_schedule.yml`)

| Job | Frequency | Purpose |
|---|---|---|
| `AppointmentHoldCleanupJob` | Every 5 min | Expire stale appointment holds so they stop blocking slots |
| `Referrals::ReconcileStuckResultExtractionsJob` | Every 5 min | Watchdog for stuck AI result extractions (CT-5382) |
| `ClinicCalendarDashboardRefreshJob` | Every 15 min | Rebuild KINNECT clinic calendar dashboard snapshot |
| `ProcessDueNudgesJob` | Every 15 min | Enqueue delivery for nudges whose `scheduled_for` has elapsed |
| `EvaluateNudgesJob` | Every 15 min | Evaluate active referrals, schedule reminder nudges |
| `OperationsDashboardRefreshJob` | Every 30 min | Warm the default (unfiltered) operations dashboard snapshot |
| `FlagOverdueConfirmedAppointmentsJob` | Hourly | Flag confirmed appointments unattended >3h past start (signals) |
| `AffiliateResponseReminderJob` | Hourly | Remind clinics about booking requests pending >24h |
| `BillNonAttendedActionFeesJob` | Daily 22:00 Brisbane | Bill due no-show / late-cancel / reschedule action fees |

---

## Jobs by functional area

### Referral completion & doctor review

**`AutoFinalizeDoctorOutcomeJob`** — `default`
Finalises a doctor review when the 5-minute grace period expires (`V1::Internal::DoctorReviews::Update::GRACE_PERIOD_DURATION`). Stamps `doctor_outcome_finalised_at`, completes services, runs `Referrals::CompleteBill`, then dispatches `referral_completed` / `doctor_review_completed` notifications. Billing failure parks the referral in "Bill Customer" without the completion notification. Idempotent — re-entry resumes billing/notification from a prior partial run.
*Enqueued*: `V1::Internal::DoctorReviews::Update` with `set(wait: grace period + 10s)` when the doctor first submits an outcome.

**`GracePeriodExpiringNotificationJob`** — `default`
Warns the assigned doctor 1 minute before the grace period expires that the review will auto-finalise. Currently a stub (notification surface TODO); scheduling wiring is in place.
*Enqueued*: same command as above, `set(wait: grace period − 1min)`.

### AI / document processing (Bedrock — `pdf_extraction` queue)

**`Referrals::ExtractResultDocumentJob`**
Extracts form-field data from an uploaded result document via `Ai::ResultDocumentExtractor` (Bedrock vision, up to 120s); persists `extracted_data` JSONB on the `CandidateDocument`. Idempotent — no-ops unless `ai_extraction_status='pending'`. Marks `skipped` on missing service/Bedrock config, `failed` on extraction failure. Retries 3× polynomial; exhaustion marks failed.
*Enqueued*: `V1::Internal::Referrals::ResultDocuments::Create` on upload; re-enqueued by the reconcile watchdog.

**`Referrals::ReconcileStuckResultExtractionsJob`** — `default`, cron every 5 min
Watchdog (CT-5382, recovers jobs lost to deploys/OOM): pending extractions 10–30 min old are re-enqueued; older than 30 min are marked failed ("timed out") so the frontend stops polling.

**`Referrals::RunMedicalClearanceReviewJob`**
Runs the AI medical clearance review (`referral.run_ai_clearance_review!`), updating `ai_clearance_recommendation` / `ai_clearance_evidence` / `ai_clearance_status`. Skips if clearance is no longer required. Handled failures mark `failed` without retry; raised errors retry 3×.
*Enqueued*: "Run AI Review" command (`V1::Internal::Referrals::MedicalClearanceReview::RunReview`) and on clearance-document upload via `Referral#require_medical_clearance_review!`.

**`Referrals::DeliverResultsJob`**
Generates result PDFs (one per assessment plus the sign-off report) and delivers them to the candidate via `Referrals::DeliverResults`, which uses an idempotent delivery claim with stale-claim recovery for dead workers. On `pdf_extraction` so multi-PDF generation doesn't starve `default`. Retries 3×.
*Enqueued*: `Notifications::Dispatch.referral_completed` (after-commit) and `V1::Client::OutcomeApprovals::Approve`.

**`Forms::ExtractPdfFormAnalysisJob`**
Bedrock PDF form-structure extraction (up to 480s, CT-4645) via `Ai::PdfFormExtractor`; marks the `PdfImportAnalysis` row succeeded/failed while the frontend polls. Retries 3×; exhaustion marks failed.
*Enqueued*: `V1::Settings::FormElements::PdfImports::Create` when an admin uploads a PDF for analysis.

### Nudges & reminders

**`EvaluateNudgesJob`** — cron every 15 min
Runs `Nudges::EvaluateAndSchedule` per active referral: booking reminder (24h), form reminder (12h), appointment reminders (0h and 2h variants), employer form reminder. Per-referral failures are isolated.

**`ProcessDueNudgesJob`** — cron every 15 min
Finds `Nudge.pending_delivery` past `scheduled_for` and fans out one `DeliverNudgeJob` each.

**`DeliverNudgeJob`** — retry 3
Delivers a single nudge (email/SMS) via `Nudges::Deliver`.

**`AffiliateResponseReminderJob`** — cron hourly
CT-5088: one-time `affiliate_request_reminder` to clinics for `AppointmentRequest`s pending (not counter-offered) >24h. Atomic claim on `response_reminder_sent_at` gives at-most-once semantics (a duplicate clinic reminder is worse than a rare miss).

### Dashboards & snapshots

All three use the snapshot pattern: compute into a persisted snapshot row, with distributed work-claiming (atomic status transitions + lease-based stale detection) so concurrent workers don't double-compute.

**`OperationsDashboardRefreshJob`** — cron every 30 min (default snapshot) *and* on-demand for filtered views (`V1::Internal::OperationsDashboard::Show`/`Refresh`). Retries 5×; exhaustion marks snapshot `failed`.

**`ClinicCalendarDashboardRefreshJob`** — cron every 15 min. Rebuilds the KINNECT clinic calendar snapshot (availability, utilisation, demand) via `V1::Internal::ClinicCalendar::ComputeDashboardPayload`.

**`InsightsSnapshotRefreshJob`** — on-demand from `V1::Client::Insights::Show` when a refresh is needed. Retries 5×; exhaustion marks snapshot `failed`.

### Report exports

All three follow BUILD_RULES §4.1: user requests an export → command creates a `ReportExport` row → job claims it atomically (`requested`→`processing`), generates the file, marks `completed`/`failed` — the frontend polls the export record.

| Job | Source command | Output |
|---|---|---|
| `HealthMonitoringCsvExportJob` | `V1::Client::HealthMonitoring::CreateCsvExport` | CSV |
| `InsightsExportJob` (retry 5×, lease recovery) | `V1::Client::Insights::CreateCsvExport` / `CreatePdfExport` | CSV or PDF |
| `ReportBuilderCsvExportJob` (lease recovery) | `V1::Settings::Reports::CreateCsvExport` | CSV |

### Appointments & billing

**`AppointmentHoldCleanupJob`** — cron every 5 min. `AppointmentHold.cleanup_expired!` releases expired holds.

**`FlagOverdueConfirmedAppointmentsJob`** — cron hourly. `Signals::ConfirmedAppointmentOverdue` flags confirmed appointments still unattended >3h past scheduled start; the signals system drives notifications from there.

**`BillNonAttendedActionFeesJob`** — cron daily 22:00 Brisbane. Bills unbilled action-fee line items (no-show / late-cancel / rescheduled) via `Billing::CompleteNonAttendedItems` per referral; 12h-age and weekend guards live in the orchestrator. Per-referral rescue so one bad referral doesn't block the batch.

**`Automation::EvaluateRulesJob`** — enqueued on form completion (candidate and internal `FormSessions::Complete`) via `enqueue_for(referral_id)`. Async because rule evaluation can hit Stripe/CLB. Uses `enqueue_after_transaction_commit = true` — discarded if the form-completion transaction rolls back; synchronous in tests.

### Users & data sync

**`Users::AssociateClinicJob`** — applies a user↔clinic (Supplier) association once the user row has been mirrored from the Auth service (arrives asynchronously over SNS, so it may not exist when the admin saves). Retries `UserNotMirrored` up to 10×; discards `RecordNotFound` (supplier deleted in the meantime).
*Enqueued*: `V1::Settings::Users::Clinic::Update` create flow.

**`DataSync::Users::ApplyReassignmentsJob`** — applies reassignment side-effects (referrals, appointments → replacement users) when a user is deactivated, from `DataSync::Users::Sync`. `enqueue_after_transaction_commit = true` so the mirrored User row is committed first. Retries 5×; on exhaustion writes a `SyncLog` row (`ApplyReassignmentsJob:` receipt prefix) so operators can find partially-deactivated users.

### Forms & settings

**`FormElementUpdateSessionsJob`** — writes a single `form_element_sessions_updated` audit row (counts of updated vs preserved sessions) when an admin confirms a structural `FormElement` change. Takes scalar counts, not session IDs, to keep Redis payloads small; `job_id` stored in audit metadata guards against retry duplication.

**`EmailBranding::RegenerateMessageTemplatesJob`** — re-renders stored `body_html` on all builder-mode `MessageTemplate`s from current `EmailBrandSettings` when branding is saved (`V1::Settings::EmailBranding::Update`). Skips legacy templates and unchanged HTML; per-template errors don't abort the batch.

---

## Mailers (`mailers` queue)

**`CandidateOtpMailer#code_email`** — sends the 6-digit OTP for candidate email login; always `deliver_later` from `V1::Candidate::Sessions::RequestOtp`.

---

## Recurring patterns worth copying

- **Snapshot + distributed claim** (dashboards): atomic status transition to claim work, lease timestamp to detect and reclaim dead workers, `failed` status on retry exhaustion.
- **Export record polling** (exports): job never returns data to the request; frontend polls the `ReportExport` row.
- **Watchdog cron** (result extractions): a cheap 5-min cron that re-enqueues or fails stuck async work, protecting against jobs lost to deploys/OOM.
- **`enqueue_after_transaction_commit = true`** wherever the job depends on rows written in the surrounding transaction.
- **At-most-once via atomic timestamp claim** (affiliate reminders) when duplicate side-effects are worse than a missed run.
- **Grace-period delayed jobs** (`set(wait: …)`) for auto-finalisation flows.
