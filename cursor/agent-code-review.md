# Cursor Agent Code Review

How to run code reviews in Cursor Agent, including the **Bugbot** subagent flow.

This is separate from **GitHub Bugbot** (the PR bot on GitHub). Same name, different product: this doc covers in-editor Agent reviews only.

---

## What happens when you ask for a review

Cursor Agent can review code in two ways:

| Mode | What runs | Best for |
| --- | --- | --- |
| **Bugbot subagent** | A dedicated readonly subagent reads the git diff and repo review rules, then returns structured findings | Pre-PR checks, rule-driven review against team standards |
| **Inline review** | The main Agent reads the diff and replies in chat | Quick, conversational feedback |

When Bugbot runs, the UI often shows something like **"Bugbot review..."** while the subagent works. Results come back as a compact table: **Severity**, **Location (file:line)**, **Finding**.

Generic prompts like *"review my changes"* may route to Bugbot automatically, especially in repos that define review rules (for example `.cursor/BUGBOT.md` or workspace rules).

---

## How to trigger a review

### Slash commands (most reliable)

| Command | Result |
| --- | --- |
| `/review-bugbot` | Run Bugbot on local changes |
| `/review` | Choose **Bugbot** or **Security Review** |
| `/review-security` | Security-focused subagent review |

### Natural language

Examples that reliably target Bugbot:

- `Run bugbot review on my branch changes`
- `Bugbot review my uncommitted changes`
- `Review PR #123 with bugbot` (or paste a GitHub PR URL)

To skip the subagent and get a lightweight chat review:

- `Review my changes inline — don't use bugbot`
- `Give me a quick conversational review of this diff`

---

## What gets reviewed (diff scope)

By default, Bugbot reviews **branch changes**: everything on your current branch since the merge-base with the repo's default base branch, **including** uncommitted (staged and unstaged) edits.

| Scope | How to ask |
| --- | --- |
| Branch changes (default) | `/review-bugbot` or `bugbot review my branch` |
| Uncommitted only | `review only my uncommitted changes` / `review my dirty working tree` |
| Specific base branch | `review against development` (see below for Carelever repos) |
| Specific PR or branch | Paste PR URL, or `review branch-name` — Agent should check out that branch first |

If there is no diff (empty branch, clean tree), Bugbot reports that there was nothing to review.

---

## Review types in Carelever workspaces

### Bugbot (general code review)

Reads each repo's **Bugbot triage map** when present:

- `carelever_assessment/.cursor/BUGBOT.md`
- `carelever_assessment_ui/.cursor/BUGBOT.md` (when added)
- Canonical copy in KB: [`cursor/BUGBOT.md`](./BUGBOT.md) (assessment rules; sync to repos as needed)

Bugbot flags patterns from **AGENTS.md**, **BUILD_RULES.md**, **TESTING_STANDARDS.md**, auth/scoping rules, and related docs referenced in `BUGBOT.md`.

### Security Review

Use `/review-security` or choose it from `/review`. Same diff mechanics as Bugbot, but focused on security (auth, tenant scoping, secrets, unsafe patterns).

### Port code reviewer (assessment porting only)

For feature-port work in `carelever_assessment`, ask explicitly:

- `Run port-code-reviewer on my branch changes`

This uses the port-review playbook (`.cursor/` port rules), not the generic Bugbot triage map. Use it when porting from Replit, not for everyday bugfix PRs.

### Inline review (main Agent)

No subagent. Useful for architecture questions, "does this approach make sense?", or a fast second opinion without the structured finding table.

---

## Carelever Assessment: review base branch

`carelever_assessment` integrates to **`development`**, not `main`.

Workspace rule **agent-review-scope** tells Agents to treat the authoritative change set as:

```bash
git diff origin/development...HEAD
```

When reviewing assessment backend work, say **`review against development`** if the default base inference is wrong.

Before reviewing, ensure refs are fresh:

```bash
git fetch origin development
```

Only findings on **lines in that diff** should be raised unless you explicitly ask for a full-file or repo-wide audit.

---

## Typical workflow

1. Finish or checkpoint your branch work.
2. Run `/review-bugbot` (or `/review` → Bugbot).
3. Read the findings table; fix issues or push back if a finding is a false positive.
4. Optionally run `/review-security` before opening a PR.
5. Open the PR; GitHub Bugbot (if enabled on the repo) may run a separate pass on the PR.

Bugbot in Agent does **not** auto-fix findings. Ask separately if you want issues addressed (`fix the bugbot findings`).

---

## Related docs

- [`cursor/BUGBOT.md`](./BUGBOT.md) — what Bugbot looks for in `carelever_assessment` diffs
- `carelever_assessment/.cursor/rules/agent-review-scope.mdc` — diff scope vs `origin/development`
- `carelever_assessment/AGENTS.md` — definition of done and safety rules
- Cursor skills (local): `~/.cursor/skills-cursor/review-bugbot/SKILL.md`, `review-security/SKILL.md`
