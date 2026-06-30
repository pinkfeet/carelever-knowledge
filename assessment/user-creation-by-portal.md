# Assessment — User creation by portal role

Date: 2026-07-01

Reference for **where** login accounts are created in the Carelever Assessment stack (`carelever_assessment` + `carelever_assessment_ui` + `carelever_authentication`), **how** the flow works, and **whether an invitation / welcome email is sent**.

Applies to the ported Angular + JSON API system. The legacy Replit monolith had different mailers and onboarding flows.

---

## Quick reference

| Portal / role | User record? | Primary create path | Password set by | Welcome / invite email? |
|---|---|---|---|---|
| **Client** | Yes (`User`, external) | Client portal → Settings → Users | Auth auto-generates | **Yes** — password-setup welcome email |
| **Client** | Yes | Internal → Settings → Users → New User (Client role) | Admin at create time | **No** |
| **Client** | Yes | Internal → Company → People → attach existing user | N/A (existing user) | **No** |
| **Client** | Yes | Client → contact → Grant portal access | Auth auto-generates | **Unlikely** (see gap note below) |
| **Affiliate** | Yes (`User`, affiliate) | Internal → Settings → Users → New User (Affiliate role + clinic) | Admin at create time | **No** |
| **Affiliate** | — | Affiliate portal → Settings → Assessors | N/A (links existing user) | **No** |
| **Doctor** | Yes (`User`, internal + Doctor role) | Internal → Settings → Users → New User (Doctor role) | Admin at create time | **No** |
| **Doctor** | — | Internal → Settings → Doctors → Add Doctor | N/A (links existing user to `DoctorProfile`) | **No** |
| **Internal staff** (admin, assessor, standard) | Yes (`User`, internal) | Internal → Settings → Users → New User | Admin at create time | **No** |
| **Assessor** (at clinic) | — | Internal → Clinic → Assessors / Setup Wizard | Varies (see below) | **No** (wizard invite email deferred CT-5418) |
| **Candidate** | **No** — referral-scoped session | Created implicitly when a referral is created | OTP or magic link per login | **OTP email** + **notification-trigger emails** (magic links) |

---

## Architecture note

User **writes** (create / update / archive) go to **carelever_authentication**. Assessment keeps a **local mirror** of users synced via SNS. Reads in Settings UI lists come from Assessment; creates patch Auth first.

Auth endpoints used by Assessment internal UI (`AssessmentAuthUsersApiService`):

| Selected role type(s) | Auth endpoint |
|---|---|
| `client` | `POST /v1/authentication/assessment/client_users` |
| `affiliate` | `POST /v1/authentication/assessment/affiliate_users` |
| `admin`, `assessor`, `doctor`, `standard` (anything else) | `POST /v1/authentication/assessment/internal_users` |

Client portal user writes use a different external-facing endpoint:

| Action | Auth endpoint |
|---|---|
| Client portal create / update / archive | `/v1/external/assessment/users` |

---

## Client

### 1. Client portal — Settings → Users → Add person (login user)

- **UI:** `carelever_assessment_ui` → client app → Settings → Users (requires `client_add_users`; system admins can set role + permissions).
- **API:** `POST /v1/external/assessment/users` (Auth).
- **Process:**
  1. Admin chooses **Login user** (vs contact-only).
  2. Enters name, email, phone, job title, updatee/reportee flags.
  3. System admins can set `client_role` (`user` vs `system_admin`) and RBAC permissions.
  4. Auth creates an external user, auto-generates a password, grants **Company Administrator** access role (required for client-portal login), syncs RBAC, mirrors to Assessment.
- **Email:** **Yes.** `Assessment::External::Users::WelcomeEmailSender` sends `External::WelcomeEmailMailer` with subject *"Your Carelever User Account Has Been Created"* and a link to `{assessment_ui_domain}/client/reset-password-request`. The recipient completes password setup via the reset-password flow.

### 2. Internal portal — Settings → Users → New User (Client role)

- **UI:** `/settings/users/new` → select **Client** role + company.
- **API:** `POST /v1/authentication/assessment/client_users`.
- **Process:** Admin enters all fields including **password** (required — no auto-generate on this path). Optionally sets roles/permissions and job title.
- **Email:** **No.** `Manager::Assessment::ClientUsers::Create` does not call a welcome mailer. Admin must communicate credentials or user uses forgot-password.

