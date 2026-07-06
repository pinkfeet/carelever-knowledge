# Security Review — `carelever_assessment` + `carelever_authentication`

**Date:** 2026-07-03
**Scope:** Authentication, authorization, tenant scoping, session/JWT handling, and cross-cutting configuration security across the Assessment API (`carelever_assessment`) and the shared Authentication microservice (`carelever_authentication`).
**Method:** Read-only code review. Every Critical/High finding below was manually verified against source (not just pattern-matched). One subagent-flagged "Critical" was disproven on inspection and is documented in the *Cleared / false positives* section for transparency.
**Nothing was modified.** This document is findings-only.

---

## How the two services fit together

- `carelever_authentication` issues JWTs (HMAC, `API_SECRET_KEY`) after login/OTP.
- `carelever_assessment` consumes those JWTs via `AuthenticationTokenParser` middleware and enforces authorization with Pundit policies + command-level tenant scoping.
- **Both services share the same `API_SECRET_KEY`.** A token forged or leaked in one is valid in the other. This makes secret hygiene and algorithm pinning a *fleet-wide* concern, not a per-repo one.

---

## Severity summary

| Sev | Count | Headline items |
|-----|-------|----------------|
| Critical | 3 | Unauthenticated data-sync webhook (both repos); any internal user can mint a candidate session for any referral |
| High | 6 | Refresh-token session revival after logout; reversible email-sender password embedded in JWTs; affiliate cross-clinic impersonation; doctor-review claim/read without doctor role; cross-tenant medical PDF downloads |
| Medium | ~12 | JWT alg not pinned in auth service; empty-secret default; fail-open session registry; weak reset/verify code entropy; missing host authorization; log param leakage |
| Low / Info | several | CSP report-only, committed dev/test secrets, upload size limits, dependency drift |

---

## CRITICAL

### C1 — Unauthenticated data-sync webhook triggers SQS processing (both repos)
- `carelever_assessment/app/middlewares/authentication_token_parser.rb:9-14` — `/v1/data_sync_recipients` is on `SKIP_PATHS` (no JWT).
- `carelever_assessment/app/commands/data_sync/receive.rb` — a body with `Type: "Notification"` triggers `DataSync::Fetch` (SQS drain/processing). No SNS signature or Topic-ARN verification on notifications.
- Same pattern in `carelever_authentication/app/middlewares/authentication_token_parser.rb:49` + `app/commands/data_sync/receive.rb`.

**Impact:** Any network caller can POST a forged SNS-shaped payload and force the API to poll/process its sync queue — resource exhaustion / unauthorized data-sync execution. The middleware comment explicitly acknowledges the missing webhook secret and defers re-securing it.

**Fix:** Verify SNS message signature + Topic ARN, or require a shared webhook secret (`AWS_LAMBDA_WEBHOOK_SECRET` is already reserved in `.env.example`), or restrict the route to the VPC/security group.

---

### C2 — Any internal user can mint a candidate session for any referral (`carelever_assessment`)
- `app/controllers/v1/internal/candidate_impersonations_controller.rb:7-9`
- `app/policies/v1/internal/candidate_view_policy.rb:9` — `view_as? = can_access?` (true for **any** authenticated internal user; the policy is still the "Phase 1: permissive" stub, per its own TODO).
- Controller then does `Referral.find(params[:id])` with **no company/site scoping** and calls `Auth::TokenMinter.mint_for_person(...)`.

**Impact:** Any internal role (assessor, standard, etc.) who knows/guesses a referral ID obtains a full candidate-session JWT for that person — cross-tenant PII exposure and the ability to act in the candidate portal *as* that candidate.

**Fix:** Restrict `view_as?` to privileged roles (admin/assessor) and/or a named permission, and scope the `Referral` lookup to the actor's tenant before minting.

---

### C3 — (Consolidated) The webhook endpoints above are the only truly unauthenticated write paths; treat C1 as fleet-wide
This is not a separate bug — it flags that the *same* class of unauthenticated-write exists in **both** repos and both funnel into `DataSync::Fetch`. Fix them together with a single shared verification strategy so the two services don't drift.

---

## HIGH

