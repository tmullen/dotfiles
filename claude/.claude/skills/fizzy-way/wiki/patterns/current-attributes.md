---
title: Current attributes
use_when: [current user, Current.user, CurrentAttributes, global state, thread local, request context, default creator, belongs_to default, who did this, pass user down, Current in jobs, Current in tests, Current.with_account, set current account]
sources:
  - app/models/current.rb
  - app/controllers/concerns/authentication.rb, app/controllers/concerns/current_request.rb, app/controllers/concerns/current_timezone.rb
  - config/initializers/tenanting/account_slug.rb, app/jobs/concerns/account_tenanted.rb, app/channels/application_cable/connection.rb
  - app/models/card.rb, app/models/board.rb, app/models/comment.rb, app/models/concerns/eventable.rb, app/models/card/closeable.rb, app/models/concerns/mentions.rb
  - app/models/notification/bundle.rb, app/models/account/seeder.rb, app/models/signup/account_name_generator.rb
  - test/test_helper.rb, test/test_helpers/session_test_helper.rb
  - commits 2ff9dbab5, 208ace721, 6bbf68a4f, 8e13ce5b7, d41d50d52, 319e4223e, 5a7f08067, 9446bc18d, 660fcff55, 75f273c6f, 9697f7b43, e51f0bfee
snapshot: 55bb38335
---

# Current attributes

## Answer

`Current < ActiveSupport::CurrentAttributes` holds the request's **who** (`session`,
`identity`, `user`), **where** (`account`), and **request facts** (`ip_address`,
`user_agent`, `request_id`, `referrer`, `http_method`). The setters cascade:
`session=` sets `identity`, and `identity=` looks up the `user` for the current
account. Models read `Current.user` **only as a default**, in `belongs_to :creator,
default: -> { Current.user }` or a keyword argument such as `close(user:
Current.user)`. Callers can always pass an explicit actor, and jobs, consoles, and
the seeder do. `Current.account` is set once at the edge (middleware, cable
connection, job `around_perform`) and switched with block helpers:
`Current.with_account(account) { }`, `Current.without_account { }`, `Current.set(...)
{ }`.

## Shape

```
app/models/current.rb                          # the whole thing, ~30 lines
config/initializers/tenanting/account_slug.rb  # Current.with_account / without_account around @app.call
app/controllers/concerns/
  authentication.rb     # set_current_session → Current.session=; bearer → Current.identity=
  current_request.rb    # before_action: Current.http_method/request_id/user_agent/ip_address/referrer
  current_timezone.rb   # around_action Time.use_zone (cookie) — time zone is NOT in Current
app/channels/application_cable/connection.rb   # Current.account = account; current_user from session
app/jobs/concerns/account_tenanted.rb          # carries Current.account across the queue
lib/action_pack/web_authn/current.rb           # a library's own CurrentAttributes (host, origin)
```

Usage at the snapshot (`grep -o "Current\.[a-z_]*"` across app, lib and config):
`Current.user` 177, `Current.account` 59, `Current.identity` 27, `Current.session` 5,
and `with_account`/`without_account`/`set` 10 together.

## Key code

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :session, :user, :identity, :account
  attribute :http_method, :request_id, :user_agent, :ip_address, :referrer

  def session=(value)
    super(value)

    if value.present?
      self.identity = session.identity
    end
  end

  def identity=(identity)
    super(identity)

    if identity.present?
      self.user = identity.users.find_by(account: account)
    end
  end

  def with_account(value, &)
    with(account: value, &)
  end

  def without_account(&)
    with(account: nil, &)
  end
end
```

Order matters. The middleware sets `account` before the controller sets `session`,
so `identity=` can resolve the right `User`.

Defaults in models, with the actor always overridable:

```ruby
class Card < ApplicationRecord
  belongs_to :account, default: -> { board.account }            # from the parent, not Current
  belongs_to :creator, class_name: "User", default: -> { Current.user }
end

module Card::Closeable
  def close(user: Current.user)
    unless closed?
      transaction do
        not_now&.destroy
        create_closure! user: user
        track_event :closed, creator: user
      end
    end
  end
end

module Eventable
  def track_event(action, creator: Current.user, board: self.board, **particulars)
    ...
  end
end
```

Jobs don't carry `Current.user`. When the actor matters, it is passed as an argument
at enqueue time:

```ruby
module Mentions
  def create_mentions(mentioner: Current.user) ... end

  private
    def create_mentions_later
      Mention::CreateJob.perform_later(self, mentioner: Current.user)
    end
end
```

Block-scoped switching where there is no request:

```ruby
# app/models/notification/bundle.rb
def deliver
  user.in_time_zone do
    Current.with_account(user.account) do
      processing!
      Notification::BundleMailer.notification(self).deliver if deliverable?
      delivered!
    end
  end
end

# app/models/account/seeder.rb
def seed
  Current.set(user: creator, account: account) { populate }
end

# app/models/signup/account_name_generator.rb — reading across all of an identity's accounts
Current.without_account do
  identity.accounts.filter_map { ... }
end
```

Request facts are captured in one controller concern and read by models that need
them, for example signup sending IP and user agent to billing:

```ruby
module CurrentRequest
  included do
    before_action do
      Current.http_method = request.method
      Current.request_id  = request.uuid
      Current.user_agent  = request.user_agent
      Current.ip_address  = request.ip
      Current.referrer    = request.referrer
    end
  end
