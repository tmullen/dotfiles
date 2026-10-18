---
description: Cull the comments a PR adds that the code should have said itself. DHH/P16 — a comment is the exception, not the default. Deletes them, verifies nothing but comments moved, commits and pushes.
argument-hint: [PR number | nothing = current branch's PR] [--dry-run] [--no-push]
---

# /cull-comments

A PR under review should read as code, not as code plus narration. Most comments a diff adds are
the author (or an agent) explaining a line the line already explains — they were free to write and
cost every future reader. Cull them.

Judge **only the comment lines this PR adds or changes**. Pre-existing comments in touched files
stay: a cull that reformats untouched code buries the change the reviewer came to read.

Args: **$ARGUMENTS**. `--dry-run` reports and edits nothing (works from any checkout).
`--no-push` commits locally only.

## The test

**P16 — the code carries the *what*; a comment earns its place only for a *why* the code can't
hold.** Applied to one comment, that yields three outcomes, not two:

- **Cut** — it restates, narrates, decorates, or defers. Most comments land here.
- **Keep** — it carries a *why* no name or structure could: an upstream bug with a link, a
  regulatory invariant, a measured tradeoff, a citation for non-obvious math.
- **The code should say it** — the comment is load-bearing *because the code is unclear*. Report
  the rename or extraction that kills it, and **leave the comment in place**. Deleting it now would
  lose what the code doesn't yet carry, and renaming is not a cull (see Verify).

Cut on sight:

- Restates the next line — `# Find the deal` above `find_deal`.
- Narrates the diff or talks to the reviewer — `# NEW:`, `# Changed from the old approach`,
  `# Added to handle the nil case`. Git and the PR body own that.
- Keeps a record of the work — a step-by-step account of what was demonstrated, a recital of the
  scope it satisfies, an evidence trail. That's real information in the wrong file: it belongs in
  the doc that owns the record, where someone will look for it. A code file is not a logbook, and
  a header narrating the work goes stale the first time the code beneath it changes.
- Section banners — `# --- Validations ---`, `# === Private methods ===`. The keywords are there.
- Doc blocks that restate the signature — `@param name [String] the name`, `// returns a User`.
- Type comments the type already declares — `// string` above `name: string`.
- Step numbering of sequential code — `# 1. Load  # 2. Validate  # 3. Save`.
- `TODO`/`FIXME`/`XXX` with no owner and no issue link. It's a wish, not a task.
- Commented-out code. Git has it.
- An agent explaining its own work to you.

## Never a candidate

These look like comments and are actually code or contract. Removing one breaks a build, a lint
run, or a downstream tool:

- Magic and pragma comments — `# frozen_string_literal: true`, `# typed: strict`, `#!/…`,
  `// @ts-expect-error`, `/* eslint-env */`, encoding lines.
- Linter directives — `rubocop:disable/enable`, `eslint-disable`, `noqa`, `nolint`.
- Structured docs a tool consumes — YARD if the repo publishes docs, JSDoc feeding a generator,
  OpenAPI/schema annotations.
- License headers and `DO NOT EDIT` / generated-file markers.
- Anything under `vendor/`, `node_modules/`, `db/schema.rb`, vendored specs, or a generated path.
  Skip those files entirely.
- Prose files — `*.md`, `docs/`, `CHANGELOG`. Comments there *are* the content.
- Config files (`*.yml`, dotfiles, Dockerfile) lean **keep**: a config value has nowhere else to
  explain why it's that value.

And read the house rules before cutting. If a linter *requires* docs — rubocop
`Style/Documentation`, eslint `require-jsdoc`, ruff `D` rules — the repo has settled this and the
cull loses to CI. Check `.rubocop.yml`, eslint config, `pyproject.toml`, `CLAUDE.md` / `STYLE.md`.
In this repo P16 is already law; elsewhere, confirm before waging the campaign.

## Loop

1. **Resolve the PR.** No number → `gh pr view --json number,headRefName,baseRefName,author,isCrossRepository`
   for the current branch. Not the author's own PR? Say so and drop to `--dry-run` — culling
   someone else's branch isn't yours to push. For a real cull the working tree must already be on
   the head branch and clean; if it isn't, name the branch or worktree to run from and stop. Don't
   switch branches to get there.

2. **List the candidates.** Every added line with its true line number:

   ```bash
   BASE=$(gh pr view --json baseRefName -q .baseRefName)
   git diff -U0 --diff-filter=d "origin/$BASE"...HEAD | awk '
     /^\+\+\+ b\// { f = substr($0, 7); next }
     /^@@/         { match($0, /\+[0-9]+/); n = substr($0, RSTART+1, RLENGTH-1) + 0; next }
     /^\+/         { print f ":" n ":" substr($0, 2); n++ }'
   ```

   Filter to lines whose content opens a comment for that file's language (`#`, `//`, `/*`, ` *`,
   `--`, `<%#`). That grep produces **candidates, not verdicts** — a `#` inside a string looks
   identical, and a comment's justification lives in the code around it. Read the surrounding
   method before judging any of them.

3. **Group contiguous lines into one comment, then judge the comment.** A ten-line header arrives
   as ten candidates, and the sixth line of a paragraph says nothing on its own — verdict per
   *block*, cut or keep whole. Blocks are what you count in the report, too. Judge each against
   the three outcomes. When a comment sits above code you had to read twice to follow, that's the
   third outcome, not the first: a paragraph carrying real understanding is evidence the code
   should carry it, not licence to delete the only place it exists.

4. **Cut.** Delete the whole block and close the hole: no doubled blank lines, no blank line left leading
   a block. Where a comment is a block's only body, the language may need `pass` / `end` to stay
   valid — check. Idempotent by construction: a second run finds nothing.

5. **Verify — the commit must be comments-only.** This is what makes the cull safe to review at a
   glance and safe to trust. Every removed line is a comment or blank:

   ```bash
   git diff -U0 | grep '^-' | grep -v '^---'
   ```

   Read that list; anything that isn't a comment or blank is a mistake — restore it. Then run the
   repo's own checks on the touched files (`bin/ci`, `bin/rubocop`, the test file's suite,
   `tsc`/lint as applicable) — a stray `end` or a deleted pragma shows up there, not in the diff.

6. **Commit and push.** One commit, subject `Cull comments the code already says`, body listing
   nothing — the diff is the message. Push to the PR branch. Skip on `--dry-run`/`--no-push`.

## Report

Terse. Path:line, the comment, and the reason in a few words:

```
Culled 14 of 19 added comments

Cut
  deal.rb:112       # Find the deal              restates find_deal
  intake.rb:44      # TODO: handle partials      no owner, no issue
  program.tsx:31    // --- handlers ---          banner

Keep (3)
  spring_eq.rb:88   links upstream bug #4412 — the why isn't in the code
  escrow.rb:20      regulatory: 3-day rescission window

The code should say it (2)
  intake.rb:203     comment explains a 40-line method.
                    Extract `settle_escrow` and the comment dies. Left in place.

bin/ci green · committed 8a3f1c2 · pushed to worktree-fac-364
```

Nothing to cut is a clean result, not a failure — say `19 added comments, all earn their place`
and stop.

For a full taste pass — naming, shape, abstraction, organization — use `/fizzy-way review`. This command
only owns comments.
