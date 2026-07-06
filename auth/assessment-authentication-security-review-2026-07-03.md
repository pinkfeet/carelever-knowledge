# Assessment + Authentication Security Review

Date: 2026-07-03

Scope:

- `carelever_assessment`
- `carelever_authentication`
- Integration boundary between Assessment, Authentication, and visible Assessment UI auth flows

Method:

- Static source/config review only.
- Existing `carelever-knowledge` documentation was intentionally ignored as review input.
- Findings below are based on repository source evidence and should be verified with runtime/infrastructure checks before final risk acceptance.

## Executive Summary

The dominant platform risk is that `carelever_authentication` issues stateful JWT sessions with Redis-backed `jti` revocation and token-source checks, while `carelever_assessment` treats the same tokens as stateless signed bearer tokens. This means logout, password-change revocation, and source binding enforced by Authentication are not enforced by Assessment.

The highest-priority issues are:

1. Both services expose unauthenticated data-sync webhook endpoints that can trigger queue processing without SNS signature verification.
2. Authentication exposes a live `ch_authenticate` path that lets any authenticated caller mint a JWT for another user by `ch_id`.
3. Assessment has high-risk impersonation and candidate-view flows that are broader than normal tenant/permission boundaries.
4. Authentication includes sensitive sender credentials in session JWTs.
5. Cross-service JWT trust relies on one shared HS256 secret, with no issuer/audience scoping and inconsistent revocation/source-binding enforcement.

## Findings

### Critical: Unauthenticated Data-Sync Webhooks Can Trigger Queue Processing

Affected repos:

- `carelever_assessment`
- `carelever_authentication`

Evidence:

- Assessment middleware skips auth for `/v1/data_sync_recipients` in `app/middlewares/authentication_token_parser.rb`.
- Assessment controller accepts the open endpoint in `app/controllers/v1/data_sync_recipients_controller.rb`.
- Assessment `DataSync::Receive` processes `"Type": "Notification"` without verifying an SNS signature in `app/commands/data_sync/receive.rb`.
- Authentication middleware skips auth for its data-sync recipient path in `app/middlewares/authentication_token_parser.rb`.
- Authentication data-sync controller and receive command follow the same open notification pattern in `app/controllers/v1/authentication/data_sync_recipients_controller.rb` and `app/commands/data_sync/receive.rb`.

Impact:

Any internet-reachable client can POST a notification-shaped payload and trigger SQS polling / sync processing. At minimum this is a resource-exhaustion and queue-drain risk. If attacker-controlled messages can enter the queue, impact can escalate to unauthorized data mutation.

Recommendation:

- Verify AWS SNS signatures before accepting webhook notifications.
- Add a shared webhook secret or mTLS/IP allowlist as defense in depth.
- Rate-limit the endpoint.
- Add request specs that reject unsigned notifications and accept valid signed ones.

Confidence: High.

### Critical: Authentication `ch_authenticate` Enables Identity Swap

Affected repo: `carelever_authentication`

Evidence:

- `POST /v1/ch_authenticate` is routed in `config/routes.rb`.
- `V1::AuthenticationController#ch_authenticate` delegates directly to `AuthenticateChUser`.
- `AuthenticateChUser` mints a JWT for the user found by `ch_id` and `organisation_id`.
- The route is not public, but it only requires any valid JWT before reaching the action; no action-level authorization or trusted service check was found.

Impact:

Any authenticated caller who knows or guesses another user's `ch_id` and organisation can mint a JWT for that user. If `ch_id` values are enumerable, this is a direct privilege-escalation and lateral-movement path.

Recommendation:

- Remove the endpoint if it is legacy.
- If still required, restrict it to a trusted inter-service caller with a dedicated service identity, explicit authorization, auditing, and non-enumerable subject identifiers.
- Add a negative request spec proving ordinary authenticated users cannot call it.

Confidence: High.

### High: Assessment Does Not Enforce Authentication Session Revocation

Affected repos:

- `carelever_assessment`
- `carelever_authentication`
- `carelever_assessment_ui`

Evidence:

- Authentication registers session JWTs with `jti` in `SessionRegistry` and revokes them on logout/password change.
- Authentication middleware calls `SessionRegistry.valid?` for normal session tokens.
- Assessment middleware only verifies HS256 signature, expiration, and local user/person activity in `app/middlewares/authentication_token_parser.rb`.
- No Assessment-side `jti`, Redis registry, or Authentication introspection check was found.
- Assessment UI logout clears local state but does not appear to call Authentication logout before clearing the token.

Impact:

A token stolen before logout, password change, or server-side revocation remains usable against Assessment until natural expiry. This weakens user offboarding, incident response, and compromised-token containment.

