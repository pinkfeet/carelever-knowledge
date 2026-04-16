# Referral Results Tab — Where the Data Comes From

## There Is No `Result` Model

The Results tab is a **composite view** — it doesn't have its own model or table. It aggregates data from several existing models:

| UI Element | Source Model | Key Fields |
|---|---|---|
| Overall Outcome | `Referral` | `doctor_outcome`, `doctor_outcome_finalised_at` |
| Service row status | `Service` | `appointment_attended_at`, `results_received_at`, `service_completed_at` |
| Service outcome | `Service` | `doctor_outcome`, `matrix_outcome` |
| Upload / Documents | `CandidateDocument` | `document_type: 'result_document'` |
| Approval blocking | `OutcomeApproval` | `status` (pending/approved/rejected) |

## FormSession — The Core Data Behind Results

`FormSession` tracks form-filling across four roles:

| session_type | Who | Purpose |
|---|---|---|
| `candidate` | Person being assessed | Pre-assessment questionnaire |
| `employer` | Employer / client | Employer-provided info |
| **`assessor`** | **Clinic staff** | **Records test results (e.g. drug test readings)** |
| `doctor` | Reviewing doctor | Doctor review and final outcome |

The **assessor form session** is the key piece — it holds the actual assessment data (test readings, observations) that feeds into the Results tab.

### Relationship Chain

```
Referral → Service (e.g. "Drug and Alcohol Test")
              → FormSession (type: assessor)
                  → FormFieldResponse (individual field values)
```

## Status Badges — How They're Computed

Status is not stored directly. It's derived from service timestamps:

| Status | Condition |
|---|---|
| Pending Assessment | No `appointment_attended_at` |
| Waiting on Clinic | Appointment attended, no `results_received_at` |
| Waiting on Doctor Review | Results received, no doctor outcome |
| Under Review | Doctor is reviewing |
| Awaiting Approval | `OutcomeApproval` is pending |
| Complete | `service_completed_at` is set |

## The "Upload" Action

Upload is for when a clinic sends paper/PDF results instead of filling out the digital assessor form.

**Flow:**
1. User uploads a scanned document (PDF, JPG, PNG)
2. Saved as `CandidateDocument` with `document_type: 'result_document'`
3. `Ai::ResultDocumentExtractor` analyses the document
4. AI extracts field values and maps them to assessor form fields
5. User reviews extracted values and selectively applies them
6. Service is marked as `results_received_at`

It bridges paper-based and digital workflows — the scan is stored as a document, and the extracted data populates the assessor form.

## Key Files (Replit Project)

- **Internal results tab template:** `app/views/referrals/_tab_results.html.erb`
- **Client results tab template:** `app/views/client/referrals/_tab_results.html.erb`
- **FormSession model:** `app/models/form_session.rb`
- **Upload controller action:** `app/controllers/services_controller.rb` → `process_result_upload`
- **AI extractor:** `app/services/ai/result_document_extractor.rb`
- **Form aggregation:** `app/services/forms/aggregate_for_referral.rb`
