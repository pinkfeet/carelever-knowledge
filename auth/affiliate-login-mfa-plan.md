# Affiliate Portal Login + MFA — Implementation Plan

**Ticket:** CT-4360 Affiliate Portal Auth Login/Logout
**Branch:** `feat/CT-4360-Affiliate-Portal-Auth-Login-Logout`

---

## Context

| Source | Key finding |
|---|---|
| Assessment backend | `V1::Affiliate::ApplicationPolicy` already has the double gate: `classification == 'affiliate'` AND `user.affiliate?`. No fine-grained `affiliate_can?` method exists yet (unlike client which has `client_can?`). |
| Screen project | Affiliate gate is a single classification check via a `RoleBasedPermissions` concern — simpler than assessment's pattern. |
| Legacy affiliate UI | No frontend permission checks at all. Simple JWT expiry guard. No MFA. Calls `/authentication/affiliate/authenticate` directly. |
| `rbac.yml` | Affiliate role (`Affiliate Clinic`) has 6 permissions: `manage_contacts`, `add_form`, `edit_form`, `add_service`, `edit_service`, `manage_suppliers`. |

### Affiliate user storage (`carelever_authentication`)

Affiliate users are stored as `is_internal: true, classification: 'affiliate'` — set by `Manager::AffiliateLocationUsers::Create`. This differs from external (client) users which are `is_internal: false, classification: 'external'`. All OTP command user lookups must use `is_internal: true, classification: :affiliate` to match.

### Existing OTP endpoints cannot be reused

`OtpService` builds the URL from the classification: `/v1/authentication/{classification}/request_otp`. Routing to the external controller wouldn't work anyway — `V1::External::Users::RequestOtp` queries `is_internal: false` and would return nil for affiliate users. New commands are thin subclasses (~5 lines each) that only override `current_user`.

---

## Part 1 — `carelever_authentication`: 12 new/modified items

### Key finding: v2 endpoint required for login

`AuthService.login()` calls `POST /v2/{classification}/authenticate`. Only `v2/internal` and `v2/external` exist — `v2/affiliate` does not. The existing `v1/authentication/affiliate/authenticate` is never called by the new UI. Additionally, **only the v2 command signals `otp_required`** — the v1 command always returns a full JWT regardless of MFA status.

### 0. v2 affiliate authenticate — 3 items

**`app/commands/v2/affiliate/users/authenticate.rb`** — subclass `V2::External::Users::Authenticate`, override `current_user` to find `is_internal: true, classification: :affiliate`, override `hashed_result` to use `JwtEncoder::Affiliate`.

**`app/controllers/v2/affiliate/authentication_controller.rb`** — mirror `V2::External::AuthenticationController`.

**`config/routes.rb`** — add under `namespace :v2`: `namespace :affiliate { post 'authenticate', to: 'authentication#authenticate' }`.

---

### 1. `app/commands/v1/affiliate/users/request_otp.rb` — new

Subclass `V1::Users::RequestOtp`. Override `current_user`:

```ruby
class V1::Affiliate::Users::RequestOtp < ::V1::Users::RequestOtp
  private

  def current_user
    @current_user ||= User.kept.affiliate.find_by(id: @user_id, is_internal: true)
  end
end
```

### 2. `app/commands/v1/affiliate/users/authenticate_otp.rb` — new

Subclass `V1::Users::AuthenticateOtp`. Override `current_user`, `generate_jwt_token` (use `JwtEncoder::Affiliate`), and `otp_cookie_class` (use `SetAffiliateCookie`).

### 3. `app/services/jwt_encoder/affiliate.rb` — new

Subclass `JwtEncoder::Base`. Mirror `JwtEncoder::External` — encodes `classification: @user.classification` dynamically (will correctly carry `'affiliate'`). Confirm whether `options: user.affiliate_details` differs from external's `options: user.options` and adjust accordingly.

### 4. `app/services/otp/cookies/set_affiliate_cookie.rb` — new

Subclass `Otp::Cookies::Base`, set `path` to an affiliate-scoped value (mirror `SetExternalCookie`).

### 5. `app/controllers/v1/authentication/affiliate/authentication_controller.rb` — modify

Add `request_otp` and `authenticate_otp` actions alongside the existing `authenticate`. Use identical error handling to the external controller (`TooManyOtpAttemptsError`, `AccountLockedError`, `InvalidTokenError`).

### 6. `config/routes.rb` — modify

Add `post 'request_otp'`, `post 'authenticate_otp'`, `post 'forgot_password'`, and `post 'reset_password'` under the v1 affiliate namespace.

