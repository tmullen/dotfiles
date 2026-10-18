---
title: What the 37signals team would do
use_when: [what would 37signals do, what would Jorge do, how does the Fizzy team review, is this the Rails way, should this be a PORO, concern or record, enum or record, where does this check belong, race condition, fail loudly, simpler design, review culture, how do they push back]
sources:
  - evidence/team-commit-themes.md (4,131 non-DHH commits, distilled)
  - evidence/pr-review-themes.md, evidence/pr-comments.jsonl (3,716 human PR comments)
  - STYLE.md, .rubocop.yml
  - sources.md (Code I like series, Minding the small stuff)
snapshot: 27d0d2e6b
---

# What the 37signals team would do

DHH's taste is in [[voice/dhh-refactors]]: inline anemic code, speak the domain, trust
the framework, cache over HTTP, short transactions, split controllers, plain beats
clever. **This page skips those** and covers what the rest of the core team adds. Most
of it is **Jorge Manrubia**, who wrote most of the current domain model, the "Code I
like" series, and STYLE.md's "Controller and model interactions" section (c87f8a87f).
Also Kevin McConnell, Mike Dalessio, Rosa Gutierrez, Jeremy Daer, and Stanko Krtalić.

His backdrop: *"we don't default to create services, actions, commands, or interactors
to implement controller actions"* and *"rich internal object models hidden behind
high-level APIs on domain models"* ([Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/)).
On review: *"computers don't execute big pictures, they execute lines of code, so how
you compose those matters too"* ([Minding the small stuff](https://dev.37signals.com/minding-the-small-stuff-in-pr-reviews/)).

Each theme gives the rule, the test, a short example, and evidence (SHAs in
`~/Work/Vendor/fizzy`, PR numbers on basecamp/fizzy). Attribution is inline. Open the
evidence files only when a rule isn't enough.

## 1. A param that keeps getting passed along means an object is missing

**Rule:** when several helpers or methods take the same record plus context, branch on
the same field, or pass the same hash around, there's a missing object. Make a small
PORO under the model's namespace in `app/models` (not `app/helpers`, not `app/services`)
and give the views one method to call.
**Test:** do 3+ functions share an argument list? Is a `{ name:, value: }` hash going
from place to place? *"The shared param is often a smell that something is missing."*
— Jorge, PR #929
**Example:** about 90 lines of `event_action_sentence_*` helpers became
`Event::Description.new(event, user)` with `#to_html` and `#to_plain_text`, so the
timeline and webhooks share one sentence (Jorge, c926d7ad6). A color hash became
`Color = Struct.new(:name, :value)` (b1e087e7c).
**Evidence:** c926d7ad6 "Extract description object to remove the helper salad",
590a63c42, b1e087e7c, a9d935147, and PR #929 (an `Ai::Quota` record replaced a `limit:` param)

## 2. Concerns hold auxiliary traits; everything else stays private

