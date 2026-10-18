---
title: What the core team refactors (Jorge and the rest)
use_when: [what would Jorge do, how does the 37signals team refactor, helper salad, should this be a PORO, concern or record, who owns X in Fizzy, cache invalidation by touch, race condition fix, row lock, state as a record, turbo stream template, where did this convention come from]
sources: 4,131 non-merge commits by nine non-DHH core developers (index: evidence/team-commits.txt); STYLE.md; sources.md
snapshot: 27d0d2e6b
---

# What the core team refactors

DHH's taste is in [[voice/dhh-refactors]]. This page is everyone else on the core
team, mostly **Jorge Manrubia** (1,821 commits, 2025-04 → 2026-09). He wrote most of the
domain model as it stands and the "Controller and model interactions" section of
`STYLE.md` (c87f8a87f). His published position is the backdrop: *"we don't default to
create services, actions, commands, or interactors to implement controller actions"*
([Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/)).

Each theme gives the rule, the test applied, one example (diff read), evidence SHAs
with subjects, and who. Open a SHA in `~/Work/Vendor/fizzy` only when the rule is not
enough. "Reusable" vs "Fizzy-specific" is called out where it matters.

## Who owns what

Ranked by commits; "areas" come from the directories each person's commits touch most.

| Who | Commits | Active | Areas (by files touched) |
|---|---|---|---|
| Jorge Manrubia | 1,821 | 2025-04 → 2026-09 | `app/models/card/*`, `app/models/command` (Fizzy Do, removed), filters, events/timeline views, columns, entropy, `User` model, the SaaS engine extraction, and the Stripe billing that was later removed |
| Mike Dalessio | 750 | 2024-12 → 2026-10 | `gems/fizzy-saas` → `saas/`, Gemfiles/deps, `db/migrate`, `script/migrations`, UUID type, search reindex, Lexxy/markdown rendering, CI hardening; created `CLAUDE.md` and `STYLE.md` (7ef7a8e49) |
| Stanko K.R. / Krtalić | 441 | 2025-07 → 2026-08 | `app/models/account/*` (export, import, deletion, join codes), passkeys (`lib/action_pack/web_authn`), auth/sign-in, mailers, AI (removed), account slugs |
| Kevin McConnell | 343 | 2024-06 → 2026-09 | early `Bubble` (now `Card`) model, `Notifier`, `Watch`, notifications views, deterministic UUID fixtures, single- vs multi-tenant config, Docker/infra |
| Jose Farias | 293 | 2024-10 → 2025-01 | `Filter` model, `filters_helper.rb`, bubble views, activity scoring |
| Jeremy Daer | 163 | 2024-10 → 2026-10 | security (CSP, SSRF, Trusted Types), storage ledger (`app/models/storage*`), `bin/setup`, CI, test fixtures/parallelism |
| Rosa Gutierrez | 128 | 2025-11 → 2026-10 | `app/models/notification/*` push targets, native push in `saas/`, import zip hardening, race fixes |
| Donal McBreen | 100 | 2025-11 → 2026-09 | `app/models/search*` (sharding, account key), UUID primary keys (`config/initializers/uuid_primary_keys.rb`), SSRF guard |
| Jeffrey Hardy | 92 | 2024-07 → 2026-03 | first-generation domain: `Account`, `Bucket`/`Project` access, `BubbleScoped`, boosts, sessions |

Nobody owns a whole layer. People own **features end to end**: model, controller,
views, and tests in one commit series. (inference, from the file spread above)

---

## Jorge Manrubia

### 1. Helper salad becomes an object

**Rule:** when a helper module grows `case` statements and passes the same 3–4 args
between functions, move the logic into a small Ruby object under the model namespace
(`Event::Description`, `User::DayTimeline::Column`, `Color`). Views call one method on
it. "Helper salad" is his term, used in two commit subjects.
**Test:** do several helpers take the same record plus context and branch on the same
field? Then that's a missing object, and it belongs in `app/models`, not `app/helpers`.
**Example:** c926d7ad6 deleted ~90 lines of `event_action_sentence_*` helpers. They
became `Event::Description.new(event, user)` with `#to_html` and `#to_plain_text`, so the
same sentence serves the timeline and the webhook. b1e087e7c replaced a `{ name:, value: }`
hash that was being passed around with `Color = Struct.new(:name, :value)` plus `to_s`.
Call sites changed from `card.color[:value]` to `card.color`. The commit body says
"Instead of managing a hash throgh the app".
**Reusable:** yes. It's the "not every model is backed by a database" move.
**Evidence:**
- c926d7ad6 Extract description object to remove the helper salad
- 590a63c42 Move helpers salad to a presenter column when rendering the timeline
- b1e087e7c Introduce a proper color poro to represent colors
- a9d935147 Extract object to represent a period to tidy up params repetition
- 744faf12c Extract "response cost" object to unify calculations around LLM usage costs
- 31a41e66c Make column have a proper ID instead of inferring it from the title