### 7. `app/controllers/v1/authentication/affiliate/authentication_controller.rb` — modify (continued)

Also add `forgot_password` and `reset_password` actions. Mirror the internal controller pattern — both are thin wrappers calling the corresponding command with `params[:login]` / reset token params and `organisation_slug`.

Commands needed:
- `app/commands/v1/affiliate/users/forgot_password.rb` — subclass the base forgot password command, override `current_user` with `is_internal: true, classification: :affiliate` lookup.
- `app/commands/v1/affiliate/users/reset_password.rb` — same pattern.

---

### 8. `app/policies/internal_external/current_user_policy.rb` — modify

`MfaPreferenceService` (used by `MfaSetupComponent`) calls `/v1/authentication/users/otp_modes`. This controller goes through `InternalExternal::CurrentUserPolicy`:

```ruby
def show?
  internal_user? || external_user?   # classification == 'internal' OR 'external'
end
```

Affiliate users (`classification: 'affiliate'`) fail both checks → **403**. Fix: add `|| affiliate_user?` where `affiliate_user?` checks `user.classification == 'affiliate'`. Without this, the MFA profile settings page cannot work for affiliates.

---

## Part 2 — `carelever_assessment`: Policy + permissions

### 8. `config/rbac.yml` — review

Current 6 affiliate permissions are carry-overs from legacy. Confirm which are still valid for the assessment context and add any missing ones before wiring `require_permission!` in controllers.

### 9. `app/policies/v1/affiliate/application_policy.rb` — no structural change

The double gate is already correct:
- `user.classification == 'affiliate'` (JWT claim)
- `user.affiliate?` (local role_type check)
- Admin bypasses both gates (impersonation support)

Consider adding an `affiliate_can?` helper (mirroring `client_can?`) for future fine-grained endpoint guards — defer until a concrete permission check is needed.

### 10. Concrete policies

`AppointmentPolicy` and `DashboardPolicy` already exist and follow the correct pattern (`def index? = can_access?`). No new policy files needed for this ticket.

---

## Part 3 — `carelever_assessment_ui`: 5 changes

### 11. `apps/affiliate/src/app/login/login.component.html` — modify

Add `[otpRedirect]` and a "Forgot password?" link slot:

```html
<lib-login-form
  [classification]="'affiliate'"
  [successRedirect]="'/dashboard'"
  [otpRedirect]="'/login/otp'"
>
  <div slot="before-submit" class="text-left">
    <a routerLink="/login/forgot" class="text-sm text-cyan-600 hover:text-cyan-800">
      Forgot password?
    </a>
  </div>
</lib-login-form>
```

The OTP page, routes, and `portalShellGuard('affiliate')` are already in place.

### 12. `apps/affiliate/src/app/login/forgot-password.component.ts/html` — new

Mirror the client pattern. Thin wrapper around `ForgotPasswordFormComponent` from `@org/auth`:

```html
<lib-forgot-password-form [classification]="'affiliate'" />
```

### 13. `apps/affiliate/src/app/login/reset-password.component.ts/html` — new

Mirror the client pattern. Thin wrapper around `ResetPasswordFormComponent` from `@org/auth`. The reset link in the password email carries a token as a query param — the component reads it and submits to `/v1/authentication/affiliate/reset_password`.

### 14. `apps/affiliate/src/app/app.routes.ts` — modify

Add two routes alongside the existing `/login` and `/login/otp`:

```typescript
{ path: 'login/forgot', component: ForgotPasswordComponent },
{ path: 'login/reset', component: ResetPasswordComponent },
```

### 15. MFA setup nudge banner — new (shell component)

Existing affiliate users migrating from the legacy system have `otp_mode: nil` — the v2 authenticate command skips OTP when `otp_mode` is nil, so they log in without friction. To encourage setup, add a nudge banner in the affiliate shell that reads the `otp_mode` claim from the JWT (already encoded in the token) and shows a dismissible prompt linking to `/security/mfa-setup` when nil.

- **Not a forced redirect** — blocking portal access until MFA is set would break existing users mid-task.
- `otp_mode` is already in the JWT claims; no extra API call needed.
- `/security/mfa-setup` is already routed to `MfaSetupComponent` from `@org/auth` in `app.routes.ts`.
- After MFA setup, `MfaSetupComponent` logs the user out and redirects to `/login` — next login will require OTP.

---

## Not in scope

- MFA profile settings page (full settings UI) — `/security/mfa-setup` route already wired. Separate ticket.
- Forgot password flow for affiliate
- `affiliate_can?` method (no concrete use case in this ticket)
