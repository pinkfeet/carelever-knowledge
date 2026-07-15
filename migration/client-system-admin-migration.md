# Plan: Handle `system_admin` in Client User Migration

**Date:** 2026-07-14
**Status:** Plan / review only — no code changed. Revised 2026-07-14 after review: §3/§4.1's derivation snippet was corrected — `access_roles` is not callable on the plain `User` AR object the export iterates (see §3).
**Repos touched:** `carelever_assessment` (export + import scripts, doc), `carelever_authentication` (parity consideration only)
**Audience:** reviewing agent — validates the gap analysis, source signal, and proposed change set before implementation.

---

## TL;DR

`system_admin` is a **client sub-role** (`User#client_role`), not a `Role`/`role_type`. The migration assigns the `client` `Role` correctly, but **never carries `client_role`** for migrated clients — so every migrated client admin lands as `client_role: nil` (treated as a plain `user`, not an admin). Root cause: the export reads a column that does not exist (`user_company_details.role`), and the live Auth backfill (`derive_user_rbac.rb`) never derives `client_role` at all. The fix is to derive `client_role` from the real legacy signal — the `company_administrator` slug on the `UserAccessRole`/`AccessRole` join (service `company`) — in the export, and re-run the idempotent import. Parity with `derive_user_rbac.rb` is recommended but the export fix alone is sufficient for the bootstrap (see §4).

---

## 1. Background — what `system_admin` actually is

In Assessment, `client_role` is a string attribute on a client `User`, distinct from the `Role` join (`role_type: 'client'`):

- `app/models/user.rb:99` — `CLIENT_ROLES = %w[system_admin user].freeze`
- `app/models/user.rb:81` — `validates :client_role, inclusion: { in: %w[system_admin user] }, allow_nil: true`
- `app/models/user.rb:201` — `client_system_admin? = client? && client_role == 'system_admin'`
- `app/models/user.rb:209-213` — `client_can?` short-circuits `true` for `client_system_admin?`

So `system_admin` is **authorization state**, not a `role_type`. The migration's `roles_by_type` only knows `client`/`affiliate` (`external_users_import.rb:33`), which is correct — we must additionally populate the `client_role` column.

---

## 2. Gap analysis — why it's dropped today

### 2.1 Export reads a non-existent column
`script/migrate/external_users_export.rb:112`:
```ruby
client_role = details.respond_to?(:role) ? details.role : nil
```
`details` is a `UserCompanyDetail`. The `user_company_details` table has **no `role` column** (verified in `carelever_authentication/db/schema.rb`):
```
user_company_details: user_id, company_id, job_title,
                      screen_roles[], monitor_roles[], manage_roles[]
```
So `details.role` is always `nil` → every client row exports `client_role: nil`. (The `respond_to?` guard only suppresses a `NoMethodError`; it never produces a value.)

This matches the documented behaviour: `docs/data-sync/initial-migration.md:466` —
> **`client_role` (`system_admin` / `user`):** not stored on `user_company_details`. Export does not derive it from access roles today — defaults to nil at import; assign via Auth/Assessment admin flows post-migration if needed.

### 2.2 Auth backfill (`derive_user_rbac.rb`) never derives it
`carelever_authentication/script/migrate/derive_user_rbac.rb` derives **only `role_type`** via `UserRole` rows (`propose_role_types` → `client`/`affiliate`/etc.) and stamps `assessment_rbac_seeded_at`. It does **not** touch `client_role`.

In Auth, `client_role` rides a **transient** accessor, not a persisted column:
- `carelever_authentication/app/models/user.rb:75` — `attr_accessor :assessment_client_role, ...`
- `carelever_authentication/app/models/user.rb:413` — `client_role: assessment_client_role` inside `model_data`
- `assessment_workflow_data` (around `user.rb:415+`) compresses `nil` away → `client_role` is **absent** from `model_data` unless an explicit command set it.

Because the live `DataSync::Users::Sync` treats an absent `client_role` as **"don't touch"** (`app/commands/data_sync/users/sync.rb:16`), and the import sets it from the snapshot, the bootstrap value persists — see §4.

---

## 3. The real source signal

The legacy "company administrator" is **not** a `client_role` value; it's an access role:

```ruby
# carelever_authentication/app/policies/concerns/external/role_based_permissions.rb:23
def company_admin?
  user.access_roles&.dig('company', 'company_administrator').present?
end
```

