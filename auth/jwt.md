## JWT Token Payload And Usage In Screen/Hub Manage

The auth service issues several JWT variants (internal, external, comply, plus short-lived password-authenticated tokens). Core claims are mostly shared, with some flow-specific additions.

### Common Core Claims

- Identity: user_id, email, first_name, last_name
- Tenant/context: organisation_id, organisation_slug, company_id
- Authorization context: access (bitmask), classification, roles, access_roles
- Session/client binding: ip_address, request_origin, user_agent
- Security UX: otp_mode

### Flow-Specific Claims

- Internal token adds: username, mobile, preference, options, sender_email/sender_key/sender_state, is_internal, user_consultant, restrict_company_view
- External token adds: company_name, screen_access/monitor_access/manage_access/comply_access, company_access, subscribed_micro_subscriptions, is_screen_to_monitor_export_allowed, intercom hashes
- Comply token adds: stripe_customer_id, comply_access, comply_employment_type, comply_location_id, contact details (mobile/landline), sex, birthdate
- Password-authenticated token (5 min) includes a reduced set plus is_password_authenticated=true

### How Screen Uses JWT Claims

1. Request authentication and payload injection:
   - Decodes JWT and injects payload to request user params in middleware.
2. Multi-tenant routing:
   - Uses organisation_id from payload to switch Apartment tenant.
3. Access gate:
   - Uses access bitmask to verify screen access before controller actions.
4. Role-based authorization:
   - Uses access_roles for policy checks (internal and external role slugs).
5. Company-level gating and scoping:
   - Uses company_access.for_screen to permit external access.
   - Uses access_roles site lists/all to evaluate site-level visibility.
6. Token source validation:
   - Validates ip_address OR request_origin+user_agent against current request.

### How Hub Manage Uses JWT Claims

1. Request authentication and payload injection:
   - Decodes JWT and injects payload into request env/params.
2. Multi-tenant routing:
   - Uses organisation_id to resolve tenant via TokenElevator.
3. Current user context:
   - CurrentUser reads user_id, company_id, classification, timezone, access_roles, access.
4. Role and module authorization:
   - Policies check access_roles for standard_external/restricted_access.
   - Manage access also requires company_access.for_manage for external users.
   - Settings policies read company role from access_roles["company"] and default to company_user if absent.
5. Row-level scope checks:
   - Uses company_id and accessible site IDs from access_roles to allow/deny case-profile records.
6. Token source validation:
   - Same source-binding checks with ip_address/request_origin/user_agent.

### Practical Note

Although auth emits both roles (string array) and access_roles (JSON map), screen and hub_manage primarily rely on access_roles for permission checks.

## Sample jwt

```json
{
  "user_id": "38f325a1-b3b4-4842-99b6-d5095f8fe311",
  "email": "jc@carelever.com",
  "mobile": "",
  "username": "jc.shin",
  "first_name": "JC",
  "last_name": "Shin",
  "organisation_id": "f7290827-c426-4e92-8ba6-45fd12ca5a70",
  "organisation_slug": "kinnect",
  "company_id": "81316bd2-fb99-452b-9200-0d7f7faca62c",
  "default_country_code": "AU",
  "business_hours_start": 9,
  "business_hours_end": 17,
  "timezone": "Brisbane",
  "access": "00001110",
  "preference": "monitor",
  "options": {},
  "sender_email": "",
  "sender_key": "1gI/0A==--qFqxSleLGfXPnj5j--RGXe/GZrLoGhuvhaHJh19A==",
  "sender_state": "",
  "roles": [
    "screen:administrator:00000000-0000-0000-0000-000000000000:00000000-0000-0000-0000-000000000000",
    "monitor:administrator:00000000-0000-0000-0000-000000000000:00000000-0000-0000-0000-000000000000",
    "manage:administrator:00000000-0000-0000-0000-000000000000:00000000-0000-0000-0000-000000000000",
    "comply:administrator:00000000-0000-0000-0000-000000000000:00000000-0000-0000-0000-000000000000"
  ],
  "access_roles": {
    "screen": {
      "administrator": "all"
    },
    "monitor": {
      "administrator": "all"
    },
    "manage": {
      "administrator": "all"
    },
    "comply": {
      "administrator": "all"
    }
  },
  "is_internal": true,
  "classification": "internal",
  "created_at": "2026-03-04 23:23:20 UTC",
  "otp_mode": "authenticator_app",
  "ip_address": "60.241.24.114",
  "user_agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
  "request_origin": "https://app.dev.carelever.com",
  "user_consultant": {
    "location_name": null,
    "role_name": null,
    "employment_status": null,
    "employment_start_date": "05 Mar 2026"
  },
  "restrict_company_view": false,
  "exp": 1774533599
}
```