### 3. Internal portal — Settings → Companies → [Company] → People

- **Contact only:** Creates a `Contact` row (no login).
- **Login user:** **Attach existing** Client-role user with no company (eligible-users picker). Does **not** create a brand-new login user (deferred follow-up CT-5117).
- **Email:** **No.**

### 4. Client portal — Grant portal access (contact → user)

- **UI:** Edit contact → **Grant portal access** (requires email + `client_add_users`).
- **API:** Assessment `POST /v1/client/settings/contacts/:id/grant_portal_access` → Auth legacy `POST /v1/external/settings/users` via `AuthenticationServiceClient`.
- **Process:** Mints Auth user + local `User` with client role and company scope assignment.
- **Email:** UI toast says *"An invitation email has been sent"*, but the legacy Auth create only sends welcome email when `user_access_roles` is non-empty. This path passes `user_access_roles: []`, so **the welcome email likely does not send**. Treat as a known gap if self-service onboarding is expected here.

---

## Affiliate

Affiliate portal users are **not** employer/client users. They log in with `username@org-slug` via **`POST /v2/affiliate/authenticate`** (Assessment UI), then complete **MFA** (email OTP by default, or authenticator app if enrolled) at `/login/otp` via `POST /v1/authentication/affiliate/authenticate_otp`. Legacy `POST /v1/authentication/affiliate/authenticate` still exists but bypasses the MFA gate — the new UI does not use it. See `carelever_authentication/docs/features/affiliate-mfa.md` (CT-4112).

### 1. Internal portal — Settings → Users → New User (Affiliate role)

- **UI:** `/settings/users/new` → select **Affiliate** role + **clinic** (supplier) picker.
- **API:** `POST /v1/authentication/assessment/affiliate_users`, then Assessment `setClinic` to link the user to the clinic.
- **Process:**
  1. Admin enters name, email, password, roles/permissions, job title.
  2. Auth creates user with `classification: affiliate`, `is_internal: true`, on the org's **affiliate default company**.
  3. Assessment links user to selected clinic (supplier).
- **Email:** **No.** Same as other internal-admin Auth creates — password is set manually at create time.

### 2. Affiliate portal — Settings → Assessors → Add assessor

- **UI:** `carelever_assessment_ui` → affiliate app → Settings → Assessors → create.
- **API:** Assessment `POST /v1/affiliate/practitioners` (links `Practitioner` to existing `User`).
- **Process:** Pick from **eligible users already assigned to the clinic**. UI copy: *"Contact an administrator to assign additional users."*
- **Email:** **No** — no user is created; only a clinic practitioner link.

### Related: internal clinic assessor linking

- **Internal → Settings → Clinics → [Clinic] → Assessors → Add:** same pattern — link existing staff user to clinic (`Practitioner` row).
- **Clinic Setup Wizard (Step 3):** can **provision a brand-new assessor** via `ProvisionPractitioner` → Auth `create_external_user`. Creates local Assessor `User` but **invite email is explicitly out of scope** (tracked as CT-5418).

---

## Doctor

Doctors are **internal-classification** users with the **Doctor** RBAC role. The doctor portal signs in with `classification: 'internal'` (email + password + MFA).

There is **no** Settings → Users page in the doctor app. All account provisioning is internal.

### 1. Internal portal — Settings → Users → New User (Doctor role)

- **UI:** `/settings/users/new` → select **Doctor** role.
- **API:** `POST /v1/authentication/assessment/internal_users`.
- **Process:** Admin creates the login account (password required). User gets Doctor role via RBAC sync.
- **Email:** **No.**

### 2. Internal portal — Settings → Doctors → Add Doctor

- **UI:** `/settings/doctors/new` → pick from **available users** (active users with Doctor role not yet linked to a `DoctorProfile`).
- **API:** Assessment `POST /v1/settings/doctors` with `user_id`.
- **Process:** Creates `DoctorProfile` + service capability configuration. **Does not create a User** — the account must already exist from step 1.
- **Email:** **No.**

---

## Internal staff (admin, assessor, standard)

Same create path as doctor accounts without the separate Doctors profile step.

### Internal portal — Settings → Users → New User