### H1 — `/v1/refresh` revives a session for any leaked/stale token, bypassing logout revocation (`carelever_authentication`)
- `app/commands/refresh_token.rb:8-25` decodes `params[:old_token]` (any signature-valid, unexpired JWT) and mints a **new registered session** for `decoded_old_token[:user_id]`.
- It never checks that `old_token` belongs to the caller, nor that its `jti` is still in the `SessionRegistry` allowlist.
- `/v1/refresh` is *not* in `SKIP_AUTH_PATHS`, so the caller must present *their own* valid token in the `Authentication` header — but the refreshed token comes from the **body** `old_token`, which is unchecked.

**Verified attack:** Attacker authenticates normally (valid header token), and passes a victim's leaked/stale JWT (e.g. from logs, still within its end-of-day `exp`) as `old_token`. They receive a **fresh, registry-registered** session token for the victim's `user_id` — even if the victim already logged out (logout only revoked the original `jti`). This is token laundering / revocation bypass.

**Fix:** Bind refresh to the authenticated caller (`old_token.user_id == current_user_id`) and require the old `jti` to still be allowlisted; rotate (revoke old `jti`) on refresh.

---

### H2 — Reversible email-sender password embedded in every internal/external JWT (`carelever_authentication`)
- `app/services/jwt_encoder/internal.rb:27` (and `external.rb`): `sender_key: EncodeDecode.new(@user.sender_detail&.password).encode`.
- `app/services/encode_decode.rb` uses AES keyed from `SECRET_KEY_BASE` with a fixed salt — reversible, not a one-way hash.

**Impact:** JWTs are forwarded to downstream services, stored in browsers, and can appear in logs. Anyone who obtains a JWT *and* `SECRET_KEY_BASE` can decrypt the SMTP sender password. Sensitive credentials should never travel inside a bearer token.

**Fix:** Remove `sender_key` from token claims; fetch sender credentials server-side at send time.

---

### H3 — Affiliate can impersonate any affiliate at any clinic (`carelever_assessment`)
- `app/policies/v1/impersonation_policy.rb:7-11` — `create?` returns true for **any** `user.affiliate?` (no permission, no scope).
- `app/commands/v1/impersonations/start.rb` — for affiliates, only checks `target.affiliate?`; no supplier/clinic binding.

**Impact:** An affiliate at clinic A can impersonate an affiliate at clinic B and inherit their supplier context. Note admin targets are correctly blocked, and `client_system_admin` impersonation *is* scoped to the same company — the affiliate branch is the gap.

**Fix:** Require a named permission and constrain the target to the actor's supplier(s).

---

### H4 — Doctor-review claim/read reachable without doctor role or eligibility (`carelever_assessment`)
- `app/controllers/v1/internal/doctor_reviews_controller.rb:60-62` authorizes `claim` with `ReferralPolicy#update?` (= `can_access?`, all internal roles).
- `app/commands/v1/internal/doctor_reviews/claim.rb` loads `Referral.find(@id)` and assigns to `@current_user` after only an at-capacity check — it does **not** call `Doctors::ClaimEligibility.call` (accreditation) and does **not** require `user.doctor?`.
- `app/queries/v1/internal/doctor_reviews/accessible_referral_query.rb:67-72` (`finalised_referral`) returns any referral with `doctor_outcome_finalised_at` set, with no `assigned_doctor_id`/role check.

**Impact:** A non-doctor internal user can self-assign medical reviews from the unclaimed queue (unlocking sign-off paths that gate on `assigned_doctor_id == current_user.id`), and can read finalized medical review detail (and linked documents) for arbitrary referral IDs.

**Fix:** Gate claim on `user.doctor?` + `ClaimEligibility.call`; add assignment/role checks to `finalised_referral`.

---

### H5 — Cross-tenant medical PDF downloads by ID / reference number (`carelever_assessment`)
- `app/controllers/reports_controller.rb` + `app/policies/report_policy.rb` — `GET /reports/fitness_for_work` authorizes with `fitness_for_work?` (= internal `can_access?`) then `Referral.find_by!(reference_number: params[:reference_number])` with no tenant scoping.
- `app/controllers/v1/doctor/doctor_reviews_controller.rb:78-91` — `health_monitoring_report` uses `Referral.find(params[:id])` + `ReferralPolicy#show?` only (bypasses `AccessibleReferralQuery`), checking only that the review is finalized.

**Impact:** Any internal/doctor-portal user who knows or guesses a reference number / numeric ID can download the fitness-for-work or health-monitoring PDF for arbitrary cases.

