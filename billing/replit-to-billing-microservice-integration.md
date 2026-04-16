# Replit App → Billing Microservice Integration

> **Context**: The replit app (`carelever-replit-reimagined`) is a prototype that handles billing calculation internally. The plan is to keep using `carelever_billing` as the NetSuite integration layer. This doc covers what linkage is needed.

---

## How the Existing Pipeline Works (Screen/Monitor → CLB)

Upstream services (Screen, Monitor, Manage) build line items locally and POST them to `carelever_billing`:

```
POST /v1/billing/line_items
Headers: billing_token, Idempotency-key (MD5 of body)
Body: { _json: [...line_items] }
```

`carelever_billing` then:
1. Stores line items in its `line_items` table (pending queue)
2. On a billing run, groups by `customer_uuid + grouping` → builds a NetSuite SalesOrder
3. Looks up `InventoryItem` in NetSuite via `item_uuid`
4. Looks up `Location` in NetSuite via `location` name string
5. Upserts the SalesOrder via SOAP, fetches back the `tran_id`
6. Updates `line_items.sales_order = tran_id` → DB trigger moves record to `line_item_shadows`

---

## What Each Line Item Field Means

| Field | Source in Screen/Monitor | What CLB Does With It |
|---|---|---|
| `item_uuid` | UUID of the NetSuite InventoryItem, stored on the screening item | SOAP search: `InventoryItem.search(externalIdString: item_uuid)` |
| `item_code` | Service/screening item code | Stored for reference; not used in NetSuite lookup |
| `item_name` | Service name | Stored for reference |
| `item_quantity` | Usually 1 | SalesOrderItem quantity |
| `item_unit_amount` | Unit price | SalesOrderItem rate |
| `price` | Total (quantity × unit) | SalesOrderItem amount |
| `location` | Clinic name string | NetSuite Location search: `Location.search(name contains location)` |
| `customer_uuid` | Company UUID | NetSuite Customer search/create by external_id |
| `customer_name` | Company name | Used when creating NetSuite Customer |
| `organisation_uuid` | Same as customer_uuid | Stored for reference |
| `grouping` | Groups line items into one SalesOrder | All items with same `customer_uuid + grouping` → single SO |
| `billing_schedule` | daily / weekly / monthly | Determines when the billing run processes this item |
| `invoicing_entity_email` | Invoicing contact email | Used to detect Workcover items |
| `invoicing_entity_name` | Invoicing contact name | Stored on SO |
| `invoicing_entity_company_name` | Company name for invoice | Stored on SO |
| `tax_business_number` | ABN | Stored on NetSuite Customer |
| `payment_terms_id` | NetSuite payment terms | Applied to SalesOrder |
| `reference_id` | Referral/request ID | Stored for traceability |
| `service_date` | Date service was performed | SalesOrderItem service date |
| `data` (jsonb) | Custom fields (PO, cost centre, candidate name, etc.) | Mapped to NetSuite custom columns via `NetSuiteFieldProvider` |
| `source` | `screen` / `monitor` / `manage` | FDW view filtering |

---

## What the Replit App Currently Has

| Needed Field | Replit App Status | Where |
|---|---|---|
| `item_uuid` (NetSuite InventoryItem UUID) | **Missing** | No column on `service_items` or `service_variations` |
| `item_code` | Available | `service_items.code` |
| `item_name` | Available | `service_items.name` |
| `location` (clinic name string) | Partial — via `netsuite_locations` table | Resolved via `service_item.netsuite_location`, `service_variation.netsuite_location`, or `supplier.netsuite_location` |
| `customer_uuid` | Available | `company.id` (UUID) |
| `grouping` | Partial — `clb_uuid` is per-service | Grouping logic (per PO, per invoicing contact, etc.) not yet defined |
| `billing_schedule` | Available | `invoicing_contact.billing_schedule` |
| `invoicing_entity_*` | Available | `invoicing_contact` model |
| `tax_business_number` | Available | `invoicing_contact.tax_number` |
| `reference_id` | Available | `referral.reference_number` |
| `service_date` | Available | `appointment.appointment_date` or `service.appointment_attended_at` |
| `data` (custom fields) | Partial | PO (`referral.purchase_order_number`), cost centre (`referral.cost_centre`), candidate info on referral |
| `source` | Needs defining | Would be a new source value e.g. `reimagined` |

