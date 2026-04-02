# SNS, SQS, and Lambda Data Sync Architecture

Date: 2026-03-30

## Overview

Carelever uses an event-driven architecture to keep data consistent across microservices. When a model changes in one service, the change propagates to all interested services via SNS, SQS, and a scheduled Lambda.

## Architecture Flow

Services are triggered to poll their SQS queues by **two mechanisms**:

1. **SNS HTTPS subscription** — immediate wake-up webhook on each publish (real-time)
2. **Scheduled Lambda** — EventBridge fires every 1 minute as a sweep/safety net

SNS also delivers the message to each service's **SQS queue** for storage.

```
                                  ┌── HTTPS POST ──→ /v1/screen/data_sync_recipients ─┐
                                  │                                                    │
┌─────────────┐    ┌───────────┐  │                                                    ▼
│ Model Change │───→│ SNS Topic │──┤                                          DataSync::Fetch.call()
└─────────────┘    └───────────┘  │                                                    ▲
                                  │                                                    │
                                  └── SQS ──→ screen_data_sync_receiver_queue          │
                                                                                       │
┌──────────────────┐    ┌─────────────────────────────┐                                │
│ EventBridge      │───→│ Lambda: data_sync_notifier  │── HTTP POST to all endpoints ──┘
│ rate(1 minute)   │    │ (sweep/safety net)          │
└──────────────────┘    └─────────────────────────────┘
```

This ensures near-real-time sync via SNS, with the Lambda sweep guaranteeing no messages sit unprocessed for more than ~1 minute if a webhook delivery fails.

### Why Two Triggers?

| Trigger                | Mechanism                            | Timing         | Purpose               |
| ---------------------- | ------------------------------------ | -------------- | --------------------- |
| SNS HTTPS subscription | SNS delivers webhook on each publish | Immediate      | Real-time sync        |
| Lambda via EventBridge | Scheduled HTTP POST to all endpoints | Every 1 minute | Catch missed webhooks |

The Lambda sweep handles edge cases where the SNS HTTPS delivery fails (network blip, service restarting, temporary downtime).

## SNS Topic Subscribers (Dev Environment)

All subscribed to `development_carelever_data_sync_publisher`:

### HTTPS Endpoints (Wake-Up Webhooks)

| Host                               | Endpoint                                  |
| ---------------------------------- | ----------------------------------------- |
| `api.dev.carelever.com`            | `/v1/screen/data_sync_recipients`         |
|                                    | `/v1/monitor/data_sync_recipients`        |
|                                    | `/v1/manage/data_sync_recipients`         |
|                                    | `/v1/company/data_sync_recipients`        |
|                                    | `/v1/authentication/data_sync_recipients` |
|                                    | `/v1/calendar/data_sync_recipients`       |
| `comply-api.dev.carelever.com`     | `/v1/data_sync_recipients`                |
| `form-api.dev.carelever.com`       | `/v1/data_sync_recipients`                |
| `hub-manage-api.dev.carelever.com` | `/v1/data_sync_recipients`                |

### SQS Queues (Message Storage)

All in account `862999456217`, region `ap-southeast-2`:

| Queue                                                           |
| --------------------------------------------------------------- |
| `development_carelever_screen_data_sync_receiver_queue`         |
| `development_carelever_monitor_data_sync_receiver_queue`        |
| `development_carelever_manage_data_sync_receiver_queue`         |
| `development_carelever_company_data_sync_receiver_queue`        |
| `development_carelever_authentication_data_sync_receiver_queue` |
| `development_carelever_calendar_data_sync_receiver_queue`       |
| `development_carelever_comply_data_sync_receiver_queue`         |
| `development_carelever_form_data_sync_receiver_queue`           |
| `development_carelever_hub_manage_data_sync_receiver_queue`     |

## Components

### 1. AwsWrapper::Syncable (Publisher)

