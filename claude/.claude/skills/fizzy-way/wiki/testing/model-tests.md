---
title: Model tests — traits through real models
use_when: [unit test a concern, test a model, mocks, stubs, mocha, assert_difference, assert_changes, freeze_time, travel_to, perform_enqueued_jobs, test a job, test broadcasts, Current.user in model tests, what should I test]
sources:
  - test/models/**/*_test.rb (102 files), test/jobs/**/*_test.rb (6 files)
  - test/test_helper.rb (perform_enqueued_jobs override, Current setup/teardown, parallelize)
  - test/test_helpers/{change,card_activity,dns,vcr}_test_helper.rb, test/test_helpers/search_test_helper.rb
  - app/models/current.rb, app/jobs/concerns/account_tenanted.rb
  - commits e51f0bfee, 9cdc34f0a, 56f47361f, 47074bb99, b4f3ee5d8, 126ccb5e3
snapshot: 27d0d2e6b
---

# Model tests — traits through real models

## Answer

A test file mirrors the trait it covers (`app/models/card/closeable.rb` →
`test/models/card/closeable_test.rb`, `class Card::CloseableTest < ActiveSupport::TestCase`).
The test drives the trait through a **real fixture record, the real database, and real
callbacks**. It sets the actor with `Current.session = sessions(:david)`, calls the
verb, and asserts the *effect*, usually with `assert_difference` or `assert_changes`
on a lambda. Time is controlled with `freeze_time`/`travel_to`. Jobs run inline with
`perform_enqueued_jobs only: SomeJob`. Mocha is available, but it only stubs the
**edges of the system**, such as the network, DNS, cache counters, Stripe and the
filesystem. Domain objects are never mocked.

## Shape

```
test/
  test_helper.rb               # ActiveSupport::TestCase: fixtures :all, ActiveJob::TestHelper,
                               #   Turbo::Broadcastable::TestHelper, house helpers, Current setup/teardown
  test_helpers/                # small modules, included globally or per-test
    change_test_helper.rb      # capture_change
    card_activity_test_helper.rb   # multiple_people_comment_on(card) — scenario builder
    dns_test_helper.rb         # stub_dns_resolution — boundary stub, shared
    search_test_helper.rb      # non-transactional search world (opt-in)
    vcr_test_helper.rb         # cassette per test (opt-in, for external HTTP)
  models/
    card_test.rb               # the class itself
    card/closeable_test.rb     # one file per trait, namespaced like the concern
    card/golden_test.rb  card/postponable_test.rb  card/stallable_test.rb ...
    card/eventable/system_commenter_test.rb   # POROs behind a trait get their own test
    concerns/mentions_test.rb  # shared concern, tested through Card
    notifier/event_notifier_test.rb
  jobs/                        # only 6: jobs are one-liners, tested via models
```

## Key code

The canonical trait test (`test/models/card/closeable_test.rb`):

```ruby
class Card::CloseableTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:david)          # → Current.identity → Current.user (see app/models/current.rb)
  end

  test "closed scope" do
    assert_equal [ cards(:shipping) ], Card.closed
    assert_not_includes Card.open, cards(:shipping)
  end

  test "close cards" do
    assert_not cards(:logo).closed?

    assert_difference -> { cards(:logo).events.count }, +1 do
      cards(:logo).close(user: users(:kevin))
    end

    assert cards(:logo).closed?
    assert cards(:logo).events.last.action.card_closed?
    assert_equal users(:kevin), cards(:logo).closed_by
  end
end
```

Nested `assert_changes` and `assert_difference` state the whole effect of a verb in
one place:

```ruby
assert_changes -> { card.reload.postponed? }, to: true do
  assert_difference -> { card.events.count }, +1 do
    card.postpone
  end
end
```

Both assertions return the block's value, so the new record comes back without a
`.last` lookup:

```ruby
notification = assert_difference -> { @user.notification_bundles.pending.count }, 1 do
  @user.notifications.create!(source: events(:logo_published), creator: @user)
end
```

Time:

```ruby
test "a card with an old activity spike is stalled" do
  cards(:logo).create_activity_spike!
  travel_to 3.months.from_now
  assert cards(:logo).stalled?
end

test "auto_postpone_at infers the period from the board when present" do
  freeze_time
  entropies(:writebook_board).update! auto_postpone_period: 90.days
  cards(:layout).update! last_active_at: 2.day.ago
  assert_equal (90 - 2).days.from_now, cards(:layout).entropy.auto_clean_at
end
```

Jobs: run only the job that matters, inline, around the domain call:

```ruby
perform_enqueued_jobs only: Mention::CreateJob do
  assert_difference -> { Mention.count }, +1 do
    card.publish
  end
end
```

The global override that keeps jobs honest about tenancy (`test/test_helper.rb`):

```ruby
# Jobs must carry their own account context via AccountTenanted,
# not rely on Current.account leaking from the test setup.
def perform_enqueued_jobs(...)
  saved_account = Current.account
  Current.account = nil
  super
ensure
  Current.account = saved_account
end

setup    { Current.account = accounts("37s") }
teardown { Current.clear_all }
```

Broadcasts are asserted like any other effect:

```ruby
assert_turbo_stream_broadcasts([ notification.user, :notifications ], count: 1) do
  perform_enqueued_jobs { notification.read }
end
```

Where Mocha is used (all 85 `stubs`/`expects` calls): `Resolv.getaddresses`,
`Net::HTTP`, `TCPSocket`, `Rails.cache.increment` (rate limits), `Stripe::Subscription`,
the web push pool, `Rails.error.report`, shelling out to `df`. A few spy on a
collaborator call that is too expensive to run (`Account.any_instance.expects(:setup_customer_template).once`).

