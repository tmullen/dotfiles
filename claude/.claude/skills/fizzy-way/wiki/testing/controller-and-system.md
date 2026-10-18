---
title: Controller and system tests
use_when: [controller test, integration test, request spec, sign in helper, login in tests, account slug in test URL, script_name, multi-tenant test, API token test, turbo_stream response test, system test, capybara, smoke test, test_helper layout, test helpers folder]
sources:
  - test/test_helper.rb (IntegrationTest / SystemTestCase setup, without_action_dispatch_exception_handling)
  - test/test_helpers/session_test_helper.rb, card_test_helper.rb, trusted_types_violations_test_helper.rb
  - test/application_system_test_case.rb, test/system/*.rb (9 files)
  - test/controllers/**/*_test.rb (107 files), test/integration/*.rb
  - config/ci.rb
  - commits 006aa4d6b, e0965d477, b6edb93c4, 7adbd8d63, fd21838f8, 883a22594, 5dec991d7, 338ff496d, 248fc5d3e, b23a5d0b7
snapshot: 55bb38335
---

# Controller and system tests

## Answer

Controller tests are `ActionDispatch::IntegrationTest`s, one file per controller,
mirroring `app/controllers` (`Cards::ClosuresControllerTest`). A global `setup` puts
the fixture account's slug into `default_url_options[:script_name]`, so ordinary
route helpers (`card_closure_path(card)`) produce tenant URLs. `untenanted { }`
switches it off for global routes such as sessions and signup. `sign_in_as :kevin`
runs the **real magic-link login** over HTTP. Each test asserts the effect on the
model (`assert_changes -> { card.reload.closed? }`) plus the response, and covers
each format the action serves (`as: :turbo_stream`, `as: :json`). **System tests are
rare on purpose**: 9 files, covering a smoke path and JS/Turbo behavior that only a
browser can show.

## Shape

```
test/
  test_helper.rb
    ActiveSupport::TestCase        # fixtures, helpers, Current.account = accounts("37s"), Current.clear_all
    ActionDispatch::IntegrationTest   # setup: script_name = "/#{FixtureSet.identify("37signals")}"
                                      # private without_action_dispatch_exception_handling
    ActionDispatch::SystemTestCase    # same script_name for system tests
  test_helpers/
    session_test_helper.rb     # sign_in_as, logout_and_sign_in_as, sign_out, untenanted,
                               #   with_current_user, with_multi_tenant_mode, parsed_cookies
    card_test_helper.rb        # assert_card_container_rerendered(card)
    trusted_types_violations_test_helper.rb   # system-test-only inventory (CSP)
  application_system_test_case.rb   # headless Chrome, sign_in_as via session transfer, fill_in_lexxy
  controllers/
    cards_controller_test.rb
    cards/closures_controller_test.rb  cards/pins_controller_test.rb ...   # namespaced like app/
    concerns/current_timezone_test.rb   # controller concerns tested through a real route
    api_test.rb                          # bearer-token auth, JSON
  integration/                 # cross-cutting HTTP checks: CSP, blob authorization, XSS
  system/
    smoke_test.rb              # join an account, create a card, upload an attachment
    card_refresh_test.rb  board_keyboard_focus_test.rb  column_pagination_refresh_test.rb ...
```

## Key code

Tenant URLs for every integration test (`test/test_helper.rb`):

```ruby
class ActionDispatch::IntegrationTest
  setup do
    integration_session.default_url_options =
      integration_session.default_url_options.merge(script_name: "/#{ActiveRecord::FixtureSet.identify("37signals")}")
  end
end
```

Sign-in goes through the real flow, with assertions that make a broken login obvious
(`test/test_helpers/session_test_helper.rb`, condensed):

```ruby
def sign_in_as(identity)
  cookies.delete :session_token
  identity = identity.is_a?(User) ? identity.identity : identities(identity)   # condensed

  identity.send_magic_link
  magic_link = identity.magic_links.order(id: :desc).first

  untenanted do
    post session_path, params: { email_address: identity.email_address }
    post session_magic_link_url, params: { code: magic_link.code }
  end

  assert_response :redirect, "Posting the Magic Link code should grant access"
  assert_not_nil cookies.get_cookie("session_token"), "Expected session_token cookie to be set after sign in"
end

def untenanted(&block)
  Rails.application.reload_routes_unless_loaded
  original_options = integration_session.default_url_options
  integration_session.default_url_options = original_options.merge(script_name: "")
  yield
ensure
  integration_session.default_url_options = original_options
end
```

A typical singular-resource controller test. It asserts the model change, the Turbo
response, and the JSON variant:

```ruby
class Cards::ClosuresControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
  end

  test "create" do
    card = cards(:logo)

    assert_changes -> { card.reload.closed? }, from: false, to: true do
      post card_closure_path(card), as: :turbo_stream
      assert_card_container_rerendered(card)      # assert_turbo_stream action: :replace, target: dom_id(card, :card_container)
    end
  end

  test "create as JSON" do
    post card_closure_path(cards(:logo)), as: :json
    assert_response :no_content
    assert cards(:logo).reload.closed?
  end
end
```

Access rules are tested by changing the fixture world, then requesting again:

```ruby
test "users can only see cards in boards they have access to" do
  get card_path(cards(:logo))
  assert_response :success

  boards(:writebook).update! all_access: false
  boards(:writebook).accesses.revoke_from users(:kevin)

  get card_path(cards(:logo))
  assert_response :not_found
end
```

Role checks switch users mid-test with `logout_and_sign_in_as :jz` and then assert
`:forbidden`. API tests pass a header env: `get boards_path(format: :json), env: { "HTTP_AUTHORIZATION" => "Bearer #{token}" }`.

System tests sign in through a shortcut, because the login flow already has its own
tests:

```ruby
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :chrome_headless, screen_size: [ 1200, 1000 ]   # SYSTEM_TESTS_BROWSER=1 → visible chrome

  private
    def sign_in_as(user)
      visit session_transfer_url(user.identity.transfer_id, script_name: nil)
      assert_current_path root_path
    end
end
```

CI (`config/ci.rb`) runs system tests in a separate step with `PARALLEL_WORKERS=1`
(*"system tests can't run reliably in parallel"*). GitHub Actions runs the suite against
both SQLite and MySQL.

## Why

- **Integration tests, not functional tests.** Every controller test goes through the
  full stack: routing, the `AccountSlug::Extractor` middleware, and authentication. This
  is what catches tenancy mistakes (inference). Mike Dalessio's 006aa4d6b "Tests need
  to set up the script_name properly" set the slug once in the base class, so no test
  has to remember it. e0965d477 "Assign default_url_options instead of mutating it"
  kept that working after Rails froze the hash, and `untenanted` now restores *"the
  whole hash rather than the one key"*.
- **Log in the way users do.** The helper sends a real magic link and posts the code.
  When b6edb93c4 "Pin sign in attempts to the current session" hardened login against
  brute force, the helper picked up the new `post session_path` step. A shortcut
  helper would have kept passing while the real flow changed (inference). ffe9fdb09
  "test: assert on the redirect in the login helper" added the assertion so a failed
  login surfaces inside the helper, not as a confusing failure three lines later.
- **Name the assertion for what the user sees.** DHH's 7adbd8d63 "Use card
  rerendering instead of redirects" changed card actions to re-render the card
  container and added `assert_card_container_rerendered` in the same commit. His
  fd21838f8 "Add assert_in_body helper" carried the note *"Remove when upstream in
  Rails has landed (https://github.com/rails/rails/pull/54938)"*, and 883a22594 "Use
  upstreamed assert_in_body" deleted it. A missing assertion goes into the framework,
  not into a private DSL.
- **Test every format the action serves.** `as: :turbo_stream` appears 49 times and
  JSON 284 times in `test/controllers`. The same controller serves the web UI and the
  API, so each gets its own test. → [[patterns/state-as-resource]]
- **Few system tests, on purpose.** DHH: *"System tests remain as slow, brittle, and
  full of false negatives as they did a decade ago."* and *"System tests work well
  for the top-level smoke test."* The hard part is *"not testing business logic,
  which model and controller tests do better and cheaper"*. ([System tests have failed](https://world.hey.com/dhh/system-tests-have-failed-d90af718), 2024)
  Fizzy follows this. DHH's 338ff496d "No system tests yet" commented the step out of
  `bin/ci`. Mike Dalessio's 5dec991d7 "Introduce a few system tests" brought them
  back with a stated scope: *"exercise active storage and action cable / turbo
  streams, both of which have been brittle when making changes to tenanting."* Every
  system test added since is a regression test for browser-only behavior: Turbo
  morph refreshes (d37480d06), focus restoration (ce07c170f), pagination on refresh
  (a703bf1de), back-link navigation (248fc5d3e).
- **Don't leak global config between tests.** Jeremy Daer's b23a5d0b7 "Fix flaky
  tests caused by leaky show_exceptions twiddling (#2028)": Rails memoizes
  `@app_env_config`, so `without_action_dispatch_exception_handling` has to clear it on
  the way in and on the way out. The same rule shaped `with_current_user`, which
  restores the previous session instead of calling `Current.clear_all` (e3d86bb21).
- **Parallel by default.** `parallelize workers: :number_of_processors, work_stealing: …`
  (85bd5c2df "Rails seeded parallel tests (#2037)": *"Enable work stealing by default
  for a tiny speedup at the cost of small loss in reproducibility."*). Fixtures are what
  make this cheap: every worker gets the same world inside a transaction (inference).

**Reusable vs Fizzy-specific.** Reusable: integration tests per controller, a real
login helper, global URL options for path-based tenancy, model-effect assertions,
per-format tests, a handful of smoke and JS-behavior system tests. Fizzy-specific: the
magic-link and session-transfer mechanics, the Trusted Types inventory, and the
SQLite and MySQL CI matrix.

## Testing

This page describes the tests themselves. Files worth copying:
- `test/controllers/cards/closures_controller_test.rb` — the smallest complete example.
- `test/controllers/cards_controller_test.rb` — access (`:not_found`) and role (`:forbidden`) checks.
- `test/controllers/api_test.rb` — token auth and `untenanted` JSON login.
- `test/controllers/join_codes_controller_test.rb` — `without_action_dispatch_exception_handling`, `assert_in_body`, rate limiting with a stubbed cache counter.
- `test/system/smoke_test.rb` — the end-to-end smoke path.

## Reuse recipe

1. Write controller tests as `ActionDispatch::IntegrationTest`, one per controller, using the same namespaces as `app/controllers`.
2. With path-based tenancy, set `default_url_options[:script_name]` in a global `setup` and add an `untenanted { }` helper for global routes. Merge and reassign the hash rather than mutating it.
3. Write `sign_in_as(fixture_label)` so it runs the real login over HTTP and asserts it worked. Add `logout_and_sign_in_as` for role switches.
4. In each test, assert the domain effect (`assert_changes -> { record.reload.state? }`) and the response. Write one test per format (`as: :turbo_stream`, `as: :json`).
5. Test authorization by changing fixture state (revoke access, change role) and asserting `:not_found` or `:forbidden`.
6. Give each repeated response assertion a domain name in `test/test_helpers/`. Upstream it to Rails if it is generic.
7. Keep system tests to one smoke file plus regression tests for JS/Turbo behavior. Run them serially in their own CI step.
8. Any helper that changes global state (config, `Current`, ENV, class attributes) must restore the exact previous value in `ensure`.

## Related

[[testing/fixtures]] · [[testing/model-tests]] · [[components/accounts-tenancy]] ·
[[components/authentication]] · [[patterns/controller-scoping]] · [[patterns/state-as-resource]] ·
[[patterns/turbo-and-caching]]