Models include the `AwsWrapper::Syncable` mixin from the custom `aws_wrapper` gem. On `after_commit`, the gem publishes a message to the central SNS topic.

Each model defines which services care about its changes:

```ruby
class User < ApplicationRecord
  include AwsWrapper::Syncable

  def microservices
    ['manage', 'monitor', 'screen', 'calendar'] if user_consultant?
  end
end
```

The published message includes: model_name, model_data, activerecord_action (create/update/destroy), organisation_id, and the target microservices array.

### Message JSON Formats

#### Layer 1: SNS Publish Payload (what AwsWrapper publishes)

```json
{
  "activerecord_action": "update",
  "model_name": "Company",
  "model_data": {
    "id": "123e4567-e89b-12d3-a456-426614174000",
    "name": "Acme Corp",
    "screen_notes": "Preferred client",
    "screen_billing_preference": "monthly",
    "created_at": "2025-01-15T10:30:00Z",
    "updated_at": "2026-03-30T10:30:00Z"
  },
  "organisation_id": "org-uuid-123",
  "microservices": [
    "CareleverAuthentication",
    "CareleverScreening",
    "manage",
    "monitor"
  ]
}
```

#### Layer 2: SQS Message Body (SNS wraps the payload in an envelope)

When SNS delivers to SQS, AWS wraps it in an SNS notification envelope. The `Message` field contains the Layer 1 payload as an escaped JSON string:

```json
{
  "Type": "Notification",
  "MessageId": "12345678-1234-1234-1234-123456789012",
  "TopicArn": "arn:aws:sns:ap-southeast-2:862999456217:development_carelever_data_sync_publisher",
  "Message": "{\"activerecord_action\":\"update\",\"model_name\":\"Company\",\"model_data\":{\"id\":\"123e4567...\",\"name\":\"Acme Corp\",...},\"organisation_id\":\"org-uuid-123\",\"microservices\":[...]}",
  "Timestamp": "2026-03-30T10:30:00.000Z",
  "SignatureVersion": "1",
  "Signature": "...",
  "SigningCertUrl": "https://sns.amazonaws.com/...",
  "UnsubscribeUrl": "https://sns.amazonaws.com/..."
}
```

#### Parsing in DataSync::Fetch (double JSON.parse)

```ruby
# message.body is the SQS message body (Layer 2 string)
# JSON.parse(message.body) → Layer 2 hash (SNS envelope)
# ['Message'] → Layer 1 as escaped string
# JSON.parse(...) → Layer 1 hash (event_data)
event_data = JSON.parse JSON.parse(message.body)['Message']
```

#### Appointment Event Payload (separate SNS topic)

Published by Screen and Monitoring services to `{env}_carelever_appointment_event_topic`:

```json
{
  "sqs_queue_url": "https://sqs.ap-southeast-2.amazonaws.com/862999456217/appointment-queue",
  "appointment_id": "appt-uuid-123",
  "appointment_created_at": "2026-03-15T09:00:00Z",
  "appointment_updated_at": "2026-03-30T10:30:00Z",
  "start_time": "2026-04-05T14:00:00Z",
  "end_time": "2026-04-05T15:30:00Z",
  "referral_id": "ref-uuid-456",
  "client_name": "John Doe",
  "organisation_id": "org-uuid-123",
  "location_id": "loc-uuid-789",
  "location_timezone": "Brisbane",
  "location_name": "Brisbane Head Office",
  "consultant_person_id": "consultant-uuid-111",
  "consultant_person_name": "Jane Smith",
  "consultant_person_email": "jane.smith@example.com",
  "master_service": "carelever_screen",
  "model": "Sns::PublishAppointment",
  "activerecord_action": "create",
  "status": "scheduled",
  "additional_data": {
    "screening_items": ["Item 1", "Item 2"]
  }
}
```

Major publishers:

