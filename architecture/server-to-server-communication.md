# Server-to-Server HTTP Communication Between ECS Microservices

## Pattern

All inter-service calls use the **CareleverServices::Base** pattern (HTTParty-based wrappers) or direct **HttpClient** classes. Services authenticate using **JWT tokens** passed as the `Authentication` header with `inter_microservice_request: true` flag, valid for 5 minutes.

---

## 1. Screen -> Calendar

**Service:** `CareleverServices::CalendarService` | **Dev:** localhost:3030

| Endpoint                                   | Method | Called By                                    | File                                                                               |
| ------------------------------------------ | ------ | -------------------------------------------- | ---------------------------------------------------------------------------------- |
| `/v1/calendar/booked_consultant_schedules` | GET    | `SelfBookings::GetAvailableRoomsByDateRange` | `carelever_screen/app/commands/self_bookings/get_available_rooms_by_date_range.rb` |

### Auth Note

This Calendar endpoint is **not** called with the candidate public-link JWT used by the self-booking page.

Screen first generates a short-lived inter-service JWT using `api_secret_key` and payload from `user_hash_with_inter_microservice_request`, which adds `inter_microservice_request: true`.

That inter-service JWT is then forwarded in the `Authentication` header to Calendar.

Calendar middleware accepts the request because it recognizes `inter_microservice_request: true` as trusted server-to-server access.

This means the call chain is:

1. Browser -> Screen public self-booking endpoint
2. Screen -> Calendar with backend-generated inter-service JWT

Relevant files:

- `carelever_screen/app/controllers/v1/screen/public/applicant_self_bookings_controller.rb`
- `carelever_screen/app/controllers/application_controller.rb`
- `carelever_calendar/app/middlewares/authentication_token_parser.rb`

---

## 2. Screen -> Form

**Service:** `CareleverServices::FormService` + `HttpClient::*` | **Dev:** localhost:3040

| Endpoint                                                 | Method | Called By                                | File                                                                          |
| -------------------------------------------------------- | ------ | ---------------------------------------- | ----------------------------------------------------------------------------- |
| `/v1/form/public/public_links/generate`                  | POST   | `V1::PublicLinks::GenerateFormLink`      | `carelever_screen/app/commands/v1/public_links/generate_form_link.rb`         |
| `/v1/form/referral_forms`                                | GET    | `HttpClient::ReferralForms`              | `carelever_screen/app/services/http_client/referral_forms.rb`                 |
| `/v1/form/referral_forms`                                | POST   | `HttpClient::CreateReferralForm`         | `carelever_screen/app/services/http_client/create_referral_form.rb`           |
| `/v1/form/referral_forms/get_referral_forms_by_statuses` | GET    | `HttpClient::GetReferralFormsByStatuses` | `carelever_screen/app/services/http_client/get_referral_forms_by_statuses.rb` |
| `/v1/form/referral_forms/status`                         | GET    | `HttpClient::ReferralFormStatus`         | `carelever_screen/app/services/http_client/referral_form_status.rb`           |
| `/v1/form/referral_forms_query`                          | GET    | `HttpClient::ReferralFormQuery`          | `carelever_screen/app/services/http_client/referral_form_query.rb`            |
| `/v1/form/nps_referral_forms`                            | GET    | `HttpClient::NpsReferralForm`            | `carelever_screen/app/services/http_client/nps_referral_form.rb`              |

---

## 3. Screen -> Comply

**Service:** `CareleverServices::ComplyService` | **Dev:** localhost:3050

| Endpoint                                  | Method | Called By                             | File                                                                    |
| ----------------------------------------- | ------ | ------------------------------------- | ----------------------------------------------------------------------- |
| `/v1/comply/public/public_links/generate` | POST   | `V1::PublicLinks::GenerateComplyLink` | `carelever_screen/app/commands/v1/public_links/generate_comply_link.rb` |

---

## 4. Screen -> Billing

**Pattern:** Direct HTTParty | **Dev:** localhost:3035 | **Auth:** `billing_token` header from `BILLING_TOKEN` env var

| Endpoint                 | Method | Called By                           | File                                                                    |
| ------------------------ | ------ | ----------------------------------- | ----------------------------------------------------------------------- |
| `/v1/billing/line_items` | POST   | `LineItems::SendToCareleverBilling` | `carelever_screen/app/commands/line_items/send_to_carelever_billing.rb` |

---

## 5. Monitoring -> Form

**Service:** `CareleverServices::FormService` + `HttpClient::*` | **Dev:** localhost:3040