**Fix:** Route both through the scoped accessible-referral query and enforce assignment/tenant checks before rendering.

---

### H6 — Fail-open session registry disables real-time revocation during Redis outage (`carelever_authentication`)
- `app/services/session_registry.rb:37-40` — `valid?` returns `true` on any Redis error (documented as intentional, CT-4108 §11.2).

**Impact:** During a Redis outage, revoked/stolen tokens are accepted until their natural `exp` (end-of-day, up to ~24h). Logout and forced-logout-on-password-change stop working. This is a deliberate availability trade-off, but it should be a conscious risk decision, not a silent default — combined with H1 (long-lived tokens) the blast radius is a full day.

**Fix (if the trade-off is unacceptable):** Fail closed for security-sensitive paths, shorten token lifetime, or alert on registry degradation.

---

## MEDIUM (selected — full list carried from area reviews)

- **M1 — JWT algorithm not pinned on decode (`carelever_authentication`).** `lib/json_web_token.rb:22` and `app/middlewares/authentication_token_parser.rb:123` call `JWT.decode(token, key)` with no `algorithms:`. Assessment correctly pins `algorithms: ['HS256']` (`carelever_assessment/app/middlewares/authentication_token_parser.rb:118`). Exploitability is limited here because a *symmetric* secret is used (RS→HS confusion needs a public key as the HMAC secret, and the `jwt` gem blocks `alg=none` by default), but pinning is standard hardening and the two services should match. **Downgraded from a subagent "Critical" after review.**
- **M2 — Empty-secret default (`carelever_authentication`).** `config/initializers/app_config.rb:2` — `API_SECRET_KEY = ENV.fetch('API_SECRET_KEY', '')`. A misconfigured deploy signs/verifies with an empty key → trivially forgeable tokens across *both* services. Fail boot if blank.
- **M3 — Weak password-reset entropy / no rate limit (`carelever_authentication`).** `app/services/password_reset_code/generator.rb:15` uses `SecureRandom.base58(4)` (~11M space), emailed alongside the reset link; `reset_password` has no rate limit and `app/commands/v1/users/reset_password.rb:31` decodes the JWT without rescue (500 error oracle).
- **M4 — Weak email-verification code (`carelever_authentication`).** `app/models/email_verification_code.rb:17` uses `rand(100000..999999)` (non-cryptographic PRNG), with no expiry and no attempt limit on the skip-auth `verify_email_code` endpoint.
- **M5 — Deprecated `POST /v1/ch_authenticate` mints a full session from IDs only (`carelever_authentication`).** `app/commands/authenticate_ch_user.rb` — no password/MFA; marked TOBEREMOVED but still routed and skip-auth. Remove it.
- **M6 — Missing host authorization (both repos).** `config.hosts` is commented out in `production.rb` for both — no allowlist, so DNS-rebinding / Host-header attacks aren't mitigated at the app layer.
- **M7 — Lograge logs raw params (`carelever_authentication`).** `config/environments/production.rb:102-107` logs `event.payload[:params]` without running them through `filter_parameters`, so passwords/OTP/`api_secret` can reach centralized logs despite the filter config.
- **M8 — Parameter-filter gaps (both repos).** `filter_parameter_logging.rb` misses `api_key`, `api_secret`, `authorization`, `refresh_token`, `access_token`, `credit_card`/`card_number`; assessment also omits `email`.
- **M9 — Coarse internal `ReferralPolicy` (`carelever_assessment`).** `app/policies/v1/internal/referral_policy.rb` gates all mutations on `can_access?` only — no ParentAccount/Company/Site scoping and no named permissions. May be intentional for the KINNECT global-operator model, but it is not object-level tenant isolation.
- **M10 — Roster IDOR across clinics (`carelever_assessment`).** `app/controllers/concerns/roster_clinic_scope.rb:22-23` — `Supplier.find(params[:clinic_id])` after the `manage_roster` permission check, with no per-user clinic binding.
- **M11 — Permissive base policies (`carelever_assessment`).** Root `app/policies/application_policy.rb` still defaults CRUD to `true` (Phase-1 stub). Any mis-wired `policy_class` inherits permissive defaults. `verify_policy_scoped` is never used anywhere in the repo.
- **M12 — Session-binding & long-lived cookies (`carelever_authentication`).** `TokenSourceValidator` accepts IP match *or* (Origin+UA) match; "remember device" cookie lives 30 days without rotation; explicit logout revokes a single `jti` only (multi-device sessions survive).