**Rule:** a concern is for a trait the host *has* (see [[patterns/model-concerns]]).
Internal mechanics stay in the class's `private` section, not in a concern. Public
methods exist only when someone calls them.
**Test:** would anyone outside call this? If not, make it private, and private code
doesn't need its own concern. *"We normally use concerns for auxiliary traits of a
class."* *"The narrower the public surface of a class the better, since it's easier to
grasp its responsibilities at a glance."* — Jorge, PR #929
**Example:** Stanko asked for the rule of thumb on extracting a concern (PR #929).
Jorge's answer: the quota's reset logic is internal, so it belongs in private methods on
the quota class, not in a separate concern. He also suggested `fetch_or_create_ai_quota`
be just `ai_quota`, so the public name doesn't leak how it works.
**Evidence:** PR #929; d5f035933 (reflection replaced two concerns); 2a79cb413

## 3. Hook methods only where the hosts really differ

**Rule:** when two models share a trait, extract one generic concern with default
private hooks, and let each host override only what differs. If every subclass would
override the hooks the same way, drop the template method and let each class implement
the one public method.
**Test:** list each host's hook bodies. If they differ, keep the hooks. If they're
identical, inline them.
**Example:** `Eventable` stays generic, and `Card::Eventable` overrides
`should_track_event?` → `published?` (Jorge, b74698771). On the other side, Rosa added
`should_push?`/`perform_push` hooks to push targets (05819f84a) and removed them the next
day because they didn't vary (7864748be). DHH asked Jorge to inline the per-event
notifier classes (PR #425). Jorge kept two of them, cards and comments, because that
"lets us remove an annoying `if` to fetch the card" (PR #431). That's a split along a
real difference.
**Evidence:** b74698771, 05819f84a, 7864748be "Simplify PushTarget by removing template method pattern"

## 4. A state is a record, and the record carries its vocabulary

**Rule:** a state with who/when/why becomes a `has_one` record, not a boolean or an
enum column. Even mutually exclusive states can stay as separate records when each one
has its own words and data. This is the team's most argued-over modelling choice.
**Test:** will this state need a timestamp, an actor, a kind, or an undo that restores
the prior state? Will one more status column crowd a hot table's indexes?
**Example:** Kevin proposed collapsing Pop/Engagement into a 3-value enum to rule out
impossible combinations (PR #346). Jorge pushed back: *"Having an additional join plays
better with keeping the indexes tighter in the table"*, and *"It's nice to have rich
vocabularies and logic about popping … and about engaging."* The trait isn't tied to
where it's displayed: *"A card can be golden, be moved back to "considering", or to
"completed", but the trait of "being golden" still makes sense to me"* (Jorge, PR #395). Later, b63a6b3e9 replaced
the 75-line `Card::Engageable` with `Card::NotNow` + `Postponable`.
**Evidence:** PR #346, b63a6b3e9 "Add postponable concern", 7406a1039; see [[patterns/state-as-resource]]

## 5. The model guards security boundaries; the UI guards niceties

**Rule:** queries start from the user's accessible scope (`Current.user.accessible_cards`).
A rule that prevents a data leak may live in the model, even when today's callers are
already safe. A rule that only keeps the UI tidy stays in the UI.
**Test:** if a future caller forgot this check, would someone see data they shouldn't?
If yes, enforce it in the model. If it only produces an odd-looking state, don't.
**Example:** *"If we place this responsibilty in the caller, someone adding
auto-watching in the future may forget"* (Jorge, PR #425). DHH, on the same PR, called
a guard like that "defensive design … YAGNI". *"I don't want to lose the
`.accessible_cards` as the starting point. A future bug where we expose cards you don't
have access to is scary."* (Jorge, PR #2971). Declining a closed-card guard: *"I see
this like an UI enhancement, more than a delicate backend operation to protect against."*
(Jorge, PR #1833). Authorization checks belong in `ensure_*` before_actions (Jeremy, PR #1841).
**This differs from DHH:** his YAGNI stops at the security boundary.
**Evidence:** PR #425, #2971, #1833, #1841

## 6. Caches follow the data: touch, don't compute keys

**Rule:** a cache key or etag is the records themselves (`fresh_when @page.records`).
When a parent's displayed attribute changes, the parent touches its dependents. Code
that lists cache dependencies gets deleted.
**Test:** is there an "invalidation parts" object, a helper that builds keys, or a page
that depends on several base caches? Replace it with `touch:` / `touch_all`.
**Example:** 2a79cb413 deleted `Card::Cacheable` and its `InvalidationParts`. 6cfc0978a
made `Column` touch its cards on rename, so controllers just call `fresh_when`. *"I
changed it to use explicit touching of the cards when the different models change. Now,
both card permas and previews can rely simply on the card model for caching purposes."*
(Jorge, PR #1429). Kevin keeps `Current` out of cacheable partials by passing `user:` as
a local (PR #346). Jorge's default is the reverse unless caching is at stake: *"I've
checked in HEY and BC4 and we access to current from nested partials often."*
**Evidence:** 2a79cb413 "Remove cacheable concern, inline cache helper", 6cfc0978a, ae4a07f84, f0c5285fb

## 7. Side effects after commit; races get a row lock

**Rule:** secondary effects (watching, broadcasts, notifications) run in
`after_*_commit`, and slow or external work never runs inside a transaction (this
extends DHH theme 5). When two writers race on one row, lock the owning row with
`with_lock`, because a bare `transaction` doesn't serialize them. When many writers bump
one total, append immutable entries and materialize the total in a job.
**Test:** if this callback is slow or fails, should the main write wait or roll back?
Can two requests both read `N` and write `N+1`?
**Example:** `self.number ||= account.with_lock { account.increment!(:cards_count).cards_count }`
(Rosa, e9c30a010). The commit body explains the race and cites ~97 production errors.
Join-code redemption moved from `transaction` to `with_lock` (Stanko, c8a5d0177). Storage
bytes moved to a `Storage::Entry` ledger with a cursor-based `Storage::Total` after
counters deadlocked (Jeremy, 761d0b4a7).
**Evidence:** 53eba9bd0 "Favor after_create_commit to keep transactions fast", ba97ec05d,
e9c30a010, c8a5d0177, 761d0b4a7, 95114b1d6

## 8. The tenant is explicit at every lookup

**Rule:** finders go through the account. A class-level convenience that could cross
tenants becomes an association extension. Jobs and search code take the account as an
argument and don't read `Current`.
**Test:** can this be called without an account in hand? Then it can leak.
**Example:** `User.system` became `has_many :users do def system … end end`, so the only
call is `account.users.system` (Kevin, d925b53b0). Search records stopped reading
`Current.account`: *"we are better off if the records always know to go to the right
shard"* (Donal, b57130338).
**Evidence:** d925b53b0, 6953701df, b57130338, 9a27ca8b4, b742963f7; see [[components/accounts-tenancy]]

## 9. Try the simpler design first, then see how it feels

**Rule:** start with server-rendered links and plain forms, and add JS or state only
when the simple version feels wrong in use. Pipelines, registries and extension points
wait until a second case shows up.
**Test:** could this be a link with different query params? Is the abstraction for a
case you actually have?
**Example:** for removable filter chips, Kevin asked *"So could the chips simply be
links?"*, then: *"In general, I find it usually works out well to go with the simpler
design and just see how the UX feels. The fewer moving parts the better (usually)"*
(PR #136). Jorge on a filter pipeline like Basecamp's: *"I think we can keep this simple
for now."* (PR #564). Kevin on multi-tenant plumbing: *"Having non-tenanted models and
non-tenanted states at all is YAGNI at this point."* (PR #159).
**Evidence:** PR #136, #564, #159

## 10. Don't make junk to clean up; delete dead experiments whole

**Rule:** don't persist speculative records and destroy them later; save on
confirmation. Re-read the source of truth instead of trusting payloads that can arrive
out of order. When an experiment ends, remove all of it (models, views, tests, cassettes)
in one commit, with no flags and no dormant code.
**Test:** is there a `destroy` that undoes a `create` in the same flow? Is the feature off
for everyone?
**Example:** unconfirmed commands stopped being saved (Jorge, 9c1185055). Fizzy Do left
in one commit (fa82dc038, about −129k lines, mostly cassettes). Billing went out in
964915bc6. 134 of Jorge's commit subjects start with "Remove".
**Reusable:** the habit. **Fizzy-specific:** which features died.
**Evidence:** 9c1185055, 5be4dca80, fa82dc038, 9317a8257, 964915bc6

## 11. Fail loudly; never swallow

**Rule:** errors raise and jobs retry with backoff. A misconfigured app crashes at boot.
Don't make correctness depend on a side effect such as a beacon or a page load.
**Test:** if this fails at 3am, will anyone find out? Is the error caught only to be logged?
**Example:** Jeremy on a rescued Stripe call: *"Shouldn't be masked and swallowed."*
(PR #2432). Rosa: *"if we never fail the job, these will be lost in the logs"* (PR #3153).
Stanko, closing a PR: *"The app should crash if it's misconfigured"* (PR #2755). Mike on
a verification beacon: *"it makes me nervous that we would be relying on a side effect
of a page load to verify the user"* (PR #1968).
**Evidence:** PR #2432, #3153, #2755, #1968

## 12. Untrusted input is bounded and streamed

**Rule:** imports, webhooks and fetches never trust a declared size or address. Cap
the bytes read, stop on truncated streams, block internal addresses, and turn malformed
input into a clean failure rather than a crashed job. Archives stream; they are never
buffered (AGENTS.md).
**Example:** 744fedbfe caps reads per zip entry. 29c792630 streams webhook responses to
check their size. db098dbb0 blocks IPv6 addresses that map to internal IPs.
**Who:** Rosa, Jeremy, Donal, Stanko. **Evidence:** 744fedbfe, 702778cc7, 29c792630, 953942694, db098dbb0;
see [[components/export-import]], [[components/webhooks]]

## 13. Tests carry signal, and fixtures are deterministic

**Rule:** don't test the framework. Don't bend app code to make testing easier. Fix flaky
ordering in fixtures, not in production indexes. Fixture UUIDs are deterministic and
sort before any runtime record.
**Test:** would this test fail if *our* code broke, or only if Rails broke? Is this
regression test worth "forever-scar-tissue"? (Jeremy, PR #2979)
**Example:** *"most of these are just testing regular Rails behavior. We aim for higher
signal tests in general."* (Jorge, PR #2313). Kevin made fixture UUIDs deterministic
(63f8a9af7). "Fix this test without changing app code" (e9e68646e).
**Evidence:** 63f8a9af7, 59dd8ca54, e9e68646e, 85bd5c2df; see [[testing/fixtures]]

## 14. House style is written down, then enforced

**Rule:** use expanded `if/else` over guard clauses, except for a guard at the very top of
a non-trivial method. Order methods by when they're called. Indent under `private`. Use `!` only
when a non-bang counterpart exists. Model endpoints as CRUD on resources. All of this is in
`STYLE.md`, and reviewers link to it instead of re-arguing.
**Test:** does it follow STYLE.md? If a rule keeps coming up in review, write it into
STYLE.md or RuboCop.
**Example:** *"This is pure in-house convention: we prefer not to use early return guards
unless for scenarios where there is a decent amount of logic below them"* (Jorge, PR #508).
Mike created STYLE.md (7ef7a8e49) and later encoded the conditional rule in RuboCop
(3a30d7796). Jorge rewrote the controller section when it *"was emphasizing too much the
enter/review pattern we used in HEY"* (PR #1697, c87f8a87f).
**Evidence:** 7ef7a8e49, c87f8a87f, 20b5e57dd, 90e654e3e, 3a30d7796

## 15. Review culture: ask, answer with a commit, cite the sibling apps

How review works on Fizzy. This is about the process, not code rules.
- **Phrase pushback as a question.** Kevin usually asks "What do you think…", and
  Jorge's is "For your consideration". Disagreement is argued with tradeoffs (PR #346 has
  a full enum-vs-record thread) and settles on whichever version reads better in code.
- **Reply with code.** Authors answer review by linking the commit that addresses it
  ("Much clearer indeed: …", Jorge, PR #425), not by arguing in prose.
- **Precedent comes from HEY, Basecamp (BC3/BC4) and Writebook.** "that's what we do in BC4
  `Subscribable`" (Jorge, PR #425). Mike checked the forked `useragent` "used in HEY, BC3,
  and Writebook" (PR #1692).
- **Small things are fair game.** *"With the importance of names to make code understandable,
  how can anyone consider discussing those superfluous?"* ([Minding the small stuff](https://dev.37signals.com/minding-the-small-stuff-in-pr-reviews/))
- **Decline outside PRs in two sentences**, saying why: *"We don't use i18n in our products,
  as it adds a lot of ceremony to something as important as editing user-facing text."*
  (Jorge, PR #2181). New dependencies and toolchain additions are the usual reason.
- **Agent replies.** From 2026 on, many rows under maintainer accounts are agent-written
  ("🤖", "Fixed —"). Treat them as follow-through, not as anyone's voice.

## Who to channel for what

| Question | Voice | Why |
|---|---|---|
| Model shape, concerns, naming, Turbo | Jorge Manrubia | wrote most of `app/models/card/*` and the Code I like series |
| Simpler design, caching, tenancy safety | Kevin McConnell | Notifier, watches, fixtures, infra |
| Migrations, deps, tenanting, tests that fully specify | Mike Dalessio | `saas/`, UUID rollout, STYLE.md |
| Races, push, job correctness | Rosa Gutierrez | push targets, race fixes; Solid Queue guest on On Rails ([[sources]]) |
| Security, ledgers, API status codes | Jeremy Daer | CSP/SSRF, storage ledger |
| Export/import, passkeys, unbounded queries | Stanko Krtalić | `app/models/account/*` |

Sources: the ownership table in `evidence/team-commit-themes.md`, and the per-reviewer section in `evidence/pr-review-themes.md`.

## Not worth capturing

CSS and Stimulus churn, VCR cassette updates, dependency bumps, and "Fix test" commits.

## Related

[[voice/dhh-refactors]] · [[decisions/index]] · [[patterns/model-concerns]] ·
[[patterns/state-as-resource]] · [[patterns/turbo-and-caching]] · [[components/accounts-tenancy]] ·
[[testing/fixtures]] · [[sources]]
