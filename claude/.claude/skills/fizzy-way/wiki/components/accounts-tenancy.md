---
title: Accounts and multi-tenancy
use_when: [multi-tenant, multitenancy, tenant, account scoping, account_id everywhere, URL slug, subdomain vs path, Current.account, cross-tenant leak, jobs lose tenant, UUID primary keys, uuidv7, single tenant mode, self-hosted vs SaaS]
sources:
  - config/initializers/tenanting/account_slug.rb, config/initializers/tenanting/turbo.rb
  - config/initializers/multi_tenant.rb, config/initializers/active_job.rb, config/initializers/active_storage.rb
  - app/models/account.rb, app/models/account/multi_tenantable.rb, app/models/account/external_id_sequence.rb
  - app/models/current.rb, app/jobs/application_job.rb, app/jobs/concerns/account_tenanted.rb
  - app/mailers/application_mailer.rb, app/channels/application_cable/connection.rb
  - lib/rails_ext/active_record_uuid_type.rb, config/initializers/uuid_primary_keys.rb
  - test/middleware/account_slug_extractor_test.rb, test/test_helper.rb, test/test_helpers/session_test_helper.rb
  - commits 4d3c26504, 5a7f08067, e3d86bb21, 142a342e5, e51f0bfee, fe6df7085, 9697f7b43, 9f6a4f1cc, 2061ab4ab, e105ca6fb, 6c04b56f4, 63f8a9af7
snapshot: 55bb38335
---

# Accounts and multi-tenancy

## Answer

One database, one schema, and an `account_id` column on every domain table. The
tenant comes from the **URL path prefix** (`/{external_account_id}/boards/...`).
A ~40-line Rack middleware, `AccountSlug::Extractor`, moves that prefix from
`PATH_INFO` to `SCRIPT_NAME`, so Rails behaves as if it were mounted there. It
looks up the `Account` and runs the request inside `Current.with_account`. Nothing
is scoped by a `default_scope` or a tenanting gem. Isolation comes from two habits:
records **inherit** their account from their parent (`belongs_to :account, default:
-> { board.account }`), and controllers **find** through `Current.user`'s
associations. Jobs serialize the account and restore it. All keys are UUIDv7, stored
as binary(16) and shown as 25-character base36.

## Shape

```
config/initializers/
  tenanting/account_slug.rb    # AccountSlug::Extractor middleware + encode/decode
  tenanting/turbo.rb           # Turbo stream renders use Current.account.slug as script_name
  multi_tenant.rb              # Account.multi_tenant from ENV["MULTI_TENANT"] / config.x
  active_job.rb                # prepend AccountTenanted onto mailer + Turbo broadcast jobs
  active_storage.rb            # ActiveStorage::Current.url_options gets script_name
  uuid_primary_keys.rb         # binary(16) → :uuid type; auto default for UUID PKs
lib/rails_ext/active_record_uuid_type.rb   # ActiveRecord::Type::Uuid (v7, base36)
app/models/
  current.rb                   # attribute :account; with_account / without_account
  account.rb                   # external_account_id, slug, create_with_owner, system_user
  account/multi_tenantable.rb  # cattr multi_tenant; accepting_signups?
  account/external_id_sequence.rb  # locked counter row for external_account_id
app/jobs/
  application_job.rb           # prepend AccountTenanted
  concerns/account_tenanted.rb # serialize Current.account as a GlobalID; around_perform
app/mailers/application_mailer.rb      # default_url_options script_name: Current.account.slug
app/channels/application_cable/connection.rb  # reads env["fizzy.external_account_id"]
app/controllers/concerns/authentication.rb    # require_account; disallow_account_scope
```

There are no tenant routes. `config/routes.rb` is drawn as if the app had one
account. Untenanted pages, such as `resource :session` and `resource :signup`, are
the same routes reached without a prefix. Their controllers say
`disallow_account_scope`.

## Key code

The middleware is the whole tenant resolver:

```ruby
module AccountSlug
  PATTERN = /(\d+)/
  PATH_INFO_MATCH = /\A(\/#{AccountSlug::PATTERN})/

  class Extractor
    # We're using account id prefixes in the URL path. Rather than namespace
    # all our routes, we're "mounting" the Rails app at this URL prefix.
    def call(env)
      request = ActionDispatch::Request.new(env)

      if request.script_name && request.script_name =~ PATH_INFO_MATCH
        env["fizzy.external_account_id"] = AccountSlug.decode($2)      # already mounted (cable reconnect)
      elsif request.path_info =~ PATH_INFO_MATCH
        request.engine_script_name = request.script_name = $1
        request.path_info   = $'.empty? ? "/" : $'
        env["fizzy.external_account_id"] = AccountSlug.decode($2)
      end

      if env["fizzy.external_account_id"]
        account = Account.find_by(external_account_id: env["fizzy.external_account_id"])
        Current.with_account(account) { @app.call env }
      else
        Current.without_account { @app.call env }
      end
    end
  end

  def self.decode(slug) slug.to_i end
  def self.encode(id) id.to_s end
end

Rails.application.config.middleware.insert_after Rack::TempfileReaper, AccountSlug::Extractor
```