---

## Critical Gap: `netsuite_item_uuid` on Service Items

The single most important missing piece. CLB cannot look up the NetSuite InventoryItem without it.

**What needs to happen:**

Add `netsuite_item_uuid` (uuid, nullable) to `service_items` and `service_variations` in the replit app:

```ruby
# migration
add_column :service_items, :netsuite_item_uuid, :uuid
add_column :service_variations, :netsuite_item_uuid, :uuid
```

This UUID is the `external_id` of the InventoryItem in NetSuite — it must match what already exists in NetSuite. The values can be sourced from the existing Screen/Monitor screening item configurations, which already carry these UUIDs.

---

## Line Item Building — What the Replit App Needs to Produce

When `ClbScheduledPushJob` actually sends to CLB (not yet implemented), each service needs to produce a payload like:

```json
{
  "item_uuid": "<netsuite_inventory_item_uuid>",
  "item_code": "PRE-EMP-MED",
  "item_name": "Pre-Employment Medical",
  "item_quantity": 1,
  "item_unit_amount": 250.00,
  "price": 250.00,
  "location": "Kinnect Brisbane",
  "customer_uuid": "<company.id>",
  "customer_name": "Acme Corp",
  "organisation_uuid": "<company.id>",
  "grouping": "<po_number or invoicing_contact_id>",
  "billing_schedule": "monthly",
  "billing_address": "123 Main St, Brisbane QLD 4000",
  "invoicing_entity_name": "Jane Smith",
  "invoicing_entity_email": "jane@acme.com",
  "invoicing_entity_company_name": "Acme Corp",
  "tax_business_number": "12 345 678 901",
  "payment_terms_id": "<netsuite_payment_terms_id>",
  "reference_id": "REF-001234",
  "service_date": "2026-04-09",
  "source": "reimagined",
  "data": {
    "purchase_order": "PO-9999",
    "cost_centre_number": "CC-001",
    "applicant_name": "John Candidate",
    "site": "Brisbane CBD"
  }
}
```

---

## `grouping` Strategy

In the existing apps, `grouping` determines which line items get merged into a single SalesOrder. The replit app needs to decide its grouping key. Options (matching existing behaviour):

| Strategy | When to use |
|---|---|
| `invoicing_contact_id` | Default — one SO per invoicing contact per billing cycle |
| `purchase_order_number` | When `invoice_merge_type = :po_merge` — group by PO |
| `referral.reference_number` | When `invoice_merge_type = :no_merge` — one SO per referral |

This mirrors `InvoicingContact.invoice_merge_type` already modelled in the replit app.

---

## `netsuite_pushed_at` — Current Role in Replit

The `ClbScheduledPushJob` already stamps `netsuite_pushed_at` on `services`, `action_fee_line_items`, and `onsite_project_billing_items`. Currently this just marks records as "ready" — it does **not** POST to CLB.

The job needs to be extended to:
1. Build the line item payload per service
2. POST to `carelever_billing /v1/billing/line_items`
3. Only stamp `netsuite_pushed_at` on success

---

## Action Fee Line Items

Action fees (`ActionFeeLineItem`) also need to be sent to CLB. They have their own `clb_uuid` and `netsuite_pushed_at`. The line item payload would need:

- `item_uuid` — a dedicated NetSuite InventoryItem for action fees (one per fee type, or a shared one)
- `item_name` — `fee_label` (e.g. "No Show — 100%")
- `price` — `fee_amount`
- `service_date` — `actioned_at.to_date`
- Same customer/invoicing fields as service line items

---

## Summary: Minimum Work to Wire Replit → CLB

1. **Add `netsuite_item_uuid`** to `service_items` and `service_variations` — populate from existing Screen/Monitor item configs
2. **Define grouping logic** based on `invoice_merge_type` on `InvoicingContact`
3. **Extend `ClbScheduledPushJob`** to build payloads and POST to CLB instead of just stamping `netsuite_pushed_at`
4. **Decide `source` value** — e.g. `reimagined` — so CLB FDW views can be extended if needed, or existing `line_items` table handles it directly
5. **Action fee item UUIDs** — confirm with NetSuite which InventoryItem UUIDs map to fee types