- **`access_roles` is not a column, and not a method on the plain `User` AR model — do not call `u.access_roles` in the export script.** It's a request-scoped hash built by `Users::ParseAccessRoles.new(user).json_roles` (`carelever_authentication/app/services/users/parse_access_roles.rb:18-20`) from `UserAccessRole` join rows, then exposed only via `CurrentUser#access_roles` (`current_user.rb:20-22` — `@attributes.access_roles`). `company_admin?` works in policy context because `user` there is a `CurrentUser`, not the AR `User`. The export iterates plain `User.kept.where(...)` records, which have no `access_roles` method — calling it raises `NoMethodError`. The export must query the underlying join table directly (see derivation rule below).
- `company_administrator` is the legacy slug (`AccessRole#slug`, under `service: :company` — `UserAccessRole` enum, `carelever_authentication/app/models/user_access_role.rb:39`); the new model's equivalent is `system_admin`. (Distinct from `AccessRole::ADMIN_SLUGS = %w[global_administrator administrator]`, which are **internal** admin slugs — do not confuse them.)

**Derivation rule (client rows only, `classification == 'external'`), querying the join table directly — the same pattern already used in `V1::External::Settings::IsAdmin` (`carelever_authentication/app/commands/v1/external/settings/is_admin.rb:14-17`) and in `derive_user_rbac.rb`'s own `propose_internal_role_types` (`user_access_role.joins(:access_role)...`):**
```ruby
u.user_access_role
 .joins(:access_role)
 .where(access_roles: { slug: 'company_administrator' }, service: UserAccessRole.services[:company])
 .any?
```

> Note: `user_company_detail.manage_roles` is a separate array and was checked — it is **not** the admin signal (it lists managed service/site roles, not the company-admin grant). The authoritative signal is the `company_administrator` slug on `UserAccessRole`/`AccessRole` (service `company`), matching `company_admin?`.

---

## 4. Proposed change set

### 4.1 `script/migrate/external_users_export.rb` (PRIMARY — in `carelever_assessment`, runs in Auth console)
Replace `external_users_export.rb:112`:
```ruby
client_role = details.respond_to?(:role) ? details.role : nil
```
with a derivation queried from the `UserAccessRole`/`AccessRole` join table — **not** `u.access_roles`, which only exists on `CurrentUser` and would raise `NoMethodError` on the plain `User` AR object the export iterates (see §3).

To avoid one query per external user, precompute the company-admin `user_id` set once before the export loop (same style as the existing `duplicate_emails`/`winning_ids` precomputation above it):
```ruby
company_admin_ids = UserAccessRole.joins(:access_role)
                                   .where(access_roles: { slug: 'company_administrator' },
                                          service: UserAccessRole.services[:company])
                                   .distinct
                                   .pluck(:user_id)
                                   .to_set
```
then inside the loop, in place of `external_users_export.rb:112`:
```ruby
# client_role is not a stored column; derive the legacy company-admin grant.
client_role = company_admin_ids.include?(u.id) ? 'system_admin' : 'user'
```
Scope to the `else` (non-affiliate) branch only — affiliates have no `client_role` (import already forces `nil` at `external_users_import.rb:87`).

### 4.2 `script/migrate/external_users_import.rb` (NO change required; optional hardening)
- `external_users_import.rb:87` already does `client_role: role_type == "client" ? row["client_role"].presence : nil` — it will carry the derived value through unchanged.
- **Optional:** default `nil → 'user'` so a migrated client never lands in the invalid `client? && client_role.nil?` state (neither admin nor plain user). With §4.1 always emitting a value, this is belt-and-suspenders.

### 4.3 Parity with `carelever_authentication/script/migrate/derive_user_rbac.rb` (RECOMMENDED, Auth repo)
The parity contract (`docs/data-sync/initial-migration.md:135-139`) requires the export's role logic to stay identical to `derive_user_rbac.rb#propose_role_types`, because "after seed, Auth wins."