### 2. Concerns are adjectives; a generic concern plus host hooks

**Rule:** a concern names a trait of its host (`Entropic`, `Postponable`, `Golden`,
`Eventable`). When two models need the same trait, extract a top-level concern and
leave a thin host concern (`Card::Eventable`) that overrides small private hooks
(`should_track_event?`, `event_was_created`). The hook methods have defaults, so a
host needs only the overrides it cares about. Before adding a concern, remove one if
reflection can do the job.
**Test:** can you say "a card *is* entropic / postponable"? If two concerns differ
only by one method, either derive that method (reflection) or keep one concern and
give it a hook.
**Example:** b74698771 moved `has_many :events` and `track_event` into
`app/models/concerns/eventable.rb`. `Card::Eventable` now just says *when* to track
and what to do after. d5f035933 deleted `Card::Mentions` and `Message::Mentions` by
finding rich-text associations through `reflect_on_all_associations(:has_one)`. db86d1788
renamed `Account::Entropy` → `Account::Entropic` to get "two tracks of similar logic"
into one model.
**Reusable:** yes. See [[patterns/model-concerns]].
**Evidence:**
- b74698771 Make eventable a generic concern and create a card's especialization for it
- d5f035933 Extract mentionable content using reflection to remove duplicated logic and the need for additional concerns
- db86d1788 Refactor to introduce an entropy model
- 9b897191d Extract attachable concerns
- 4e2f56f4c Extract concern, add tests
- 18cc24e1d Add an event prefix named after the model now that events are generic
- 2a79cb413 Remove cacheable concern, inline cache helper

### 3. A state is a record, not a column

**Rule:** a toggleable state that has its own lifecycle (who/when, touch, destroy)
gets its own table with `has_one`. Scopes use `joins` / `where.missing`, and the verbs
`create_x!` / `x.destroy` are wrapped in domain words (`gild`/`ungild`,
`postpone`/`resume`). The controller is a singular resource (`Cards::GoldnessesController`).
**Test:** would you otherwise add a boolean plus a timestamp plus an enum value? Make
it a record.
**Example:** b63a6b3e9 deleted the 75-line `Card::Engageable` concern and its status
logic. It added `Card::NotNow` (`belongs_to :card, touch: true`) and a 30-line
`Card::Postponable`, where `scope :active, -> { where.missing(:not_now) }`.
**Reusable:** the shape is reusable. The names (`Goldness`, `NotNow`) are Fizzy product language.
See [[patterns/state-as-resource]].
**Evidence:**
- b63a6b3e9 Add postponable concern
- 7406a1039 Add models to track gold cards and implement basic toggle behavior
- 4f3f32252 Rename inconsistency: go with goldness
- 3e67da7d0 Add a new join model to link summaries with users
- 2061ab4ab Use dedicated sequence record instead of deal with issues with ids and uuids when using the previous approach

### 4. Invalidate caches by touching, not by computing keys

**Rule:** the etag/cache key is just the records (`fresh_when @page.records`). When a
parent's displayed attribute changes, the parent touches its children
(`after_save_commit -> { cards.touch_all }, if: -> { saved_change_to_name? }`).
Bespoke "invalidation parts" objects and per-controller etag helpers get deleted.
**Test:** is there code that lists what a cache depends on? Replace it with `touch:` /
`touch_all` on the dependency, so the key stays `[record]`.
**Example:** 2a79cb413 deleted `Card::Cacheable` and its
`InvalidationParts#for_perma` / `#for_preview`. 6cfc0978a deleted the
`cards_fresh_when` helper from `CollectionScoped`. Every column controller became plain
`fresh_when @page.records`, and `Column` now touches its cards.
**Reusable:** yes. See [[patterns/turbo-and-caching]].
**Evidence:**
- 2a79cb413 Remove cacheable concern, inline cache helper
- 6cfc0978a Columns touch the cards when the name/color changes
- ae4a07f84 Collections touch the cards when the name changes
- a9939ac47 Invalidate cards when columns are added/removed
- 176b8ad3b Move caching to collection rendering
- f0c5285fb Move column editing to stream so that we can remove the invalidation concern
- 8ebb3f2fa We need to remember on after_touch so that the mechanism triggers when touch-cascading records automatically via associations

