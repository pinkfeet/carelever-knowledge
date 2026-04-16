# Billing Flow & Payments — Detailed Rules and Data

> **Source**: `carelever-replit-reimagined` codebase  
> **Last updated**: 2026-04-09

---

## Table of Contents

1. [Overview](#overview)
2. [Billing Actors & Account Types](#billing-actors--account-types)
3. [Referral Billing Flow](#referral-billing-flow)
4. [Service Billing Lifecycle](#service-billing-lifecycle)
5. [Action Fees (No-Show / Cancel / Reschedule)](#action-fees-no-show--cancel--reschedule)
6. [Pricing Resolution Hierarchy](#pricing-resolution-hierarchy)
7. [Discounts & Pricing Rules](#discounts--pricing-rules)
8. [Payment Processing (Stripe)](#payment-processing-stripe)
9. [Refunds & Credit Notes](#refunds--credit-notes)
10. [Onsite Project Billing](#onsite-project-billing)
11. [Billing Settings & Configuration](#billing-settings--configuration)
12. [Data Schemas](#data-schemas)
13. [API Endpoints](#api-endpoints)
14. [Background Jobs](#background-jobs)
15. [Key Constants & Business Rules](#key-constants--business-rules)

---

## Overview

The billing system handles revenue across three streams:

| Stream | Description |
|---|---|
| **Service billing** | Charges for completed assessments/services on a referral |
| **Action fees** | Penalty fees for no-shows, cancellations, reschedules |
| **Affiliate fees** | Booking fee added when an external (affiliate) supplier conducted the service |

Payment can be collected via:
- **Stripe** (pre-paid / credit card accounts) — immediate charge at intake or auto-charge on file
- **Invoice** (credit accounts) — billed via NetSuite through the separate `carelever_billing` service

---

## Billing Actors & Account Types

**Company** is the top-level billing entity. Key fields:

| Field | Description |
|---|---|
| `account_type` | `:credit_account` (invoice) or `:pre_paid` (card required) |
| `allow_invoice_payment` | Enables invoice payment method |
| `allow_credit_card_payment` | Enables credit card payment method |
| `stripe_customer_id` | Stripe Customer ID for saved card |
| `stripe_payment_method_id` | Stripe PaymentMethod for off-session charging |
| `stripe_card_on_file` | Boolean — whether a card is saved |

A company's effective `payment_method` is computed from these flags. Pre-paid companies can be auto-charged without manual payment steps.

---

## Referral Billing Flow

### Trigger Points

Billing is initiated from three paths:

1. **Service attended** — `appointment_attended_at` set on a service → callback advances billing status to `pending`
2. **Referral cancelled** — `cancelled_at` set → unattended services are marked `cancelled`; attended services remain billable
3. **Admin manual action** — `POST /referrals/{id}/complete_bill`

### Calculation Engine (`ReferralBillingService`)

**File**: `app/services/referral_billing_service.rb`

```
1. service_line_items
   - For each service on the referral:
     a. Resolve price via pricing hierarchy (site → company → standard)
     b. If hourly: price = hourly_rate × duration_hours
     c. Determine kinnect_price vs affiliate_price based on supplier type
     d. Check remote fee applicability

2. action_fee_line_items
   - Pull ActionFeeLineItem records for this referral
   - Include: action_type, fee_label, fee_amount, billing_status

3. discount_line_items
   - Evaluate active ReferralDiscount records
   - Apply percentage or fixed discounts per pricing rule

4. totals
   - Subtotal     = Σ service prices
   - Discounts    = Σ discount amounts
   - Action Fees  = Σ action fee amounts
   - Final Total  = max(subtotal − discounts + action_fees, 0)
```

### Billing Completion (`Referral#complete_bill!`)

When billing is marked complete:

1. Sets `service.billing_status = :billed` and `service.billed_at = now` for all attended services
2. Sets `service.billing_status = :cancelled` for unattended services on cancelled referrals
3. Creates affiliate fee service if attended services had affiliate suppliers
4. Sets `referral.billing_completed_at = now`

---

## Service Billing Lifecycle

**Enum** on `Service#billing_status`:

| Value | State | Description |
|---|---|---|
| `0` | `unbilled` | Initial; service created but not yet ready to bill |
| `1` | `pending` | Service attended; awaiting batch billing |
| `2` | `billed` | Billing complete |
| `3` | `cancelled` | Service not attended; excluded from billing |

**Transition rules**:
- `unbilled → pending`: triggered by `appointment_attended_at` being set
- `pending → billed`: triggered by `complete_bill!`
- `pending → cancelled`: triggered by referral cancellation for unattended services

**Card payment status** (for pre-paid auto-charge):

| Value | State |
|---|---|
| `0` | `card_payment_not_applicable` |
| `1` | `card_payment_succeeded` |
| `2` | `card_payment_failed` |

---

## Action Fees (No-Show / Cancel / Reschedule)

**Model**: `ActionFeeLineItem`  
**Service**: `ActionFeeCalculationService`  
**File**: `app/services/action_fee_calculation_service.rb`

### Fee Matrix

Fees are calculated by:
- **Action type**: `no_show`, `cancel`, `reschedule`
- **Lead time**: `< 1 day`, `1–3 days`, `> 3 days`
- **Clinic type**: Internal/Kinnect, External/Affiliate, Split

Exemptions:
- `walk_in_only` services are never subject to action fees
- Internal bookings may have different fee tiers

### Billing Status

| Value | State | Description |
|---|---|---|
| `0` | `pending` | Created; awaiting auto-bill window |
| `1` | `billed` | Transitioned by nightly job |

### `billable_at` Rule

Action fees become billable at **10pm AEST the next day** after the action occurred. Computed via `compute_billable_at` in the service.

### Auto-Bill Job

**File**: `app/jobs/action_fee_auto_bill_job.rb`  
**Schedule**: Runs at **22:00 AEST** daily (configured in `config/sidekiq.yml`)

Transitions all `ActionFeeLineItem` records where `billing_status = pending` and `billable_at <= Time.current` to `billed`.

### Affiliate Fee

**Model**: `AffiliateFee`  
**Service**: `AffiliateFeeService`

Triggered at billing completion when attended services were conducted at affiliate (external) suppliers:

- Creates a special service with item code `AFFILIATE-CLINIC-BOOKING-FEE`
- Uses **collection fee** if referral has bundle assessments (multiple tests in an assessor group)
- Uses **standalone fee** otherwise
- Configuration lives in `AffiliateFee.current` (singleton)

---

## Pricing Resolution Hierarchy

**Service**: `ReferralBillingService#price_for_service`

For each service, price is resolved in this order (first match wins):

```
1. Hourly pricing?
   → price = hourly_rate × duration_hours (from appointment times)

2. Site-level price
   → SiteServicePrice where (site + service_item + variation)

3. Company-level price
   → CompanyServicePrice where (company + service_item + variation)

4. Standard/global price
   → ServicePrice where (service_item + variation)
```

Each pricing record has two columns:
- `kinnect_price` — used when supplier is a KINNECT/internal clinic
- `affiliate_price` — used when supplier is an external/affiliate clinic

Supplier type on the `SupplierAssignment` determines which column is used.

---

## Discounts & Pricing Rules

**Models**: `PricingRule`, `ReferralDiscount`

### PricingRule Structure

A rule defines:
- **Conditions**: 2+ services that must all be on the referral
- **Discount targets**: 1+ service items to discount
- **Discount type**: `percentage` or `fixed_amount`
- **Discount value**: Amount to deduct

### Evaluation

Triggered via `after_create_commit` callback on `Service`. When a new service is created:

1. All active `PricingRule` records are evaluated against the referral
2. If all condition services are present → `ReferralDiscount` records are created
3. Discounts are reflected in the billing totals via `ReferralBillingService#discount_line_items`

---

## Payment Processing (Stripe)

**Services**:
- `StripePaymentService` — PaymentIntent creation and confirmation
- `CompanyCardChargeService` — Off-session auto-charge
- `FurtherInfoPaymentService` — Further medical info fee payment
- `ReReviewPaymentService` — Re-review payment handling

**Configuration**: `config/initializers/stripe.rb`  
Keys: `STRIPE_PUBLISHABLE_KEY`, `STRIPE_SECRET_KEY` (env or `SystemSetting`)

### Intake Payment (Referral Draft)

Used for pre-paid companies at the point of referral creation:

```
1. StripePaymentService.create_payment_intent
   - Amount calculated from selected service items
   - Creates Stripe PaymentIntent with referral metadata
   - Stores stripe_payment_intent_id on referral_draft
   - Optionally: setup_future_usage if saving card

2. Client completes payment in browser (Stripe Elements)

3. StripePaymentService.confirm_payment
   - Retrieves PaymentIntent from Stripe
   - Verifies status = 'succeeded'
   - Sets referral_draft.payment_confirmed = true
```

### Auto-Charge to Saved Card (`CompanyCardChargeService`)

For pre-paid companies with a card on file:

```
1. Check company.has_saved_card?
   (requires stripe_customer_id + stripe_payment_method_id)

2. Create PaymentIntent with:
   - off_session: true
   - confirm: true
   - payment_method: company.stripe_payment_method_id
   - customer: company.stripe_customer_id

3. On success → service.card_payment_status = :card_payment_succeeded
   On failure → service.card_payment_status = :card_payment_failed
                service.stripe_charge_error = error.message
```

### Further Info Payment

Charged when additional medical information is required during a case:

1. Creates service with code `FURTHER-MEDICAL-INFORMATION-FEE`
2. Attempts auto-charge if company has saved card
3. Otherwise: sends payment link to complete via Stripe checkout
4. Status tracked in `referral.further_info_payment_status` (enum: `not_required → pending → completed → failed`)

### Re-Review Payment

Similar flow to further info — triggered when medical results require re-review:
- Service code: `RE-REVIEW-OF-MEDICAL-RESULTS`
- Status tracked in `referral.re_review_payment_status`

### Card Management (Client Self-Service)

Clients can save/remove a card via:

```
GET  /settings/payment_card           → Show card management
POST /settings/payment_card/setup_intent → Create Stripe SetupIntent
POST /settings/payment_card/save       → Save card token to company
DELETE /settings/payment_card          → Remove saved card
```

---

## Refunds & Credit Notes

**Service**: `RefundService`  
**Models**: `Refund`, `CreditNote`

### Refund Types

| Type | When Used |
|---|---|
| `stripe` | Original payment was made via Stripe |
| `credit_note` | Original payment was invoice-based |

### Refund Flow

```
1. Admin initiates refund from billing tab
   POST /referrals/{id}/services/{service_id}/refund

2. RefundService:
   a. Validate amount ≤ max refundable
   b. If stripe: Stripe::Refund.create(payment_intent:, amount:)
   c. If credit_note: CreditNote.create(...)
   d. Create Refund record with status: pending → succeeded/failed
   e. Log activity
```

### Credit Note Numbering

Auto-generated: `CN-YYYYMMDD-{hex}` (e.g., `CN-20260409-a3f2`)

### Credit Note Statuses

`active` or `voided`

---

## Onsite Project Billing

**Model**: `OnsiteProjectBillingItem`  
**Services**: `OnsiteProjects::CalculateBilling`, `OnsiteProjects::FinaliseBilling`

### Item Types

| Value | Type | Description |
|---|---|---|
| `0` | `base_fee` | Fixed base charge for the project |
| `1` | `assessor_cost` | Cost for each assessor deployed |
| `2` | `candidate_fee` | Per-candidate service fee |
| `3` | `manual_item` | Manually added line item |
| `4` | `adjustment` | Credit, discount, or additional charge |

### Adjustment Subtypes

`credit`, `discount`, `additional_charge`

### Billing Statuses

`unbilled → pending → billed` (same enum pattern as service billing)

### Locking

Items can be `locked: true` to prevent modification after finalisation.

Billing calculation uses `ReferralBillingService` internally to price candidate fees from individual referral services.

---

## Billing Settings & Configuration

**Controller**: `Admin::BillingSettingsController`  
**View**: `app/views/admin/billing_settings/index.html.erb`

### Billing Defaults (`BillingDefault`)

Hierarchical configuration of PO numbers, cost centres, and invoicing contacts.

Resolution order (first match wins):

```
1. Company + Service Item + Service Type
2. Site + Service Item + Service Type   (if site present)
3. Company + Site + Service Type
4. Company only
```

Returns `{ values: { po, cost_centre, invoicing_contact }, resolved_from: { level, label } }`.

### Invoicing Contacts (`InvoicingContact`)

| Field | Description |
|---|---|
| `contact_name`, `contact_email` | Who receives invoices |
| `billing_address` | Billing address for invoice |
| `billing_schedule` | `daily`, `weekly`, `monthly` |
| `invoice_merge_type` | `no_merge(0)`, `po_merge(1)`, `full_merge(2)` |
| `screen_enabled`, `monitor_enabled` | Filter by service type |
| `is_primary` | Whether this is the default contact |

### PO Blacklist

Prevents specific PO numbers from being accepted. Managed via admin settings.

### Non-Attended Fees Configuration

Matrix of fees configurable by action type × lead time × clinic type. Managed at `PATCH /admin/billing_settings/non_attended_fees`.

---

## Data Schemas

### Referral Billing Fields

| Column | Type | Notes |
|---|---|---|
| `purchase_order_number` | string | PO for invoicing |
| `cost_centre` | string | Cost centre code |
| `payment_method` | string | `credit_card` or `invoice` |
| `stripe_payment_intent_id` | string | Intake Stripe intent |
| `payment_amount_cents` | integer | Intake payment amount |
| `payment_completed_at` | datetime | When intake payment completed |
| `invoicing_contact_id` | bigint | FK → InvoicingContact |
| `billing_completed_at` | datetime | When billing marked complete |
| `further_info_payment_status` | integer | Enum: 0=not_required, 1=pending, 2=completed, 3=failed |
| `further_info_payment_intent_id` | string | |
| `further_info_payment_amount_cents` | integer | |
| `re_review_payment_status` | integer | Same enum as further_info |
| `re_review_payment_amount_cents` | integer | |
| `re_review_payment_intent_id` | string | |

### Service Billing Fields

| Column | Type | Notes |
|---|---|---|
| `billing_status` | integer | Enum: 0=unbilled, 1=pending, 2=billed, 3=cancelled |
| `billed_at` | datetime | When service was billed |
| `card_payment_status` | integer | Enum: 0=not_applicable, 1=succeeded, 2=failed |
| `stripe_charge_id` | string | Stripe PaymentIntent ID |
| `stripe_charge_amount_cents` | integer | Amount charged in cents |
| `stripe_charge_error` | string | Error message on failure |

### ActionFeeLineItem Fields

| Column | Type | Notes |
|---|---|---|
| `referral_id`, `service_id` | bigint | FK references |
| `action_type` | string | `cancel`, `reschedule`, `no_show` |
| `fee_amount` | decimal(10,2) | Dollar amount |
| `billing_status` | integer | 0=pending, 1=billed |
| `actioned_at` | datetime | When action was taken |
| `billable_at` | datetime | When fee becomes billable |
| `fee_label` | string | Human label (e.g. "No Show — 100%") |
| `clb_uuid` | uuid | For CLB accounting system sync |
| `netsuite_pushed_at` | datetime | External system tracking |

### OnsiteProjectBillingItem Fields

| Column | Type | Notes |
|---|---|---|
| `onsite_project_id`, `onsite_project_site_id` | bigint | |
| `staff_assignment_id`, `referral_id`, `service_id` | bigint | Optional references |
| `item_type` | integer | 0=base_fee, 1=assessor_cost, 2=candidate_fee, 3=manual_item, 4=adjustment |
| `description` | string | |
| `amount` | decimal(10,2) | Unit price |
| `quantity` | integer | |
| `total` | decimal(10,2) | Computed: amount × quantity |
| `billing_status` | integer | 0=unbilled, 1=pending, 2=billed |
| `adjustment_type` | string | `credit`, `discount`, `additional_charge` |
| `locked` | boolean | Prevents modification |
| `clb_uuid` | uuid | CLB sync |
| `netsuite_pushed_at` | datetime | |

---

## API Endpoints

### Referral Billing

| Method | Path | Description |
|---|---|---|
| `POST` | `/referrals/{id}/complete_bill` | Mark billing complete (admin) |
| `PATCH` | `/referrals/{id}/update_billing` | Update billing info (PO, cost centre) |
| `POST` | `/referrals/{id}/services/{service_id}/refund` | Issue refund |
| `GET` | `/referrals/{id}?tab=billing` | View billing tab |

### Payment Pages

| Method | Path | Description |
|---|---|---|
| `GET` | `/referrals/{id}/further_info_payment` | Further info payment page |
| `POST` | `/referrals/{id}/confirm_further_info_payment` | Confirm payment |
| `GET` | `/referrals/{id}/re_review_payment` | Re-review payment page |
| `POST` | `/referrals/{id}/confirm_re_review_payment` | Confirm payment |

### Billing Settings (Admin)

| Method | Path | Description |
|---|---|---|
| `GET` | `/admin/billing_settings` | All settings |
| `PATCH` | `/admin/billing_settings/affiliate_fees` | Update affiliate fees |
| `PATCH` | `/admin/billing_settings/non_attended_fees` | Update action fee matrix |
| `POST` | `/admin/billing_settings/netsuite_locations` | Create NetSuite location |
| `PATCH` | `/admin/billing_settings/netsuite_locations/{id}` | Update location |
| `PATCH` | `/admin/billing_settings/netsuite_locations/{id}/archive` | Archive location |
| `POST` | `/admin/billing_settings/po_blacklist` | Add to PO blacklist |
| `DELETE` | `/admin/billing_settings/po_blacklist/{id}` | Remove from blacklist |

### Billing Defaults

| Method | Path | Description |
|---|---|---|
| `PATCH` | `/settings/billing_defaults` | Client update defaults |
| `PATCH` | `/admin/referrals/{id}/billing_default` | Admin update |

### Card Management

| Method | Path | Description |
|---|---|---|
| `GET` | `/settings/payment_card` | Show card management |
| `POST` | `/settings/payment_card/setup_intent` | Create Stripe SetupIntent |
| `POST` | `/settings/payment_card/save` | Save card token |
| `DELETE` | `/settings/payment_card` | Remove saved card |

### Onsite Project Billing

| Method | Path | Description |
|---|---|---|
| `POST` | `/admin/onsite_projects/{id}/billing_items` | Create item |
| `PATCH` | `/admin/onsite_projects/{id}/billing_items/{item_id}` | Update item |
| `DELETE` | `/admin/onsite_projects/{id}/billing_items/{item_id}` | Delete item |

---

## Background Jobs

| Job | Schedule | Description |
|---|---|---|
| `ActionFeeAutoBillJob` | 22:00 AEST daily | Transitions `pending` action fees where `billable_at <= now` to `billed` |

---

## Key Constants & Business Rules

| Rule | Value / Behaviour |
|---|---|
| Action fee `billable_at` | Next day at 10pm AEST |
| Auto-bill job time | 22:00 AEST daily |
| Off-session charging | Requires `stripe_customer_id` + `stripe_payment_method_id` on Company |
| Affiliate fee trigger | Any attended service at an external supplier |
| Affiliate fee type | Collection fee if bundle assessments; standalone fee otherwise |
| Pricing column selection | `kinnect_price` for internal/KINNECT; `affiliate_price` for external |
| Hourly pricing | `hourly_rate × duration_hours` from appointment start/end times |
| Final total floor | `max(subtotal − discounts + action_fees, 0)` — never negative |
| Discount evaluation trigger | `after_create_commit` on Service |
| Billing default resolution | 4-layer hierarchy: service+company → site+service → site+company → company |
| Credit note number format | `CN-YYYYMMDD-{hex}` |

### Immutable Business Rules

1. **Billing total can never go below zero** — discounts are capped at subtotal + action fees
2. **Services transition to `cancelled` (not `billed`) on referral cancellation** if never attended
3. **Auto-charge only runs for companies with both `stripe_customer_id` and `stripe_payment_method_id`** — missing either skips auto-charge silently
4. **Affiliate fee is created at `complete_bill!` time** — not at service creation
5. **Action fees are never charged for `walk_in_only` services**
6. **Pricing rule discounts re-evaluate on every new service added** — late-added services can unlock discounts retroactively

---

## Key Files

| Purpose | File |
|---|---|
| Core billing calculation | `app/services/referral_billing_service.rb` |
| Action fee calculation | `app/services/action_fee_calculation_service.rb` |
| Stripe payment service | `app/services/stripe_payment_service.rb` |
| Auto-charge service | `app/services/company_card_charge_service.rb` |
| Further info payment | `app/services/further_info_payment_service.rb` |
| Re-review payment | `app/services/re_review_payment_service.rb` |
| Refund processing | `app/services/refund_service.rb` |
| Affiliate fee service | `app/services/affiliate_fee_service.rb` |
| Onsite billing calc | `app/services/onsite_projects/calculate_billing.rb` |
| Onsite billing finalise | `app/services/onsite_projects/finalise_billing.rb` |
| Auto-bill job | `app/jobs/action_fee_auto_bill_job.rb` |
| Referral model | `app/models/referral.rb` |
| Service model | `app/models/service.rb` |
| ActionFeeLineItem model | `app/models/action_fee_line_item.rb` |
| BillingDefault model | `app/models/billing_default.rb` |
| InvoicingContact model | `app/models/invoicing_contact.rb` |
| Billing tab UI | `app/views/referrals/_tab_billing.html.erb` |
| Billing settings admin | `app/views/admin/billing_settings/index.html.erb` |
| DB schema | `db/schema.rb` |