---

## LOW / INFO

- CSP is **report-only** in `carelever_authentication` (`content_security_policy.rb:44`) — not enforced. Assessment has no CSP (API-only).
- Committed dev/test secrets in `carelever_authentication`: `config/secrets.yml` (dev/test keys) and a tracked `.env.test`; its `.gitignore` does not ignore `.env*` (assessment does). Rotate and stop tracking.
- Several `carelever_assessment` CarrierWave uploaders lack `size_range` (`medical_review_guideline_uploader.rb`, `position_document_uploader.rb`, `pdf_template_uploader.rb`, `pdf_import_analysis_uploader.rb`) — unbounded upload size. S3 ACL is correctly `private` globally.
- Dependency drift: `carelever_authentication` runs older `jwt` (2.7.0 vs 3.1.2), `nokogiri`, `rack-cors` (2.0.1 vs 3.0.0), and `stripe` (8.5.0 vs 19.2.0) than assessment. Worth a CVE pass.
- Dev auto-auth in assessment (`ApplicationController` dev stub as `admin@carelever.com`) — dev-only, no prod impact unless `Rails.env` is misconfigured.

---

## Cleared / false positives (verified, not issues)

- **OTP completion guard is correct.** `carelever_authentication/app/commands/v1/users/authenticate_otp.rb:21` — `if not valid_jwt_token? && valid?(current_user)`. A subagent flagged this as inverted/Critical, reading it as `(not valid_jwt) && valid?`. Ruby's `not` has **lower** precedence than `&&`, so it parses as `not (valid_jwt_token? && valid?(current_user))` — the request is rejected unless **both** the OTP-phase JWT and the OTP are valid. This is the intended behavior (equivalent to `request_otp.rb`'s `!(valid_jwt && valid?)`). **Not a vulnerability.**
- **CORS is not wildcard in either repo.** Assessment uses an env-driven allowlist with credentials off; auth pairs `credentials: true` with an explicit `carelever.com` regex allowlist — the correct pattern.
- **Passwords use bcrypt** (`has_secure_password`, default cost 12) in both; partner API-key secrets are bcrypt-digested and compared with `authenticate_secret` (constant-time). No MD5/SHA1 for credentials.
- **Stripe webhooks** in auth verify signatures via `StripeEvent` with `STRIPE_WEBHOOK_KEY` (fails closed if unset).
- **No `permit!`** in production controllers in either repo; strong params are used throughout.

---

## Recommended remediation order

1. **C1/C3** — Authenticate/verify the data-sync webhook (SNS signature + Topic ARN, or shared secret) in both repos with one shared strategy.
2. **C2** — Restrict candidate `view_as` to privileged roles and scope the referral lookup before minting a candidate token.
3. **H1** — Bind `/v1/refresh` to the authenticated caller and require the old `jti` to be allowlisted; rotate on refresh.
4. **H2** — Remove `sender_key` from JWT claims.
5. **H3/H4/H5** — Add role/permission + tenant/assignment scoping to affiliate impersonation, doctor-review claim/read, and report PDF downloads.
6. **M1/M2** — Pin `algorithms: ['HS256']` on all decode paths in auth; fail boot if `API_SECRET_KEY` is blank.
7. **M3/M4/M5/M6/M7** — Harden reset/verify code entropy + rate limits, remove `ch_authenticate`, configure `config.hosts`, and route Lograge params through `filter_parameters`.

---

## Appendix — evidence trail

Detailed per-area findings from the three parallel review passes:
- Assessment authorization & scoping: [Assessment authz review](522de7f6-26a7-4cf9-8ab1-f05ae4d5e17a)
- Authentication service internals: [Auth service review](d6fca4d4-1fb4-4345-b301-3bdd717c1c77)
- Cross-cutting configuration: [Config & cross-cutting review](338fb768-2749-4eb8-993c-96254b8b1d5b)

Files read and verified directly during synthesis: both `authentication_token_parser.rb` middlewares, `lib/json_web_token.rb`, `refresh_token.rb`, `authenticate_otp.rb`, `authentication_controller.rb`, `session_registry.rb`, `jwt_encoder/internal.rb`, `candidate_impersonations_controller.rb`, `candidate_view_policy.rb`.