end
```

## Why

- **Sharp tool, used on purpose.** Jorge: *"Sacrificing purity for convenience is
  one of the Rails pillars."* and *"On the tactical side, the combination of
  callbacks with CurrentAttributes achieves something powerful: you can create a
  project normally, and the operation gets seamlessly audited."*
  ([Globals, callbacks and other sacrileges](https://dev.37signals.com/globals-callbacks-and-other-sacrileges/))
  That post's example is exactly Fizzy's `belongs_to :creator, default: -> {
  Current.person }`. DHH's 2018 episode covers the same ground: *"how we use globals
  in Basecamp to provide access to the current user and request details"*
  ([On Writing Software Well #3](https://www.youtube.com/watch?v=D7zUOtlpUPw), video
  description).
- **A default, never a requirement.** Every model read of `Current.user` sits in a
  `default:` lambda or a keyword default. Code without a request (jobs, the seeder,
  `Account::Cancellable#cancel(initiated_by: Current.user)`) passes the actor
  explicitly or wraps itself in `Current.set`. The model stays usable from a console
  (inference from the uniform pattern). The creator default dates from the first
  weeks of the app (2ff9dbab5 "Track creator").
- **`Current.account` is for the edge. Models use `record.account`.** It took the
  team three tries to settle this:
  - 6bbf68a4f "The tenanted db is the account scope" (DHH) deleted
    `Current.account`, because with a database per tenant the connection *was* the
    scope.
  - 8e13ce5b7 "Drop Current.account and just use Account.sole": *"I had reintroduced
    this in dacb53b8 after David removed it in 6bbf68a4, but now I agree we don't
    need it."*
  - d41d50d52 "Account.sole → Current.account" brought it back when tenancy moved
    into one MySQL database (PR #1631 "Bring back current account").

  The lesson that stuck is 9697f7b43 "Replace some instances of Current.account with
  model account": inside models, derive from the record. See
  [[components/accounts-tenancy]].
- **Set it as early as possible.** 5a7f08067 "Move setting Current.account into the
  middleware": *"so that code called from the Rails controllers can use
  Current.account"*. Anything that can run outside `ApplicationController` (Active
  Storage, Action Cable, Rack endpoints) needs it set before the controller.
- **Use the framework's `with`.** 9446bc18d "Simplify Current.with_account and
  .without_account" replaced hand-written save, assign and `ensure` restore with
  `with(account: value, &block)`. The block helpers remain as named domain
  shortcuts. Anonymous block forwarding followed in 0d83e9b90 "Refactor with_account
  and without_account methods".
- **Derive, don't duplicate.** 208ace721 "Delegate Current.user to session" first
  made user a delegation. Once a session-less API token could authenticate
  (660fcff55 "Authenticate api requests without needing a session"), `identity`
  became its own attribute and `user` became derived from identity plus account.
  75f273c6f "Fix Current not setting a session in some contexts" removed an
  `account.present?` guard that broke untenanted pages.
- **Request details belong in Current, time zone doesn't.** 319e4223e "Add request
  details to Current". Time zone uses `Time.use_zone` in an `around_action`, Rails'
  own per-request mechanism, so there's nothing to duplicate (inference).

**Reusable vs Fizzy-specific:** all of it is reusable. The `identity` layer only
matters when one login spans several accounts. Without that, `session=` can set
`user` directly.

## Testing

- `test/test_helper.rb` sets `Current.account = accounts("37s")` in `setup` and
  calls `Current.clear_all` in `teardown` for every test. Model tests can create
  records without passing an account.
- Actor-dependent model tests set `Current.session = sessions(:david)`
  (`test/models/card/closeable_test.rb`) or use `with_current_user(:kevin) { ... }`
  from `test/test_helpers/session_test_helper.rb`, which builds an unsaved
  `Session.new(identity: user.identity)`.
- `perform_enqueued_jobs` is overridden to set `Current.account = nil` while jobs
  run, so a job that relies on leaked state fails in tests.
- Cross-account code is tested inside `Current.without_account { }`
  (`test/models/signup_test.rb`, `test/models/account_test.rb`).

## Reuse recipe

1. Create `app/models/current.rb` with `attribute :session, :user, :account` and request facts. Write setters that derive downstream attributes (`session=` → `user`).
2. Set the tenant in middleware, or at least first in the controller chain. Set the session in your `Authentication` concern. Fill in request facts in a `CurrentRequest` concern.
3. In models, write `belongs_to :creator, default: -> { Current.user }` and verbs with `user: Current.user` keywords. Never read `Current` in a way that can't be overridden.
4. Derive `account` from the parent association, and keep `Current.account` for root records and URL generation.
5. For jobs, serialize the account automatically (prepend a module on `ApplicationJob`) and pass actors explicitly as job arguments.
6. Write named block helpers (`with_account`, `without_account`) on top of `Current.with`, and use `Current.set(user:, account:) { }` for scripts and seeders.
7. In tests, set `Current` in `setup`, clear it in `teardown`, and nil it out while performing jobs.

## Related

[[components/accounts-tenancy]] · [[components/authentication]] · [[patterns/model-concerns]] ·
[[patterns/events-as-spine]] · [[patterns/jobs-later-now]] · [[testing/model-tests]]
