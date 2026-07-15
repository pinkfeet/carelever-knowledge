# Staging → Development: Service Item Catalog + Form Builder Sync

**Date:** 2026-07-15  
**Repo tooling:** `carelever_assessment/script/db_reference/`  
**Direction:** staging (source) → development (target)  
**Keeps:** referrals and other transactional data (not in this sync)  
**Soft-hides:** catalog rows that exist only on development after import

Canonical engine docs: `carelever_assessment/script/db_reference/README.md` (sibling repo).

---

## What this copies

| Group                                       | Tables                                                                                                                                                                                                                                                                                        |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Lookups needed by catalog                   | `tags`, `service_outcome_options`, `component_bundles`                                                                                                                                                                                                                                        |
| Service item catalog                        | `service_items`, `service_variations`, `component_variants`, `service_item_outcome_options`, `service_bundle_items`, `previous_result_requirements`, `allowed_next_test_services`, `allowed_add_on_services`, `next_test_rules`, `service_prices`, `component_tags`, `component_bundle_items` |
| Form builder (new system) + component links | `form_elements`, `form_fields`, `form_options`, `field_validation_rules`, `form_section_definitions`, `form_section_elements`, `component_form_section_links`                                                                                                                                 |

`component_form_section_links` is required so Component Settings stay wired to form sections.

## What this does **not** copy

- Referrals, services, appointments, form sessions/responses
- Users, companies, sites
- Medical matrix, FMI (`further_info_*`), preparation items, notifications, consent defaults, issue definitions
- Legacy form system (`form_templates` / `form_sections`)

Import is **upsert by `id` only** — it does not delete extras on development. Soft-deactivate those in Step 5.

---

## Prerequisites

1. Rails console on **staging** (export) and **development** (import).
2. AWS access to the migration bucket (default pattern: `carelever-migrations`), **or** use `SNAPSHOT_DIR` for a local copy between environments.
3. On development, pick remap targets if staging user / netsuite location ids are missing:
   - a real `users.id` → `GENERIC_USER_ID`
   - a real `netsuite_locations.id` → `GENERIC_NETSUITE_LOCATION_ID`
4. All `ENV` flags are set **inline in the console** before `load`. Prefer `"1"` for booleans (`DRY_RUN`, `SKIP_PREFLIGHT`).

### Shared `TABLES` string

Use the same `TABLES` on export and import:

```ruby
CATALOG_AND_FORM_TABLES = %w[
  tags
  service_outcome_options
  component_bundles
  service_items
  service_variations
  component_variants
  service_item_outcome_options
  service_bundle_items
  previous_result_requirements
  allowed_next_test_services
  allowed_add_on_services
  next_test_rules
  service_prices
  component_tags
  component_bundle_items
  form_elements
  form_fields
  form_options
  field_validation_rules
  form_section_definitions
  form_section_elements
  component_form_section_links
].join(",")
```

---

## Step 1 — Export from staging

On the **staging** Assessment Rails console:

```ruby
CATALOG_AND_FORM_TABLES = %w[
  tags service_outcome_options component_bundles
  service_items service_variations component_variants
  service_item_outcome_options service_bundle_items
  previous_result_requirements allowed_next_test_services
  allowed_add_on_services next_test_rules service_prices
  component_tags component_bundle_items
  form_elements form_fields form_options field_validation_rules
  form_section_definitions form_section_elements
  component_form_section_links
].join(",")

ENV["TABLES"]           = CATALOG_AND_FORM_TABLES
ENV["MIGRATION_BUCKET"] = "carelever.uploads.staging"
ENV["MIGRATION_ENV"]    = "staging"
load "script/db_reference/export.rb"
```

Note the printed snapshot prefix, e.g. `reference/staging/2026-07-15T02-00-00Z`.

### Optional: local export (no S3)

```ruby
ENV["TABLES"]        = CATALOG_AND_FORM_TABLES
ENV["SNAPSHOT_DIR"]  = "/tmp/ref"
ENV["MIGRATION_ENV"] = "staging"
load "script/db_reference/export.rb"
# then copy /tmp/ref/reference/staging/<timestamp>/ to the machine that can reach the development console
```

---

## Step 2 — Resolve remap ids on development

On the **development** console:

```ruby
# Pick any real internal user that exists on development
User.limit(5).pluck(:id, :email)
# => set GENERIC_USER_ID to one of these

# Pick a netsuite location that should own remapped catalog location FKs
NetsuiteLocation.limit(5).pluck(:id, :name)
# => set GENERIC_NETSUITE_LOCATION_ID to one of these (import will WARN with counts)
```

---

## Step 3 — Dry-run import on development

Still on **development**. Use the prefix from Step 1.