## Why

- **Test the model against the database.** DHH: *"I rarely unit test in the
  traditional sense of the word, where all dependencies are mocked out, and thousands
  of tests can close in seconds. It just hasn't been a useful way of dealing with the
  testing of Rails applications. I test active record models directly, letting them
  hit the database, and through the use of fixtures."*
  ([TDD is dead. Long live testing.](https://dhh.dk/2014/tdd-is-dead-long-live-testing.html))
  The same post blames mock-driven isolation for *"A dense jungle of service objects,
  command patterns, and worse"*. That is the shape [[patterns/model-concerns]] avoids.
- **A trait gets tested through its host.** Each concern is a slice of a real model,
  so there is no dummy class to include it into (inference, consistent with every file
  under `test/models/card/`). The shared `Mentions` concern is tested by creating and
  publishing real cards (`test/models/concerns/mentions_test.rb`).
- **Tests come after the code, and only where they pay.** Jorge: "I rarely write my tests
  first or use them to help design my code." ([Pending tests](https://dev.37signals.com/pending-tests/),
  meta description). DHH: *"Knowing what not to test is the harder part of the lesson."*
  ([Testing like the TSA](https://signalvnoise.com/posts/3159-testing-like-the-tsa))
  That post also says *"Don’t test standard Active Record associations, validations,
  or scopes."* Fizzy does test scopes, but only domain scopes that join state records
  (`Card.closed`, `Card.stalled`), never plain `where` wrappers (inference). Jorge's
  stalled-card work shows the rhythm: 9cdc34f0a "Basic tests for detecting stalled
  cards", then d22cbe6f7 "Add tests for stalled detection", then 67b45cc5a "Test scope".
- **Jobs carry their own tenant.** Donal McBreen's e51f0bfee "Fix account destroy
  cascade gaps" extracted `AccountTenanted` into `ApplicationJob`. The same commit
  added the `perform_enqueued_jobs` override, so a job that forgets its account fails
  in tests instead of borrowing the test's `Current.account`. → [[patterns/current-attributes]]
- **Thin jobs mean few job tests.** A job is `perform(x) = x.do_thing`, so the model
  test that calls `do_thing_later` and runs `perform_enqueued_jobs` covers it. Only
  6 files live in `test/jobs/`, and they cover jobs with real logic of their own
  (incineration, import, storage reconcile). → [[patterns/jobs-later-now]]
- **Stub the boundary once, in a named helper.** Mike Dalessio's 56f47361f "Fix flaky
  web push test and deduplicate DNS stub helper (#2825)" replaced five copies of
  `stub_dns_resolution` with `DnsTestHelper`. Rob Zolkos's 47074bb99 "Stub DNS in
  notification delivery tests (#2838)" added `stub_web_push_dns_resolution`.
- **Include the test helpers you rely on.** b4f3ee5d8 "Include broadcast test helpers":
  *"We were relying on these without explicitly including them, leading to flaky tests."*
- **Inline a helper that has one caller.** Rosa Gutierrez's 126ccb5e3 "Add integration
  test for notification delivery and simplify test helpers" deleted
  `PushNotificationTestHelper` and moved its code into the only test that used it.
  This is the anemic-code rule from [[voice/dhh-refactors]], applied to tests.

**Reusable vs Fizzy-specific.** Reusable: one test file per trait, Current set from a
session fixture, effect assertions with lambdas, `perform_enqueued_jobs only:`, stubs
only at I/O edges. Fizzy-specific: `Current.session=` cascades to identity and user
because of the Identity/User split, and the `perform_enqueued_jobs` override exists
because of URL-based multi-tenancy.

## Testing

Representative files to copy from:
- `test/models/card/closeable_test.rb`, `postponable_test.rb` — verb pairs with events.
- `test/models/card/entropic_test.rb`, `stallable_test.rb` — `freeze_time`/`travel_to`.
- `test/models/notifier/event_notifier_test.rb` — real notifier against fixtures, `assert_no_difference`.
- `test/models/notification_test.rb` — Turbo broadcast assertions, `capture_turbo_stream_broadcasts`.
- `test/models/account/incineratable_test.rb` — before/after counts across ~35 models, then all enqueued jobs.
- `test/integration/notifications_test.rb` — an `ActiveSupport::TestCase` that runs the whole notify → bundle → push chain with only DNS and the push pool stubbed.

## Reuse recipe

1. Mirror the model tree: one `test/models/<model>/<trait>_test.rb` per concern, with the class named `<Model>::<Trait>Test`.
2. In `setup`, set the actor the way production does (`Current.session = sessions(:david)`). Clear it in a global `teardown { Current.clear_all }`.
3. Call the domain verb on a fixture. Assert the effect with `assert_difference`/`assert_changes` on a lambda, nesting them when the verb has several effects. Capture the block's return value instead of looking it up afterwards.
4. Use `freeze_time` for exact arithmetic and `travel_to` for "after a while".
5. Wrap the call in `perform_enqueued_jobs only: TheJob` to run its job inline. If jobs carry context (tenant, user), override `perform_enqueued_jobs` to blank that context, so jobs have to restore it themselves.
6. Stub only I/O: HTTP, DNS, payment APIs, the clock source, the cache counter. Put each stub in a named helper module. Never stub your own models.
7. Skip tests for framework behavior (plain associations and validations). Test domain scopes and verbs.

## Related

[[testing/fixtures]] · [[testing/controller-and-system]] · [[patterns/model-concerns]] ·
[[patterns/jobs-later-now]] · [[patterns/current-attributes]] · [[components/notifications]]