### 5. Stream templates, smallest replacement, broadcast only on change

**Rule:** Turbo stream responses live in `*.turbo_stream.erb` templates, not inline in
controllers. Replace the smallest region that changed (the assignees or the reaction,
not the whole card), so editing context and in-flight UI survive. Broadcast only when
the rendered preview actually changes, and use the `_later` variant.
**Test:** does a controller build streams inline? Does a change re-render more than
it touched? Does a touch for bookkeeping trigger a broadcast?
**Example:** be246d204 swapped a full-card replace for an assignees stream "So that we
don't lose th editing context if you do it while editing a card". 2d96e7c9c moved
reactions to streams to stop flicker caused by a race.
**Evidence:**
- 1a4619919 Move actions to stream templates
- 68ef01114 Not needed anymore since we moved the streams to the templates
- be246d204 Replace assignees with a turbo stream instead of replacing the full card
- 2d96e7c9c Use streams to update/remove reactions
- c89db89f2 Only broadcast when the preview changes, use the _later variant for the broadcast, add tests
- c007176ed Don't broadcast card changes when touching activity spikes
- 19051aec3 Append dropped cards instead of relying on server-side rendering to refresh the columns

### 6. Keep transactions short; side effects after commit

**Rule:** secondary effects (watching, mentions, broadcasts) run in `after_*_commit`.
Don't hold a transaction across slow work (LLM calls), and delete transactions that
protect nothing. Add one where a multi-write must be atomic (undo).
**Test:** if this callback fails or is slow, should the main write roll back or wait?
If not, it belongs after commit.
**Example:** 53eba9bd0 is a one-word diff, `after_create` → `after_create_commit
:add_mentionee_as_watcher`. ba97ec05d dropped `ApplicationRecord.transaction` around
`Command::Composite#execute` because AI commands held it too long.
**Evidence:**
- 53eba9bd0 Favor after_create_commit to keep transactions fast
- ba97ec05d Remove transaction as the AI commands can hold the transaction for too long
- 4183a5a32 Remove unneeded transaction
- c29768e98 Add missing transaction
- 5e812b15b Make undo transactional too
This matches DHH theme 5 in [[voice/dhh-refactors]]. Callbacks are for *"secondary or
orthogonal concerns"*. The quote is from [Globals, callbacks and other sacrileges](https://dev.37signals.com/globals-callbacks-and-other-sacrileges/).

### 7. Don't create junk then clean it; re-read the source of truth

**Rule:** don't persist and then destroy speculative records. Validate first and save
on confirmation. Don't trust payloads that can arrive out of order; re-fetch the
authoritative state. Give things real identifiers instead of deriving them from
display text.
**Test:** is there a `destroy` that undoes a `create` in the same flow? Or a branch
on a human-readable title?
**Example:** 9c1185055 stopped appending every parsed command to `Current.user.commands`.
`command.save!` now happens only when confirmed. 5be4dca80 (Stripe webhooks, since
removed) refreshed the subscription instead of applying event payloads. The commit body
says "Events can land out of order".
**Evidence:**
- 9c1185055 Instead of removing uncofirmed commands don't create them in the first place
- 5be4dca80 Refresh the subscription instead of relying on event payloads
- 31a41e66c Make column have a proper ID instead of inferring it from the title
- 32c9cdbba Extract filter partials and rely on filter as the source of truth for the selected collections
- ee917f99d Override search params instead of accumulating them

### 8. Delete experiments wholesale

**Rule:** when a product experiment ends, delete all of it in one commit: models,
controllers, views, tests, cassettes. Don't leave flags or dormant code.
**Test:** is the feature off for everyone? Then it goes.
**Evidence:** these are the line counts that `git show --shortstat` reports.
- fa82dc038 Remove code related to Fizzy Do /command support and filtering (−129,080 lines; mostly VCR cassettes)
- 9317a8257 Remove Fizzy Ask (70 files, −4,693)
- 964915bc6 Remove payment/subscription system and card/storage limits (74 files, −2,221)
- 588f03e92 Remove insight experimental code
- 24f1394ca Remove workflows code, remove more unused code
- 6d05ab428 Remove engagements
**Fizzy-specific:** which features died. **Reusable:** the habit. 134 of his subjects start with "Remove".

### 9. Rename until the vocabulary is consistent

