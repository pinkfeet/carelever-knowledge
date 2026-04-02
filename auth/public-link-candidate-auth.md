# Candidate Public-Link Authorization

Date: 2026-04-02

## Overview

The candidate self-booking page does **not** use normal staff or candidate login.

It uses a dedicated public-link flow:

1. Candidate receives a generated public URL containing an encrypted token (`encoded_iv`)
2. Frontend opens `/internal/screen-external-access/validation/applicant_self_booking/:encoded_iv`
3. Backend validates the link and sends a 6-digit OTP
4. Candidate enters the OTP
5. Backend returns a narrow JWT for external page access
6. Frontend stores that JWT and uses it for later self-booking API calls

This is a one-referral, one-link authorization flow, not a reusable application session.

## Frontend Flow

### Validation Route

- Validation page route: `/screen-external-access/validation/:reroute_path/:encoded_iv`
- Self-booking page route: `/screen-external-access/applicant_self_booking/:encoded_iv`

The Angular guard first calls the Screen backend to validate the link.

If the link is already authorized in the browser, the user is routed directly to the self-booking page.

If not, the user is redirected to the validation page and prompted for OTP.

## Backend Flow

### Step 1: Public Link Validation

`POST /v1/screen/public/public_links/:encoded_iv/validate`

Validation logic:

1. Decode `encoded_iv`
2. Extract `record_id`, `public_link_id`, `record_type`
3. Find the matching `public_links` row
4. Reject if link is invalid or expired
5. If an existing valid auth token is present, return `{ valid: true }`
6. Otherwise send OTP and return a temporary OTP bootstrap token

Possible validation errors:

- `invalid_token`
- `link_expired`

### Step 2: OTP Authentication

`POST /v1/screen/public/public_links/:encoded_iv/authenticate_otp`

The backend verifies:

1. Link still exists
2. Link has not expired
3. OTP has not expired
4. Submitted OTP matches the current OTP state on the `public_links` row

On success, backend returns a JWT signed with `public_link_secret_key`.

### Step 3: Authorized Public API Access

Subsequent self-booking requests go to endpoints like:

- `GET /v1/screen/public/applicant_self_bookings`
- `GET /v1/screen/public/applicant_self_bookings/available_dates`
- `POST /v1/screen/public/applicant_self_bookings/reserve_date`

These requests must send the returned JWT in the `Authentication` header.

## JWT Shape And Scope

The OTP-authenticated JWT includes claims such as:

- `organisation_id`
- `public_link_id`
- `record_id`
- `record_type`
- `external_form_access: true`
- `ip_address`
- `request_origin`
- `user_agent`
- `exp`

This token is intentionally narrow:

- It authorizes access to one public-link flow
- It is tied to one referral/public link
- It is not a full internal or external user session

## Why This Token Is Accepted In Screen

Screen middleware has special handling for applicant self-booking public endpoints:

1. Public link validation endpoints are skipped from normal auth middleware checks
2. Applicant self-booking public endpoints decode JWT using `public_link_secret_key`
3. `external_form_access` bypasses normal token-source restrictions
4. The public base controller requires `Authentication` header and `organisation_id`
5. The public base controller switches Apartment tenant using `organisation_id`

That means authorization is enforced by:

- possession of the correct public link
- successful OTP verification
- possession of the returned JWT
- tenant scoping via `organisation_id`

## Does This JWT Work In Other Microservices?

Usually **no**.

`external_form_access` is a shared pattern across multiple services, but this specific Screen self-booking JWT is not a general cross-service credential.

Why not:

1. Other services often decode with different keys (`API_SECRET_KEY` or service-specific public-link handling)
2. Other services only allow their own public-link paths to use special public-link keys
3. The Screen token payload is designed for Screen public-link flows, not generic inter-service access

Examples:

- Hub Manage decodes normal requests with `API_SECRET_KEY`, so the Screen self-booking token is not accepted as a normal auth token there
- Manage has its own public-link flow and own accepted public-link paths
- Form supports `external_form_access`, but through Form-specific token handling and paths

So the correct mental model is:

- `external_form_access` = shared authorization pattern
- Screen applicant self-booking JWT = Screen-specific token instance

## How It Still Calls Calendar

The candidate JWT does **not** call Calendar directly.

Instead, the flow is:

