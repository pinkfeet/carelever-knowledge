# Billing Service & NetSuite Integration

## Overview

The billing service (`carelever_billing`) is a Rails 7 app that receives line items from upstream services (Screen, Monitoring, Manage), creates SalesOrders in NetSuite via SOAP API, and processes Workcover invoices. It runs on port **3035** locally.

---

## Data Model

### Core Tables

#### line_items

Main table for incoming billing data.

| Column                                    | Type    | Notes                                                   |
| ----------------------------------------- | ------- | ------------------------------------------------------- |
| id                                        | uuid    | PK                                                      |
| grouping                                  | string  | Groups line items into a single SalesOrder              |
| customer_uuid, customer_name              | string  | Maps to NetSuite Customer                               |
| item_uuid, item_code, item_name           | string  | Maps to NetSuite InventoryItem                          |
| item_quantity                             | decimal |                                                         |
| item_unit_amount                          | decimal |                                                         |
| price                                     | decimal | Calculated total                                        |
| service_date                              | date    |                                                         |
| year, month, day                          | integer | Parsed from service_date                                |
| source                                    | enum    | 'screen', 'monitor', 'manage'                           |
| billing_schedule                          | enum    | 'daily', 'weekly', 'monthly'                            |
| organisation_uuid                         | uuid    |                                                         |
| billing_address                           | string  |                                                         |
| tax_business_number                       | string  | ABN/VAT                                                 |
| payment_terms_id                          | string  |                                                         |
| invoicing_entity_company_name             | string  |                                                         |
| invoicing_entity_name                     | string  |                                                         |
| invoicing_entity_email                    | string  | Used to identify Workcover items                        |
| location, location_uuid, location_address | string  |                                                         |
| reference_id                              | string  |                                                         |
| consultant_id, consultant_name            | string  |                                                         |
| duration                                  | string  |                                                         |
| description                               | string  |                                                         |
| sales_order                               | string  | NetSuite SO number (populated after sync)               |
| process_errors                            | string  | Error tracking                                          |
| data                                      | jsonb   | Custom fields (Workcover metadata, claim numbers, etc.) |

#### line_item_shadows

Archive table. DB trigger inserts here when `line_items.sales_order` is updated. A second trigger then deletes from `line_items`.

#### workcover_line_items

Workcover-specific invoice data created from line items with Workcover customer email.

#### workcover_line_item_shadows

Archive of workcover items. DB trigger inserts here when `invoice_number` is updated, then deletes from main table.

### Shadow Table Pattern

```
line_items → (sales_order updated) → INSERT line_item_shadows → DELETE line_items
workcover_line_items → (invoice_number updated) → INSERT workcover_line_item_shadows → DELETE workcover_line_items
```

### Foreign Data Wrapper Views

Uses PostgreSQL `dblink` to read from upstream databases directly:

- `screen_line_items` / `screen_unbilled_line_items`
- `monitor_line_items` / `monitor_unbilled_line_items`
- `manage_line_items` / `manage_unbilled_line_items`

---

## Line Items Ingestion Flow

### Upstream Services POST line items

**Screen:** `carelever_screen/app/commands/line_items/send_to_carelever_billing.rb`
**Monitoring:** `carelever_monitoring/app/commands/line_items/send_to_carelever_billing.rb`

Both use identical implementation:

```ruby
HTTParty.post(uri, body: { _json: body }, headers: {
  "billing_token": ENV['BILLING_TOKEN'],
  "Idempotency-key": Digest::MD5.hexdigest(body.to_json)
})
```

### Billing receives at:

`POST /v1/billing/line_items` → `LineItemsController#create` → `LineItems::Create` command

Creates LineItem records, parsing `service_date` into `day/month/year` components.

---

## NetSuite Integration

### Configuration

**File:** `carelever_billing/config/initializers/netsuite.rb`
**Gem:** `netsuite` (SOAP API wrapper)

```
Env vars: BILLING_WSDL_URL, BILLING_WSDL_DOMAIN, BILLING_NETSUITE_ACCOUNT,
          BILLING_NETSUITE_CONSUMER_KEY, BILLING_NETSUITE_CONSUMER_SECRET,
          BILLING_NETSUITE_TOKEN_ID, BILLING_NETSUITE_TOKEN_SECRET
```