- **Authentication**: User, Company, Location, Site, CompanyServiceRestriction, UserComplySubscription, ManagerialRole, ServiceArea, and others.
- **Organisation**: Company, Location, State, Country, CompanySubscription, CompanyMicroSubscription, CompanyPartnerAccess, OrganisationModuleAccess, PreApprovalTag, and others.
- **Screen**: Referral, Appointment, Person, CompanyLog, ReferralKpiInsightsDuration.
- **Monitoring**: Referral, Appointment, Person, MonitoringItemDetail, TestItemDetail.

### 2. SNS Topic

**Topic name**: `{env}_carelever_data_sync_publisher`

Central fan-out topic. All model sync events are published here. SNS delivers each message to all HTTPS and SQS subscribers simultaneously.

**Appointment event topic**: `{env}_carelever_appointment_event_topic`

Separate topic for appointment-specific events published by Screen and Monitoring services, consumed by Calendar via `/v1/calendar/sns_appointment_events`.

### 3. Data Sync Recipients Controller (Receiver)

Each microservice exposes a `data_sync_recipients` endpoint that handles the SNS HTTPS subscription:

- If `Type == 'SubscriptionConfirmation'`: confirms the SNS subscription.
- If `Type == 'Notification'`: triggers `DataSync::Fetch.call()` to poll SQS.

The HTTPS endpoint acts purely as a wake-up signal. The actual message data comes from SQS, not the webhook body. This is because the Rails services don't have persistent SQS listeners — they only fetch from the queue when told to.

Controller locations:

- `carelever_authentication`: `/v1/authentication/data_sync_recipients`
- `carelever_company`: `/v1/company/data_sync_recipients`
- `carelever_screen`: `/v1/screen/data_sync_recipients`
- `carelever_monitoring`: `/v1/monitor/data_sync_recipients`
- `carelever_hub_manage`: `/v1/data_sync_recipients` (via `hub-manage-api` host)
- `carelever_calendar`: `/v1/calendar/data_sync_recipients`
- `comply`: `/v1/data_sync_recipients` (via `comply-api` host)
- `form`: `/v1/data_sync_recipients` (via `form-api` host)

### 4. DataSync::Fetch (SQS Processor)

Each service's `DataSync::Fetch` command:

