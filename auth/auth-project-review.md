# Carelever Authentication Project Review

Date: 2026-03-27

## What Information It Keeps

The authentication service stores:

- User identity and account data: name, email, username, classification, company_id, preferences/options.
- Credential and login security data: password_digest, login_attempts, locked_until, password_reset_code.
- OTP/MFA data: otp_mode, otp_secret_key, otp counters/expiry, and separate user_mfas records.
- Session metadata: user_login_sessions includes remote_ip, user_agent, OTP verification/expiry timestamps, and session secret_key.
- Role assignment data: user_access_roles links user + access_role by service and scope (site_id/location_id).
- Role catalog data: access_roles contains role slug/name/classification and per-service flags.
- External-company role metadata: user_company_details stores screen_roles, monitor_roles, manage_roles arrays and job_title.
- Organisation tenant config: slug, defaults JSON, allowed_access_services, otp_enabled.
- Company service toggles/restrictions: company for\_\* flags and company_service_restrictions.
- Auxiliary auth artifacts: sender_authorisations with encrypted access/refresh tokens, email_verification_codes for verify flows.

## Permission Model

Authorization is role-based on top of JWT-authenticated identity:

1. Middleware decodes JWT, validates token source, and injects token payload into request params.
2. Controllers use Pundit with a CurrentUser wrapper built from token payload fields.
3. Policy gates check both:
   - user classification (internal/external/comply)
   - role presence in access_roles claim (derived from user_access_roles + access_roles)

There is also bitmask-style microservice access in users.access (screen/monitor/manage/comply), which is used alongside role assignments.

## Roles Observed

Internal roles:

- standard_internal
- administrator
- global_administrator

External roles:

- standard_external
- restricted_access
- starter_external
- external_administrator
- company_administrator

Comply role:

- comply_user

Other role present in seed task:

- access_referral_only (Files Only)

## Possible Values Reference

### Role Slug Values (Observed Across Seed Tasks And Policies)

- global_administrator
- administrator
- standard_internal
- standard_external
- restricted_access
- starter_external
- external_administrator
- company_administrator
- comply_user
- access_referral_only

### User Classification Values

- internal
- external
- comply
- affiliate

### UserAccessRole Service Values

- screen
- monitor
- manage
- comply
- cloudhealth
- company

### OTP Mode Values

- sms
- email
- authenticator_app
- no_otp

### Policy Checks In Authentication Service

Internal role checks:

- global_admin?(microservices)
- admin?(microservices)
- standard_internal?(microservices)

External role checks:

- standard_external?(microservices)
- external_restricted_access?(microservices)
- starter_external?(microservices)
- external_administrator?(microservices)
- company_admin?

Classification checks:

- internal_user?
- external_user?
- comply_user?

Top-level access predicates:

- Internal::ApplicationPolicy#can_access?
- External::ApplicationPolicy#can_access?
- Comply::ApplicationPolicy#can_access?
- InternalExternal::CurrentUserPolicy#show?

### Policy Checks In Screen

Internal checks:

- global_admin?("screen")
- admin?("screen")
- standard_internal?("screen")
- access_referral_only?("screen")

External checks:

- standard_external?("screen")
- external_restricted_access?("screen")
- starter_external?("screen")
- company_administrator?

Top-level predicates:

- External::ApplicationPolicy#can_access?
- External::ApplicationPolicy#external_user_or_company_admin?

### Policy Checks In Hub Manage

External role checks:

- standard_external?("manage")
- external_restricted_access?("manage")
- external_user?
- external_user_with_company_access?

Module-level checks:

- module_access?(access_keys, classification:, service:)
- org_module_access_for(classification:, service:, role:)

Top-level predicate:

- External::ApplicationPolicy#can_access?

### Common access_roles JSON Shapes

Single role with all sites:

```json
{
  "screen": {
    "standard_external": "all"
  }
}
```

Single role with scoped sites:

```json
{
  "manage": {
    "restricted_access": ["site-uuid-1", "site-uuid-2"]
  }
}
```

Company admin role:

```json
{
  "company": {
    "company_administrator": "all"
  }
}
```

## Classification Vs UserAccessRole

These are separate concepts and they solve different problems.

### Classification

Classification is the high-level user type.

It answers:

- What kind of user is this?
- Which policy family should treat this user as valid?

Typical values are:

- internal
- external
- comply
- affiliate

Classification is stored directly on the user record and is used as the first authorization gate. For example:

- internal policies require classification = internal
- external policies require classification = external
- comply policies require classification = comply

So classification is about identity category, not detailed permissions.

### UserAccessRole

UserAccessRole is the detailed permission assignment layer.

It answers:

- Which service does this user have access to?
- Which access role do they hold for that service?
- Is that role scoped to all sites/locations or only specific ones?

Each user_access_roles row links:

- user
- access_role
- service
- scope via site_id or location_id

Typical service values are:

- screen
- monitor
- manage
- comply
- company
- cloudhealth

Typical role examples are:

- standard_internal
- administrator
- global_administrator
- standard_external
- restricted_access
- starter_external
- company_administrator
- comply_user

### How They Work Together

The system generally evaluates access in layers:

1. classification decides whether the user belongs to the correct user family
2. access bitmask decides whether the user has coarse microservice access
3. user_access_roles decides the exact role and scope inside that microservice

Example:

- A user can be classification = external but still have no manage access if they do not have a relevant user_access_role for manage.
- A user can be classification = internal but only have standard_internal on screen, not administrator.
- A user can be classification = external with restricted_access for manage and only a subset of site IDs.

### Practical Rule

Use classification to understand who the user is.

Use user_access_roles to understand what the user can do and where they can do it.
