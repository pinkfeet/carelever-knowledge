# Doctor Assignment for Referrals

## How Doctors Get Assigned

There is no auto-assignment or round-robin. Doctors pull work from a shared queue.

| Method | Who | When |
|---|---|---|
| Self-claim | Doctor from doctor portal queue | Normal flow — doctor picks from unassigned referrals |
| Admin assign | Staff/admin from referral page | Override — manually assign a specific doctor |
| Auto-reassign | System | After doctor review issues are resolved, re-assigns to the original doctor |

## Self-Claim (Primary Flow)

Doctors see a queue of referrals that need review in the doctor portal (`doctor/reviews`). They claim a referral by clicking "Claim", which triggers an atomic update to prevent race conditions:

```ruby
# Only assigns if no doctor is currently assigned
Referral.where(id: @referral.id, assigned_doctor_id: nil)
        .update_all(assigned_doctor_id: current_user.id, assigned_doctor_at: Time.current)
```

If another doctor has already claimed it, the request fails with "This request is already assigned to another doctor".

Doctors can also **release** a referral back to the queue:

```ruby
@referral.update!(assigned_doctor_id: nil, assigned_doctor_at: nil)
```

### Key files (Replit)

- Controller: `app/controllers/doctor/reviews_controller.rb` — `claim`, `release` actions
- Dashboard: `app/controllers/doctor/dashboard_controller.rb` — queue and stats

## Admin Assign (Secondary Flow)

Admin/staff users can manually assign a doctor from the referral page:

```ruby
doctor_profile = DoctorProfile.ama_available.find_by(user_id: doctor_user_id)
@referral.update!(assigned_doctor: doctor_profile.user)
```

Only doctors with `ama_available` doctor profiles are eligible for selection.

### Key files (Replit)

- Controller: `app/controllers/referrals_controller.rb` — `assign_doctor` action

## Auto-Reassign After Issue Resolution

When a doctor flags issues during review (retests, clarifications), the referral enters an `awaiting_doctor_review_issues` state. Once all issues are resolved, the system automatically re-assigns the referral back to the original doctor:

```ruby
original_doctor_id = current_batch_issues.order(created_at: :asc).first&.flagged_by_id
update_attrs[:assigned_doctor_id] = original_doctor_id
update_attrs[:assigned_doctor_at] = Time.current
```

### Key files (Replit)

- Concern: `app/models/concerns/referral/status_transitions.rb` — `flag_doctor_review_issues!`, `check_all_doctor_review_issues_resolved!`

## AMA (Appointed Medical Adviser)

During referral creation (wizard), the creator can select an AMA — a specific doctor or contact to be the medical adviser. This is stored as `ama_selected` on the referral draft and mapped during referral creation via `Referrals::RelationshipCreator`.

AMA selection is different from doctor assignment — AMA is the nominated medical adviser for the employer, while `assigned_doctor` is who reviews the results.

## Doctor Notifications

When certain events occur on an assigned referral, the system creates `DoctorNotification` records for the assigned doctor (e.g. results received, further info uploaded).

## Related Models

- `referrals.assigned_doctor_id` — FK to `users`, the currently assigned doctor
- `referrals.assigned_doctor_at` — timestamp of when doctor was assigned
- `doctor_profiles` — extended doctor info, `ama_available` flag, signature data
- `doctor_service_capabilities` — which services a doctor can review
- `doctor_notifications` — in-app notifications for doctors
- `doctor_review_issues` — issues flagged by doctor during review (Replit only)
