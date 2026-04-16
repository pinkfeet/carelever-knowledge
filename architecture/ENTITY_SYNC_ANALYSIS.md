# Entity Structure Comparison & Sync Strategy

Date: 2026-04-09

## Context

The assessment project has its own local copies of `users`, `companies`, `sites`, and `positions` — mirrored from the Replit app structure. The carelever platform's microservices (Organisation, Company, Authentication) own the master copies of this data and distribute updates via SNS/SQS using `AwsWrapper::Syncable`.

The assessment project currently has no data sync participation (listed as standalone in source-of-truth.md). When assessment replaces the screen project, it must plug into the same sync pipeline that screen currently uses.

---

## ID Type Gap

This is the central tension. Every microservice uses UUID primary keys. Assessment uses bigint auto-increment (inherited from the Replit app).

| System                        | PK Type         | Cross-service bridge field                                           |
| ----------------------------- | --------------- | -------------------------------------------------------------------- |
| `carelever_assessment`        | `bigint`        | `sites.uuid`, `positions.uuid` (string columns, generated on create) |
| `carelever-replit-reimagined` | `bigint`        | same — `sites.uuid`, `positions.uuid`                                |
| `carelever_company`           | `UUID` natively | —                                                                    |
| `carelever_screen`            | `UUID` natively | —                                                                    |
| `carelever_authentication`    | `UUID` natively | —                                                                    |

The `uuid` string columns on `sites` and `positions` in assessment ARE the existing bridge to the microservices. Companies and users have no equivalent bridge field yet.

---

## Entity-by-Entity Comparison

### User / Person

| Field         | Assessment (`users`)                   | carelever_company (`people`)                                    | carelever_screen (`people`)       |
| ------------- | -------------------------------------- | --------------------------------------------------------------- | --------------------------------- |
| PK            | `id` bigint                            | `id` UUID                                                       | `id` UUID                         |
| External link | — (none yet)                           | `authentication_user_id` UUID                                   | `authentication_user_id` UUID     |
| Name          | `first_name`, `last_name`              | `first_name`, `last_name`                                       | `first_name`, `last_name`         |
| Email         | `email` citext                         | `email` string                                                  | `email` string                    |
| Company link  | `primary_company_id` (bigint FK)       | `company_id` UUID FK                                            | `company_id` UUID FK              |
| Roles         | `client_role` enum, `role_template_id` | `screen_roles`, `monitor_roles`, `manage_roles` (string arrays) | via `roles` association           |
| Site/Position | —                                      | —                                                               | `site_id`, `position_id` UUID FKs |
| Soft delete   | `active` boolean + `deactivated_at`    | `discarded_at` (Discard gem)                                    | `discarded_at` (Discard gem)      |
| Auth source   | owns password_digest                   | `authentication_user_id` references auth service                | same                              |

**Key differences:**

- Assessment owns credentials; microservices treat user as a synced `Person` from the Authentication service
- Assessment has no `authentication_user_id` or equivalent UUID link to the auth service's user record
- Soft delete mechanism differs

---

### Company

| Field          | Assessment (`companies`)                     | carelever_company (`companies`)                         | carelever_screen (`companies`)       |
| -------------- | -------------------------------------------- | ------------------------------------------------------- | ------------------------------------ |
| PK             | `id` bigint                                  | `id` UUID                                               | `id` UUID                            |
| External link  | — (none yet)                                 | — (it IS the source)                                    | synced from Organisation             |
| Name           | `name`                                       | `name`, `display_name`, `short_name`                    | `name`                               |
| Parent         | `parent_account_id` bigint FK                | `entity_id` UUID FK                                     | — (Organisation via multi-tenancy)   |
| Service flags  | `screen_active`/`monitor_active` on children | `for_screen`, `for_monitor`, `for_manage`, `for_comply` | —                                    |
| Compliance Hub | —                                            | `ch_id` integer                                         | `ch_id` integer                      |
| Billing        | Stripe fields, credit check fields           | —                                                       | `billing_preference`, contract dates |
| Soft delete    | `active` boolean                             | `discarded_at`                                          | `discarded_at`                       |
| Tiers          | `tier` enum (1-3)                            | `screen_tier`, `monitor_tier`, `manage_tier` (separate) | `tier` (single)                      |