Uses Token-Based Authentication (TBA) with OAuth 1.0.

### NetSuite Records

| Record                  | Operation     | Notes                                          |
| ----------------------- | ------------- | ---------------------------------------------- |
| **SalesOrder**          | Create/Upsert | Primary record created from grouped line items |
| **Customer**            | Search/Create | Created on-demand if not found by external_id  |
| **InventoryItem**       | Search only   | Must pre-exist in NetSuite                     |
| **Location**            | Search only   | Searched by name (contains), must pre-exist    |
| **Subsidiary**          | Get           | Hardcoded internal_id: 1                       |
| **Employee (SalesRep)** | Get           | Hardcoded internal_id: 22923                   |
| **Invoice**             | Search        | Used for Workcover processing                  |

### SalesOrder Custom Fields

Mapped from `line_item.data` jsonb via `NetSuiteFieldProvider`:

| NetSuite Field                   | Data Key                  |
| -------------------------------- | ------------------------- |
| `custcol_dwr_kinn_wor_name`      | applicant_name            |
| `custcol_dwr_kinn_refe_name`     | referrer_name             |
| `custcol_dwr_kinn_care_id_no`    | carelever_id_number       |
| `custcol_dwr_kinn_po_no`         | purchase_order            |
| `custcol_dwr_kinn_dob`           | date_of_birth             |
| `custcol_dwr_kinn_site`          | site                      |
| `custcol_dwr_kinn_positi`        | position                  |
| `custcol_dwr_kinn_cost_cen_no`   | cost_centre_number        |
| `custcol_dwr_kinn_claim_no`      | claim_number              |
| `custcol_dwr_kinn_prov_no`       | kinnect_provider_number   |
| `custcol_dwr_kinn_insu`          | insurer                   |
| `custcol_dwr_kinn_agent`         | agent                     |
| `custcol_dwr_kinn_cos_date`      | cost_to_date              |
| `custcol_dwr_kinn_tot_appr_cost` | total_approved_cost       |
| `custcol_dwr_kinn_bal_rema_plan` | balance_remaining_on_plan |
| `custcol_dwr_kinn_serv_reques`   | service_requested         |
| `custcol_dwr_kinn_servi_date`    | service_date              |
| `custcol_dwr_kinn_duration`      | duration                  |
| `custcol_dwr_kin_consultant`     | consultant_name           |

---

## Billing Schedule & Processing

### API Endpoints

```
POST /v1/billing/line_items              ← Receive from upstream
GET  /v1/billing/daily/validate          ← Validate daily batch
POST /v1/billing/daily/run               ← Create daily SalesOrders
GET  /v1/billing/weekly/validate
POST /v1/billing/weekly/run
GET  /v1/billing/monthly/validate
POST /v1/billing/monthly/run
POST /v1/billing/workcover/run           ← Process Workcover invoices
GET  /v1/billing/dashboard               ← Dashboard data
WS   /v1/billing/cable                   ← ActionCable for real-time logs
```

All validate/run endpoints accept: `?date=YYYY-MM-DD&customer_id=UUID&source=screen|monitor|manage&grouping=XXX`

### Processing Pipeline

```
1. Filter line items by schedule (daily/weekly/monthly) + date + optional filters
   → ModelGetter::Daily/Weekly/Monthly + QueryBuilder

2. Group by customer_uuid + grouping

3. For each group:
   a. VALIDATE (Chain of Responsibility):
      LocationStep → CustomerStep → InventoryItemStep → SalesRepStep → LineItemStep

   b. BUILD (Builder Pattern):
      SalesOrder Builder
        ├── Customer Builder (search or create)
        ├── SalesOrderItemList Builder
        │     └── SalesOrderItem Builder (per line item)
        │           ├── InventoryItem Builder (search + cache)
        │           └── Location Builder (search + cache)
        ├── Subsidiary Builder (hardcoded id: 1)
        └── SalesRep Builder (hardcoded id: 22923)

   c. UPSERT to NetSuite via SOAP

   d. Fetch created SO, update line_items.sales_order
      → Triggers shadow insert + line_items delete

   e. Workcover::LineItemProcessor checks for Workcover items
```

### Concurrency Control

Uses class variable `@@counter` to limit to 3 concurrent threads. Not ideal for scale.

### Real-time Updates

ActionCable broadcasts log messages to 'messages' channel for dashboard WebSocket clients.

