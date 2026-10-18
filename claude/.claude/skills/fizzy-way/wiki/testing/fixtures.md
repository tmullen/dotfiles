---
title: Fixtures over factories
use_when: [factory_bot, factories vs fixtures, test data, seed data for tests, fixture naming, uuid fixtures, deterministic ids, ".first/.last flaky in tests", polymorphic fixture, test setup scenario, multi-tenant fixtures]
sources:
  - test/fixtures/*.yml, test/fixtures/{account,card,identity,user,webhook,action_text}/*.yml
  - test/test_helper.rb (fixtures :all, FixturesTestHelper)
  - lib/rails_ext/active_record_uuid_type.rb
  - test/models/board/accessible_test.rb, test/models/notifier/event_notifier_test.rb
  - commits e4011ef21, 63f8a9af7, a81986816, 59dd8ca54, a48c88cb5, 12928f530
snapshot: 27d0d2e6b
---

# Fixtures over factories

## Answer

Fizzy has no factories. Every test loads one small, realistic world from YAML
(`fixtures :all`): 3 accounts, 7 users, 3 boards, 8 cards, with **one fixture per
interesting state** (one closed card, one golden card, one drafted card, one user per
role). Tests reach records by label (`cards(:logo)`) and build each scenario by
calling **domain methods** on fixtures (`card.close`, `accesses.revoke_from`), not
by building records attribute-by-attribute. A small prepend on `ActiveRecord::FixtureSet`
makes labels produce **deterministic UUIDv7s that sort before anything created at
runtime**, so `Card.last` still means "the one I just made".

## Shape

```
test/
  test_helper.rb            # fixtures :all; FixturesTestHelper prepended into FixtureSet
  fixtures/
    accounts.yml            # 37s (home), initech, acme (other tenants for isolation tests)
    identities.yml          # david, jz, jason, kevin, mike  (global, email-based)
    users.yml               # david/jz member, jason owner, kevin admin, system; mike + system_initech in initech
    sessions.yml            # one per identity → Current.session = sessions(:david)
    boards.yml              # writebook (all_access), private (kevin's), miltons_wish_list (initech)
    columns.yml             # writebook_triage, writebook_in_progress, ...
    cards.yml               # logo, layout, text, shipping, buy_domain, radio, paycheck, unfinished_thoughts
    closures.yml            # shipping           ← state records named after their owner
    card/goldnesses.yml     # logo               ← namespaced model → namespaced folder
    pins.yml / watches.yml / accesses.yml       # <parent>_<user>: logo_kevin, writebook_david
    events.yml              # <card>_<action>: logo_published, shipping_closed, layout_commented
    notifications.yml, comments.yml, mentions.yml, entropies.yml, webhooks.yml ...
    action_text/rich_texts.yml   # rich text bodies as fixtures, polymorphic record:
    files/                  # avatar.png, moon.jpg → file_fixture("moon.jpg")
```

32 YAML files back 274 test files. The names come from the domain and the team
(`david`, `jz`, `kevin` are real 37signals people. `initech` and `miltons_wish_list`
come from *Office Space*). Labels read well inside assertions.

## Key code

Every row sets its id explicitly and references others by label with a `_uuid` suffix.
Polymorphic references put the class in parentheses:

```yaml
# cards.yml
logo:
  id: <%= ActiveRecord::FixtureSet.identify("logo", :uuid) %>
  number: 1
  board: writebook_uuid
  creator: david_uuid
  column: writebook_triage_uuid
  title: The logo isn't big enough
  created_at: <%= 1.week.ago %>
  status: published
  last_active_at: <%= 1.week.ago %>
  account: 37s_uuid

# events.yml
logo_published:
  id: <%= ActiveRecord::FixtureSet.identify("logo_published", :uuid) %>
  creator: david_uuid
  eventable: logo_uuid (Card)
  action: card_published
  account: 37s_uuid
```

The account slug in URLs comes from the same mechanism. A plain integer `identify`
gives the decimal `external_account_id`:

```yaml
37s:
  id: <%= ActiveRecord::FixtureSet.identify("37s", :uuid) %>
  external_account_id: <%= ActiveRecord::FixtureSet.identify("37signals") %>
```

The UUID hook (condensed from `test/test_helper.rb`):

```ruby
module FixturesTestHelper
  extend ActiveSupport::Concern

  class_methods do
    def identify(label, column_type = :integer)
      if label.to_s.end_with?("_uuid")
        column_type = :uuid
        label = label.to_s.delete_suffix("_uuid")
      end

      return super(label, column_type) unless column_type.in?([ :uuid, :string ])
      generate_fixture_uuid(label)
    end

    private
      def generate_fixture_uuid(label)
        fixture_int = Zlib.crc32("fixtures/#{label}") % (2**30 - 1)   # same hash Rails uses for integer ids
        timestamp = Time.utc(2024, 1, 1) + (fixture_int / 1000.0)        # always in the past
        uuid_v7_with_timestamp(timestamp, label)                         # random bits seeded by MD5(label)
      end
  end
end

ActiveSupport.on_load(:active_record_fixture_set) { prepend(FixturesTestHelper) }
```

A scenario is built from fixtures plus domain verbs. No attribute soup:

```ruby
test "revising access" do
  boards(:writebook).update! all_access: false

  boards(:writebook).accesses.revise granted: users(:david, :jz), revoked: users(:kevin)
  assert_equal users(:david, :jz).to_set, boards(:writebook).users.to_set
end

test "does not create a notification for access-only users" do
  boards(:writebook).access_for(users(:kevin)).access_only!
  ...
end
```

When a test needs a brand-new record, it creates it through the association that
owns it, with only the attributes that matter:
`boards(:writebook).cards.create!(creator: users(:kevin), status: :drafted)`.

## Why

- **The house style is fixtures.** Jorge's recommended stack: *"Test your apps with
  Minitest. Use fixtures and build a realistic set of those as you cook your app."*
  ([A vanilla Rails stack is plenty](https://dev.37signals.com/a-vanilla-rails-stack-is-plenty/))
  DHH: *"I test active record models directly, letting them hit the database, and
  through the use of fixtures."* ([TDD is dead. Long live testing.](https://dhh.dk/2014/tdd-is-dead-long-live-testing.html))
  The Gemfile's test group has no factory gem, and `git log -S factory_bot` finds nothing.
- **Small and named beats large and generated** (inference). With 8 cards, a reader
  knows `cards(:shipping)` is *the* closed card and `cards(:logo)` is *the* golden one.
  Tests assert exact collections (`assert_equal [ cards(:shipping) ], Card.closed`),
  and that only works when the world is small and known.
- **Deterministic UUIDs keep `.first`/`.last` meaningful.** Mike Dalessio's e4011ef21
  "Update primary keys on customer data to UUIDs" added the `_uuid` label suffix. Kevin
  McConnell's 63f8a9af7 "Deterministic fixture UUIDs" made ids derive from the label,
  and 59dd8ca54 "Make IDs more time-sortable in tests" explains the rule: *"Fixtures
  are all created in the past"* and *"Models sort in the order that they were
  created"*, which *"allows us to do things like this: … `created_card = Card.last`"*.
  That commit replaced `Card.order(created_at: :desc).first` with `Card.last` in six
  controller tests. AGENTS.md now warns: *don't "fix" ordering by comparing insertion
  order to id order.*
- **Helper code lives in `test/`, not `app/`.** a81986816 "Move test-related UUID
  helper" moved the generator out of `app/models/concerns/uuid_primary_key.rb` (since removed) and into
  `test_helper.rb`.
- **Make order explicit in the fixture when the code orders by time.** a48c88cb5
  "Stabilize notifications tray test ordering via fixture updated_at timestamps" gave
  three notifications `updated_at: 1.week.ago + 1/2/3.seconds` instead of relying on
  id as a tie-breaker.
- **Other tenants are fixtures too.** `initech` and `acme`, each with their own users
  and boards, make cross-account leaks testable without building a second world
  (`boards(:miltons_wish_list)`, `users(:mike)`). (inference)
- **One justified exception.** Search runs against an FTS/sharded index outside the
  transaction, so `SearchTestHelper` sets `use_transactional_tests = false` and builds
  its own account, user, and board in setup. 12928f530 "Refactor search test to use
  instance variables" fixed a test that mixed those records with fixtures: it *"uses
  fixtures directly by creating comments and publishing cards making test state
  unpredictable."* If you opt out of
  transactions, opt out of fixtures as well.

**Reusable vs Fizzy-specific.** Reusable: fixtures only, a small cast with one record
per state, label-derived ids, scenarios built through domain verbs. Fizzy-specific:
the base36 UUIDv7 encoding and the `_uuid` suffix exist because of Fizzy's custom
binary `uuid` type (`lib/rails_ext/active_record_uuid_type.rb`). An app with integer or
native UUID keys gets deterministic ids from stock Rails.

## Testing

This page is about test data, so here is how to check the fixtures themselves:
- `test/models/uuid_primary_key_test.rb` asserts that runtime ids are 25-char base36.
- When a model change breaks ordering, look for tests that compare `Model.last` and
  confirm the fixture timestamps still sit in the past (base time `2024-01-01`).
- Multi-record accessors keep assertions short: `users(:david, :jz)`.

## Reuse recipe

1. Drop factory gems. Put `fixtures :all` in `ActiveSupport::TestCase`.
2. Design a small cast: one home account, one or two foreign accounts, one user per role (including a system user), one record per state your traits model (closed, archived, drafted, golden).
3. Name fixtures in domain words. Name join and state rows `<parent>_<child>` or after their owner (`closures.yml: shipping`) so the label tells you what it joins.
4. Use ERB only for relative times (`<%= 1.week.ago %>`) and computed ids, never for loops that generate bulk data.
5. With UUID keys, prepend an `identify` override that derives a time-ordered UUIDv7 from the label, with a timestamp in the past. That keeps `.last` meaning "newest".
6. In tests, start from fixtures and move them into the needed state with domain methods (`card.close`, `board.accesses.revoke_from user`). Create new records through the owning association.
7. If a test has to leave transactional tests off, have it build its own world and clean it up in teardown. Don't mix that world with fixtures.

## Related

[[testing/model-tests]] · [[testing/controller-and-system]] · [[patterns/model-concerns]] ·
[[components/accounts-tenancy]] · [[decisions/index]]
