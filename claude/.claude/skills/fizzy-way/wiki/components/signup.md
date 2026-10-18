---
title: Signup and join codes
use_when: [signup, sign up, registration, onboarding, create account, invite link, invitation, join code, join an account, team invite, account owner, self-hosted single tenant signup, SigningUpService, form object]
sources:
  - app/models/signup.rb, app/models/signup/account_name_generator.rb
  - app/controllers/signups_controller.rb, app/controllers/signups/completions_controller.rb
  - app/controllers/sessions_controller.rb (sign_up branch)
  - app/models/account.rb (create_with_owner), app/models/account/multi_tenantable.rb, app/models/account/seedeable.rb
  - app/models/account/join_code.rb, app/controllers/join_codes_controller.rb, app/controllers/account/join_codes_controller.rb
  - app/models/identity/joinable.rb, app/controllers/users/verifications_controller.rb, app/controllers/users/joins_controller.rb
  - saas/lib/fizzy/saas/signup.rb, saas/lib/fizzy/saas/engine.rb
  - test/models/signup_test.rb, test/controllers/join_codes_controller_test.rb, test/models/account/join_code_test.rb, test/models/identity/joinable_test.rb
  - commits a9cf7c2c7, 4e09352c0, 2311efd03, a8f328c92, edf6b5346, 6858b9661, c834cce50, 6e9381abb, c8a5d0177, 4602cd3cd, 43069b1ea, e3d91f4ba
snapshot: 55bb38335
---

# Signup and join codes

## Answer

There are two ways in. **Signup** creates a new account. **Join codes** add a
person to an existing one. Both start the same way: an email address becomes an
`Identity` and receives a magic link (see [[components/authentication]]). Signup is
a **PORO form model**, `Signup` (ActiveModel, not a table), with two validation
contexts and two verbs: `create_identity` (step 1, email) and `complete` (step 2,
name, then account plus owner). `Account.create_with_owner` does the inserts. The
SaaS engine overrides two private hook methods (`create_tenant`,
`handle_account_creation_error`) through `prepend` to add billing. Join codes are a
`has_one` record on the account, with a usage limit and an atomic
`redeem_if { identity.join(account) }`.

## Shape

```
app/models/
  signup.rb                         # ActiveModel; create_identity, complete; hooks create_tenant / handle_account_creation_error
  signup/account_name_generator.rb  # "Kevin's Fizzy", "Kevin's 2nd Fizzy"
  account.rb                        # create_with_owner(account:, owner:) → system user + owner; after_create :create_join_code
  account/multi_tenantable.rb       # accepting_signups? = multi_tenant || Account.none?
  account/seedeable.rb              # setup_customer_template → Account::Seeder
  account/join_code.rb              # code "xxxx-xxxx-xxxx", usage_count/usage_limit, redeem_if, reset
  identity/joinable.rb              # join(account, **attrs) → find_or_create_by! user; previously_new_record?
app/controllers/
  signups_controller.rb             # new/create: email → magic link (purpose: sign_up)
  signups/completions_controller.rb # new/create: full name → Signup#complete → redirect into account
  join_codes_controller.rb          # tenanted, unauthenticated: GET/POST /join/:code
  account/join_codes_controller.rb  # admin: show/edit/update usage_limit, destroy = reset code
  users/verifications_controller.rb # new/create: mark user verified after join
  users/joins_controller.rb         # new/create: set name + avatar (profile setup)
saas/lib/fizzy/saas/signup.rb       # prepended: create_tenant → Queenbee account
```

Routes:

```ruby
get "/signup", to: redirect("/signup/new")
resource :signup, only: %i[ new create ] do
  collection do
    scope module: :signups, as: :signup do
      resource :completion, only: %i[ new create ]
    end
  end
end

get "join/:code", to: "join_codes#new", as: :join
post "join/:code", to: "join_codes#create"

namespace :users do
  resources :joins
  resources :verifications, only: %i[ new create ]
end

namespace :account do
  resource :join_code
end
```

## Key code

The form model has two steps, each with its own validation context:

