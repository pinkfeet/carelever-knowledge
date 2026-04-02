# Self-Booking Feature

## Overview
Self-booking allows candidates to book their own screening appointments via a link sent in SMS/email. The link is generated regardless of whether self-booking is actually configured — validation happens when the candidate opens the link.

## Validation Conditions
All must be **true** for self-booking to be valid (see `carelever_screen/app/commands/self_bookings/validate_for_self_booking.rb`):

1. **Organisation** has `self_booking_enabled: true`
2. **Company** has `self_bookable: true`
3. At least one **Location** has `self_bookable: true`
4. **Screening items** are `self_bookable: true` and `is_appointment_required: true`
5. For screening item collections, **all children** must also be `self_bookable: true`
6. Every appointment-required screening item count matches self-bookable count

## Who Uses It
Self-booking routes exist for all three user types:

| Namespace | User | Routes |
|-----------|------|--------|
| `v1/screen/public` | **Candidate** | `applicant_self_bookings` — public-facing flow via SMS link |
| `v1/screen/external` | **Internal staff** | `self_bookings`, `validate_for_self_booking` |
| `v1/internal/external` | **Company client** | `self_bookings` |

**Note:** `validate_for_self_booking` under `v1/screen/external` appears to be unused/dead code — no frontend references it.

## Candidate Flow
1. SMS is sent with `{{applicant_self_booking_link}}` template variable (link always generated, no pre-validation)
2. Candidate clicks link -> opens `screen-applicant-self-booking-link` component in `carelever_internal_ui`
3. Component calls `GET /v1/screen/public/applicant_self_bookings` (index action)
4. If referral not found -> 400 error
5. After loading, candidate selects country/suburb -> gets suggested clinics
6. Component calls `available_dates` for the selected clinic
7. If dates available -> `canSelfBook = true`, candidate can pick a time slot
8. If no dates available -> falls back to availability submission form (`showAvailability = true`)
9. If backend returns `not_valid_for_self_booking` -> shows "Invalid Page" message

## Link Generation
- `Referral#generate_applicant_self_booking_link` calls `V1::PublicLinks::Generate`
- Creates a `PublicLink` record with encrypted token
- URL format: `{domain}/internal/screen-external-access/applicant_self_booking/{encrypted_token}`
- Token decoded by `AuthenticationTokenParser` middleware using `public_link_secret_key`

## Key Database Columns

### organisations
- `self_booking_enabled` (boolean, default: false)

### companies
- `self_bookable` (boolean, default: false)

### locations
- `self_bookable` (boolean, default: false)
- `self_booking_max_value` (integer, default: 14)
- `self_booking_max_unit` (string, default: "days")
- `self_booking_min_value` (integer, default: 3)
- `self_booking_min_unit` (string, default: "hours")
- `self_booking_business_hours` (json)

### screening_items
- `self_bookable` (boolean, default: false)
- `self_bookable_category` (string)

### consultants
- `self_bookable` (boolean, default: false)
- `self_booking_priority` (integer)

### appointments
- `self_bookable` (boolean, default: false)

## Testing Self-Booking Locally

### Prerequisites (all required)
1. `Organisation.last.update(self_booking_enabled: true)`
2. `Company.find(id).update(self_bookable: true)`
3. `Location.find(id).update(self_bookable: true)`
4. `ScreeningItem.where(is_appointment_required: true).update_all(self_bookable: true)`
5. Consultants with `self_bookable: true` and `self_booking_priority` set at the location
6. `consultant_screening_items` mappings exist for matching screening items to time slots

### Generate the Link
```ruby
Apartment::Tenant.switch!('org-id')
referral = Referral.find('referral-id')
referral.generate_applicant_self_booking_link
# => "localhost:4200/internal/screen-external-access/applicant_self_booking/<token>"
```

Without consultants (step 5 & 6), validation passes but the calendar shows no available dates, falling back to availability submission.

## Module Ownership
- **All self-booking logic lives in `carelever_screen`** — validation, available dates calculation, booking creation, triggers
- **`carelever_calendar` is only used as a data source** — screen calls `GET v1/calendar/booked_consultant_schedules` to get existing consultant schedules, then calculates available slots itself
- Calendar module has zero knowledge of self-booking; it just returns booked schedules for given consultant IDs and date range
- The call is made via `SelfBookings::GetAvailableRoomsByDateRange` which uses `CareleverServices::CalendarService`

## Key Files
- **Validation:** `carelever_screen/app/commands/self_bookings/validate_for_self_booking.rb`
- **Public controller:** `carelever_screen/app/controllers/v1/screen/public/applicant_self_bookings_controller.rb`
- **Index command:** `carelever_screen/app/commands/v1/applicant_self_bookings/index.rb`
- **Serializer:** `carelever_screen/app/serializers/applicant_self_bookings_serializer.rb`
- **Link generation:** `carelever_screen/app/commands/v1/public_links/generate.rb`
- **SMS variable:** `carelever_screen/app/controllers/concerns/sms_email_variables.rb` (line 686)
- **Frontend component:** `carelever_internal_ui/src/app/screen-external-access/screen-applicant-self-booking-link/`
- **Frontend service:** `carelever_internal_ui/src/app/screen-external-access/screen-applicant-self-booking-link/applicant-self-booking.service.ts`
- **Trigger config:** `applicant_self_booking_triggers` table — configures when self-booking SMS is sent
