---
description: The fit-and-finish pass on a PR an agent run finished and you now own — cull comments, strip drifting ids, fix the defects it left, tighten the markdown, taste pass, bring the branch current, leave it merge-ready.
argument-hint: [PR number | nothing = current branch's PR] [--dry-run] [--no-push]
---

# /fit-finish

Make the diff read as though a person wrote it on purpose, and leave the PR merge-ready.

Args: **$ARGUMENTS**. `--dry-run` changes nothing. `--no-push` commits locally only.
Report plain and terse, no emoji. **The diff is the deliverable** — don't narrate it.

## Setup

1. `gh pr view [N] --json number,headRefName,baseRefName,author,isDraft,mergeStateStatus,url`
2. **`EnterWorktree`** — never branch-switch the shared checkout; other sessions use it and these
   branches gain commits from them. `./lola setup` if new; `FACTORY_DB_PREFIX` inline on every
   command (see the `lola` skill).
3. Read `.spear/<instance>/scope.md`, `plan.md`, `resolve.md` for what the PR is *for* and what it
   left open. **`.spear/**` is history — never edited.** A durable rule trapped in a `resolve.md`
   gets promoted into `agents/` or `specs/`; the run file stays as-is.

Stop if the tree is dirty or the PR is someone else's.

## 1 — Bring the branch current

```bash
git fetch origin && git merge origin/main
```

First, not last: everything below is judged against the code that ships, and `./lola validate` only
means something on the merged tree. Merge, never rebase — shared branch, and a rebase invalidates a
review in progress. Re-merge at the end if `main` moved.

## 2 — Cull the comments

Run `/cull-comments`, which owns the test, the never-a-candidate list, and the verification. Two
things it doesn't cover:

- **Every kept comment on one line.** If the *why* doesn't fit, restructure the code.
- **Strip every external id, code and prose** — `FAC-1234`, `Rock 3`, `plan 4.2`, `scope §6`,
  `Resolved decision 4`, `PR #823`, `[[copy]] Pat4`. Keep the durable why in plain words, drop the
  label ([[engineering]] Examples). Grep, don't trust the read:

  ```bash
  git diff origin/main...HEAD -- rails app agentic infra |
    grep -nE '^\+' | grep -inE 'FAC-[0-9]+|Rock [0-9]|plan [0-9]+\.[0-9]|scope §|SPEAR|Resolved decision|\[\[[a-z-]+\]\]'
  ```

`/cull-comments`' third outcome — *the code should say it* — is a **defect for §4, not a deferral**.

## 3 — Review the markdown

```bash
git diff --name-only origin/main...HEAD -- '*.md'
```

`agents/**` and `specs/**` load every session, so a loose line costs forever. Read the `prose-style`
and `writing-for-agents` skills first. Per change: **relevant to this PR** (revert the wandering
hunk, don't tighten it) · **in the right file** (one home per fact, cross-reference elsewhere) ·
**terse** (STE, 25-word cap, lending glossary) · **changes behavior** (a line nobody acts on is
sediment — delete it) · **no external ids**. Elsewhere (`README`, `docs/`): terseness and ids only.

## 4 — Taste, and fix what's wrong

Run `/dhh-review --fix`. It applies what has one defensible resolution and reports the rest.

**Then fix the defects — this pass owns them.** The method the comment had to explain, the nil case
the test asserted around, the name that lies. Fix with a test where one is owed, in its own commit
so the cull stays reviewable. Escalate only what needs a decision that isn't yours — a schema
change, a contract break, a design call — naming the options in the report.

## 5 — Prove it and hand over

```bash
./lola validate
```

It can print `❌ CI failed` and still exit 0 — grep the per-step markers, never the exit code. Green,
then commit and push: one commit per concern, imperative subjects (`Merge main`, `Cull comments the
code already says`, `Extract settle_gate`).

Report per line: merged main · comments culled/kept · ids stripped · markdown touched · defects
fixed · taste applied · checks and SHA · anything escalated with its options. Nothing to change is a
clean result — say so in two lines.

Then **stop**. `/ll:ship` merges, watches the deploy, and cleans up.
