---
title: Decisions and rejected alternatives
use_when: [why don't they use X, service objects vs models, fixtures vs factories, rspec vs minitest, validations vs db constraints, sqlite per tenant, mysql vs sqlite, uuid vs integer ids, sidekiq vs solid queue, redis, webpack vs importmap, no build, elasticsearch, boolean vs record, enum vs record, callbacks vs explicit, i18n, current attributes, data migrations, tradeoff, alternative rejected]
sources:
  - STYLE.md, AGENTS.md, Gemfile, config/importmap.rb, config/queue.yml, config/puma.rb, config/database.yml, config/search.rb
  - config/initializers/uuid_primary_keys.rb, app/models/account/data_transfer/record_set.rb
  - app/models/signup.rb, app/models/concerns/notifiable.rb, app/models/card.rb, app/models/storage/entry.rb
  - evidence/pr-review-themes.md, evidence/team-commit-themes.md, evidence/pr-comments.jsonl
  - commits 4d3c26504, 52ce8b50c, e4011ef21, 90538afb3, 3aa4a1a56, c834cce50, 761d0b4a7, ad6f3a9ff, 2a79cb413, b57130338
  - sources.md (Vanilla Rails is plenty, Globals/callbacks, A vanilla Rails stack is plenty, RECORDABLES)
snapshot: 27d0d2e6b
---

# Decisions and rejected alternatives

## Answer

Fizzy's architecture comes from a series of "boring default wins" decisions. Rich
models stand in for a service layer. The database enforces rules instead of validations.
Fixtures stand in for factories, the database for Redis, importmaps for a JS build, and
small records for boolean flags. The one decision that went against the team's own
experiment was **per-tenant SQLite**: it was built, then replaced by one shared MySQL
database just before launch ("Plan B"). Each entry below gives the decision, what was
rejected, why (cited), and where to see it. Entries are tagged **Reusable** (a default
for any Rails SaaS) or **Fizzy-specific** (a product or ops choice).

## Shape (at a glance)

| # | Chose | Rejected | Tag |
|---|---|---|---|
| 1 | Rich models + concerns, called from controllers | service / interactor layer | Reusable |
| 2 | Callbacks for side concerns, explicit verbs for primary flows | callback orchestration; or no callbacks at all | Reusable |
| 3 | State as a `has_one` record | boolean column / enum | Reusable |
| 4 | New resource per state change (`resource :closure`) | custom member actions | Reusable |
| 5 | DB constraints + bang methods | validations nobody displays | Reusable |
| 6 | Minitest + fixtures | RSpec + factories | Reusable |
| 7 | One shared MySQL DB (SQLite supported for self-host) | one SQLite DB per tenant + replication | Fizzy-specific |
| 8 | `account_id` on every row + URL slug | DB-per-tenant, subdomains | Reusable |
| 9 | UUIDv7 primary keys, base36 | auto-increment integers | Reusable (for portable data) |
| 10 | Solid Queue / Cache / Cable in the DB | Redis + Sidekiq/Resque | Reusable |
| 11 | importmap + Propshaft, no `package.json` | webpack/esbuild/node | Reusable |
| 12 | Full-text search in the DB | Elasticsearch / external search | Reusable at moderate scale |
| 13 | Compute on write, invalidate by `touch` | read-time queries, computed cache keys | Reusable |
| 14 | Append-only ledger for hot totals | synchronous counter columns | Reusable when contended |
| 15 | OSS app + SaaS engine with its own Gemfile | Bundler groups for private gems | Fizzy-specific |
| 16 | English strings in templates | i18n | 37signals house choice |
| 17 | `Current` in requests; explicit args in jobs and shards | threading `user:` everywhere; `Current` everywhere | Reusable |
| — | Data migrations: models vs SQL | — | **Open** |

## Key decisions

### 1. Rich domain models, no service layer
**Rejected:** `app/services`, interactors, command objects as the default.
**Why:**
- *"we don't default to create services, actions, commands, or interactors to implement
  controller actions."* ([Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/))
- STYLE.md § "Controller and model interactions": *"We don't use services or other
  artifacts to connect the two."* A PORO is still allowed *"When justified … but don't
  treat those as special artifacts"*. Jorge rewrote that section (c87f8a87f) because it
  over-emphasized HEY's pattern (PR #1697).
**Where:** `Cards::GoldnessesController#create` → `@card.gild`. `app/models/signup.rb` is
an ActiveModel PORO (`Signup.new(...).create_identity`) living in `app/models`, not
`app/services`. See [[patterns/model-concerns]].

### 2. Callbacks for side concerns; explicit verbs for the primary flow
**Rejected:** orchestrating multi-step flows through callback chains. Also the opposite,
banning callbacks and calling every side effect by hand.
**Why:**
- *"you don't want to orchestrate complex flows using callbacks."* and *"An auditing
  concern is orthogonal to creating projects."* ([Globals, callbacks and other sacrileges](https://dev.37signals.com/globals-callbacks-and-other-sacrileges/))
- *"Callbacks are a powerful technique for making that which isn't essential to a primary
  flow live on the side."* (DHH, [On Writing Software Well #2](https://www.youtube.com/watch?v=m1jOWu7woKM))
- They go after commit when no integrity is at stake: 53eba9bd0 "Favor after_create_commit
  to keep transactions fast".
**Where:** `Notifiable` → `after_create_commit :notify_recipients_later`. The primary verb
is explicit: `Card#close` wraps `create_closure!` + `track_event` in one transaction.

### 3. State is a record, not a boolean or enum
**Rejected:** `closed: boolean` + `closed_at`, or a `status` enum. Kevin proposed a
3-value enum in PR #346, and Jorge kept the records.
**Why:** *"Having an additional join plays better with keeping the indexes tighter in the
table"*, and separate records keep *"rich vocabularies and logic"* per state (Jorge, PR #346).
A record also carries who and when, and maps to a REST resource. b63a6b3e9 "Add
postponable concern" replaced the status-based `Card::Engageable`.
**Cost acknowledged:** exclusivity between states isn't enforced by the schema. Kevin's
concern was that a card could end up in two states (PR #346).
**Where:** `Closure`, `Card::Goldness`, `Card::NotNow`; scopes use `joins` / `where.missing`.
See [[patterns/state-as-resource]].

### 4. A new resource instead of a custom action
**Rejected:** `post :close`, `post :reopen` member routes.
**Why:** STYLE.md § "CRUD controllers": *"When an action doesn't map cleanly to a standard
CRUD verb, we introduce a new resource rather than adding custom actions."* DHH applied
the same rule in 43069b1ea (see [[voice/dhh-refactors]] §6).
**Where:** `resources :cards { resource :closure; resource :goldness; resource :pin; resource :watch }`.

### 5. Database constraints over validations
**Rejected:** presence and uniqueness validations that duplicate the schema.
**Why:** *"Generally speaking, we've almost entirely stopped using validations like
this."* (DHH, PR #1304), applied in c834cce50 "Simplify join code creation and validation
and test controller". Validations can't prevent the uniqueness race anyway. The index does,
and the code rescues the error where the race can actually happen (inference, per
[[voice/dhh-refactors]] §3).
**Where:** only 14 `validates` lines in all of `app/models`. They remain where a form shows
the error (`Signup`, `Identity#email_address`, `Webhook#name`). Everything else relies on
`create!`/`update!` and the schema.

### 6. Minitest + fixtures over RSpec + factories
**Rejected:** FactoryBot, per-test object graphs, mocking the database.
**Why:**
- *"Test your apps with Minitest. Use fixtures and build a realistic set of those as you
  cook your app."* ([A vanilla Rails stack is plenty](https://dev.37signals.com/a-vanilla-rails-stack-is-plenty/))
- *"I test active record models directly, letting them hit the database, and through the
  use of fixtures."* (DHH, [TDD is dead](https://dhh.dk/2014/tdd-is-dead-long-live-testing.html))
- Fixtures were made deterministic, so they survived the UUID switch: 63f8a9af7
  "Deterministic fixture UUIDs" (Kevin).
**Where:** `test/fixtures/` (33 entries), `fixtures :all` in `test/test_helper.rb`. Faker
appears only in `script/populate.rb`, for dev data, never in tests. See [[testing/fixtures]].

### 7. One shared MySQL database, not one SQLite file per customer
**Rejected:** the plan Fizzy was built on for most of 2025. Each account got its own SQLite
database through the `active_record-tenanted` gem (Mike), with SQLite replication ("Beamer")
to put data close to users.
**Why:**
- *"And we launched Fizzy with MySQL instead of with SQLite."* (Mike Dalessio,
  [RECORDABLES: Rails Multi-Tenancy](https://dev.37signals.com/rails-multi-tenancy/))
  The companion episode ([Behind the Fizzy Infrastructure](https://dev.37signals.com/fizzy-infrastructure/),
  Kevin McConnell) covers the decision, days before launch, to revert to a conventional setup.
- The switch was PR #1558 "Plan B" ("Fizzy on MySQL"): 4d3c26504 "Rip out
  activerecord-tenanting", 52ce8b50c "Switch to mysql", 6705b5225 "Remove the untenanted
  database", plus an import script for the existing SQLite tenants (65f97babd).
- Friction visible in review beforehand: untenanted contexts made "normal Rails idioms
  become brittle" (Mike, PR #168), and migrations couldn't use models under the tenanted
  setup (Jorge, PR #1088).
**Still true:** self-hosters can run SQLite as **one** database (`config/database.sqlite.yml`,
FTS5 search). So the SQLite support that remains is single-database, not per-tenant.
**Fizzy-specific:** the experiment and its reversal. **Reusable:** a single shared
database with row-level tenancy is the default; per-tenant files are an experiment.

### 8. Row-level tenancy via `account_id` + URL slug
**Rejected:** a database per tenant (see #7) and subdomains.
**Why:** after Plan B, every customer-data table got `account_id`: fe6df7085 "Finish the
rollout of account_id to all core data models". AGENTS.md describes the
`AccountSlug::Extractor` middleware, which moves `/{account_id}` into `SCRIPT_NAME`.
Jobs serialize `Current.account` themselves (142a342e5).
**Where:** `config/initializers/multi_tenant.rb`, `app/models/current.rb`. See
[[components/accounts-tenancy]].

### 9. UUIDv7 primary keys, base36-encoded
**Rejected:** auto-increment integers. Also exposing ids in URLs: cards are addressed by
their per-account `number` (f5305b2fe "Use Card `number` as the model param").
**Why:**
- Rolled out right after Plan B: e4011ef21 "Update primary keys on customer data to
  UUIDs", whose body includes "import script updated". Ids that are unique across
  databases let data from many SQLite tenants, and later account exports, load without
  remapping. Jeremy: with UUIDs first, *"the db import script is "just" a dumb
  dump-all/load-all"* (PR #1573).
- Account import preserves ids: `Account::DataTransfer::RecordSet#import_batch` calls
  `model.insert_all!` with each record's exported `id` and checks that the file name
  matches the id. (inference: integer keys would collide across instances)
- v7 is time-ordered, so `.first`/`.last` and id-ordered indexes still behave. Fixtures
  sort older than runtime records (59dd8ca54, AGENTS.md).
**Where:** `config/initializers/uuid_primary_keys.rb` (binary(16) on MySQL, an auto
default for every table: 13db38464), and 6c04b56f4 "Compact the UUIDs to base36".
**Cost acknowledged:** a numeric id lookup silently broke when ids stopped being card
numbers (Mike, PR #2665).

### 10. Solid Queue / Cache / Cable over Redis
**Rejected:** Redis, Sidekiq, Resque.
**Why:** Jorge's recommended Rails 8 stack drops Redis for the Solid trio, and *"Your
Gemfile should be almost identical to the one that Rails generates."* ([A vanilla Rails stack is plenty](https://dev.37signals.com/a-vanilla-rails-stack-is-plenty/))
90538afb3 "Add Solid Queue" (Kevin): "We'll run jobs via the Puma plugin for now, to
simplify the deployment." Background on why 37signals left Resque is in the On Rails
episode with Rosa Gutiérrez (see [[sources]]).
**Where:** `Gemfile` (`solid_queue`, `solid_cache`, `solid_cable`), `config/queue.yml`,
`plugin :solid_queue` in `config/puma.rb`, `config/recurring.yml`. Jobs stay shallow:
`_later` enqueues, `_now` does the work (STYLE.md). See [[patterns/jobs-later-now]].

### 11. No build step: importmap + Propshaft
**Rejected:** a node toolchain, bundlers, npm dependencies.
**Why:** *"one of the things people were shocked about how Vanilla it is actually. No
build and a lot of Vanilla Rails"* (Jason Fried, [REWORK](https://37signals.com/podcast/open-source-outside-the-box/)).
DHH declined an outside PR that grew the toolchain: *"don't like the idea of proliferating
on the tool chain here"* (PR #1814).
**Where:** `config/importmap.rb` pins Turbo, Stimulus and Lexxy, plus `pin_all_from
app/javascript/controllers`. There's no `package.json`. CSS is plain files.

### 12. Search in the database, not a search service
**Rejected:** Elasticsearch or another external engine. Also a `SearchIndex` AR model.
**Why:** e8abc66eb "MySQL search" (Donal): queries are raw SQL *"because we'll likely want
to shard the table"*. 3aa4a1a56 "Shard the search index into 16 tables": *"MySQL has no
ability to pre-filter fulltext indexes by another field so this is the best bet for
improving performance."* On SQLite it's a single FTS5 index (AGENTS.md).
**Where:** `config/search.rb`, `has_search` in models, and `ActiveSearch::StoreAdapters::MysqlSharded`.
See [[components/search]].
**Fizzy-specific:** the 16-way CRC32 shard. **Reusable:** keep search in the primary DB
until it hurts.

### 13. Compute on write; invalidate caches by touching
**Rejected:** complex read-time queries and in-memory sorts. Also cache-key builder objects.
**Why:** *"All this manipulation has to happen when you save, not when you present … Otherwise
you won't be able to paginate."* (DHH, PR #108). 2a79cb413 "Remove cacheable concern,
inline cache helper" deleted `Card::Cacheable`'s `InvalidationParts`. Parents `touch_all`
their dependents instead (6cfc0978a).
**Where:** `belongs_to :card, touch: true` on state records, and `fresh_when @page.records`.
See [[patterns/turbo-and-caching]].

### 14. Append-only ledger over counter columns for hot totals
**Rejected:** incrementing `bytes_used` on account and board inline.
**Why:** 761d0b4a7 "Speedy, auditable, deadlock-resistant storage tracking (#2026)"
(Jeremy). Bubble-up counter updates deadlocked, so immutable `Storage::Entry` rows are
materialized into `Storage::Total` by a job, using a cursor.
**Where:** `app/models/storage/`, `app/models/concerns/storage/`. For a single contended
counter (card numbers), a row lock is enough: `account.with_lock { … }` (e9c30a010).
See [[components/storage]].

### 15. Open-source app, SaaS as an engine with its own Gemfile
**Rejected:** Bundler groups for the private SaaS gems.
**Why:** ad6f3a9ff "Instead of a dedicated group, use a completely separate Gemfile for
the saas version": "The group-based approach won't work if you don't have access to the
gems!" Open source became the default in e1e9a0172. Shared flows stay in the app, and the
engine only adds hooks (3d849a202).
**Where:** `saas/`, `Gemfile.saas`, `tmp/saas.txt`, and `Fizzy.saas?` in `config/database.yml`.
**Fizzy-specific** (O'Saasy licensing), reusable for any app with a self-hosted edition.

### 16. No i18n
**Rejected:** locale files for UI copy.
**Why:** *"We don't use i18n in our products, as it adds a lot of ceremony to something as
important as editing user-facing text."* (Jorge, PR #2181)
**Where:** English strings directly in ERB. **House choice:** right for a single-language
product, wrong if you ship translations.

### 17. `Current` for request context; explicit arguments where context is ambiguous
**Rejected:** passing `user:` through every layer. Also relying on `Current` in jobs and
sharded storage.
**Why:** *"the combination of callbacks with CurrentAttributes achieves something powerful:
you can create a project normally, and the operation gets seamlessly audited."* ([Globals,
callbacks and other sacrileges](https://dev.37signals.com/globals-callbacks-and-other-sacrileges/))
Defaults look like `belongs_to :account, default: -> { card.account }` and
`creator: Current.user`. Search records are the exception, because *"we are better off if the
records always know to go to the right shard"* (b57130338). Kevin's partials take `user:`
when they need to be cacheable (PR #346).
**Where:** `app/models/current.rb`, and `track_event(action, creator: Current.user, …)`.
See [[patterns/current-attributes]].

### Open: data migrations with models or with SQL
DHH: *"Interacting directly with models present at the time of the migration is totally
fine."* (PR #425). Kevin, once self-hosting existed: *"in a self-hosted environment it's
harder to know how far behind an installation could be… I think we could write the migration
in SQL."* (PR #2512). Nothing settles it. Rule of thumb (inference): use models for a
SaaS-only app, and SQL or inline model classes when other people deploy your app.

## Testing

Each decision has a testing consequence:
- Constraints over validations means tests assert the raise, not `errors[:x]`:
  `assert_raises ActiveRecord::RecordNotUnique` (`test/models/storage/total_test.rb`),
  `RecordInvalid` (`test/models/comment_test.rb`).
- State records are tested through verbs on fixtures (`cards(:logo).close` → `closed?`), in
  `test/models/card/*_test.rb`.
- Tenancy is tested with the extra `initech`/`acme` fixture accounts (`test/fixtures/accounts.yml`).
- Jobs are tested from the model by asserting what gets enqueued (`assert_enqueued_with`
  in `test/models/account/export_test.rb`, `test/models/notification/pushable_test.rb`).

See [[testing/model-tests]] and [[testing/fixtures]].

## Reuse recipe

1. Start from `rails new` defaults: Solid Queue/Cache/Cable, importmap, Propshaft, Minitest. Add a gem only when a PR can justify it in a sentence.
2. Put behavior on models as concerns. Allow a PORO in `app/models` when a flow spans models (`Signup`), and never create `app/services`.
3. Model each toggleable state as a `has_one` record plus a singular resource. Use an enum only for a pure label with no actor, timestamp or vocabulary.
4. Enforce invariants with NOT NULL, unique indexes and foreign keys. Keep `validates` only for errors a form shows.
5. Put `account_id` on every tenant row from day one, and use UUIDv7 keys if data will ever move between databases.
6. Keep search, jobs and cache in the primary database until measurements say otherwise.
7. Store derived state on write, and bust caches with `touch`. Lock the owning row for contended counters, and use a ledger when the contention is a fan-in.
8. Write the decision and the rejected alternative into the commit body. Fizzy's best "why" lives there.

## Related

[[voice/team]] · [[voice/dhh-refactors]] · [[patterns/model-concerns]] · [[patterns/state-as-resource]] ·
[[patterns/jobs-later-now]] · [[patterns/current-attributes]] · [[components/accounts-tenancy]] ·
[[components/search]] · [[components/storage]] · [[testing/fixtures]] · [[sources]]
