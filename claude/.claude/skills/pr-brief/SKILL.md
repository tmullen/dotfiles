---
name: pr-brief
description: Brief the reader on one pull request before they review it — what changes for the user and why, then the shape of the solution, short enough to decide whether to dive into the diff. Use whenever someone asks what a PR does, for background or context on a PR, to summarize or explain a PR, what a Linear story is about, "catch me up on #1207", "why are we doing this one", or runs /pr-brief. Read-only, and it stays in the session afterward so the reader can ask follow-up questions against what it read.
---

# pr-brief — what is this PR, and do I need to read it?

Two screens at most. The reader has a PR they did not write — often the output of a SPEAR run or another agent — and one question: **is the intent right, and does the shape of the solution warrant my reading the diff?**

Then they ask follow-ups. So **read the source material into this session and answer from it.** Never delegate this to a subagent: a subagent returns a summary and discards the PR, the story, and the diff, and the next question costs a second full pass.

## What this is not

| Out of scope | Who owns it |
|---|---|
| Whether the code is any good | `/code-review`, `/review-diff`, `/dhh-review` |
| Deployment risk, who may ship it | `/pr-risk`, `/pr-triage` |
| Whether the agent run finished its own plan | `/spear-reconciler` |
| CI red, conflicts, base drift | the PR's own checks UI, `/ll:babysit` |

Naming one of those is a defect: it buries the two answers the reader came for under facts they can already see.

## Step 1 — Resolve the PR and its story

The argument is a PR number, a PR URL, a `FAC-NNN` issue id, or nothing (the current branch's PR).

```bash
gh pr view <n> --json number,title,body,url,headRefName,author,isDraft,state,additions,deletions,changedFiles,labels
gh api repos/{owner}/{repo}/pulls/<n>/files --paginate --jq '.[] | {filename, additions, deletions, status}'
```

Find the Linear issue from, in order: an issue id in the title, a `FAC-NNN` in the branch name, a Linear link in the body. Read it with the connected Linear MCP server's `get_issue` tool — find the tool with `ToolSearch` ("select:get_issue" or "linear issue"), since its full name varies by config. Read the issue's description and its project; read its comments only when the description leaves the *why* unanswered.

A SPEAR PR also carries its own scope. Look for it in the file list and read it off the head branch:

```bash
gh pr diff <n> --name-only | grep '^\.spear/'
gh api repos/{owner}/{repo}/contents/.spear/<slug>/scope.md?ref=<headRefName> -H 'Accept: application/vnd.github.raw'
```

`scope.md` beats the PR body for intent — the body is written by whatever wrote the code. A 404 means there is no scope, which is normal outside SPEAR and never worth reporting.

## Step 2 — Read enough of the diff to name the solution

Read **in full**, always: every file under `db/migrate/`, `db/schema.rb`, `config/routes.rb`, and any file the PR adds or deletes outright.

```bash
gh api repos/{owner}/{repo}/pulls/<n>/files --paginate \
  --jq '.[] | select(.filename|test("db/migrate|db/schema.rb|config/routes.rb")) | .patch'
```

Read **selectively**: the models and controllers, for their public surface and what moved — not their logic. Skim the rest from the file list and the counts. Tests and specs are a count, not a reading, unless a test is the only place a behavior is stated.

What you are looking for is the *shape*: a new table, a column that moved, a concern extracted, a class renamed, an endpoint added, a state added to a vocabulary, a job split out. Not the correctness of any of it.

## Step 3 — The output

Exactly this shape. Nothing before it, nothing after it.

```
**#1207 · FAC-843 · An unknown document type is refused, not a 500**

A member who picks a document type the workspace no longer carries now gets a
message naming the problem, instead of an error page. Nothing else changes.

**Why** — 14 of these a week in Sentry, all one member re-typing a document
after its type was retired. The 500 lost the upload.

**Solution**
- **API** — `documents#update` validates `document_type` against the workspace's own catalog and renders `validation_failed` with the field named.
- **Models** — no change; the type lookup already existed on `DocumentType`.
- **Frontend** — the type picker reads the error's `detail` and marks the field.
- **Tests** — 3 request tests, one per refusal path.

**Worth a look** — the refusal is a 422, not the 404 the tenancy rule asks for
when the type belongs to another workspace.
```

- **The header line** — `#<pr>` · the issue id · the title, rewritten to under twelve words if it is longer. No links; the reader has the PR open.
- **The opening paragraph** — two or three sentences, no heading. What a named person can now do that they could not, in the vocabulary of the product rather than the code. When the change is invisible to every user (a refactor, a convention test, an infra move), say so in one sentence and say who it is for instead — "no user-visible change; this is so the next partner adapter does not need a migration."
- **Why** — one or two sentences, from the Linear story or the scope. The *pressure* that produced the work: the error count, the customer, the thing that was impossible. Never "to improve maintainability", which is a sentence with no content.
- **Solution** — one bullet per layer that actually changed, in the order **Schema · Models · API · Frontend · Jobs · Config · Tests**, skipping every layer that did not. Name the artifact — the table, the column, the class, the endpoint, the state — in one clause. Lead the Schema bullet with the DDL verb (`adds`, `drops`, `renames`, `backfills`) because that is the bullet that decides whether the reader dives in. Six bullets is the cap; fold the small ones together rather than running to eight.
- **Worth a look** — nought to three sentences, only for something that genuinely changes whether the reader reads the diff: a mismatch between the story and the code, a decision the diff makes that the story never asked for, a convention this repo states and the code does not follow. **Omit the whole section when there is nothing** — an empty one trains the reader to skip it. This is not a review finding; it is a pointer.

Hard cap: the whole brief fits on two screens. If it does not, the Solution bullets are carrying detail that belongs in an answer to a follow-up.

## Rules

- **Read-only.** No comments, labels, reviews, pushes, or merges. Ever.
- **The story is the intent; the PR body is a claim.** When they disagree, report the story's intent and put the disagreement in *Worth a look* — that disagreement is usually the most decision-bearing thing on the page.
- **Never infer a user benefit the story does not support.** A PR whose only stated purpose is a refactor gets the invisible-change sentence, not an invented one.
- **Name facts, not sizes.** "adds `documents.archived_at`" earns its bullet; "significant model changes" does not.
- **Stay in the session.** After the brief, answer follow-ups from what you read. Re-read a file when the question reaches past it, rather than guessing from the summary you just wrote.