- **Minimal:** the export fix (§4.1) is sufficient for the migration bootstrap. The live `DataSync` treats absent `client_role` as "don't touch" (`sync.rb:16`), so the import-set value is **not** overwritten by later Auth events. Re-running the export after the fix and re-running the idempotent import refreshes Assessment.
- **Full parity (recommended):** add the same `company_administrator`-slug join-table derivation (§3/§4.1 — `derive_user_rbac.rb`'s `users_scope` is also plain `User` AR objects, so this needs the same `user_access_role.joins(:access_role)` query, not `access_roles.dig`) to `derive_user_rbac.rb` and have it set `assessment_client_role` + publish an SNS event, so Auth's `model_data` is self-consistent and a future re-derive cannot diverge. This is more involved (transient accessor + event publish) and can be a follow-up if the export-only path is validated first.

### 4.4 Re-run sequence (post-change)
1. Edit `external_users_export.rb` (§4.1).
2. Re-run export in Auth console → fresh snapshot with correct `client_role`.
3. Re-run `external_users_import.rb` (idempotent per-user upsert) in Assessment console.
4. (If §4.3 done) re-run `derive_user_rbac.rb` on Auth, once per org.

---

## 5. Verification

- Spot-check the exported snapshot: count `client_role == 'system_admin'` vs the count of Auth clients where `company_admin?` is true (should match).
- Post-import in Assessment: `User.client.where(client_role: 'system_admin')` should equal the Auth `company_administrator` population; confirm `client_system_admin?` returns true for a sample.
- Confirm a `system_admin` client can hit an admin-gated endpoint (e.g. `v1/client/settings/users`) — see `app/policies/v1/client/settings/user_policy.rb:7` (`user.client_system_admin?`).
- Idempotency: re-run import twice; no duplicate rows, counts stable.

---

## 6. Risks / open questions

- **Invalid `nil` state:** if §4.1 is skipped for any row, a client could land `client_role: nil`. Mitigate via §4.2 default-to-`'user'`.
- **Transient accessor in `derive_user_rbac.rb`:** `assessment_client_role` is not persisted; the backfill must set it in-process and publish an event for it to reach Assessment via live sync. If not done, rely on the import bootstrap (safe, per §2.2 / §4.3).
- **Catalog drift:** `system_admin`/`user` are values, not `Role` names — no RBAC catalog coupling, so no `rbac.yml` parity risk.
- **Not in scope:** `manage_roles`/`screen_roles`/`monitor_roles` mapping to client permissions — separate from `client_role`. The migration currently does not carry client permission grants; that is a distinct follow-up (the docs note "assign via admin flows post-migration").

---

## 7. File reference index

| File | Line | Relevance |
|------|------|-----------|
| `carelever_assessment/script/migrate/external_users_export.rb` | 112 | reads non-existent `details.role` → must derive from `UserAccessRole`/`AccessRole` join |
| `carelever_assessment/script/migrate/external_users_import.rb` | 33, 87 | `roles_by_type` (client/affiliate) + carries `client_role` |
| `carelever_assessment/app/models/user.rb` | 81, 99, 201, 209 | `client_role` validation, `CLIENT_ROLES`, `client_system_admin?`, `client_can?` |
| `carelever_assessment/app/commands/data_sync/users/sync.rb` | 16 | absent `client_role` = "don't touch" |
| `carelever_assessment/docs/data-sync/initial-migration.md` | 466 | documents client_role not derived today |
| `carelever_authentication/script/migrate/derive_user_rbac.rb` | — | derives only `role_type`; parity target |
| `carelever_authentication/app/models/user.rb` | 75, 413 | `assessment_client_role` transient accessor in `model_data` |
| `carelever_authentication/app/policies/concerns/external/role_based_permissions.rb` | 23-24 | `company_admin?` = `access_roles.dig('company','company_administrator')`; `user` there is a `CurrentUser`, not the AR `User` |
| `carelever_authentication/db/schema.rb` | — | `user_company_details` has no `role` column |
| `carelever_authentication/app/commands/v1/external/settings/is_admin.rb` | 14-17 | canonical join-table derivation pattern the export fix copies (`user_access_role.joins(:access_role).where(...)`) |
| `carelever_authentication/app/models/current_user.rb` | 20-22 | `access_roles` is defined **only** here — not on the plain `User` AR model the export iterates |
| `carelever_authentication/app/services/users/parse_access_roles.rb` | 18-20 | builds the `access_roles` hash `CurrentUser` carries, from `UserAccessRole` rows |
| `carelever_authentication/app/models/user_access_role.rb` | 39 | `service` enum incl. `company: 6`, used in the join-table query |