1. Polls up to 10 messages from SQS (single batch, no loop — does not drain the queue).
2. Checks for data staleness (skips if local record's `updated_at` is newer).
3. Routes to the correct processor via `ModelFactory`.
4. The processor creates, updates, or soft-deletes the local record.
5. Deletes the SQS message after processing.

Multi-tenancy is handled by switching tenant: `Apartment::Tenant.switch!(organisation_id)`.

#### Error Handling

Error handling differs significantly between services:

**Screen, Authentication, Monitoring, Company (simple):**

```ruby
rescue StandardError => exception
  create_sync_log(message, exception)   # log to DB
  sqs_client.delete_message(...)        # delete from queue anyway
```

On any error: logs a `sync_log` record, then deletes the message. The data sync is lost — no retry.

**Hub Manage (retry-aware):**

Distinguishes between retryable and permanent errors:

| Error Type | Examples                                                                                                   | Action                               |
| ---------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| Retryable  | `ActiveRecord::InvalidForeignKey`, `PG::ForeignKeyViolation`, `RecordNotFound`, FK-related `RecordInvalid` | Leaves message in SQS for redelivery |
| Permanent  | All other errors                                                                                           | Deletes message                      |

This handles out-of-order delivery (e.g. `Site` arrives before its parent `Company`).

#### No Infinite Loop Protection

There is no retry limit at any level:

- **Application code**: No retry counter or max attempts in `DataSync::Fetch`.
- **SQS queue configuration**: No dead-letter queue (DLQ) configured. No `maxReceiveCount` / redrive policy set.
- **Only safety net**: SQS message retention period of **4 days**. A stuck retryable message in Hub Manage would retry every ~1 minute (via Lambda sweep) for up to ~5,760 attempts before SQS auto-expires it.

SQS queue settings (observed on `development_carelever_screen_data_sync_receiver_queue`):

| Setting                    | Value                                        |
| -------------------------- | -------------------------------------------- |
| Type                       | Standard (not FIFO — no ordering guarantees) |
| Dead-letter queue          | None                                         |
| Redrive allow policy       | None                                         |
| Message retention period   | 4 days                                       |
| Default visibility timeout | 30 seconds                                   |
| Encryption                 | Disabled                                     |
| Maximum message size       | 256 KiB                                      |

#### Error Handling Summary

```
Message fails processing
        │
        ├── Screen, Auth, Monitor, Company:
        │       Log error → Delete message → Gone forever
        │
        └── Hub Manage:
                ├── Retryable error (FK violation):
                │       Log warning → Leave in queue → Retry up to ~5,760 times over 4 days
                │
                └── Permanent error:
                        Log error → Delete message → Gone forever
```

### 5. Sync Processors (Model Handlers)

Each service has processors under `app/commands/data_sync/` that extend `BaseSync`:

```ruby
class DataSync::Companies::Sync < DataSync::BaseSync
  def model_class = Company
  def create_or_update_class = DataSync::Companies::CreateOrUpdate
  def destroy_class = DataSync::Companies::Discard
end
```

`BaseSync` routes based on `activerecord_action`: create/update calls `CreateOrUpdate`, destroy calls `Discard`.

### 6. Lambda: data_sync_notifier (Scheduled Sweep)

**Function**: `development_data_sync_notifier`
**Trigger**: EventBridge rule `development_carelever_data_sync_scheduled_notification_event`
**Schedule**: `rate(1 minute)`
**Application**: `carelever-development-08-03-Calendar-Data-Sync`

The Lambda runs every minute and sends HTTP POST requests to all service `data_sync_recipients` endpoints with `Type: 'Notification'` and an `aws_access_key` param. This triggers each service to poll its SQS queue.

It acts as a reliability safety net alongside the SNS HTTPS subscriptions, ensuring no messages get stuck in SQS if a real-time webhook delivery fails.

## Services and Hosts

| Host                                 | Services                                                   |
| ------------------------------------ | ---------------------------------------------------------- |
| `api.{env}.carelever.com`            | Authentication, Company, Screen, Monitor, Manage, Calendar |
| `comply-api.{env}.carelever.com`     | Comply                                                     |
| `form-api.{env}.carelever.com`       | Form                                                       |
| `hub-manage-api.{env}.carelever.com` | Hub Manage                                                 |

## AWS Configuration

Each service stores AWS config in `config/aws_config.yml` with:

- `aws_access_key` / `aws_secret_access_key`
- `aws_default_region`: `ap-southeast-2`
- `sns_topic_arn_data_sync_publisher`
- `data_sync_receiver_queue`
- `sns_topic_arn_appointment_event` (Screen and Monitoring only)
- `sqs_url_appointment_event` (Screen and Monitoring only)

## Why Both HTTPS and SQS Subscriptions?

The Rails services don't have persistent SQS listeners (unlike Azure Service Bus subscribers which are always-on). Messages would sit in SQS indefinitely without something triggering a fetch.

The dual-subscription pattern solves this:

- **SQS** stores the message reliably (with retry, dead-letter queue support)
- **HTTPS** wakes up the service to poll its queue immediately

This avoids the cost of always-running background consumers while still providing near-real-time sync.

## Key Design Decisions

- **SNS native fan-out**: SNS delivers to all HTTPS and SQS subscribers simultaneously.
- **Dual trigger reliability**: Real-time SNS webhooks for immediate sync + scheduled Lambda sweep every minute as a safety net.
- **Pull model**: Services pull from their own SQS queues rather than processing data from the webhook body. This decouples processing from notification delivery.
- **Staleness prevention**: Each service compares `updated_at` before applying changes to avoid overwriting newer data with older events.
- **Tenant isolation**: All processing switches Apartment tenant by `organisation_id` before touching the database.
- **Dedicated queues**: Each service processes independently, preventing cascading failures.

## Example: Company Name Update Flow

When an internal user updates a company name via the internal UI, this is the full end-to-end flow:

### Step 1: Internal UI → Organisation Service

The Angular internal UI sends a request to the Organisation service (the source of truth for company data):

```
PUT https://api.{env}.carelever.com/v1/organisation/settings/companies/:id
Body: { "name": "New Company Name" }
```

### Step 2: Organisation Updates and Publishes

Controller: `V1::Organisation::Settings::CompaniesController#update`
Command: `Manager::Companies::Update`

```ruby
def call
  Company.transaction do
    company.update!(params)                              # 1. Save to Organisation DB
    create_or_update_comply_user_subscription_price       # 2. Handle related records
    create_company_log(company)                           # 3. Log who changed what
    company
  end
end
# after_commit fires → AwsWrapper::Syncable → publish_sns('update')
```

### Step 3: SNS Publishes to All Subscribers

Organisation's Company model has `include AwsWrapper::Syncable`, so `after_commit` publishes the full record to SNS topic `{env}_carelever_data_sync_publisher`.

### Step 4: Each Service Receives and Updates Locally

Example for Screen:

```
SNS → SQS (screen_data_sync_receiver_queue)
    → SNS HTTPS webhook hits /v1/screen/data_sync_recipients
    → DataSync::Receive → DataSync::Fetch (polls SQS, up to 10 messages)
    → ModelFactory routes "Company" → Companies::Sync
    → Companies::CreateOrUpdate → company.update!(params)
```

Screen's `Companies::Sync` maps Organisation's field names to Screen's local columns:

```ruby
result = model_data.slice(*Company.column_names)    # take only columns Screen has
result['notes']              = model_data['screen_notes']
result['billing_preference'] = model_data['screen_billing_preference']
result['is_preferred']       = model_data['preferred_screen']
result['tier']               = model_data['screen_tier']
```

### Step 5: No Loop Back

Screen's local Company model does **not** include `AwsWrapper::Syncable`, so updating it does not trigger another SNS publish. The chain stops here.

### Visual Summary

```
Internal UI (Angular)
    │
    ▼
PUT /v1/organisation/settings/companies/:id
    │
    ▼
carelever_organisation
    ├── company.update!(name: "New Name")
    ├── create_company_log(company)
    │
    ▼  after_commit → AwsWrapper::Syncable
    │
SNS: data_sync_publisher  (full company record as JSON)
    │
    ├──→ screen_queue   → Screen:  Companies::CreateOrUpdate → local update (no Syncable, stops here)
    ├──→ monitor_queue  → Monitor: Companies::CreateOrUpdate → local update (no Syncable, stops here)
    ├──→ manage_queue   → Manage:  local update
    ├──→ auth_queue     → Auth:    local update
    ├──→ company_queue  → Company: local update
    ├──→ calendar_queue → Calendar: local update
    ├──→ comply_queue   → Comply:  local update
    ├──→ form_queue     → Form:    local update
    └──→ hub_manage_queue → Hub Manage: local update
```

### Data Ownership Model

Organisation is the **single source of truth** for company data. All services receive copies. Even service-specific fields (e.g. `screen_notes`, `monitor_tier`) are stored in Organisation and synced down:

| Owner | Fields | Updated via |
|-------|--------|-------------|
| Organisation | All company fields (name, address, service flags, per-service notes/tiers/billing) | Internal UI → Organisation API |
| Screen, Monitor, etc. | Local copies of relevant columns only | Data sync from Organisation (read-only) |

Services that receive Company data do have API write endpoints (e.g. `POST /v1/screen/companies`), but these use the same `CreateOrUpdate` command as data sync. Local-only changes would be **overwritten** on the next sync from Organisation.

## Check the existing model

`app/commands/data_sync/model_factory.rb`
