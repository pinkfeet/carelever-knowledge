# Authentication Login Endpoints

## Login Endpoints by Classification

| Endpoint | Classification | Login format | Users | MFA |
|---|---|---|---|---|
| `POST /v1/authentication/internal/authenticate` | `internal` | `username@org-slug` | Staff, admins, operations | Yes — email, SMS, or authenticator app (per `otp_mode`) |
| `POST /v1/authentication/external/authenticate` | `external` | `email` | Clients, employers, doctors | Yes — email, SMS, or authenticator app |
| `POST /v2/affiliate/authenticate` | `affiliate` | `username@org-slug` | Affiliate clinic users | **Yes** — email OTP (default) or authenticator app (Assessment UI uses this) |
| `POST /v1/authentication/affiliate/authenticate` | `affiliate` | `username@org-slug` | Affiliate clinic users | Legacy — returns full JWT without MFA gate; **not used by Assessment affiliate app** |

### OTP Endpoints (internal, external, and affiliate)

| Endpoint | Purpose |
|---|---|
| `POST /v1/authentication/internal/request_otp` | Request OTP for internal user |
| `POST /v1/authentication/internal/authenticate_otp` | Verify OTP for internal user |
| `POST /v1/authentication/external/request_otp` | Request OTP for external user |
| `POST /v1/authentication/external/authenticate_otp` | Verify OTP for external user |
| `POST /v1/authentication/affiliate/request_otp` | Resend OTP for affiliate user (during MFA step) |
| `POST /v1/authentication/affiliate/authenticate_otp` | Verify OTP for affiliate user |

## Login Flow

### Internal / External (with MFA)

1. User submits credentials → `POST .../authenticate`
2. Auth service validates password, returns JWT with `otp_mode` in payload
3. If `otp_mode` is `sms` or `email` → system sends OTP via `POST .../request_otp`
4. User submits OTP → `POST .../authenticate_otp`
5. If `otp_mode` is `authenticator_app` → user enters TOTP code from app → `POST .../authenticate_otp`
6. If `otp_mode` is `no_otp` → MFA skipped, JWT is immediately usable

### Affiliate (with MFA — Assessment UI)

1. User submits `username@org-slug` + password → `POST /v2/affiliate/authenticate`
2. Auth validates credentials. If a valid remember-device cookie is present → full JWT immediately. Otherwise → `login_attempt: "otp_required"` + short-lived OTP-scoped JWT; Auth emails a 6-digit code (`Affiliate::OtpLoginMailer`).
3. User enters OTP → `POST /v1/authentication/affiliate/authenticate_otp` → full affiliate JWT.
4. Optional: user can enroll an authenticator app via `/v1/authentication/affiliate/users/otp_modes/*` (profile MFA setup).

See `carelever_authentication/docs/features/affiliate-mfa.md` for full behaviour (CT-4112 pentest remediation).

## User Creation by Classification

| Classification | Created via | Notes |
|---|---|---|
| `internal` | Internal UI → auth service settings endpoints | Full user with access roles per service |
| `external` | Internal UI or client UI → auth service settings endpoints | Email-based login, linked to a company |
| `affiliate` | Internal UI at `/settings/general/location/{uuid}/affiliate-users` → `POST /v1/authentication/settings/affiliate_location_users` | Linked to a supplier location, `last_name` hardcoded to `'Location'` |

## Account Locking

All classifications share the same locking mechanism:
- After `MAX_LOGIN_ATTEMPTS` failed logins → account locked for `RETRY_LOGIN_MINUTES` minutes
- Locked state stored in `users.locked`, `users.locked_until`, `users.login_attempts`
- Successful login resets counter via `user.reset_login_counter`

## Doctor Login

Doctors do not have a separate login endpoint. They are `external` classification users with specific access roles granting doctor-level permissions. They log in via `/v1/authentication/external/authenticate` using their email + password, with MFA.

## Frontend Apps

| App | Login URL | Auth endpoint used |
|---|---|---|
| `carelever_internal_ui` | `/login` | internal authenticate |
| `carelever_client_ui` | `/login` | external authenticate |
| `carelever_assessment_ui` (affiliate app) | `/login` | `POST /v2/affiliate/authenticate` + affiliate OTP endpoints |
| `carelever_affiliate_ui` (legacy) | `/affiliate/login` | v1 affiliate authenticate (pre-MFA) |
| `carelever_hub_ui` | `/login` | internal authenticate |
| `carelever-replit-reimagined` | Multiple portals (admin, client, candidate, affiliate) | All — monolith handles auth internally |
