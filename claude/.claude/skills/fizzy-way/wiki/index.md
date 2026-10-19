---
title: The Fizzy Way — index
snapshot: 55bb38335 (oldest page; basecamp/fizzy main, 2026-10-18)
---

# The Fizzy Way

This wiki covers how 37signals builds a Rails SaaS app: the structure, the names,
and the reasoning, distilled from Fizzy. It does not document the Fizzy product.

**Covers:** reusable SaaS components, code organization patterns, Minitest
practice, and what DHH and the team refactor and why. Sources are the code, the git
history, PRs, dev.37signals.com, DHH's writing, and podcasts.
**Doesn't cover:** UI/CSS design, deployment ops (see Fizzy's `docs/`), or the SaaS-only `saas/` engine beyond where it plugs in.
**Current as of:** the snapshot above. Pages cite paths, so check them against the Fizzy checkout (see SKILL.md).

Page shape: *Answer → Shape → Key code → Why (cited, or marked inference) → Testing → Reuse recipe → Related*.
Each page's `use_when` frontmatter lists more trigger phrases.

## Components — "has Fizzy built X?"

| Page | Use when |
|---|---|
| [[components/cards-boards-columns]] | the core domain model: slimming a big central model, lifecycle states, containers, ordering, drag and drop |
| [[components/accounts-tenancy]] | multi-tenancy, URL slug tenancy, `Current.account`, account_id everywhere, UUIDv7 |
| [[components/authentication]] | login, magic links, passkeys, sessions, API bearer tokens, Identity vs User |
| [[components/signup]] | signup, onboarding, invites and join codes |
| [[components/access]] | permissions, roles, per-record access, policy-object alternatives |
| [[components/events]] | activity feed, audit trail, "X did Y" sentences |
| [[components/notifications]] | inbox, tray, email digest, push, who gets notified |
| [[components/comments]] | comment threads, rich text, system comments |
| [[components/mentions]] | @mentions, scanning rich text, mention picker |
| [[components/reactions]] | emoji reactions, boosts |
| [[components/watching]] | subscribe/follow, watchers, involvement levels |
| [[components/assignments]] | assignees, assign to me, assignment limits |
| [[components/pins-tags-steps]] | pins, tags, checklists: small per-user or child traits |
| [[components/webhooks]] | outbound webhooks, signing, SSRF, retries |
| [[components/entropy]] | auto-postpone or archive stale work, recurring sweeps |
| [[components/search]] | full-text search, sharding, FTS5 |
| [[components/filters]] | saved filters, params→scopes |
| [[components/export-import]] | account export/import, streaming zips, S3 |
| [[components/storage]] | storage quotas, attachment accounting, Active Storage hardening |

## Patterns — "how do they structure X?"

| Page | Use when |
|---|---|
| [[patterns/model-concerns]] | organizing a big model, "where does this go", the pull toward service objects |
| [[patterns/naming]] | naming models, concerns, verbs, controllers, scopes |
| [[patterns/state-as-resource]] | toggles such as close/reopen, pin and mark-read as singular resources; boolean vs record |
| [[patterns/events-as-spine]] | where side effects go; one event driving the feed, notifications and webhooks |
| [[patterns/current-attributes]] | `Current.user`/`account`, defaults, Current in jobs and tests |
| [[patterns/controller-scoping]] | loading the parent record, scoping through `Current.user`, html+json+turbo responses |
| [[patterns/jobs-later-now]] | background jobs, `_later`, thin jobs, recurring jobs, deploy-safe renames |
| [[patterns/turbo-and-caching]] | turbo streams, morphing, broadcasts, `fresh_when`/etags |

## Testing

| Page | Use when |
|---|---|
| [[testing/fixtures]] | fixtures vs factories, deterministic UUIDs, scenario setup |
| [[testing/model-tests]] | testing concerns through real models, stubs only at system edges, time and jobs |
| [[testing/controller-and-system]] | controller tests with an account slug, sign-in helpers, system tests |

## Voice — "what would they do?"

| Page | Use when |
|---|---|
| [[voice/dhh-refactors]] | DHH-style review; "is this too abstract?" |
| [[voice/team]] | "what would 37signals do": the core team's themes (mostly Jorge Manrubia), attributed inline |
| [[decisions/index]] | "why don't they use X": tradeoffs and rejected alternatives |
| [[sources]] | blog posts, DHH writing and podcasts, with verified quotes |

## Planned — not yet written

The completeness critic flagged these. For now, grep the code or evidence for them.

- **components:** public-boards, prompts (editor pickers), identity-transfers (QR login, email change), account-lifecycle (cancel/incinerate), mailers, json-api, native-and-pwa clients, user-settings, admin
- **patterns:** system-user, rails-ext (framework patching via `on_load` + `prepend`), saas-engine-seam, framework-shaped libs in `lib/` (ActionPack::Passkey), pagination, recurring-jobs and Continuable, outbound-http/SSRF, rate-limiting, cache-safe personalization, stimulus conventions, house-style (STYLE.md), ci

## Evidence (grep, don't read)

`evidence/` holds the raw material the pages were distilled from. Pages cite it by
SHA or PR. Open it only when a page doesn't answer the question.

- `evidence/dhh-commits.txt`: 548 DHH commits (`sha date subject`)
- `evidence/team-commits.txt`: 4,131 core-team commits (`sha date author: subject`)
- `evidence/team-commit-themes.md`: themes from team commits, plus who owns which area
- `evidence/pr-comments.jsonl`: 3,716 human PR comments, one JSON object per line (`pr, author, path, created_at, url, body, kind`). About 578 are agent-written replies; see the filter in the themes file.
- `evidence/pr-review-themes.md`: 11 review themes with verbatim example comments
