# BugBot Review Guidelines — carelever_assessment

This file is a **triage map**: each item names a pattern to look for in a diff and
points to the source file where the rule lives. **Read the referenced file before
flagging** — it is the source of truth, and this file is intentionally thin to avoid
drift.

Update this file only when adding a *new category* of thing to flag, not when the
underlying rules change.

## Authoritative References

- [`AGENTS.md`](../AGENTS.md) — definition of done, safety rules, prohibited patterns.
- [`BUILD_RULES.md`](../BUILD_RULES.md) — performance-safe patterns.
- [`TESTING_STANDARDS.md`](../TESTING_STANDARDS.md) — test coverage and RSpec style.
- [`DOMAIN_GLOSSARY.md`](../DOMAIN_GLOSSARY.md) — approved business terms.
- [`docs/RUBY_ARCHITECTURE.md`](../docs/RUBY_ARCHITECTURE.md) — controllers / commands / serializers / policies layering and portal namespaces.
- [`docs/RUBY_STYLE.md`](../docs/RUBY_STYLE.md) — human-readable summary of `.rubocop.yml`.
- [`CLAUDE.md`](../CLAUDE.md) — repo overview and command reference.

---

## Definition of Done

Block the PR if any of these are true — see `AGENTS.md` §1 and `TESTING_STANDARDS.md` §4 for the full list:

- Missing tests for non-trivial logic.
- Existing tests not updated after a behaviour change.
- Bug fix without a regression test.
- Authorization or tenant scoping bypassed or unverified.
- Queries violate `BUILD_RULES.md`.

---

## Performance

Flag and cite `BUILD_RULES.md`:

- List/index endpoints without pagination — `BUILD_RULES.md` §1.
- `.select` / `.sort` / `.reject` / `.group_by` on ActiveRecord collections in controllers or views — `BUILD_RULES.md` §2.
- Heavy work in the request cycle (CSVs, PDFs, dashboard metrics over many records) instead of Sidekiq — `BUILD_RULES.md` §3, §4.
- New foreign keys or filterable columns without indexes — `BUILD_RULES.md` §5.1, §5.2.
- N+1 queries / missing `.includes` near serializer or view loops — `BUILD_RULES.md` §5.3.
- Business logic in controllers instead of commands — `BUILD_RULES.md` §6.
- New admin/list pages — verify `BUILD_RULES.md` §7 checklist (paginated, SQL filter, SQL sort, indexes, works at 100k records).

---

## Prohibited Patterns

Block — see `AGENTS.md` §5:

- `Rails.cache.*` usage of any kind.

---

## Configuration & Environment

Flag — see `AGENTS.md` §4:

- New `ENV[...]` / `ENV.fetch(...)` reads or `Rails.application.credentials.*` lookups not wired into `.env.example`, `Dockerfile`, and `.circleci/config.yml`.
- Dynamic keys (e.g. `ENV["#{prefix}_API_KEY"]`) — ask the author to confirm parity manually in the PR body.

---

## Authorization & Tenant Scoping

Flag — see `AGENTS.md` §4:

- Controller actions without a Pundit policy check or `require_permission!(:name)` where neighbouring actions in the same namespace use one.
- Queries that bypass tenant scoping (`ParentAccount` → `Company` → `Site`).
- Missing `User#can?(:name)` checks for granular permissions.

When in doubt, compare against neighbouring controllers/commands in the same `v1/<portal>/` namespace.

---

## Architecture & Naming

See `docs/RUBY_ARCHITECTURE.md` for the canonical layering.

Flag:

- Business logic in controllers instead of commands (`app/commands/v1/<portal>/`).
- Files placed outside the versioned, portal-namespaced layout.
- Plural/singular mismatches between route shape and controller/command/serializer paths:
  - `resources :foo` → plural controller, command, serializer namespaces.
  - `resource :foo` → singular controller name; command and serializer namespaces stay plural.
- Plural model class names.

Do **not** flag `v1`, `internal`, or `settings` as namespace violations — they are structural.

---

## Testing

Flag — see `TESTING_STANDARDS.md`:

- Missing test coverage for items listed in `TESTING_STANDARDS.md` §2.
- RSpec style violations — `TESTING_STANDARDS.md` §5 (Shoulda, predicate matchers, `described_class`, `change` matcher, factory traits over post-create updates, no mocking of the code path under test, request specs not controller specs, command specs invoke `described_class.call` directly).

---

## Style

`.rubocop.yml` is authoritative. `docs/RUBY_STYLE.md` is the human-readable summary.

Defer formatting nits to RuboCop. Flag a style issue here only when the choice indicates a logical bug or genuine readability problem.

---

## Domain Terminology

Flag synonyms for approved terms — see `DOMAIN_GLOSSARY.md`. Code uses the **code term**; UI/API copy uses the **business term**. The runtime mapping lives in `app/helpers/terminology_helper.rb`.

---

## How To Comment

Cite the specific file and section in every flag (e.g., "`BUILD_RULES.md` §2.1"). The author should be able to verify against the source of truth without arguing with BugBot.