- **UI:** `/settings/users/new` → select one or more of Administrator, Assessor, Standard User, etc.
- **API:** `POST /v1/authentication/assessment/internal_users`.
- **Process:** Admin sets password, roles, permissions, optional job title. Legacy internal access roles are provisioned so Auth login works.
- **Login:** Internal portal uses `username@org-slug` + MFA (`POST /v1/authentication/internal/authenticate`).
- **Email:** **No** welcome / invitation email on this Assessment Auth path.

Assessors are often **linked to clinics** after creation (see Affiliate section) rather than receiving a separate account type.

---

## Candidate

Candidates are **not** `User` records. Access is **referral-scoped** via JWT claims (`is_candidate_session`, `person_id`, `referral_id`).

There is **no** Settings UI to "create a candidate user."

### How candidates get portal access

1. **Referral creation** — when a referral is created (internal/client/API), candidate details (`candidate_email`, name, etc.) are stored on the `Referral` / `Person`. A `candidate_access_token` may be generated for magic-link URLs embedded in notification templates.

2. **Magic link (primary entry)** — notification triggers / emails can include URLs like:
   `{app_host}/candidate/token_login?token={candidate_access_token}`

3. **OTP login (secondary)** — from the candidate portal:
   - `POST /v1/candidate/session/request_otp` with email
   - Sends **`CandidateOtpMailer`** (*"Your Carelever sign-in code"*) with a 6-digit code (10-minute expiry)
   - `POST /v1/candidate/session/verify` → JWT

### Email summary for candidates

| Email | When | Purpose |
|---|---|---|
| Notification-trigger emails | Referral lifecycle events (configured triggers) | May include magic links using `candidate_access_token` |
| `CandidateOtpMailer#code_email` | Candidate requests OTP sign-in | 6-digit one-time code |

This is **not** the Auth `WelcomeEmailMailer` / password-setup invitation used for client employer users.

See also: `carelever-knowledge/auth/candidate-login-assessment-plan.md`.

---

## Welcome email implementation (Auth)

Only relevant for flows that call a welcome sender:

| Sender | Password-setup link target | Used by |
|---|---|---|
| `Assessment::External::Users::WelcomeEmailSender` | Assessment client UI `/client/reset-password-request` | Client portal create (`/v1/external/assessment/users`) |
| `V1::External::Users::WelcomeEmailSender` | Legacy client UI domain | Generic external settings create (when access roles present) |
| `Hub::External::Users::WelcomeEmailSender` | Hub UI | Monitor/Hub user create (not Assessment) |

Mailer subject (external): *"Your Carelever User Account Has Been Created"*. Body instructs recipient to visit the password-setup link, request a reset email, and set a password.

**Assessment internal-admin creates** (`client_users`, `affiliate_users`, `internal_users` under `/v1/authentication/assessment/*`) **do not invoke any of these senders.**

---

## Known gaps / follow-ups

| Item | Ticket / note |
|---|---|
| Company People tab cannot create new login users (attach-only) | CT-5117 follow-up |
| Clinic setup wizard practitioner invite email | CT-5418 |
| Grant portal access UI claims email sent; Auth path may not send | Verify/fix welcome email + access role provisioning |
| Internal-created client/affiliate/doctor users rely on admin-set password | Consider adding welcome email parity with client-portal create |

---

## Code pointers

| Area | Location |
|---|---|
| Internal create user UI | `carelever_assessment_ui/apps/internal/.../settings/users/create-user.component.ts` |
| Client add user UI | `carelever_assessment_ui/apps/client/.../settings/users/components/add-person-form.component.ts` |
| Auth client create command | `carelever_authentication/app/commands/v1/external/assessment/users/create.rb` |
| Auth internal/client/affiliate create commands | `carelever_authentication/app/commands/manager/assessment/{internal,client,affiliate}_users/create.rb` |
| Welcome email (Assessment client) | `carelever_authentication/app/commands/assessment/external/users/welcome_email_sender.rb` |
| Grant portal access | `carelever_assessment/app/commands/v1/client/settings/contacts/grant_portal_access.rb` |
| Doctor profile link | `carelever_assessment/app/commands/v1/settings/doctors/create.rb` |
| Affiliate practitioner link | `carelever_assessment/app/commands/v1/affiliate/practitioners/create.rb` |
| Candidate OTP | `carelever_assessment/app/commands/v1/candidate/sessions/request_otp.rb` |
| Login endpoints overview | `carelever-knowledge/auth/login-endpoints.md` |