| Endpoint                                                  | Method | Called By                                  | File                                                                               |
| --------------------------------------------------------- | ------ | ------------------------------------------ | ---------------------------------------------------------------------------------- |
| `/v1/form/public/public_links/generate`                   | POST   | `V1::PublicLinks::GenerateFormLink`        | `carelever_monitoring/app/commands/v1/public_links/generate_form_link.rb`          |
| `/v1/form/referral_forms`                                 | POST   | `HttpClient::CreateReferralForm`           | `carelever_monitoring/app/services/http_client/create_referral_form.rb`            |
| `/v1/form/master_forms`                                   | GET    | `HttpClient::GetMasterForms`               | `carelever_monitoring/app/services/http_client/get_master_forms.rb`                |
| `/v1/form/referral_forms/get_referral_forms_by_statuses`  | GET    | `HttpClient::GetReferralFormsByStatuses`   | `carelever_monitoring/app/services/http_client/get_referral_forms_by_statuses.rb`  |
| `/v1/form/referral_forms/status`                          | GET    | `HttpClient::ReferralFormStatus`           | `carelever_monitoring/app/services/http_client/referral_form_status.rb`            |
| `/v1/form/referral_forms/submitted_referral_forms`        | GET    | `HttpClient::SubmittedReferralForms`       | `carelever_monitoring/app/services/http_client/submitted_referral_forms.rb`        |
| `/v1/form/referral_form_data/{referral_id}`               | PUT    | `HttpClient::RefreshReferralForms`         | `carelever_monitoring/app/services/http_client/refresh_referral_forms.rb`          |
| `/v1/form/referral_forms/get_result_data`                 | GET    | `HttpClient::GetReferralFormResultData`    | `carelever_monitoring/app/services/http_client/get_referral_form_result_data.rb`   |
| `/v1/form/referral_forms/clinic_submitted_referral_forms` | GET    | `HttpClient::ClinicSubmittedReferralForms` | `carelever_monitoring/app/services/http_client/clinic_submitted_referral_forms.rb` |
| `/v1/form/referral_forms/non_clinic_referral_forms`       | GET    | `HttpClient::NonClinicReferralForms`       | `carelever_monitoring/app/services/http_client/non_clinic_referral_forms.rb`       |
| `/v1/form/referral_forms/value`                           | GET    | `HttpClient::ReferralFormValue`            | `carelever_monitoring/app/services/http_client/referral_form_value.rb`             |

---

## 6. Monitoring -> Comply

**Service:** `CareleverServices::ComplyService` | **Dev:** localhost:3050

| Endpoint                                  | Method | Called By                             | File                                                                        |
| ----------------------------------------- | ------ | ------------------------------------- | --------------------------------------------------------------------------- |
| `/v1/comply/public/public_links/generate` | POST   | `V1::PublicLinks::GenerateComplyLink` | `carelever_monitoring/app/commands/v1/public_links/generate_comply_link.rb` |

---

## 7. Monitoring -> Billing

**Pattern:** Direct HTTParty | **Dev:** localhost:3035 | **Auth:** `billing_token` header from `BILLING_TOKEN` env var

| Endpoint                 | Method | Called By                           | File                                                                        |
| ------------------------ | ------ | ----------------------------------- | --------------------------------------------------------------------------- |
| `/v1/billing/line_items` | POST   | `LineItems::SendToCareleverBilling` | `carelever_monitoring/app/commands/line_items/send_to_carelever_billing.rb` |

---

## 8. Organisation -> API (Screen/Calendar)

**Pattern:** `Net::HTTP` via `Util::HttpRequest` | **Config:** `api_domain`

| Called By           | File                                                       |
| ------------------- | ---------------------------------------------------------- |
| `Util::HttpRequest` | `carelever_organisation/app/commands/util/http_request.rb` |

---

## 9. Billing -> External Services (Non-ECS)

| Service   | Auth                                                                         | Called By           | File                                                 |
| --------- | ---------------------------------------------------------------------------- | ------------------- | ---------------------------------------------------- |
| Workcover | Basic Auth (`WORKCOVER_API_KEY`, `WORKCOVER_USERNAME`, `WORKCOVER_PASSWORD`) | `Workcover::Sender` | `carelever_billing/app/services/workcover/sender.rb` |
| NetSuite  | SDK Integration                                                              | `NetSuiteHelper`    | `carelever_billing/app/services/net_suite_helper.rb` |

---

## Communication Summary Diagram

```
Screen ──HTTP──> Calendar (booked schedules)
Screen ──HTTP──> Form (referral forms, public links)
Screen ──HTTP──> Comply (public links)
Screen ──HTTP──> Billing (line items)

Monitoring ──HTTP──> Form (referral forms, public links, result data)
Monitoring ──HTTP──> Comply (public links)
Monitoring ──HTTP──> Billing (line items)

Organisation ──HTTP──> API (dynamic)

Billing ──HTTP──> Workcover (external)
Billing ──SDK───> NetSuite (external)
```

## Dev Ports

| Service  | Port |
| -------- | ---- |
| Screen   | 3000 |
| Calendar | 3030 |
| Billing  | 3035 |
| Form     | 3040 |
| Comply   | 3050 |

## Config Files

- `carelever_screen/config/domain_names.yml`
- `carelever_monitoring/config/domain_names.yml`
