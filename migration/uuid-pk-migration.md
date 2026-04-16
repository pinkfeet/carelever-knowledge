# UUID Primary Key Migration for Assessment

## Context

All Carelever microservices (screen, authentication, company, manage, form) use **UUID primary keys**. Assessment is the only project still using **bigint** PKs.

This creates ongoing costs:
- Every synced table needs a bridge column + unique index
- Two-step lookups on sync (find by UUID, then use bigint FK)
- Publishing requires bigint→UUID translation for all foreign keys
- Risk of ID type confusion for developers
- No direct cross-service joins for debugging/reporting

Assessment's database is **copied from the Replit monolith** — there is existing data with bigint IDs that must be preserved. The existing data is primarily for developers to verify relationships and test against. External UUIDs (e.g. matching microservice company/site records) do not need to be preserved — the initial data migration and sync will re-establish correct UUIDs from microservices later.

## Scope

| Category                  | Count | Severity |
| ------------------------- | ----- | -------- |
| Tables to migrate         | 181   | CRITICAL |
| Foreign keys to repoint   | 372   | CRITICAL |
| Model associations        | 696+  | HIGH     |
| Polymorphic associations  | 6     | HIGH     |
| Serializers exposing IDs  | 16+   | HIGH     |
| Production data to convert| None  | LOW      |

### Polymorphic associations (require special handling)

- `audit_log` — `belongs_to :record, polymorphic: true`
- `domain_event` — `belongs_to :record, polymorphic: true`
- `user_scope_assignment` — `belongs_to :scopeable, polymorphic: true`
- `contact` — `belongs_to :owner, polymorphic: true`
- `referral` — `belongs_to :cancelled_by, polymorphic: true`
- `reschedule_request` — `belongs_to :requested_by, polymorphic: true`

## Approach: 3-step Rails migration with data preservation

Since the database has existing data copied from the Replit monolith, we cannot simply swap column types. Instead, add new UUID columns alongside existing bigint columns, backfill FK references, then swap. All existing rows get fresh `gen_random_uuid()` values — no microservice UUID lookup needed at this stage.

### Distribution

The migration is distributed via git as standard Rails migration files. Other developers run `rails db:migrate` and their local DB is converted in place with all relationships preserved. No need to redistribute DB dumps.

### Migration 1 — Add UUID columns alongside existing bigint

Nothing breaks — old `id` bigint still works, new column sits alongside it.

```ruby
class AddUuidColumnsToAllTables < ActiveRecord::Migration[7.1]
  def up
    enable_extension "pgcrypto"

    # Add new UUID PK column to every table
    tables = ActiveRecord::Base.connection.tables - ["schema_migrations", "ar_internal_metadata"]
    tables.each do |table|
      add_column table, :uuid_pk, :uuid, default: "gen_random_uuid()"
    end
  end
end
```

### Migration 2 — Add UUID FK columns and backfill references

This is the big one — 372 FKs. Programmatic approach loops through all foreign key definitions:

```ruby
class AddUuidForeignKeys < ActiveRecord::Migration[7.1]
  def up
    foreign_keys = ActiveRecord::Base.connection.tables.flat_map do |table|
      ActiveRecord::Base.connection.foreign_keys(table)
    end

    foreign_keys.each do |fk|
      # Add new UUID FK column
      add_column fk.from_table, "#{fk.column}_uuid", :uuid

      # Backfill by joining on old bigint
      execute <<~SQL
        UPDATE #{fk.from_table}
        SET #{fk.column}_uuid = #{fk.to_table}.uuid_pk
        FROM #{fk.to_table}
        WHERE #{fk.from_table}.#{fk.column} = #{fk.to_table}.id
      SQL
    end
  end
end
```

**Note:** This only captures FKs declared at the DB level. Convention-based Rails FKs (e.g. `company_id` without an explicit `foreign_key` constraint) must also be found by scanning model `belongs_to` associations.

### Migration 3 — Swap columns and re-add constraints

This is the point of no return. Drops old bigint columns and promotes UUID columns.

