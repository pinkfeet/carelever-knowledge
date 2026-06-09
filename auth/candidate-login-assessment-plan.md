# Candidate Login — Assessment API Plan

Date: 2026-05-11

## Overview

Adds candidate authentication to `carelever_assessment` (Rails JSON API). Candidates log in via one of two flows:

1. **Token login** — click magic link containing `candidate_access_token` from the Referral record → receive JWT. This is the primary entry point; the link is referral-specific and sent on referral creation.
2. **OTP flow** — from the token-login page, candidate can choose "send me a code instead" → OTP sent to their email → submit code → receive JWT. The `referral_id` is carried from the magic link URL; there is no standalone email-based lookup. This mirrors screen's pattern where the public link identifies the referral and OTP is a second path on top of it.

The issued JWT carries `is_candidate_session: true` — the existing middleware and `V1::Candidate::ApplicationController` already handle this claim. We are only adding the session creation layer.

## Auth Record

`Referral` model. Relevant columns:

| Column | Purpose |
|---|---|
| `candidate_email` | Login identifier for OTP flow |
| `candidate_otp_code` | Stored plaintext OTP (cleared after use) |
| `candidate_otp_expires_at` | OTP TTL (10 minutes) |
| `candidate_access_token` | Magic link token for token login flow |
| `candidate_access_token_expires_at` | Token TTL |
| `candidate_last_accessed_at` | Updated on every successful login |

## JWT Shape

```json
{
  "is_candidate_session": true,
  "person_id": 123,
  "referral_id": 456,
  "exp": "<24h from now>"
}
```

Signed with `API_SECRET_KEY`. Decoded by `AuthenticationTokenParser` middleware.

## Email Service

**Microsoft Office 365 SMTP** — same provider used by `carelever_screen`.

```
address:    smtp.office365.com
port:       587
auth:       login
starttls:   true
env vars:   SMTP_USERNAME, SMTP_PASSWORD, SMTP_DOMAIN, SMTP_DISPLAY_NAME, CANDIDATE_PORTAL_URL
```

`CANDIDATE_PORTAL_URL` — base URL of the candidate Angular app (e.g. `https://candidate.carelever.com`). Used to build the magic link in invitation emails. Must be added to `.env.example`.

Development: `letter_opener` gem (opens email in browser, no real send).

## Implementation Steps

### A. Email Infrastructure (new to assessment)

- Add `gem "letter_opener"` to `Gemfile` (development group)
- `config/environments/development.rb` — set `delivery_method: :letter_opener`
- `config/environments/production.rb` — SMTP settings as above
- `app/mailers/application_mailer.rb` — base mailer mirroring screen pattern:
  - `default from: "#{DISPLAY_NAME} <#{SYSTEM_EMAIL}>"`
  - `after_action :redirect_to_devs` in non-production (redirects all mail to dev list)
- `app/views/layouts/mailer.html.erb` — shared HTML layout (port from replit: `max-width: 600px` centred card, system font stack)

#### A1. OTP Mailer

- `app/mailers/candidate_otp_mailer.rb`
- `app/views/candidate_otp_mailer/otp_email.html.erb` — port content from screen's `otp_public_mailer/generic_email.haml`, rendered inside replit's mailer layout:
  - Greeting with first name
  - Bold OTP code
  - 10-minute expiry note
  - Security warning (do not forward; contact support if not initiated)
  - No `otp_reference` line (not applicable for candidates)

#### A2. Invitation Mailer (new — token link delivery)

- `app/mailers/candidate_invitation_mailer.rb` — `invitation_email` action, params: `email`, `first_name`, `token`
- `app/views/candidate_invitation_mailer/invitation_email.html.erb` — rendered inside replit's mailer layout:
  - Greeting with first name
  - Brief intro ("You have been invited to complete your pre-employment assessment")
  - Magic link button/URL: `#{ENV['CANDIDATE_PORTAL_URL']}/token-login?token=<token>&referral_id=<referral_id>` — `referral_id` included so the token-login page can pass it to the OTP flow if the candidate chooses "send me a code instead"
  - Note that the link expires in 30 days