Recommendation:

- Add revocation parity for Assessment by validating `jti` against the same registry or an Authentication introspection endpoint.
- Ensure UI logout calls Authentication `/v1/logout` with the token before local cleanup.
- Add an integration test: login through Authentication, access Assessment, logout/revoke, then assert Assessment rejects the same token.

Confidence: High.

### High: Assessment Does Not Enforce Authentication Token-Source Binding

Affected repos:

- `carelever_assessment`
- `carelever_authentication`

Evidence:

- Authentication validates token source with `TokenSourceValidator`, accepting matching IP or matching Origin plus User-Agent.
- Assessment has no equivalent source-binding check in its JWT middleware.

Impact:

A stolen JWT can be replayed against Assessment from a different client even when Authentication would reject it.

Recommendation:

- Decide whether source binding is a platform contract.
- If yes, enforce the same source-binding policy in Assessment or centralize validation via Authentication introspection.
- If no, document Authentication source binding as service-local defense in depth and do not rely on it in security claims.

Confidence: High.

### High: Authentication Embeds Sender Credentials in Session JWTs

Affected repo: `carelever_authentication`

Evidence:

- Internal/external JWT encoders include `sender_key` generated from `EncodeDecode.new(user.sender_detail&.password).encode`.
- Login/authentication commands pass sender detail into JWT payloads.

Impact:

Bearer tokens become containers for encrypted third-party or sender credentials. Tokens are exposed to browser memory, client logs, and XSS/token exfiltration paths. If the encryption key is compromised, captured JWTs can disclose sender credentials.

Recommendation:

- Remove sender credentials from JWT payloads.
- Fetch sender details server-side only when needed.
- Rotate exposed sender credentials if production tokens have carried them.
- Add tests asserting session JWTs do not include `sender_key`, `sender_email`, or raw OAuth/access credentials.

Confidence: High.

### High: Assessment Affiliate Impersonation Allows Cross-Clinic Lateral Movement

Affected repo: `carelever_assessment`

Evidence:

- `V1::ImpersonationPolicy#create?` allows affiliate users.
- `V1::Impersonations::Start#transition_allowed?` allows affiliate-to-affiliate targets without checking shared supplier/clinic scope.
- Existing tests appear to cover this permissive behavior as expected behavior.

Impact:

An affiliate user can mint a token acting as another affiliate and inherit that token's `supplier_id`, potentially accessing another clinic's appointments, forms, and documents.

Recommendation:

- Remove affiliate-to-affiliate impersonation unless there is a clear business requirement.
- If required, restrict targets to the same supplier/clinic scope.
- Add a negative request spec for cross-supplier affiliate impersonation.

Confidence: High.

### High: Assessment Internal Candidate View-As Is Too Broad

Affected repo: `carelever_assessment`

Evidence:

- `V1::Internal::CandidateViewPolicy#view_as?` only checks internal portal access.
- `V1::Internal::CandidateImpersonationsController` loads a referral by ID and mints a candidate session without a stricter named permission or tenant-scope check.

Impact:

Any internal user with internal portal access may mint a 24-hour candidate session for any referral. That can expose candidate PII, forms, documents, and candidate actions outside assigned scope.

Recommendation:

- Require a named permission for candidate view-as.
- Enforce referral tenant scope using the user's company/site/parent-account assignments.
- Audit candidate view-as events with actor, referral, person, tenant, and reason metadata.

Confidence: High.

### High: Shared-Secret Inter-Service Tokens Are Trust-by-Claim

Affected repos:

- `carelever_assessment`
- `carelever_authentication`

Evidence:

- Assessment mints `inter_microservice_request: true` JWTs using the shared `API_SECRET_KEY`.
- Authentication bypasses session registry and token-source validation for `inter_microservice_request`.
- No separate service signing key, issuer, audience, or service allowlist was found.

Impact:

Compromise of the shared API secret allows arbitrary short-lived service tokens and user impersonation against Authentication APIs. The boolean claim itself becomes the authority.

Recommendation:

- Use a dedicated service-to-service signing key or asymmetric key pair.
- Add `iss`, `aud`, `jti`, and service identity claims.
- Enforce a minter allowlist and short TTL.
- Register or audit service tokens separately.

Confidence: High.

### Medium: Assessment Trusts Affiliate `supplier_id` JWT Claim Over DB Assignment

Affected repo: `carelever_assessment`

Evidence:

- `User#acting_supplier_id` prefers the JWT `supplier_id` claim.
- Affiliate controllers scope requests through `current_user.acting_supplier_id`.
- Tests confirm claim value wins over DB supplier assignment.

Impact:

If a valid token is minted or forged with a different `supplier_id`, Assessment scopes affiliate data to that supplier. The exploit requires token minting authority or shared-secret compromise, but the blast radius is cross-clinic data access.

Recommendation:

- Resolve supplier assignment from DB for normal affiliate sessions.
- Permit claim-based supplier only for explicitly audited impersonation flows.
- Reject mismatches between JWT claim and DB assignment.

Confidence: Medium-High.

### Medium: Assessment Candidate Session Does Not Validate Person-to-Referral Binding

Affected repo: `carelever_assessment`

Evidence:

- Candidate controllers load `current_referral` from the JWT `referral_id` claim.
- No consistent check was found that `current_referral.person_id == current_person.id`.

Impact:

If a JWT is minted or forged with a mismatched `person_id` / `referral_id`, the request can act on another referral under the wrong candidate identity.

Recommendation:

- Validate person/referral binding on every candidate request.
- Add request specs for mismatched candidate JWT claims returning 401/403.

Confidence: Medium.

### Medium: Internal Referral Record Access May Bypass Tenant Scope

Affected repo: `carelever_assessment`

Evidence:

- `V1::Internal::ReferralPolicy#show?` / `update?` are broad internal portal checks.
- Internal referral controller loads referrals by reference number without an obvious policy scope filter.
- Other internal search/list paths do apply accessible company/site scoping.

Impact:

Scoped internal users may be able to read or update referrals outside assigned companies/sites if they know a reference number.

Recommendation:

- Add record-level checks to internal referral policy or controller loading.
- Add request specs for scoped internal users attempting out-of-scope referral show/update.

Confidence: Medium.

### Medium: Authentication JWT Decoding Does Not Explicitly Pin Algorithms

Affected repo: `carelever_authentication`

Evidence:

- Several `JWT.decode` calls decode with `AppConfig::API_SECRET_KEY` but without an explicit `algorithms: ['HS256']` allowlist.
- Assessment does explicitly pass `algorithms: ['HS256']`.

Impact:

Modern JWT libraries mitigate many classic `alg: none` paths, but explicit algorithm allowlisting is still required hardening and prevents configuration/library drift.

Recommendation:

- Pass `algorithms: ['HS256']` on every symmetric JWT decode.
- Add negative tests for `none`, wrong algorithm, wrong secret, and expired tokens.

Confidence: Medium.

### Medium: Authentication Signing Keys Default to Blank Strings

Affected repo: `carelever_authentication`

Evidence:

- `AppConfig::API_SECRET_KEY` and `PARTNER_API_SECRET_KEY` use `ENV.fetch(..., '')`.

Impact:

A misconfigured deployment can boot with a known empty signing key, making token forgery trivial in that environment.

Recommendation:

- Fail fast at boot when signing secrets are blank outside test/development.
- Add a boot/config spec for production-like environments.

Confidence: High for the configuration gap; deployment likelihood unknown.

### Medium: Authentication Session Registry Fails Open on Redis Errors

Affected repo: `carelever_authentication`

Evidence:

- `SessionRegistry.valid?` rescues Redis errors and returns `true`.

Impact:

During Redis outage, revoked sessions become valid until JWT expiry. This is an availability-favoring choice with security trade-offs.

Recommendation:

- Prefer fail-closed for protected routes, or return 503 when revocation state is unavailable.
- If fail-open remains intentional, document the accepted risk, monitor Redis errors, and shorten token TTLs during incidents.

Confidence: High.

### Medium: Candidate OTP Is Stored Plaintext and Request Flow Lacks Send Throttling

Affected repo: `carelever_assessment`

Evidence:

- Candidate OTP request stores the generated OTP on the referral row.
- Verification has attempt limits, but the request/send path does not appear to enforce equivalent send-rate limiting.

Impact:

A DB leak exposes active OTPs. Attackers can also flood OTP emails for known candidate email/referral combinations.

Recommendation:

- Store hashed OTPs.
- Rate-limit OTP requests per email, referral, and IP.
- Add request specs for repeated OTP requests.

Confidence: High.

### Medium: Password Reset Completion Uses Short Code and Weak Rate-Limit Coverage

Affected repo: `carelever_authentication`

Evidence:

- Password reset uses a 4-character generated code inside a JWT-backed flow.
- Clear rate limiting was found on request/initiation paths, but not on all reset completion attempts.

Impact:

The effective code space is smaller than desirable for account recovery. If completion attempts are not throttled uniformly, brute-force risk increases.

Recommendation:

- Use longer single-use reset tokens.
- Store token hashes server-side.
- Rate-limit reset completion by token, user, and IP.

Confidence: Medium.

### Medium: Authentication Exposes Microsoft Graph Access Tokens Through User Show

Affected repo: `carelever_authentication`