1. Candidate calls Screen public self-booking endpoint
2. Screen validates the candidate public-link JWT
3. Screen generates a new short-lived inter-service JWT using `api_secret_key`
4. Screen calls Calendar with that inter-service JWT in the `Authentication` header
5. Calendar accepts it because the payload includes `inter_microservice_request: true`

So there are two different tokens involved:

- Candidate token: public-link + OTP based, scoped to Screen public endpoints
- Inter-service token: backend-generated, 5-minute token for Screen -> Calendar communication

The inter-service token is generated from the current request user payload using:

```ruby
JsonWebToken.encode(user_hash_with_inter_microservice_request, 5.minutes.from_now, key: Rails.application.secrets.api_secret_key)
```

That helper adds:

```ruby
inter_microservice_request: true
```

Calendar middleware checks for that flag and treats the request as trusted server-to-server access.

This is why the candidate flow can use Calendar data without exposing Calendar directly to the browser.

## OTP Storage

OTP data is stored on the `public_links` table, not in plaintext form.

Relevant columns:

- `otp_secret_key`
- `otp_counter`
- `otp_attempts`
- `otp_expires_at`
- `otp_reference`

The current OTP value itself is not stored in plaintext in the database.

Generating a new OTP rotates the current OTP state for that same `public_links` row.

## Practical Debugging Notes

### Why A Code Can Fail Even If It Looks Correct

If the browser shows reference `FYNW`, but the backend has already generated a newer OTP/reference, the old displayed code will fail.

The code and reference must match the current OTP state of the same `public_links` row.

### How To Get A Fresh Link

Normal path:

1. Open the referral profile in internal UI
2. Go to Forms
3. Click `Send to Applicant`

This creates a new `public_links` row and sends a new applicant self-booking link.

### How To Inspect A Link In Rails Console

```ruby
encoded_iv = "..."
record_id, public_link_id, record_type = V1::PublicLinks::Encryption.decode(encoded_iv)

org = Organisation.find_by!(slug: "kinnect")
Apartment::Tenant.switch(org.id) do
  pl = PublicLink.find_by!(id: public_link_id, record_id: record_id, record_type: record_type)
  puts pl.attributes.slice("id", "record_id", "record_type", "link_expires_at", "otp_expires_at", "otp_reference", "otp_attempts", "otp_counter")
end
```

### How To Generate A Fresh OTP In Rails Console

```ruby
encoded_iv = "..."
record_id, public_link_id, record_type = V1::PublicLinks::Encryption.decode(encoded_iv)

org = Organisation.find_by!(slug: "kinnect")
Apartment::Tenant.switch(org.id) do
  pl = PublicLink.find_by!(id: public_link_id, record_id: record_id, record_type: record_type)
  result = Otp::Generator.new(pl).call
  puts result[:otp]
  puts result[:otp_reference]
  puts pl.reload.otp_expires_at
end
```

This rotates the active OTP for that link.

## Key Files

- `carelever_internal_ui/src/app/screen-external-access/screen-external-access-routing.module.ts`
- `carelever_internal_ui/src/app/screen-external-access/screen-external-access.guard.ts`
- `carelever_internal_ui/src/app/screen-external-access/screen-external-access.service.ts`
- `carelever_internal_ui/src/app/screen-external-access/validation/validation.component.ts`
- `carelever_screen/app/controllers/v1/screen/public/public_links_controller.rb`
- `carelever_screen/app/controllers/v1/screen/public/base_controller.rb`
- `carelever_screen/app/controllers/v1/screen/public/applicant_self_bookings_controller.rb`
- `carelever_screen/app/controllers/application_controller.rb`
- `carelever_screen/app/commands/self_bookings/get_available_rooms_by_date_range.rb`
- `carelever_screen/app/commands/v1/public_links/validate.rb`
- `carelever_screen/app/commands/v1/public_links/authenticate_otp.rb`
- `carelever_screen/app/commands/v1/public_links/generate.rb`
- `carelever_screen/app/services/otp/generator.rb`
- `carelever_screen/app/middlewares/authentication_token_parser.rb`
- `carelever_calendar/app/middlewares/authentication_token_parser.rb`
- `carelever_calendar/app/controllers/v1/calendar/booked_consultant_schedules_controller.rb`