### A3. Referral Creation — Token Generation & Invitation Send

In `app/commands/v1/internal/referrals/create.rb`, before saving the referral:

```ruby
candidate_access_token: SecureRandom.urlsafe_base64(32)
candidate_access_token_expires_at: 30.days.from_now
```

After successful save:

```ruby
CandidateInvitationMailer.with(
  email: referral.candidate_email,
  first_name: referral.person.first_name,
  token: referral.candidate_access_token
).invitation_email.deliver_later
```

`deliver_later` keeps the create request fast (Sidekiq already configured).

**Re-invite / token regeneration** — out of scope for this ticket. If staff need to resend the invitation, a separate internal endpoint should be added later that regenerates `candidate_access_token` + `candidate_access_token_expires_at` and re-sends the email.

### B. Middleware — `app/middlewares/authentication_token_parser.rb`

Add candidate session paths to skip list:

```ruby
SKIP_PATHS = %w[/health /healthz /v1/candidate/session].freeze
```

### C. Routes — `config/routes.rb`

```ruby
namespace :candidate do
  resource :session, only: [:create, :destroy] do
    post :request_otp
    post :token_login
  end
end
```

| Method | Path | Action |
|---|---|---|
| POST | `/v1/candidate/session/request_otp` | Send OTP email |
| POST | `/v1/candidate/session` | Verify OTP → return JWT |
| POST | `/v1/candidate/session/token_login` | Magic token → return JWT |
| DELETE | `/v1/candidate/session` | Logout (no-op; client drops token) |

### D. Commands

**`app/commands/v1/candidate/session/request_otp.rb`**
- Accepts `referral_id` (not email) — referral is always known from the magic link URL
- Find `Referral.active.find_by(id: referral_id)`
- Rate-limit: 5 attempts / 15 min via `Rails.cache` (key: `"candidate_otp_attempts:#{referral.id}"`). Cache store must be Redis in production (already present for Sidekiq)
- Generate 6-digit OTP: `SecureRandom.random_number(100_000..999_999).to_s`
- Store `candidate_otp_code` + `candidate_otp_expires_at` (10 min from now)
- `CandidateOtpMailer.with(email: referral.candidate_email, first_name:, otp:).otp_email.deliver_now`
- Success: `{ sent: true }` — always returns success even if referral not found (prevents enumeration)

**`app/commands/v1/candidate/session/authenticate.rb`**
- Accepts `referral_id` + `otp_code`
- Find `Referral.active.find_by(id: referral_id)`
- Check rate limit (same counter as `request_otp`), OTP match, OTP not expired
- On success: clear `candidate_otp_code` / `candidate_otp_expires_at`, update `candidate_last_accessed_at`
- Issue JWT (24h expiry)

**`app/commands/v1/candidate/session/authenticate_from_token.rb`**
- Find `Referral.active.find_by(candidate_access_token:)`
- Validate `candidate_access_token_expires_at > Time.current`
- **Token is reusable** — not consumed on use; valid for 30 days from referral creation. Candidate can click the magic link multiple times within the expiry window.
- Update `candidate_last_accessed_at`
- Issue same JWT shape

### E. Controller

`app/controllers/v1/candidate/sessions_controller.rb`
- Inherits `ApplicationController`
- `skip_before_action :authenticate_user!`
- Actions: `request_otp`, `create`, `token_login`, `destroy`

### F. Specs

`spec/requests/v1/candidate/sessions_spec.rb`

| Scenario | Expected |
|---|---|
| `request_otp` — valid referral_id | 200, OTP stored, email sent |
| `request_otp` — unknown referral_id | 200 (no enumeration) |
| `request_otp` — cancelled referral | 200 (no enumeration — same as unknown) |
| `request_otp` — rate limited | 429 |
| `create` — correct OTP | 200, JWT with correct claims |
| `create` — wrong OTP | 401 |
| `create` — expired OTP | 401 |
| `create` — rate limited | 429 |
| `token_login` — valid token | 200, JWT |
| `token_login` — valid token used twice | 200 both times (token reusable) |
| `token_login` — expired token | 401 |
| `token_login` — invalid token | 401 |
| `token_login` — cancelled referral | 401 |

