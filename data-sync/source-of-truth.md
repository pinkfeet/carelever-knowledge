# Data Model Source of Truth

Date: 2026-03-30

## Overview

Each data model has a single source of truth — the service that owns the data, stores the master copy, and publishes changes via SNS. Other services receive read-only copies via data sync.

The source of truth is identified by: the model has `include AwsWrapper::Syncable` and defines a `microservices` method.

## Source of Truth by Domain

### Organisation Service — Master Data

Organisation owns company-level configuration and reference data. All other services receive copies.

| Model                       | Syncs To                                                                  |
| --------------------------- | ------------------------------------------------------------------------- |
| Company                     | company, authentication, form, + conditional manage/monitor/screen/comply |
| Location                    | screen, monitor, authentication, manage, calendar                         |
| State                       | manage                                                                    |
| Country                     | manage                                                                    |
| CompanyServiceRestriction   | authentication                                                            |
| CompanyPartnerAccess        | company, authentication, + conditional screen/monitor/manage/comply       |
| PreApprovalTag              | monitor, screen                                                           |
| ComplyUserSubscriptionPrice | authentication                                                            |
| CompanySubscription         | authentication, monitor, form, manage                                     |
| CompanyMicroSubscription    | authentication, screen, monitor, manage, form                             |
| NetsuiteLocation            | screen, monitor, manage                                                   |
| OrganisationModuleAccess    | company, manage                                                           |
| CompanyLog                  | company                                                                   |

### Authentication Service — User Identity and Permissions

Authentication owns user accounts, credentials, roles, and access.

| Model                             | Syncs To                                                                                                                             |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| User                              | conditional: manage, monitor, screen, calendar (if consultant), screen (if internal), comply (if comply user), company (if external) |
| ServiceArea                       | calendar                                                                                                                             |
| ScreenReassignedRelationshipRole  | screen                                                                                                                               |
| MonitorReassignedRelationshipRole | monitor                                                                                                                              |
| ManagerialRole                    | calendar                                                                                                                             |
| CompanyLog                        | company                                                                                                                              |
| UserComplySubscription            | comply                                                                                                                               |

### Company Service — Organisational Structure

Company owns the structural entities: sites, positions, people, divisions.

| Model                    | Syncs To                                                    |
| ------------------------ | ----------------------------------------------------------- |
| Site                     | comply, authentication, + conditional manage/monitor/screen |
| Position                 | comply, + conditional manage/monitor/screen                 |
| Person                   | manage, monitor, screen                                     |
| Division                 | manage, monitor, screen                                     |
| InvoicingEntity          | manage, monitor, screen                                     |
| BusinessUnit             | manage                                                      |
| SitesPosition            | screen, monitor                                             |
| Default (CompanyDefault) | screen, monitor                                             |
| ComplyLocation           | comply, authentication                                      |
| DirectoryEntry           | manage (conditional)                                        |

### Screen Service — Screening Data

Screen owns referral and appointment data for the screening workflow.

| Model                       | Syncs To |
| --------------------------- | -------- |
| Referral                    | comply   |
| Appointment                 | calendar |
| Person                      | comply   |
| CompanyLog                  | company  |
| ReferralKpiInsightsDuration | form     |

### Monitoring Service — Monitoring Data

Monitoring owns referral and appointment data for the monitoring workflow, plus item details.

| Model                | Syncs To |
| -------------------- | -------- |
| Referral             | comply   |
| Appointment          | calendar |
| Person               | comply   |
| MonitoringItemDetail | screen   |
| TestItemDetail       | screen   |

### Hub Manage Service — Directory

Hub Manage owns directory entries with bidirectional sync back to Company.

| Model          | Syncs To                                                       |
| -------------- | -------------------------------------------------------------- |
| DirectoryEntry | company (conditional, uses `last_synced_from` to track source) |
| CompanyLog     | company                                                        |

### Form Service — Forms and Templates

Form owns form definitions, templates, marking matrices, and referral form results.

| Model                         | Syncs To                                                  |
| ----------------------------- | --------------------------------------------------------- |
| Form                          | screen, monitor                                           |
| FormTemplate                  | screen, monitor, manage                                   |
| MarkingMatrix                 | screen, monitor, manage                                   |
| MasterForm                    | monitor, screen, manage                                   |
| ReferralForm                  | dynamic (based on `source` attribute — screen or monitor) |
| ReferralFormPredictedOutcome  | screen                                                    |
| ReferralFormPredictFitOutcome | screen                                                    |

### Manage Service — Case Management

Manage owns referral tasks and syncs them to Calendar.

| Model        | Syncs To |
| ------------ | -------- |
| ReferralTask | calendar |
| CompanyLog   | company  |

### Comply Service — Compliance

Comply is primarily a consumer. Only publishes logs.

| Model      | Syncs To |
| ---------- | -------- |
| CompanyLog | company  |

### Calendar Service — Pure Consumer

Calendar does not publish any data. It only receives from other services.

No models with `AwsWrapper::Syncable`.

### Services Without Data Sync

These services do not participate in the SNS/SQS data sync:

| Service    | Role                          |
| ---------- | ----------------------------- |
| Billing    | No sync — standalone          |
| Assessment | No sync — standalone          |
| Reports    | No sync — read-only reporting |

## Data Flow Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        ORGANISATION                                      │
│  Company, Location, Subscriptions, Partner Access, Module Access         │
└───┬──────┬──────┬──────┬──────┬──────┬──────┬───────────────────────────┘
    ▼      ▼      ▼      ▼      ▼      ▼      ▼
  Auth  Company Screen Monitor Manage Comply  Form

