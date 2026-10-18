---
name: pr-review
description: Review someone else's factory PR for approval — brief Ted on what it introduces, review it for bugs, architecture, DDL, naming, and taste, check its SPEAR run, then leave a pending GitHub review of concise inline comments for Ted to edit and submit as Approve or Request changes. Use when asked to review a PR, approve a PR, gate a PR for deploy, or run /pr-review. Never pushes, fixes, merges, or submits the review.
argument-hint: "<PR number or URL> [dry-run]"
---

One PR, written by someone else. Ted decides; this skill gives him the context and a drafted review. It changes nothing on the branch. Skip a Dependabot PR and say why.

## 1. Brief

Read `~/.claude-work/skills/pr-brief/SKILL.md` and brief the PR exactly as it says, in this session. That brief is the executive summary: what changes for the user and why, then the shape of the solution. It never goes to GitHub.

## 2. Check out

Check the PR's head out read-only in `.claude/worktrees/pr-review-<n>` (`git worktree add --detach .claude/worktrees/pr-review-<n> <head sha>`). Every review below reads this checkout, never the main one.

## 3. Review, in parallel

Start every review that applies before reading any result.

| Review | When | How |
|---|---|---|
| Code | always | `/code-review high <n>`; `xhigh` when the PR is large or touches the schema, `/api/v1`, auth, or tenancy. Also Codex: `codex exec -s read-only`, asked what is wrong with the PR. |
| Shape and naming | always | `/fizzy-way review` on the changed Ruby and TypeScript, against `agents/function/engineering.md`. Names that reach a table, a column, a route, or an API field are design findings, not taste. |
| Architecture | the PR adds a model, table, concern, controller, route, job, adapter, module, or dependency, or crosses a product boundary | Name the brief and spec that own the area (`AGENTS.md` lists them) and check the PR against them: one home per fact, the RESTful Routing and Skinny Controllers patterns, tenancy, no role word in a name. Propose the strongest alternative design and say which is better. |
| Database | `db/migrate/` or `schema.rb` changed | Read every migration against the Database Migration process in `engineering.md`, P8, P20, and P23: `workspace_id` set at creation, a foreign key with an `on_delete` that matches the association, `NOT NULL` and indexes where the model assumes them, `algorithm: :concurrently`, jsonb only for unstructured data, a backfill that is safe at production size, and a reversible `down`. Propose the strongest alternative schema and say which is better. |
| SPEAR | `.spear/<slug>/` is on the branch | The run's report card: read `resolve.md`, `plan.md`, and `scope.md` off the head as `.claude/commands/spear-reconciler.md` does, and report open plan rows, BLOCKED items, or a stopped loop. Then scope fit, as the Scope axis of `.claude/commands/review-diff.md`: what the scope asked that the diff lacks, and what the diff adds that the scope never asked. |
| Security | the server side changes who can read or write what: auth, sessions or tokens, an authorization gate, query scoping, a token-scoped endpoint, file handling, or a new dependency | `/security-review` inside the checkout. |

**Done when** every review that applies has returned.

## 4. Verify and grade

Check every finding against the code before keeping it. Drop what is wrong, already covered, or settled by a repo rule, and keep the reason for the report.

Grade each kept finding:

- **blocking**: a bug, a race, an N+1, data loss, a DDL or tenancy defect, a design that fights a brief or spec, a name that reaches a table, column, route, or API field, an unfinished SPEAR run, or scope drift.
- **nit**: a simplification, a local name, or taste. A nit never blocks on its own.

The suggested verdict is **Request changes** when any finding is blocking, and **Approve** otherwise.

## 5. Report in the session

```
## <PR title> (#<n>): <Approve | Request changes>

<the brief from step 1>

### Findings
**Blocking**
- `<file:line>` <the ask, one line>
**Nits**
- `<file:line>` <the ask, one line>
<"None." when empty>

### Database        (omit when no schema change)
<the strongest alternative, and which is better, in one or two sentences>

### Architecture    (omit when not run)
<the strongest alternative, and which is better, in one or two sentences>

### SPEAR           (omit when no run)
<finished clean, or what was open; scope gaps and extras>

### Dismissed
- <finding>: <why, one line>
```

Explain anything Ted may want explained here, in the session. The GitHub comments carry none of it.

## 6. Draft the pending review

One pending review, Ted's to edit and submit. Every comment is the ask plus the one concrete change: one sentence, then at most one bullet or one ```` ```suggestion ```` block. No rationale, no doctrine citation, no precedent, no praise. Prefix a nit with `nit: `.

- A finding on a line in the diff is an inline comment on that line, on the `RIGHT` side.
- A finding outside the diff is one line in the review body, with its `file:line`. The body is empty otherwise.
- The suggested verdict stays in the session. The review carries no event, so GitHub holds it as pending.

GitHub allows one pending review per reviewer per PR. When one exists, it is an earlier draft from this skill: delete it, then create the new one.

```bash
gh api repos/{owner}/{repo}/pulls/<n>/reviews --jq '.[] | select(.state=="PENDING") | .id'
gh api -X DELETE repos/{owner}/{repo}/pulls/<n>/reviews/<id>
gh api -X POST repos/{owner}/{repo}/pulls/<n>/reviews --input <review.json>
```

`review.json` holds `commit_id` (the head sha), `body`, and `comments`, each `{path, line, side: "RIGHT", body}`.

**Done when** the pending review on GitHub holds one comment per kept finding, and its id is in the report.

## 7. Clean up

Remove the worktree: `git worktree remove .claude/worktrees/pr-review-<n>`.

Wait for every agent and background command you started. Finish with one line: the PR, the suggested verdict, and the count of blocking findings and nits, stated as done.

**dry-run:** write nothing to GitHub. Print the comments step 6 would post, with their `file:line`.