**Key differences:**

- Assessment has billing/payment data (Stripe, credit check) — these are assessment-specific and won't exist in microservices
- Per-service tier split in company service vs single tier in assessment
- No `ch_id` in assessment
- `parent_account` in assessment maps conceptually to `Organisation` in the microservice architecture

---

### Site

| Field           | Assessment (`sites`)                                             | carelever_company (`sites`)                                                              | carelever_screen (`sites`) |
| --------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | -------------------------- |
| PK              | `id` bigint                                                      | `id` UUID                                                                                | `id` UUID                  |
| External link   | `uuid` string (unique)                                           | IS the UUID                                                                              | synced from Company        |
| Company link    | `company_id` bigint                                              | `company_id` UUID                                                                        | `company_id` UUID          |
| Name            | `name`                                                           | `name`                                                                                   | `name`                     |
| Service flags   | `screen_active`, `monitor_active`                                | `for_screen`, `for_monitor`, `for_manage`                                                | —                          |
| Purchase orders | `default_purchase_order`, `default_cost_centre`                  | `purchase_order_number`, `screen_purchase_order_number`, `monitor_purchase_order_number` | `purchase_order_number`    |
| Contacts        | `default_updates_to_contact_id`, `default_results_to_contact_id` | —                                                                                        | —                          |
| Soft delete     | `active` boolean                                                 | `discarded_at`                                                                           | `discarded_at`             |
| Compliance Hub  | —                                                                | `ch_id` integer                                                                          | `ch_id` integer            |

**Key differences:**

- Assessment `sites.uuid` ↔ Company service `sites.id` — the bridge already exists
- Assessment has richer defaults (contacts, service item IDs, cost centre)
- Purchase order fields split differently between systems

---

### Position

| Field             | Assessment (`positions`)          | carelever_company (`positions`)           | carelever_screen (`positions`) |
| ----------------- | --------------------------------- | ----------------------------------------- | ------------------------------ |
| PK                | `id` bigint                       | `id` UUID                                 | `id` UUID                      |
| External link     | `uuid` string (unique)            | IS the UUID                               | synced from Company            |
| Company link      | `company_id` bigint               | `company_id` UUID                         | `company_id` UUID              |
| **Name field**    | `name`                            | **`title`**                               | **`title`**                    |
| Site relationship | belongs to company directly       | many-to-many via `sites_positions`        | many-to-many via join          |
| Service flags     | `screen_active`, `monitor_active` | `for_screen`, `for_monitor`, `for_manage` | —                              |
| Safety critical   | `safety_critical` boolean         | —                                         | —                              |
| Soft delete       | `active` boolean                  | `discarded_at`                            | `discarded_at`                 |
| Compliance Hub    | —                                 | `ch_id` integer                           | `ch_id` integer                |

**Key differences:**

- **`name` vs `title`** — field renamed between assessment and microservices
- Site-position relationship: assessment has position → company (flat); microservices have many-to-many via `sites_positions`
- `safety_critical` exists only in assessment

---

### Organisation / Parent Account

|        | Assessment                      | carelever_company                        | carelever_screen                                                  |
| ------ | ------------------------------- | ---------------------------------------- | ----------------------------------------------------------------- |
| Entity | `parent_accounts` table         | `organisations` table (UUID PK, minimal) | `organisations` table (UUID PK, full multi-tenancy via Apartment) |
| Role   | Groups companies under a parent | Tenant container                         | Tenant container                                                  |
| Sync   | Not synced                      | IS the master                            | receives from Organisation service                                |

Assessment's `parent_accounts` is the closest equivalent to `organisations` but is structurally different — not multi-tenant.

---

## Existing Sync Architecture

From `carelever-knowledge/data-sync/source-of-truth.md`:

- **Organisation service** owns `Company` — syncs to: company, authentication, screen, monitor, manage, comply, form
- **Company service** owns `Site`, `Position`, `Person` — syncs to: screen, monitor, manage, comply
- **Authentication service** owns `User` — syncs to: screen, monitor, manage, company, calendar
- **Screen service** currently owns `Referral` and `Appointment` — syncs to: comply, calendar
- **Assessment** is currently: `No sync — standalone`

