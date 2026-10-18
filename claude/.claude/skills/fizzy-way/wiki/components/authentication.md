---
title: Authentication
use_when: [login, sign in, authentication, magic link, passwordless, one-time code, passkeys, webauthn, sessions, session cookie, API token, bearer token, personal access token, Identity vs User, one email many accounts, devise alternative, require_authentication, allow_unauthenticated_access]
sources:
  - app/controllers/concerns/authentication.rb, app/controllers/concerns/authentication/via_magic_link.rb
  - app/controllers/concerns/authorization.rb, app/helpers/login_helper.rb
  - app/controllers/sessions_controller.rb, app/controllers/sessions/*.rb
  - app/controllers/my/access_tokens_controller.rb, app/controllers/my/passkeys_controller.rb, app/controllers/my/passkey_challenges_controller.rb
  - app/models/identity.rb, app/models/identity/*.rb, app/models/session.rb, app/models/magic_link.rb, app/models/magic_link/code.rb
  - app/models/current.rb, app/channels/application_cable/connection.rb
  - lib/action_pack/passkey.rb, lib/action_pack/passkey/*.rb, lib/action_pack/web_authn/
  - test/controllers/sessions/*, test/controllers/api_test.rb, test/test_helpers/session_test_helper.rb
  - commits 3399e4513, edf837fed, fd7a9330e, 660fcff55, 895b0e13b, 88902485e, 96b62d6ec, 0ce3a8577, 79fc57a82, b6edb93c4, 7ab06d1db, 2311efd03, c9ebb79db, 017bcc9ce; PRs #1766, #2086, #2623
snapshot: 27d0d2e6b
---

# Authentication

## Answer

The app hand-rolls authentication, starting from the Rails 8 sessions generator. There
is no Devise. A global **`Identity`** (one per email address) authenticates. A
per-account **`User`** is what the rest of the domain sees. Login is **passwordless**:
a 6-character emailed code (`MagicLink`) or a **passkey**. Success creates a
`Session` row and puts its `signed_id` in a permanent, httponly cookie. API clients
send a per-identity **`Identity::AccessToken`** as a Bearer token, with `read` or
`write` permission. All of this lives in one controller concern, `Authentication`,
whose class macros (`allow_unauthenticated_access`, `require_unauthenticated_access`,
`disallow_account_scope`) state each controller's policy in one line.
`Current.session=` derives `Current.identity`, and `Current.identity=` derives
`Current.user` for the account in the URL.

## Shape

```
app/models/
  identity.rb                 # email_address; has_many :users, :sessions, :magic_links, :access_tokens; has_passkeys
  identity/access_token.rb    # has_secure_token; enum permission read/write; allows?(method)
  identity/joinable.rb        # join(account) → find_or_create User
  identity/transferable.rb    # one-time transfer tokens (move a login to another device)
  identity/transfer.rb
  session.rb                  # belongs_to :identity  (that's all)
  magic_link.rb               # code, expires_at (15 min), purpose sign_in/sign_up; consume
  magic_link/code.rb          # base32 generate; sanitize (O→0, I/L→1)
  user.rb                     # belongs_to :account, :identity (optional — nulled on deactivate)
  current.rb                  # session= → identity= → user
app/controllers/
  concerns/authentication.rb              # the policy + session plumbing
  concerns/authentication/via_magic_link.rb  # pending-auth cookie, dev code leak guard
  concerns/authorization.rb               # account membership check, ensure_admin/staff
  sessions_controller.rb                  # new/create (email → code), destroy
  sessions/magic_links_controller.rb      # show (enter code), create (consume)
  sessions/passkeys_controller.rb         # create
  sessions/menus_controller.rb            # account picker (untenanted)
  sessions/transfers_controller.rb        # sign in via transfer token
  my/access_tokens_controller.rb          # personal API tokens
  my/passkeys_controller.rb               # register/rename/delete passkeys
  my/passkey_challenges_controller.rb     # < ActionPack::Passkey::ChallengesController
lib/action_pack/passkey.rb, passkey/{holder,request,form_helper,challenges_controller}.rb
lib/action_pack/web_authn/...             # in-house WebAuthn, no gem
```

Routes (untenanted, reached without an account prefix):

```ruby
resource :session do
  scope module: :sessions do
    resources :transfers
    resource :magic_link
    resource :menu
    resource :passkey, only: :create
  end
end

namespace :my do
  resource :passkey_challenge, only: :create
  resource :identity, only: :show
  resources :access_tokens
  resources :passkeys, except: %i[ show new ]
end
```

## Key code

The concern sets the default (everything requires an account and a login), and
controllers opt out by name:

```ruby
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_account # Checking and setting account must happen first
    before_action :require_authentication
    helper_method :authenticated?
    etag { Current.identity.id if authenticated? }
    include Authentication::ViaMagicLink, LoginHelper
  end

  class_methods do
    def require_unauthenticated_access(**options)
      allow_unauthenticated_access **options
      before_action :redirect_authenticated_user, **options
    end

    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
      before_action :resume_session, **options
      allow_unauthorized_access **options
    end

    def disallow_account_scope(**options)
      skip_before_action :require_account, **options
      before_action :redirect_tenanted_request, **options
    end
  end

  private
    def require_authentication
      resume_session || authenticate_by_bearer_token || request_authentication
    end

    def resume_session
      if session = Session.find_signed(cookies.signed[:session_token])
        set_current_session session
      end
    end

    def authenticate_by_bearer_token
      if request.authorization.to_s.include?("Bearer")
        if bearer_token_authenticatable_request?          # request.format.json?
          authenticate_or_request_with_http_token do |token|
            if identity = Identity.find_by_permissable_access_token(token, method: request.method)
              Current.identity = identity
            end
          end
        else
          request_http_token_authentication
        end
      end
    end

    def start_new_session_for(identity)
      identity.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        set_current_session session
      end
    end

    def set_current_session(session)
      Current.session = session
      cookies.signed.permanent[:session_token] = { value: session.signed_id, httponly: true, same_site: :lax }
    end
end
```

*(Condensed. The file also has `terminate_session`, `after_authentication_url`, and redirects.)*

A controller states its policy at the top:

```ruby
class SessionsController < ApplicationController
  disallow_account_scope
  require_unauthenticated_access except: :destroy
  rate_limit to: 10, within: 3.minutes, only: :create, with: :rate_limit_exceeded
end
# Public::BaseController (published boards) is just: allow_unauthenticated_access
```

Magic-link sign-in is two requests. The email step sets a signed, expiring
`pending_authentication_token` cookie that holds the email address. The code step
consumes the link and checks that it belongs to *that* email:

```ruby
class Sessions::MagicLinksController < ApplicationController
  disallow_account_scope
  require_unauthenticated_access
  rate_limit to: 10, within: 15.minutes, only: :create, with: :rate_limit_exceeded
  before_action :ensure_that_email_address_pending_authentication_exists

  def create
    if magic_link = MagicLink.consume(code)
      authenticate magic_link
    else
      invalid_code
    end
  end

  private
    def authenticate(magic_link)
      if ActiveSupport::SecurityUtils.secure_compare(email_address_pending_authentication || "", magic_link.identity.email_address)
        sign_in magic_link
      else
        email_address_mismatch
      end
    end
end

class MagicLink < ApplicationRecord
  CODE_LENGTH = 6
  EXPIRATION_TIME = 15.minutes
  enum :purpose, %w[ sign_in sign_up ], prefix: :for, default: :sign_in

  def self.consume(code) = active.find_by(code: Code.sanitize(code))&.consume
  def consume
    destroy
    self
  end
end
```

The access token is a model with one predicate:

```ruby
class Identity::AccessToken < ApplicationRecord
  belongs_to :identity
  has_secure_token
  enum :permission, %w[ read write ].index_by(&:itself), default: :read

  def allows?(method)
    method.in?(%w[ GET HEAD ]) || write?
  end
end
```

A new token is shown once. `create` redirects to `my_access_token_path(expiring_id)`,
where the ID is signed with `message_verifier(:access_tokens)` and
`expires_in: 10.seconds`.

Passkeys are a framework-shaped library in `lib/action_pack/`. The app touches it in
three places: `has_passkeys` on the holder, `include ActionPack::Passkey::Request` in
controllers, and the view helper `passkey_sign_in_button`:

```ruby
class Identity < ApplicationRecord
  has_passkeys name: :email_address, display_name: -> { Current.user&.name || email_address }
end

class Sessions::PasskeysController < ApplicationController
  include ActionPack::Passkey::Request

  def create
    if credential = ActionPack::Passkey.authenticate(passkey_authentication_params)
      start_new_session_for credential.holder
      ...
```

## Why

- **Start from the generator, not a gem.** e3983d5bb "Use Rails' new sessions
  generator to replace the existing setup" (2024). Everything since has been edits
  to that generated code: `Session` model, signed cookie, `Authentication` concern.
- **Identity is global, User is per account.** 3399e4513 "Introduce an "Identity"
  model to ease login": *"make it easy to login without a tenanted URL and to jump
  between tenants"*. When tenants were separate SQLite databases, a cross-tenant
  identity was required. After the move to one database it stayed, because it models
  the domain: one person, many account memberships. The intermediate `Membership`
  join was dropped (edf837fed "Drop memberships"), and credentials moved off `User`
  (fd7a9330e "Remove email_address & password_digest from User"). `User` keeps
  `name`, `role`, and `active`. Deactivation nulls `identity_id`, so history stays
  attached to a person-shaped record. See [[components/accounts-tenancy]].
- **Passwordless by default.** There is no password column anywhere. Magic links
  reuse the email flow they already need for invitations and signup, and a code
  (rather than a clickable link) works when the email is opened on another device
  (inference). 2311efd03 "Make sign up Magic Links work across devices" added
  `purpose` for exactly that case.
- **Hardened step by step, each fix small.** b6edb93c4 "Pin sign in attempts to the
  current session": *"This makes it way more difficult to brute-force a magic
  link."* That added the pending-auth cookie and the `secure_compare` (PR #2086).
  7ab06d1db "Use cryptographically secure randomness for Magic Link code generation"
  replaced `#sample` (*"uses PRNG under the hood"*). Per-action `rate_limit` (Rails
  8 built-in) covers every sign-in endpoint. c9ebb79db "Add some protections around
  sharing the magic link in development" became the `after_action` that raises if a
  code ever lands in the flash outside development.
- **Unknown emails get a fake magic link.** When signups are closed,
  `redirect_to_fake_session_magic_link` renders the same "check your email" page,
  so the endpoint doesn't reveal which emails exist (inference from the code).
- **API tokens belong to the identity, not a session.** DHH's sequence on Dec 1–2,
  2025 (PR #1766 "Add basic API"): db29562c4 "Tie access token directly to session",
  then 895b0e13b "Drop the need for access tokens to have a session", 660fcff55
  "Authenticate api requests without needing a session", 88902485e "Access tokens
  are strictly personal" (moved from `Users::` to `My::`), 96b62d6ec "Only allow new
  token to be viewed within 10 seconds", and 0ce3a8577 "Only allow writing when the
  access token has permission". `Current.identity=` resolving the user is what lets
  a session-less token work in any account URL.
- **Use the framework's built-in.** 79fc57a82 "Use built-in
  authenticate_or_request_with_http_token" replaced a hand-split `Authorization`
  header and moved the permission check into `Identity.find_by_permissable_access_token`.
  See [[voice/dhh-refactors]] §3.
- **Passkeys without a gem, shaped like Rails.** PR #2623 "Passkeys" implemented
  WebAuthn in `lib/action_pack/web_authn` and `lib/action_pack/passkey` (no
  `webauthn` gem in the Gemfile). The polish commit 017bcc9ce "Polish up Passkey
  interface" lists the moves: *"Extract framework library out of controllers"*,
  *"Introduce has_passkeys"*, *"Rename identity to holder in Passkey"*, *"Inline
  anemic methods"*. The API is written to look like a future Rails framework piece:
  a polymorphic `holder`, rdoc comments, and config under
  `config.action_pack.passkey` (inference about intent).
- **Policy as class macros, named for intent.** `disallow_account_scope` arrived in
  89d1299ec "Fix authentication on "untenanted" controllers", whose message admits:
  *"trying out the name "disallow_account_scope" for this, but I don't think it's
  quite right yet."* 87d9c3cd0 "Make unauthenticated access permit unauthorized
  access" made `allow_unauthenticated_access` imply skipping the account-membership
  check as well, so one macro covers both.

**Reusable vs Fizzy-specific:** reusable: Identity/User split, `Session` row plus
signed cookie, the `Authentication` concern and its macros, magic-link code plus
pending cookie, identity-scoped bearer tokens with read/write. Fizzy-specific: the
`ActionPack::Passkey` library (copy it, or use a gem), session transfers for the
mobile app, the `staff?` flag, and the saas engine's extra `Authorization::Controller`.

## Testing

- `sign_in_as(:kevin)` in `test/test_helpers/session_test_helper.rb` runs the real
  flow (`identity.send_magic_link`, then `post session_path`, then `post
  session_magic_link_url` with the code) inside `untenanted { }`. Tests never stub
  authentication.
- `test/controllers/sessions/magic_links_controller_test.rb` covers sign-in code,
  sign-up code, a code that belongs to another user, an invalid code, the JSON
  variants, and an expired pending token.
- `test/controllers/api_test.rb` uses `{ "HTTP_AUTHORIZATION" => "Bearer #{token}" }`.
  One test is "changing data requires a write-endowed access token".
- `test/controllers/controller_authentication_test.rb` checks that a request with no
  slug redirects to the menu, and a slug without a session redirects to login.
- Passkeys: `test/controllers/sessions/passkeys_controller_test.rb`,
  `test/controllers/my/passkeys_controller_test.rb`, `test/lib/action_pack/passkey_test.rb`,
  and `test/test_helpers/webauthn_test_helper.rb`.
- Model-level work that needs a user: `with_current_user(:david) { ... }`, or set
  `Current.session = sessions(:david)` directly.

## Reuse recipe

1. Run `bin/rails generate authentication`, then rename the generated `User` to `Identity` and add a per-tenant `User` with `belongs_to :identity, optional: true`.
2. `Current`: `attribute :session, :identity, :user, :account`. `session=` sets identity, and `identity=` sets `user = identity.users.find_by(account:)`.
3. `Authentication` concern: `require_account`, then `require_authentication` (cookie, then bearer, then redirect). Add the class macros `allow_unauthenticated_access`, `require_unauthenticated_access`, `disallow_account_scope`.
4. `MagicLink` model (code, expiry, purpose, `consume` destroys it). Email the code. Pin the attempt with a signed, expiring cookie that holds the email, and `secure_compare` on consume. Add `rate_limit` to every endpoint.
5. `Identity::AccessToken` with `has_secure_token` and a read/write enum. Authenticate with `authenticate_or_request_with_http_token`, only for JSON requests. Show the token once through a short-lived signed ID.
6. Passkeys: put `has_passkeys` on `Identity`. Use a sessions/passkeys `create`, plus a `my/passkeys` CRUD controller.
7. Authorization (account membership, admin) is a separate concern. See [[components/access]].

## Related

[[components/accounts-tenancy]] · [[components/signup]] · [[components/access]] ·
[[patterns/current-attributes]] · [[voice/dhh-refactors]] · [[testing/controller-and-system]]