**Rule:** rename the moment a name drifts from its siblings or from what the method
does. Units go in names (`cost_in_microcents`), predicates say what they test
(`filters_by_association?`), and a param loses its redundant prefix. Renames are their
own commits. He has 62 "Rename" subjects.
**Test:** read it next to its siblings (`comments` vs `messages`, `collect` vs `create`).
Does it describe *what* or *how*?
**Evidence:**
- e629d41da Rename fans_out? to filters_by_association?
- 853a75a54 Rename "cost_microcents" => "cost_in_microcents"
- c3cd87358 Rename collect => create
- 696732a90 Rename mentions' container => source
- ccb72ad22 Rename for consistency with what we had for comments
- bec4abad0 Rename method to match semantics
- 973b4e4ae Rename param to remove redundant bit
See [[patterns/naming]], and *"With the importance of names to make code understandable,
how can anyone consider discussing those superfluous?"* ([Minding the small stuff](https://dev.37signals.com/minding-the-small-stuff-in-pr-reviews/)).

### 10. Expanded conditionals over guard clauses

**Rule:** prefer `if/else` that shows both branches over an early `return`. A guard
clause is acceptable only at the very top of a non-trivial method. This is codified in
`STYLE.md` § "Conditional returns", and Mike formalized it in RuboCop.
**Example:** 90e654e3e turned `return relation if fans_out?` + body into `if fans_out?
relation else relation.use_index(...) end`.
**Evidence:**
- 20b5e57dd Prefer if/else over early return
- 90e654e3e Use if/else instead of early return in filter_boards
- 5b2fa6b74 Remove nested if
- 3a30d7796 style: formalize preference for if/unless in rubocop (#2816) (Mike Dalessio)

### 11. Open-source core, SaaS as an engine

**Rule:** the app runs fully without the SaaS bits. SaaS-only config, deploy,
monitoring and billing hooks move into an engine/gem (now `saas/`), loaded through a
separate `Gemfile.saas`. Bundler groups don't work when outsiders can't fetch the
private gems. Shared flows such as signup stay in the app, and the engine only adds
hooks.
**Fizzy-specific:** the O'Saasy split. **Reusable:** for any app with a self-hosted edition.
**Evidence:**
- e1e9a0172 Make open source the default, and check for sass instead
- ad6f3a9ff Instead of a dedicated group, use a completely separate Gemfile for the saas version
- 3d849a202 Move signup code back to the app, leave only queenbee hooks
- 486d56d24 Move env-specific config bits to the saas gem
- db57a7ba0 Initial commit: Move fizzy-saas to separate repository

---

## The rest of the team

### 12. Serialize with a row lock, not a hopeful transaction

**Rule:** when two requests or jobs can race on one row (counters, redemptions,
notification upserts), lock the owning row (`with_lock`). Bare `transaction` doesn't
serialize. Write commit bodies with the production timeline that proved it.
**Example:** e9c30a010 (Rosa) changed `Card#assign_number` to
`account.with_lock { account.increment!(:cards_count).cards_count }`. Two creates that
both loaded `cards_count = N` collided on the unique index. c8a5d0177 (Stanko) swapped
`transaction` for `with_lock` in `Account::JoinCode#redeem_if`. 95114b1d6 (Rosa) used
`source_type_will_change!` because dirty tracking skipped an unchanged-but-stale column.
**Who:** Rosa, Stanko, Jeremy, Kevin.
**Evidence:**
- e9c30a010 Serialize card numbering with a per-account row lock
- c8a5d0177 Wrap join code redemption in a lock
- 95114b1d6 Fix race condition between concurrent Event and Mention notifier jobs
- ae3d27786 Fix race condition on notification creation
- ea8a78cc2 Fix stale-read race when creating push subscriptions
- bd259f779 Add optimistic pausing to avoid stale reads
- a253c31de Batch webhook delivery cleanup to prevent DB lock contention (#2555)

### 13. Append-only ledger over synchronous counters

**Rule:** for totals that many writers bump (storage bytes), record immutable entries
and materialize snapshots with a cursor in a job. Don't increment parent counters
inline, because bubble-up updates deadlock.
**Example:** 761d0b4a7 (Jeremy) added `Storage::Entry` (ledger), `Storage::Total`
(snapshot + `last_entry_id` cursor), and the concerns `Storage::Totaled` / `Storage::Tracked`
(`app/models/concerns/storage/`). It also added `MaterializeJob` and `ReconcileJob`.
Account and Board each consume the same stream independently.
**Who:** Jeremy Daer. **Evidence:**
- 761d0b4a7 Speedy, auditable, deadlock-resistant storage tracking (#2026)
- 5d181af39 Storage: ignore jobs for now-deleted targets
See [[components/storage]].

### 14. Template methods only when the hooks earn their keep

**Rule:** a base class with `should_x?` / `perform_x` hooks is fine when subclasses
really vary on both. When every subclass just wraps one check, collapse the hooks:
each subclass implements the one public method, and the shared check moves to the
caller. This is a counterweight to theme 2, where the hooks *do* vary
(`should_track_event?` differs per eventable).
**Example:** 05819f84a (Rosa) introduced `Notification::Push` with
`should_push?`/`perform_push`. The next day 7864748be removed the template methods.
`PushTarget::Web#process` now holds `if subscriptions.any?`, and `pushable?` is
checked once in `Notification::Pushable#push`.
**Who:** Rosa Gutierrez. **Evidence:**
- 05819f84a Refactor notification push system with registry pattern
- 7864748be Simplify PushTarget by removing template method pattern
- b5205ce6b Rename Push to PushTarget for better readability
- 3621df8f0 Consolidate push jobs into single Notification::PushJob
See [[components/notifications]].

### 15. Tenant scope is explicit at every lookup

**Rule:** every finder goes through the account (`account.users`, `Current.account`
scoping in controllers). Class-level conveniences that could cross tenants become
association extensions. Background and search code takes the account as an argument
instead of reading `Current`.
**Example:** d925b53b0 (Kevin) replaced `User.system` with
`has_many :users do def system ... end end`, so the call is always `account.users.system`.
**Who:** Kevin, Jeffrey, Donal, Mike, Rosa, Jorge.
**Evidence:**
- d925b53b0 Prevent calling `system` without scoping to account
- 6953701df Scope user finding by Current.account
- ab35c730d Scope `account.cards`
- b57130338 Don't use Current.account for search records
- 9a27ca8b4 Scope clear_search_records to the account being destroyed (#2847)
- b742963f7 Add account ownership check to import GID resolution
- 4a30663df Scope tags by account
See [[components/accounts-tenancy]].

### 16. Name the nouns early, rename the schema when they're wrong

**Rule:** domain nouns get renamed at the schema level (migration + fixtures + tests)
as soon as they're wrong. Don't keep an alias. Controller lookups shared across
resources become a `*Scoped` concern on day one.
**Who:** Jeffrey Hardy (2024 foundation), Jose Farias, Jorge.
**Evidence:**
- 683338fb0 Go with Account instead of Organization as the top-level tenant entity
- 5aae70298 Rename Splat to Bubble
- 4e579e5a3 Rename Project to Bucket
- 723e6d94f Rename bubbles => cards
- 044117f9c Extract Bucket::Assignable and rename Assignment#user to #assignee
- 7f45b8fe6 Extract BubbleScoped
- 5b83d0b5b Filter#persist! -> Filter#remember
**Reusable:** the habit. The names trace the product's history: Splat → Bubble → Card, and Project → Bucket → Collection → Board (the last rename was PR #1498).

### 17. Untrusted input is bounded and streamed

**Rule:** imports, webhooks and fetches never trust a declared size or address. Cap
bytes read per zip entry, stop on truncated streams, stream responses to check
size, block internal and NAT64 addresses, and turn malformed archives into a clean
failure, not a job crash.
**Who:** Rosa, Jeremy, Donal, Stanko.
**Evidence:**
- 744fedbfe Cap what an account import reads out of a zip entry
- 702778cc7 Stop reading an entry whose deflate stream is truncated
- 53cb27e2f Hold a streamed import entry to the size it declares
- 29c792630 Stream response in webhook request manually to check size
- 953942694 Handle MissingEOCD as invalid zip file, not job failure (#2572)
- db098dbb0 Block IPv6 addresses that reach internal IPs in the SSRF guard
- d3185b5e9 SSRF: take the address policy from surfguard instead of keeping our own copy (#3026)
See [[components/export-import]], [[components/webhooks]].

### 18. Deterministic tests

**Rule:** fixtures get deterministic UUIDs that sort before runtime records. Time is
fixed, parallel tests are seeded, and leaky global test state is removed. Fix the test,
not the app ("without changing app code").
**Who:** Kevin, Jeremy, Mike.
**Evidence:**
- 63f8a9af7 Deterministic fixture UUIDs
- 59dd8ca54 Make IDs more time-sortable in tests
- e9e68646e Fix this test without changing app code
- 85bd5c2df Rails seeded parallel tests (#2037)
- b23a5d0b7 Fix flaky tests caused by leaky show_exceptions twiddling (#2028)
- 6f1d20031 Use fixed date as well as time in test
See [[testing/fixtures]].

## Not worth capturing

- Stylesheet, JS-controller and VCR-cassette churn: 1,146 of Jorge's file touches are cassettes.
- "Remove trace" / "Fix test" commits.
- Dependency bumps.
- Lexxy editor plumbing.