```ruby
class Signup
  include ActiveModel::Model
  include ActiveModel::Attributes
  include ActiveModel::Validations

  attr_accessor :full_name, :email_address, :identity, :skip_account_seeding
  attr_reader :account, :user

  validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }, on: :identity_creation
  validates :full_name, :identity, presence: true, on: :completion
  validates :full_name, length: { maximum: 240 }

  def create_identity
    @identity = Identity.find_or_create_by!(email_address: email_address)
    @identity.send_magic_link for: :sign_up
  end

  def complete
    if valid?(:completion)
      begin
        @tenant = create_tenant
        create_account
        true
      rescue => error
        destroy_account
        handle_account_creation_error(error)
        errors.add(:base, "Something went wrong, and we couldn't create your account. Please give it another try.")
        Rails.error.report(error, severity: :error)
        false
      end
    else
      false
    end
  end

  private
    # Override to customize the handling of external accounts associated to the account.
    def create_tenant
      nil
    end

    # Override to inject custom handling for account creation errors
    def handle_account_creation_error(error)
    end

    def create_account
      @account = Account.create_with_owner(
        account: { external_account_id: @tenant, name: generate_account_name },
        owner: { name: full_name, identity: identity }
      )
      @user = @account.users.find_by!(role: :owner)
      @account.setup_customer_template unless skip_account_seeding
    end
end
```

*(Lightly condensed.)* The account factory is a class method on the model:

```ruby
class Account < ApplicationRecord
  def self.create_with_owner(account:, owner:)
    create!(**account).tap do |account|
      account.users.create!(role: :system, name: "System")
      account.users.create!(**owner.with_defaults(role: :owner, verified_at: Time.current))
    end
  end
end
```

The SaaS engine adds billing without touching core code:

```ruby
# saas/lib/fizzy/saas/engine.rb
::Signup.prepend Signup

# saas/lib/fizzy/saas/signup.rb
module Fizzy::Saas::Signup
  private
    def create_tenant
      @queenbee_account = Queenbee::Remote::Account.create!(queenbee_account_attributes)
      @queenbee_account.id.to_s           # becomes external_account_id → URL slug
    end

    def handle_account_creation_error(error)
      @queenbee_account&.cancel
    end
end
```

The controller is thin:

```ruby
class Signups::CompletionsController < ApplicationController
  disallow_account_scope

  def create
    @signup = Signup.new(signup_params)
    if @signup.complete
      redirect_to landing_url(script_name: @signup.account.slug)
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    def signup_params
      params.expect(signup: %i[ full_name ]).with_defaults(identity: Current.identity)
    end
end
```

*(Condensed. The real one also responds to JSON.)*

Join code redemption is a lock plus a block. The block returns whether a user was
created, and only a new user counts against the limit:

```ruby
class Account::JoinCode < ApplicationRecord
  belongs_to :account
  scope :active, -> { where("usage_count < usage_limit") }
  before_create :generate_code, if: -> { code.blank? }

  def redeem_if(&block)
    with_lock do
      increment!(:usage_count) if active? && block.call(account)
    end
  end

  def reset                       # admin "destroy" = rotate the code
    generate_code
    self.usage_count = 0
    save!
  end
end

module Identity::Joinable
  def join(account, **attributes)
    attributes[:name] ||= email_address
    transaction do
      account.users.find_or_create_by!(identity: self) { it.assign_attributes(attributes) }.previously_new_record?
    end
  end
end
```

*(Condensed: the block in `join` is written `do |user| ... end` in the source.)*

`JoinCodesController#create` (tenanted, unauthenticated) then sends one of three
people somewhere different. A signed-in person who is already set up goes to the
landing page. A signed-in person who just joined goes to verification. Anyone else
is signed out and emailed a magic link, with `return_to:` set to the verification
page.

## Why

- **A model, not a service.** The PORO was reintroduced deliberately (a9cf7c2c7
  "Re-introduce a Signup PORO model"). This is the canonical 37signals example:
  "Vanilla Rails is plenty" presents a `Signup` model as the alternative to a
  `SigningUpService` ([sources](../sources.md)), and *"You can find many POROs in our
  app/models folders."* ([Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/))
  Validation contexts (`on: :identity_creation`, `on: :completion`) let one class
  cover both steps without a wizard framework.
- **Open-source core, SaaS hooks.** Signup first lived in the private `fizzy-saas`
  gem. 4e09352c0 "Bring simple signup flow from the fizzy-saas gem": *"We skip the
  QB code and we fill external account ids automatically on creation with a
  sequence"*. The core keeps documented no-op hook methods ("Override to …"), and
  the engine `prepend`s a module that fills them in. The same move registers push
  targets in [[components/notifications]].