```ruby
class SwapToUuidPrimaryKeys < ActiveRecord::Migration[7.1]
  def up
    tables = ActiveRecord::Base.connection.tables - ["schema_migrations", "ar_internal_metadata"]

    # Drop all existing FKs first
    tables.each do |table|
      ActiveRecord::Base.connection.foreign_keys(table).each do |fk|
        remove_foreign_key table, name: fk.name
      end
    end

    tables.each do |table|
      # Drop old bigint PK
      remove_column table, :id
      # Rename uuid_pk → id
      rename_column table, :uuid_pk, :id
      execute "ALTER TABLE #{table} ADD PRIMARY KEY (id);"
    end

    # Rename FK columns: company_id_uuid → company_id
    # Drop old bigint FK columns
    # Re-add foreign key constraints
    # Drop now-redundant bridge columns (sites.uuid, positions.uuid, suppliers.uuid)
  end
end
```

### Why 3 migrations instead of 1

| Step                    | Reversible?       | Verify before next step              |
| ----------------------- | ----------------- | ------------------------------------ |
| 1. Add UUID columns     | Yes, drop columns | Check columns exist, no NULLs        |
| 2. Add + backfill FKs   | Yes, drop columns | Check referential integrity          |
| 3. Swap + constrain     | Hard to reverse   | Run full test suite after            |

Steps 1–2 are safe — if anything goes wrong, drop the new columns and the original state is untouched. Step 3 is the commit point.

### Post-migration: Update ApplicationRecord

```ruby
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  self.implicit_order_column = "created_at"  # UUID PKs aren't sequential
end
```

### Post-migration: Remove bridge columns

These become redundant when `id` IS the UUID:

- `sites.uuid` → drop (use `sites.id`)
- `positions.uuid` → drop (use `positions.id`)
- `suppliers.uuid` → drop (use `suppliers.id`)

Update sync code (`DataSync::ModelFactory` receivers) to match on `id` directly instead of a separate `uuid` column.

### Post-migration: Update serializers and API

16+ serializers expose integer IDs in JSON responses. Update both assessment API and assessment_ui to expect UUID strings instead of integers.

## What does NOT need to change

- Association declarations (`belongs_to`, `has_many`) — Rails handles UUID FKs transparently
- Sync payloads from microservices — they already send UUIDs, which now match directly
- Publishing payloads to downstream services — no more bigint→UUID translation

## Risks to watch

| Risk                    | Detail                                                                 |
| ----------------------- | ---------------------------------------------------------------------- |
| Ordering                | UUIDs aren't sequential. Any code relying on `id` ordering breaks. Use `created_at`. |
| URL routes              | `/referrals/123` becomes `/referrals/a1b2c3d4-...` — longer but functional |
| Test factories          | Any hardcoded integer IDs in tests need updating                       |
| `find` / `find_by(id:)` | Parameters arrive as strings; Rails handles this but watch for `to_i` calls |

## Effort estimate

Estimated **4–6 hours** with AI-assisted development. Existing data is preserved for relationship testing; external UUID mapping is deferred to initial data migration + sync.

| Task                                | Time    | Notes                                                                              |
| ----------------------------------- | ------- | ---------------------------------------------------------------------------------- |
| Generate migration files (1–3)      | ~1h     | Auto-generate table dependency graph, FK map, and 3 migration files. Must also scan models for convention-based FKs not declared at DB level. |
| Fix models                          | ~30m    | `ApplicationRecord` change + drop bridge column references (`uuid` attrs)          |
| Update serializers & controllers    | ~1–2h   | 16+ serializers need review. Check for `to_i` calls and integer param assumptions. |
| Update tests & factories            | ~1–2h   | Depends on hardcoded integer IDs. Factory Bot can auto-generate UUIDs.             |
| Update assessment_ui (frontend)     | ~30m–1h | ID comparisons using `===` with integers, route params, etc.                       |
| Verify data integrity between steps | ~30m    | Check no NULL uuid_pk values, verify FK referential integrity before step 3.       |
| Smoke test & fix edge cases         | ~30m    | Run test suite, fix whatever breaks.                                               |

**Biggest variable:** how many places assume integer IDs (string comparisons, `to_i` calls, hardcoded IDs in tests).

## Impact on data sync strategy

If this migration is done **before** implementing data sync:

- Phase 1 (bridge columns) becomes unnecessary — no bridge columns needed
- Phase 2 (ModelFactory receivers) is simpler — incoming UUID maps to `id` directly
- Phase 4 (publishing) is simpler — outgoing FKs are already UUIDs

The data sync strategy document should be updated to reflect whichever path is chosen.