*(Lightly condensed.)* Because `SCRIPT_NAME` carries the slug, every `_path` and
`_url` helper emits it for free. Places with no request get the slug passed
explicitly: `ApplicationMailer#default_url_options` merges `script_name:
Current.account.slug`, Turbo stream renders use
`ApplicationController.renderer.new(script_name: Current.account.slug)`, and
links that cross accounts use `root_url(script_name: account.slug)`.

The account is inherited from the parent record, not from `Current`:

```ruby
class Card < ApplicationRecord
  belongs_to :account, default: -> { board.account }
  belongs_to :creator, class_name: "User", default: -> { Current.user }
end

class Access < ApplicationRecord
  belongs_to :account, default: -> { user.account }
end
```

Of the 29 `belongs_to :account` defaults in `app/models`, only `Tag` uses
`Current.account`, and `Search::Query` uses it only as a fallback. Everything else
derives from a parent.

Jobs carry the account themselves (prepended so `initialize` sees `Current` at
enqueue time):

```ruby
module AccountTenanted
  extend ActiveSupport::Concern

  prepended do
    attr_reader :account
    around_perform :with_account_context
  end

  def initialize(...)
    super
    @account = Current.account
  end

  def serialize
    super.merge({ "account" => @account&.to_gid })
  end

  def deserialize(job_data)
    super
    @account_gid = job_data["account"]
  end

  private
    def with_account_context(&block)
      resolve_account!                    # GlobalID locate; RecordNotFound → DeserializationError
      account.present? ? Current.with_account(account, &block) : yield
    end
end
```

*(Condensed.)* `ApplicationJob` prepends it, and `config/initializers/active_job.rb`
prepends it onto `ActionMailer::MailDeliveryJob` and the three Turbo broadcast jobs.

The account's public number is separate from its UUID and comes from a locked
counter row:

```ruby
class Account < ApplicationRecord
  before_create :assign_external_account_id

  def slug = "/#{AccountSlug.encode(external_account_id)}"
  def account = self            # lets Account stand in wherever "x.account" is expected

  private
    def assign_external_account_id
      self.external_account_id ||= ExternalIdSequence.next
    end
end
```

Single-tenant mode, the self-hosted default, is one class attribute:

```ruby
module Account::MultiTenantable
  included { cattr_accessor :multi_tenant, default: false }

  class_methods do
    def accepting_signups?
      multi_tenant || Account.none?
    end
  end
end
```

UUIDs come from a custom Active Record type registered for `trilogy` and `sqlite3`:
`SecureRandom.uuid_v7` as hex, then base36 padded to 25 characters. They are stored
as `binary(16)`. `config/initializers/uuid_primary_keys.rb` maps `binary(16)` to
`:uuid` and gives every UUID primary key a generated default, so models need no
`before_create`.

## Why

- **Plan A was a database per tenant, and it was abandoned.** Mike Dalessio:
  *"So when we were building Fizzy here at 37signals, we wanted it to be
  multi-tenant and we wanted one application to work for all the customers similar
  to what Basecamp does."* … *"And we launched Fizzy with MySQL instead of with
  SQLite."* ([RECORDABLES: Rails Multi-Tenancy](https://dev.37signals.com/rails-multi-tenancy/))
  The switch was PR #1558 ("Fizzy on MySQL", branch `plan-b`, 219 commits).
  4d3c26504 "Rip out activerecord-tenanting" kept the URL slug and replaced the
  tenant resolver with the middleware (ec5401483 "Add account slug middleware").
  The slug-as-`SCRIPT_NAME` idea survived from the SQLite design, which is why the
  routes never learned about tenants.
- **Set `Current.account` in middleware, not a controller filter.** 5a7f08067
  "Move setting Current.account into the middleware": *"so that code called from
  the Rails controllers can use Current.account"*. That covers Active Storage, Action
  Cable, and other non-`ApplicationController` endpoints. 3b717bbe0 "Move
  AccountSlug::Extractor later in the stack" placed it after the dev reloader.
- **Derive the account from the parent, not the global.** 9697f7b43 "Replace some
  instances of Current.account with model account" removed a `TODO:PLANB:
  Current.account is not quite right, we should use the webhook's account_id`.
  fe6df7085 "Finish the rollout of account_id to all core data models": *"add
  `belongs_to :account` to all models (default to using a domain model's account
  whenever possible)"*. A record built in a job, a console, or a cross-account
  admin task then lands in the right tenant. `Current.account` belongs to the
  request edge.
- **They checked for leaks with a temporary gem, then removed it.** e3d86bb21
  "Clean up some spots where "current account" is ambiguous": problems *"were caught
  by temporarily introducing acts_as_tenant and enabling safety checks"*. The
  shipped app has no tenanting dependency.