┌──────────────────────────────────────────────────────────────────────────┐
│                        AUTHENTICATION                                    │
│  User, Roles, Permissions, ReassignedRelationshipRoles                   │
└───┬──────────┬──────────┬──────────┬──────────┬─────────────────────────┘
    ▼          ▼          ▼          ▼          ▼
  Screen    Monitor    Manage    Calendar    Company

┌──────────────────────────────────────────────────────────────────────────┐
│                        COMPANY                                           │
│  Site, Position, Person, Division, InvoicingEntity, BusinessUnit         │
└───┬──────────┬──────────┬──────────┬────────────────────────────────────┘
    ▼          ▼          ▼          ▼
  Screen    Monitor    Manage     Comply

┌──────────────────────────────────────────────────────────────────────────┐
│                          FORM                                            │
│  Form, FormTemplate, MarkingMatrix, MasterForm, ReferralForm             │
└───┬──────────┬──────────┬───────────────────────────────────────────────┘
    ▼          ▼          ▼
  Screen    Monitor    Manage

┌─────────────────────┐          ┌─────────────────────┐
│       SCREEN        │          │      MONITORING      │
│ Referral,Appointment│          │ Referral,Appointment │
│ (screening workflow)│          │ (monitoring workflow) │
└───┬──────┬──────┬───┘          └───┬──────┬──────┬───┘
    ▼      ▼      ▼                  ▼      ▼      ▼
  Comply Calendar Form            Comply Calendar Screen
                                              (MonitoringItemDetail,
                                               TestItemDetail)

┌─────────────────────┐          ┌─────────────────────┐
│       MANAGE        │          │     HUB MANAGE      │
│    ReferralTask     │          │   DirectoryEntry     │
└───┬─────────────────┘          └───┬─────────────────┘
    ▼                                ▼
  Calendar                        Company (bidirectional)

┌─────────────────────┐
│       COMPLY        │
│    CompanyLog only   │
└───┬─────────────────┘
    ▼
  Company

                    ┌─────────────────────────────────┐
                    │  CALENDAR, BILLING, ASSESSMENT,  │
                    │  REPORTS — Pure consumers or     │
                    │  no data sync participation      │
                    └─────────────────────────────────┘
```

## What Each Service Receives (via DataSync::ModelFactory)

### Authentication receives from:

- Organisation: Company, Location, ComplyLocation, CompanyServiceRestriction, CompanySubscription, CompanyMicroSubscription, CompanyPartnerAccess, ComplyUserSubscriptionPrice
- Company: Site

### Company receives from:

- Organisation: Company, CompanyLog, CompanyPartnerAccess, OrganisationModuleAccess
- Authentication: User (as Person)
- Hub Manage: DirectoryEntry

### Screen receives from:

- Organisation: Company, Location, CompanySubscription, CompanyMicroSubscription, CompanyPartnerAccess, PreApprovalTag, NetsuiteLocation
- Company: Site, Division, Position, Person, InvoicingEntity, SitesPosition, Default (CompanyDefault)
- Authentication: User (as Person), ScreenReassignedRelationshipRole
- Monitoring: MonitoringItemDetail, TestItemDetail
- Form service: ReferralForm, FormDownloadDetail, Form, MarkingMatrix, FormTemplate, MasterForm

### Monitoring receives from:

- Organisation: Company, Location, CompanySubscription, CompanyPartnerAccess, PreApprovalTag, NetsuiteLocation
- Company: Site, Division, Position, Person, InvoicingEntity, SitesPosition, Default (CompanyDefault)
- Authentication: User (as Person), MonitorReassignedRelationshipRole
- Form service: Form, MarkingMatrix, FormTemplate, MasterForm (FormType), ReferralForm (TestItemReferralForm)

### Hub Manage receives from:

- Organisation: OrganisationModuleAccess
- Company: Site, Position, Person (CompanyPerson), BusinessUnit, DirectoryEntry

### Form receives from:

- Organisation: Company, CompanySubscription, CompanyMicroSubscription
- Screen: ReferralKpiInsightsDuration

### Manage receives from:

- Organisation: Company, Location, CompanySubscription, CompanyPartnerAccess, NetsuiteLocation, OrganisationModuleAccess
- Company: Site, BusinessUnit, DirectoryEntry
- Authentication: User (as Consultant)
- Form: ReferralForm, MasterForm, MarkingMatrix, FormTemplate
- Hub Manage: CompanyEmailSenderDetail

### Comply receives from:

- Organisation: Company, CompanyPartnerAccess
- Company: Site, Position, Person, ComplyLocation
- Authentication: User (as Person), UserComplySubscription
- Screen: Referral
- Monitoring: Referral

### Calendar receives from:

- Authentication: User, ServiceArea, ManagerialRole
- Screen: Appointment (as ServiceEvent)
- Monitoring: Appointment (as ServiceEvent)
- Manage: ReferralTask (as ServiceEvent)
- Organisation: Location

## Key Rules

1. **Only the source of truth publishes** — receiving services do not have `AwsWrapper::Syncable` on received models.
2. **Conditional syncing** — many models sync conditionally based on company service flags (`for_screen`, `for_monitor`, `for_manage`, `for_comply`).
3. **Field mapping on receive** — receivers map source field names to local columns (e.g. Organisation's `screen_notes` → Screen's `notes`).
4. **User → Person mapping** — Authentication publishes `User`, but Screen/Monitor/Company receive it as `Person` with different column names.
5. **Bidirectional sync** — DirectoryEntry syncs between Hub Manage and Company, tracked via `last_synced_from` field.
6. **No loop prevention in code** — loops are prevented architecturally by only including `Syncable` on the owning service's model.