---

## Workcover Integration

### Flow

1. After SO creation, `Workcover::LineItemProcessor` checks if any line items have `invoicing_entity_email == 'upload@wcq.kinnect'`
2. Creates `WorkcoverLineItem` records with SO data + claim details from `line_item.data`
3. Manual trigger via `POST /v1/billing/workcover/run`
4. `Workcover::InvoiceProcessor`:
   - Groups workcover line items by sales_order
   - Searches NetSuite for Invoices created from the SalesOrder
   - Picks invoice with max total amount
   - Formats JSON payload with invoice + item details
   - POSTs to Workcover Portal API
5. On success, updates `invoice_number` → triggers shadow archive + delete

### Workcover API Auth

```ruby
# Net::HTTP POST with:
'Authorization' => "Basic #{Base64.encode64("#{username}:#{password}")}"
'API_CLIENT_KEY' => ENV['WORKCOVER_API_KEY']
```

Env vars: `WORKCOVER_URL`, `WORKCOVER_API_KEY`, `WORKCOVER_USERNAME`, `WORKCOVER_PASSWORD`

---

## Key Architecture Patterns

| Pattern                 | Where                                            |
| ----------------------- | ------------------------------------------------ |
| Command (SimpleCommand) | All business logic                               |
| Builder                 | SalesOrder/Customer/Item construction            |
| Chain of Responsibility | Validation pipeline                              |
| Strategy                | Daily/Weekly/Monthly billing schedules           |
| Shadow Table            | Archive processed records via DB triggers        |
| Foreign Data Wrapper    | Read upstream line items directly from their DBs |

---

## Key Files

| Purpose                | File                                                                        |
| ---------------------- | --------------------------------------------------------------------------- |
| Line item model        | `carelever_billing/app/models/line_item.rb`                                 |
| Line item creation     | `carelever_billing/app/commands/line_items/create.rb`                       |
| Line items controller  | `carelever_billing/app/controllers/v1/billing/line_items_controller.rb`     |
| NetSuite config        | `carelever_billing/config/initializers/netsuite.rb`                         |
| NetSuite helper        | `carelever_billing/app/services/net_suite_helper.rb`                        |
| SO builder             | `carelever_billing/app/services/sales_orders/builder/sales_order.rb`        |
| Customer builder       | `carelever_billing/app/services/sales_orders/builder/customer.rb`           |
| SO item builder        | `carelever_billing/app/services/sales_orders/builder/sales_order_item.rb`   |
| Inventory item builder | `carelever_billing/app/services/sales_orders/builder/inventory_item.rb`     |
| Custom field provider  | `carelever_billing/app/services/net_suite_field_provider.rb`                |
| Validator factory      | `carelever_billing/app/services/sales_orders/validator/factory.rb`          |
| Process run            | `carelever_billing/app/commands/sales_orders/process/run.rb`                |
| Process validate       | `carelever_billing/app/commands/sales_orders/process/validate.rb`           |
| Workcover processor    | `carelever_billing/app/services/workcover/line_item_processor.rb`           |
| Workcover invoice      | `carelever_billing/app/services/workcover/invoice_processor.rb`             |
| Workcover sender       | `carelever_billing/app/services/workcover/sender.rb`                        |
| Screen sender          | `carelever_screen/app/commands/line_items/send_to_carelever_billing.rb`     |
| Monitoring sender      | `carelever_monitoring/app/commands/line_items/send_to_carelever_billing.rb` |
| DB schema              | `carelever_billing/db/schema.rb`                                            |
| Routes                 | `carelever_billing/config/routes.rb`                                        |

---

## Notes for Reimplementation

1. **Shadow table pattern** could be replaced with a `status` column or soft-delete approach
2. **FDW views** create tight DB coupling — consider event-driven ingestion instead
3. **@@counter concurrency** is fragile — use proper job queue (Sidekiq/SQS)
4. **Hardcoded NetSuite IDs** (subsidiary: 1, sales rep: 22923) should be configurable
5. **InventoryItems must pre-exist** in NetSuite — billing cannot create them
6. **No retry mechanism** for failed SO creations
7. **Workcover processing is manual** (triggered via API call) — could be automated
8. **SOAP API** — NetSuite also offers REST API (SuiteTalk REST) which may be preferable for new builds