```ruby
CATALOG_AND_FORM_TABLES = %w[
  tags service_outcome_options component_bundles
  service_items service_variations component_variants
  service_item_outcome_options service_bundle_items
  previous_result_requirements allowed_next_test_services
  allowed_add_on_services next_test_rules service_prices
  component_tags component_bundle_items
  form_elements form_fields form_options field_validation_rules
  form_section_definitions form_section_elements
  component_form_section_links
].join(",")

ENV["TABLES"]                       = CATALOG_AND_FORM_TABLES
ENV["MIGRATION_BUCKET"]             = "carelever-migrations"
ENV["SNAPSHOT_PREFIX"]              = "reference/staging/<timestamp>" # from export
ENV["GENERIC_USER_ID"]              = "<dev-user-uuid>"
ENV["GENERIC_NETSUITE_LOCATION_ID"] = "<dev-netsuite-location-uuid>"
ENV["DRY_RUN"]                      = "1"
load "script/db_reference/import.rb"
```

Local snapshot instead of S3:

```ruby
ENV["SNAPSHOT_DIR"]    = "/tmp/ref"
ENV["SNAPSHOT_PREFIX"] = "reference/staging/<timestamp>"
# plus TABLES / GENERIC_* / DRY_RUN as above
load "script/db_reference/import.rb"
```

Confirm preflight passes and upsert counts look reasonable. `DRY_RUN=1` rolls back — nothing is persisted.

If needed, use this for cleanup

```ruby
ENV["LONG_ENV_NAME"]


base = "/tmp/ref/reference/staging/2026-07-15T02-33-54Z" # your SNAPSHOT_PREFIX path
stg = JSON.parse(File.read("#{base}/service_items.json"))

# fix collision
stg_by_code = stg.to_h { |r| [r["code"], r["id"]] }
conflicts = ServiceItem.where(code: stg_by_code.keys).filter_map do |si|
  next if stg_by_code[si.code] == si.id
  { code: si.code, dev_id: si.id, staging_id: stg_by_code[si.code], name: si.name, active: si.active }
end
conflicts.size
#conflicts.first(20)

conflicts.each do |c|
  ServiceItem.where(id: c[:dev_id]).update_all(
    code: "#{c[:code]}__DEV_LEGACY_#{c[:dev_id].to_s[0, 8]}",
    active: false
  )
end

# fix form

stg = JSON.parse(File.read("#{base}/form_elements.json"))
stg_by_name = stg.to_h { |r| [r["name"], r["id"]] }
conflicts = FormElement.where(name: stg_by_name.keys).filter_map do |fe|
  next if stg_by_name[fe.name] == fe.id
  { id: fe.id, name: fe.name, staging_id: stg_by_name[fe.name] }
end
conflicts.size
#conflicts.first(10)

conflicts.each do |c|
  FormElement.where(id: c[:id]).update_all(
    name: "#{c[:name]} __DEV_LEGACY_#{c[:id].to_s[0, 8]}"
  )
end

# fix form fields

stg = JSON.parse(File.read("#{base}/form_fields.json"))
conflicts = stg.filter_map do |r|
  next if r["form_element_id"].blank? # legacy rows excluded from sync anyway
  q = FormField.where(
    form_element_id: r["form_element_id"],
    field_key: r["field_key"]
  ).where.not(id: r["id"])
  next if q.none?
  q.pluck(:id, :field_key)
end
# flatten: [[id, key], ...]
pairs = conflicts.flatten(1)
puts "conflicts: #{pairs.size}"


pairs.each do |id, key|
  FormField.where(id: id).update_all(
    field_key: "#{key}__DEV_LEGACY_#{id.to_s[0, 8]}"
  )
end

# fix form_section_elements
stg = JSON.parse(File.read("#{base}/form_section_elements.json"))
ids = stg.flat_map do |r|
  FormSectionElement.where(
    form_section_definition_id: r["form_section_definition_id"],
    form_element_id: r["form_element_id"]
  ).where.not(id: r["id"]).pluck(:id)
end.uniq
puts "deleting #{ids.size}"

FormSectionElement.where(id: ids).delete_all


# fix all others

{
  "service_item_outcome_options.json" => [ServiceItemOutcomeOption, %w[service_item_id service_outcome_option_id service_variation_id]],
  "service_bundle_items.json"         => [ServiceBundleItem, %w[bundle_id component_id service_variation_id]],
  "component_tags.json"               => [ComponentTag, %w[service_item_id tag_id]],
  "component_bundle_items.json"       => [ComponentBundleItem, %w[component_bundle_id service_item_id]], # verify columns if this fails
  "component_form_section_links.json" => [ComponentFormSectionLink, %w[service_item_id form_section_definition_id service_variation_id component_variant_id]],
  "allowed_next_test_services.json"   => [AllowedNextTestService, %w[service_item_id service_variation_id next_test_service_item_id next_test_service_variation_id]],
  "allowed_add_on_services.json"      => [AllowedAddOnService, %w[service_item_id service_variation_id add_on_service_item_id add_on_service_variation_id]],
}.each do |file, (model, cols)|
  path = "#{base}/#{file}"
  next unless File.exist?(path)
  stg = JSON.parse(File.read(path))
  ids = stg.flat_map do |r|
    model.where(cols.index_with { |c| r[c] }).where.not(id: r["id"]).pluck(:id)
  end.uniq
  puts "#{model}: deleting #{ids.size}"
  model.where(id: ids).delete_all if ids.any?
end
```