Evidence:

- User show logic can include sender authorization data, including encoded OAuth access token material, when `with_sender_authorisations=true`.

Impact:

Authorized internal callers may retrieve third-party access tokens for users within reachable scope. This increases damage from an internal account compromise.

Recommendation:

- Do not expose raw or reversibly encoded OAuth access tokens through read APIs.
- Keep token use server-side behind explicit actions.
- Add response-shape tests proving access tokens are omitted.

Confidence: High.

### Low: Development Auth Bypasses Are Dangerous If Misconfigured

Affected repos:

- `carelever_assessment`
- `carelever_assessment_ui`

Evidence:

- Assessment middleware fails open in `development`.
- Assessment can stub the current user from `DEV_STUB_USER_EMAIL`.
- Assessment UI local environments enable dev auth bypass for some apps.
- Assessment service client has `BYPASS_AUTH_SERVICE`.

Impact:

If development settings leak into staging/production, auth can be bypassed or user provisioning can be faked.

Recommendation:

- Gate each bypass behind explicit local-only checks.
- Fail boot if bypass flags are enabled outside development/test.
- Add deployment checks for `RAILS_ENV`, `BYPASS_AUTH_SERVICE`, and UI auth bypass configs.

Confidence: Medium.

### Low: CORS and Legacy Header Surface Should Be Tightened

Affected repos:

- `carelever_assessment`
- `carelever_authentication`

Evidence:

- Assessment accepts legacy `HTTP_AUTHENTICATION` in addition to standard `Authorization: Bearer`.
- Authentication uses credentialed CORS for broad carelever subdomain patterns.
- Assessment allows any request headers from configured origins.

Impact:

This is not a direct vulnerability if production origins are tightly controlled, but it broadens the client and proxy surface.

Recommendation:

- Remove legacy auth header support after migration.
- Enumerate exact production origins where possible.
- Avoid credentialed CORS unless required.

Confidence: Medium.

## Positive Controls

- Assessment uses a global `authenticate_user!` before action and Pundit authorization verification in `ApplicationController`.
- Assessment JWT decoding pins `HS256` and verifies expiration.
- Assessment rejects inactive users/people after token decode.
- Assessment portal policies double-gate on JWT classification and local role state.
- Assessment client company scoping includes DB/contact checks instead of blindly trusting `company_id` claims.
- Authentication uses bcrypt via `has_secure_password`.
- Authentication has login lockout and OTP attempt controls.
- Authentication has Redis-backed session registration/revocation for normal sessions.
- Authentication includes request specs around logout/session registry, rate limiting, RBAC sync, and token parser behavior.
- Both repos configure sensitive parameter filtering for passwords/tokens/OTP-like values.
- Production/staging Rails SSL enforcement is configured.

## Recommended Contract Tests

1. Revocation parity: login through Authentication, call Assessment, revoke/logout in Authentication, then assert Assessment rejects the same token.
2. JWT schema parity: shared tests for internal, external, affiliate, candidate, impersonation, and service-token claim shapes.
3. Algorithm hardening: both services reject `none`, wrong algorithm, wrong secret, and expired tokens.
4. Service-token boundary: only trusted service identities can call inter-service endpoints, and service tokens carry `iss`, `aud`, and `jti`.
5. Affiliate claim binding: affiliate token with mismatched `supplier_id` is rejected by Assessment.
6. Candidate claim binding: candidate token with mismatched `person_id` / `referral_id` is rejected by Assessment.
7. Data-sync webhook: unsigned SNS notification is rejected; valid signed notification is accepted.
8. UI logout: logout calls Authentication `/v1/logout` before clearing local token state.

## Priority Remediation Plan

1. Lock down data-sync webhooks in both services.
2. Remove or strictly gate `ch_authenticate`.
3. Make Assessment enforce Authentication revocation or token introspection.
4. Remove sender credentials and third-party tokens from JWT/API responses.
5. Tighten Assessment impersonation, candidate view-as, affiliate supplier binding, and candidate referral binding.
6. Harden service-to-service auth with dedicated keys, issuer/audience, and registered token IDs.
7. Fail fast on blank signing secrets and dangerous bypass flags outside local/test.
8. Add the cross-service security contract tests listed above.

## Residual Risks / Not Verified

- Production secret storage, rotation, and parity across services.
- Edge controls such as WAF, mTLS, IP allowlists, and SNS subscription restrictions.
- Redis availability and operational handling during session-registry outages.
- Data-sync latency for Authentication deactivation/archive events reaching Assessment.
- Whether deployed branches contain route or gateway controls not present in the local workspaces.
- Whether any carelever subdomain covered by CORS is user-controlled or separately compromise-prone.