The sync mechanism uses `AwsWrapper::Syncable` on the owning model and `DataSync::ModelFactory` on receiving services. SQS/SNS delivers changes.

**When assessment replaces screen, it needs to receive exactly what screen currently receives:**

| From           | What                                                                                                                     |
| -------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Organisation   | Company, Location, CompanySubscription, CompanyMicroSubscription, CompanyPartnerAccess, PreApprovalTag, NetsuiteLocation |
| Company        | Site, Division, Position, Person, InvoicingEntity, SitesPosition, Default                                                |
| Authentication | User (as Person), ScreenReassignedRelationshipRole                                                                       |
| Monitoring     | MonitoringItemDetail, TestItemDetail                                                                                     |
| Form           | ReferralForm, Form, MarkingMatrix, FormTemplate, MasterForm                                                              |

---

## Open Questions Before Sync Strategy

1. **Authority for assessment-specific fields**: Who owns `safety_critical`, Stripe/billing fields, contact defaults? These exist in assessment but not in microservices. Do they stay assessment-only, or do they need to be added upstream?

2. **User identity bridge**: Assessment currently owns credentials (`password_digest`). When connecting to the Auth service, does assessment become a consumer of auth service users, or does it keep its own user table and link via `authentication_user_id`?

3. **Position name vs title**: When assessment receives `Position` from Company service with field `title`, does it map to assessment's `name`, or does assessment rename its column to `title`?

4. **Site-position relationship**: Assessment has positions flat under company; Company service has `sites_positions` join. Does assessment need to adopt the many-to-many model, or keep the flat model and accept the join table as supplementary?

5. **`parent_accounts` → `organisations`**: Does assessment's `parent_accounts` table get replaced by synced `organisations` from the Organisation service, or remain separate?

6. **Soft delete alignment**: Migrate from `active` boolean to `discarded_at` to match microservice convention, or keep and map on receipt?

---

## Preliminary Sync Strategy (pending answers above)

### Phase 1 — Add UUID bridge columns to companies and users

Sites and positions already have `uuid` bridge columns. Add equivalents:

- `companies.external_uuid` (string, unique) — maps to Company service UUID
- `users.authentication_user_id` (string, unique) — maps to Auth service UUID

This gives every locally-owned entity a handle into the microservice world without requiring a schema overhaul.

### Phase 2 — Implement DataSync::ModelFactory receivers

Following the pattern used by `carelever_screen`, implement SQS consumers in assessment for:

- `Company` (from Organisation service)
- `Site`, `Position`, `Person` (from Company service)
- `User` (from Authentication service)

Each receiver maps incoming UUID-keyed payloads to assessment's local bigint records by matching on the bridge UUID columns.

### Phase 3 — Handle field mapping

| Incoming field           | Assessment field            | Action                                         |
| ------------------------ | --------------------------- | ---------------------------------------------- |
| `positions.title`        | `positions.name`            | Map on receive (or rename column)              |
| `discarded_at`           | `active` / `deactivated_at` | Map: `discarded_at` present → `active: false`  |
| `for_screen`             | `screen_active`             | Map on receive                                 |
| `ch_id`                  | —                           | Add column to assessment entities              |
| `sites_positions` (join) | —                           | Add `sites_positions` join table to assessment |

### Phase 4 — Assessment becomes publisher for Referral/Appointment

When screen is retired, assessment takes over publishing `Referral` and `Appointment` to comply and calendar services. This requires adding `AwsWrapper::Syncable` to assessment's `Referral` and `Appointment` models.

---

## Summary of ID Strategy

Assessment keeps its bigint PKs internally. All cross-service references use UUID bridge columns:

```
assessment.companies.id (bigint) ←→ assessment.companies.external_uuid ←→ org_service.companies.id (UUID)
assessment.sites.id (bigint)     ←→ assessment.sites.uuid              ←→ company_service.sites.id (UUID)
assessment.positions.id (bigint) ←→ assessment.positions.uuid          ←→ company_service.positions.id (UUID)
assessment.users.id (bigint)     ←→ assessment.users.authentication_user_id ←→ auth_service.users.id (UUID)
```

Internal Rails associations continue using bigint. Sync payloads to/from microservices use UUIDs exclusively.