- **Sign-in doubles as sign-up.** a8f328c92 "Sign up new users on sign in":
  `SessionsController#create` sends an unknown email down `sign_up` when
  `Account.accepting_signups?`. The magic link carries `purpose: :sign_up`, so the
  code page redirects to `new_signup_completion_path`, even on another device
  (2311efd03 "Make sign up Magic Links work across devices").
- **Every account has a system user and an owner.** `create_with_owner` makes both.
  edf6b5346 "Introduce an "owner" role, and prevent it from being administered":
  *"to prevent the owner from being demoted or kicked out."* The system user is the
  actor for automated events (see [[components/access]] for roles).
- **Join codes went from a feature to a record.** 6858b9661 "Simplify join codes"
  moved the code off memberships into `Account::JoinCode`. c834cce50 "Simplify join
  code creation and validation and test controller" (DHH) trimmed it further. Two
  race fixes followed: 6e9381abb "Fix crash in join code redemption race condition"
  and c8a5d0177 "Wrap join code redemption in a lock". Together they produced
  `redeem_if` with `with_lock`. Rotating a code is `destroy` on the singular
  resource, which calls `reset`.
- **Joining is split into resources, not actions.** 43069b1ea "Extract
  Users::JoinsController from overloaded UsersController" (DHH): *"Good code smell is
  when the before_action callbacks stack up but can't be shared across actions"*.
  4602cd3cd "Add verified_at timestamp to use for spam prevention" added
  `Users::VerificationsController`: a user is verified once they prove the email
  (magic link or an already-signed-in identity). Owners are verified at creation.
- **Account names are generated, not asked for.** `AccountNameGenerator` produces
  "Kevin's Fizzy" and then "Kevin's 2nd Fizzy" (1b1a17b93 "Auto-generate account
  names"), so the form asks only for a name.
- **Self-hosted installs close signup after the first account.** `accepting_signups?
  = multi_tenant || Account.none?` (eb8655dc8, a5580666a). After that, people join
  through join codes.

**Reusable vs Fizzy-specific:** reusable: the two-step form model with validation
contexts, the `create_with_owner` factory, hook methods for the paid tier, a
singular `JoinCode` with `redeem_if` under a lock, verification as its own resource.
Fizzy-specific: Queenbee, the "Fizzy" name suffix, and seeding a customer template
board (`Account::Seeder`).

## Testing

- `test/models/signup_test.rb` runs `Signup#complete` inside `Current.without_account`
  and stubs only the slow seeding (`Account.any_instance.expects(:setup_customer_template)`).
  It asserts that `signup.account` and `signup.user` exist and that an invalid name
  adds errors.
- `test/models/account/join_code_test.rb` covers `redeem_if`, the usage limit, and
  `reset`. `test/models/identity/joinable_test.rb` checks the `join` return value
  (true only for a new user).
- `test/controllers/join_codes_controller_test.rb` covers new/inactive/invalid codes,
  an existing identity, a signed-in identity being redirected to verification, a
  different identity terminating the session, an invalid email, and the rate limit.
- `with_multi_tenant_mode(true)` in `test/test_helpers/session_test_helper.rb` turns
  signups on.
- `saas/test/models/signup_test.rb` tests the prepended hooks separately.

## Reuse recipe

1. Write `app/models/signup.rb` as an `ActiveModel::Model`, with one validation context per step and verbs named for the steps.
2. Put the multi-insert in `Account.create_with_owner(account:, owner:)` and have `Signup#complete` call it. Clean up and report on any failure.
3. Leave `create_tenant` / `handle_account_creation_error` as private no-op hooks, and `prepend` billing from an engine or initializer.
4. Controllers: `signups#new/create` (email → magic link `for: :sign_up`), then `signups/completions#new/create` (name → `complete` → redirect into the account's slug).
5. Invitations: `has_one :join_code` created `after_create`. Use `GET/POST /join/:code`, `redeem_if { identity.join(account) }` under `with_lock`, and `resource :join_code` for admins (`destroy` rotates the code).
6. Verify joined users in a separate resource before trusting them with outbound email.
7. Gate open signup with one predicate (`accepting_signups?`).

## Related

[[components/authentication]] · [[components/accounts-tenancy]] · [[components/access]] ·
[[patterns/model-concerns]] · [[patterns/state-as-resource]] · [[voice/dhh-refactors]]