- **Jobs restore the account explicitly.** 142a342e5 "Make sure ActiveJob preserves
  the current account context": *"This is a pretty common pattern, something like
  this is in both ActiveRecord::Tenanted and ActsAsTenanted."* e51f0bfee "Fix
  account destroy cascade gaps" moved it from a global initializer into the
  `AccountTenanted` concern. It also deferred lookup to `around_perform` *"so that
  missing accounts raise DeserializationError inside the execution path where
  discard_on can handle it"*. Without that, jobs for an incinerated account crash
  instead of being discarded.
- **Isolation is enforced by finding through the user, not the account.**
  9f6a4f1cc "Fix unauthorized column reordering" changed
  `Current.account.columns.find` to `Current.user.accessible_columns.find` after a
  HackerOne report. An account scope stops cross-tenant leaks, but only the user's
  associations stop leaks between boards. See [[components/access]].
- **A counter row instead of `MAX(id)+1`.** 2061ab4ab "Use dedicated sequence record
  instead of deal with issues with ids and uuids when using the previous approach".
  Once the IDs became UUIDs, the account needed a separate short public number for
  its URL.
- **Short slugs.** e105ca6fb "Remove zero-padding from account slug": *"This shortens
  URLs in the self-hosted case, where external account ID is typically a small
  number."* `decode` still accepts old padded slugs.
- **UUIDv7, base36.** e4011ef21 "Update primary keys on customer data to UUIDs" and
  6c04b56f4 "Compact the UUIDs to base36". v7 is time-ordered, so `.first`/`.last`
  and index locality behave like integer IDs. Base36 keeps them URL-friendly. Fixture
  UUIDs are built to sort older than runtime ones (63f8a9af7 "Deterministic fixture
  UUIDs"). Global unique IDs also make moving accounts between instances possible
  (see [[components/export-import]]) (inference).
- **Self-hosted is single-tenant by default.** a5580666a "Single tenant by default &
  update tests" and eb8655dc8 put it behind `MULTI_TENANT`. The same code serves the
  SaaS and the one-company install. Only signup is gated (`accepting_signups?`).

**Reusable vs Fizzy-specific:** the reusable parts are path-slug-as-`SCRIPT_NAME`,
the `Current.account` middleware, inherited `belongs_to :account` defaults,
`AccountTenanted`, and finding through the user. Fizzy-specific: `external_account_id`
is a Queenbee (37signals billing) ID in SaaS (the middleware comment says *"Stash
the account's Queenbee ID"*), the sequence fallback exists for self-hosting, and the
custom UUID type exists because MySQL has no native UUID column.

## Testing

- `test/middleware/account_slug_extractor_test.rb` calls the middleware with a Rack
  env and asserts on `script_name`, `path_info`, and the captured `Current.account`.
- `test/test_helper.rb`: every `ActiveSupport::TestCase` sets `Current.account =
  accounts("37s")` in setup and calls `Current.clear_all` in teardown. Integration and
  system tests set `default_url_options[:script_name]` to the fixture account's slug.
- The same file overrides `perform_enqueued_jobs` to **nil out `Current.account`**
  while jobs run: *"Jobs must carry their own account context via AccountTenanted,
  not rely on Current.account leaking from the test setup."*
- `untenanted { ... }` in `test/test_helpers/session_test_helper.rb` clears
  `script_name` for login and signup requests. `with_multi_tenant_mode(true)` flips
  the class attribute.
- Cross-tenant tests use a second fixture account, `accounts(:initech)`
  (`test/controllers/active_storage/direct_uploads_controller_test.rb`: "create in
  another account is forbidden").
- `test/models/account/incineratable_test.rb` destroys an account, runs every
  enqueued job, and asserts that no rows are left behind.
- `test/models/uuid_primary_key_test.rb`, `test/lib/rails_ext/active_record_uuid_type_test.rb`.

## Reuse recipe

1. Add `account_id` (NOT NULL, indexed, often leading composite indexes) to every domain table.
2. Write the slug middleware: match `/\A\/(\d+)/`, move it into `SCRIPT_NAME`, find the account, and wrap `@app.call` in `Current.with_account`. Insert it early, after the reloader.
3. In `Authentication`, add `before_action :require_account` that redirects to an account picker, plus a `disallow_account_scope` class method for login/signup controllers.
4. On every model, write `belongs_to :account, default: -> { parent.account }`. Use `Current.account` only for root records that have no parent.
5. Prepend an `AccountTenanted` module on `ApplicationJob`, mailer delivery jobs, and Turbo broadcast jobs: capture at `initialize`, serialize the GlobalID, restore in `around_perform`.
6. Give renderers and mailers without a request `script_name: Current.account.slug`.
7. Load records through `Current.user.<association>`, not `Model.find`, and not just `Current.account.<association>` when there is per-record access.
8. In tests, set `Current.account` in setup, clear it while performing jobs, and keep a second account fixture for leak tests.
9. Optional: UUIDv7 keys, if records must move between databases or you want IDs that don't reveal counts.

## Related

[[patterns/current-attributes]] · [[components/authentication]] · [[components/access]] ·
[[components/signup]] · [[patterns/jobs-later-now]] · [[components/export-import]] ·
[[components/search]] · [[testing/fixtures]]