`spec/commands/v1/internal/referrals/create_spec.rb` (additions)

| Scenario | Expected |
|---|---|
| referral created | `candidate_access_token` present and unique |
| referral created | `candidate_access_token_expires_at` ~30 days from now |
| referral created | invitation email enqueued to `candidate_email` |

## Key Files (existing, already handle candidate JWT)

- `app/middlewares/authentication_token_parser.rb` — decodes `is_candidate_session` JWTs
- `app/controllers/v1/candidate/application_controller.rb` — sets `current_person` / `current_referral`

## Reference: How Screen Does OTP

Screen uses a `public_links` table + `Otp::Generator` service. Assessment is simpler — OTP fields live directly on `Referral`, matching the replit app's existing pattern. See `carelever-replit-reimagined/app/controllers/concerns/otp_authenticatable.rb` for the shared OTP concern to port from.

---

## UI — carelever_assessment_ui

### Stack

Angular 21, Nx monorepo. Candidate app is at `apps/candidate/`. Shared auth logic lives in `libs/auth/`.

### Current State

The candidate app already has login and OTP pages:

- `apps/candidate/src/app/login/login.component.html` — uses `<lib-login-form classification="external">`
- `apps/candidate/src/app/login/otp.component.html` — uses `<lib-otp-form classification="external">`
- Routes: `/login` → `LoginComponent`, `/login/otp` → `OtpComponent`

The `JwtClaims` model in `libs/auth/src/lib/claims.model.ts` already includes `is_candidate_session`, `person_id`, and `referral_id`.

### Problem

`LoginFormComponent` (`libs/auth`) uses `login` + `password` fields and calls `AuthService.login()`. `OtpFormComponent` is MFA (2nd factor after password login). Neither fits the candidate email-only → OTP primary auth flow.

### Changes Required

**1. `libs/auth/src/lib/candidate-auth.service.ts`** (new)

| Method | Calls | Purpose |
|---|---|---|
| `requestOtp(referralId)` | `POST /v1/candidate/session/request_otp` | Trigger OTP email |
| `authenticate(referralId, otpCode)` | `POST /v1/candidate/session` | Verify OTP, store JWT |
| `loginFromToken(token)` | `POST /v1/candidate/session/token_login` | Magic link login, store JWT |

Token stored via existing `AUTH_TOKEN_KEY` in localStorage — interceptors and guards continue to work without changes.

Export from `libs/auth/src/index.ts`.

**2. Update `apps/candidate/src/app/login/token-login.component.ts`** (primary entry point)

Reads `token` from query param on init, calls `CandidateAuthService.loginFromToken()`, redirects to `/dashboard` on success. Offers a "send me a code instead" link that navigates to `/login/otp?referral_id=<id>` — the `referral_id` is returned in the token_login response so the UI can pass it through. No other visible UI — shows a loading spinner only.

**3. Remove `apps/candidate/src/app/login/login.component.html`** email entry form

The standalone email login page is no longer needed — OTP is always initiated from the token-login page which carries the `referral_id`.

**4. Update `apps/candidate/src/app/login/otp.component.html`**

Replace `<lib-otp-form>` with a candidate OTP form. Reads `referral_id` from query param, calls `CandidateAuthService.authenticate(referralId, otpCode)`, navigates to `/dashboard` on success.

**4. New `apps/candidate/src/app/login/token-login.component.ts`** (new)

Reads `token` from query param on init, calls `CandidateAuthService.loginFromToken()`, redirects to `/dashboard`. No visible UI — shows a loading spinner only.

Add route in `app.routes.ts`:
```typescript
{ path: 'token-login', component: TokenLoginComponent }
```

### Visual Reference

Replit candidate views (`carelever-replit-reimagined/app/views/candidate/sessions/`) use Tailwind CSS — the cyan-to-blue gradient header, lock icon on the OTP screen, and card layout are the design reference. The existing Angular candidate pages already match this structure closely; no major restyling needed.