---

## Step 4 — Real import on development

Clear dry-run, then import again:

```ruby
ENV.delete("DRY_RUN") # or unset; only "1" enables dry-run

ENV["TABLES"]                       = CATALOG_AND_FORM_TABLES
ENV["MIGRATION_BUCKET"]             = "carelever-migrations"
ENV["SNAPSHOT_PREFIX"]              = "reference/staging/<timestamp>"
ENV["GENERIC_USER_ID"]              = "<dev-user-uuid>"
ENV["GENERIC_NETSUITE_LOCATION_ID"] = "<dev-netsuite-location-uuid>"
load "script/db_reference/import.rb"
```

Referrals are untouched. Catalog + form rows from staging are upserted by id.

---

## Step 5 — Soft-deactivate development-only extras

Import does not remove rows that exist only on development. Hide extras from the active catalog:

```ruby
# Paths if using SNAPSHOT_DIR; otherwise download the three JSON files from S3 into /tmp
base = "/tmp/ref/reference/staging/<timestamp>"

keep_si = JSON.parse(File.read("#{base}/service_items.json")).map { |r| r["id"] }
keep_sv = JSON.parse(File.read("#{base}/service_variations.json")).map { |r| r["id"] }
keep_cv = JSON.parse(File.read("#{base}/component_variants.json")).map { |r| r["id"] }

extra_si = ServiceItem.where.not(id: keep_si)
extra_sv = ServiceVariation.where.not(id: keep_sv)
extra_cv = ComponentVariant.where.not(id: keep_cv)

puts "Extras: SI=#{extra_si.count} SV=#{extra_sv.count} CV=#{extra_cv.count}"
# spot-check: extra_si.limit(20).pluck(:id, :name, :active)

extra_si.update_all(active: false)
extra_sv.update_all(active: false)
extra_cv.update_all(active: false)



# additional for forms
keep_fe  = JSON.parse(File.read("#{base}/form_elements.json")).map { |r| r["id"] }
keep_fsd = JSON.parse(File.read("#{base}/form_section_definitions.json")).map { |r| r["id"] }
FormElement.where.not(id: keep_fe).update_all(active: false)
FormSectionDefinition.where.not(id: keep_fsd).update_all(active: false)

```

Effects:

- Extras drop out of `.active` pickers / Settings lists that filter active
- Rows remain so historical referral / service FKs do not break
- Reversible with `update_all(active: true)` if needed

Optional check that forms still link after import:

```ruby
ComponentFormSectionLink.joins(:service_item).where(service_items: { active: true }).count
ServiceItem.components.active.joins(:component_form_section_links).distinct.count
```

---

## Step 6 — Smoke checks

1. Settings → service item catalog shows staging-like assessments / variants / components.
2. Open a component → Form Sections match staging (via `component_form_section_links`).
3. Spot-check a few known referrals still open and resolve their service items.
4. Confirm soft-deactivated extras do not appear in active pickers.

---

## Troubleshooting

| Symptom                                          | Fix                                                                                                  |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| Preflight missing `users` / `netsuite_locations` | Set `GENERIC_USER_ID` / `GENERIC_NETSUITE_LOCATION_ID` to real development ids                       |
| Import aborts mid-way                            | Do not set `SKIP_PREFLIGHT=1` unless you understand the missing FKs; fix remaps first                |
| Component Settings forms empty / wrong           | Ensure form tables **and** `component_form_section_links` were in `TABLES` on both export and import |
| Extras still visible                             | Soft-deactivate Step 5 was skipped, or UI is showing inactive rows                                   |
| Want medical matrix / FMI too                    | Re-run without narrowing `TABLES`, or extend `TABLES` to include those manifest groups               |

---

## Related

- Full reference manifest (all 40 tables): `carelever_assessment/script/db_reference/manifest.rb`
- Operator README: `carelever_assessment/script/db_reference/README.md`
- Prefixed-user / netsuite audit helper: `carelever_assessment/script/db_reference/audit_prefixed_refs.rb`
