---
title: Controller scoping — load through Current.user, respond in two formats
use_when: [authorization, before_action load parent, nested controller, set_card, scoping records to user, CanCan, Pundit, policy object, 404 vs 403, API json alongside html, respond_to, turbo_stream response, render vs redirect, thin controller, API endpoint]
sources:
  - app/controllers/concerns/{card_scoped,board_scoped,column_scoped,filter_scoped,day_timelines_scoped,authorization,request_forgery_protection,turbo_flash}.rb
  - app/controllers/application_controller.rb, app/controllers/public/base_controller.rb
  - app/controllers/cards_controller.rb, app/controllers/boards_controller.rb
  - app/controllers/cards/*.rb, app/controllers/boards/*.rb
  - app/models/user/accessor.rb, app/models/user/role.rb, app/models/card.rb (to_param)
  - app/views/cards/_card.json.jbuilder, app/views/cards/show.json.jbuilder
  - test/controllers/cards_controller_test.rb, test/controllers/cards/closures_controller_test.rb, test/controllers/api_test.rb, test/controllers/api/flat_json_params_test.rb
  - commits 366fe0611, 7adbd8d63, ac9cbad4f, 3e1a2bcc7, f5977522c, 65d04f681, fcad4518d, 43069b1ea, f5305b2fe, 983a19fd8, f0c0a87c7, efbd2cc3d, 723c8180b
snapshot: 27d0d2e6b
---

# Controller scoping — load through `Current.user`, respond in two formats

## Answer

Every nested controller includes a **`<Parent>Scoped` concern** that adds a
`before_action` and loads the parent **through the current user's associations**
(`Current.user.accessible_cards.find_by!(number: params[:card_id])`). That lookup *is*
the read authorization: a record you can't see raises `RecordNotFound` → 404. Anything
stricter (admin, creator) is a named `ensure_*` before_action that returns `head
:forbidden`. Actions call one model method, then `respond_to` with `turbo_stream` for
the app and `json` for the API — the same controller, the same action. For card
mutations the turbo response is usually `render_card_replacement`, a morphing replace
of the card container, not a redirect.

## Shape

```
app/controllers/
  application_controller.rb       # Authentication, Authorization, CurrentRequest, TurboFlash, ...
  concerns/
    card_scoped.rb                # set_card, set_board, render_card_replacement, capture_card_location
    board_scoped.rb               # set_board, ensure_permission_to_admin_board
    column_scoped.rb              # set_column via Current.user.accessible_columns
    filter_scoped.rb              # @filter from saved id or params; @user_filtering
    day_timelines_scoped.rb       # includes FilterScoped; @day_timeline
    authorization.rb              # account/user active gate; allow_unauthorized_access
  cards/*_controller.rb           # 21 controllers include CardScoped
  boards/*_controller.rb          # 14 include BoardScoped
  public/base_controller.rb       # unauthenticated variant: load by publication key
app/models/user/accessor.rb       # has_many :accessible_cards / :accessible_columns through :boards
app/models/user/role.rb           # can_administer_board?(board), can_administer_card?(card)
app/views/**/*.json.jbuilder      # API representation next to the HTML templates
```

Routes nest one level and let `scope module:` pick the namespace:
`resources :cards { scope module: :cards { resource :closure; resources :comments { resources :reactions, module: :comments } } }`.

## Key code

The whole concern:

```ruby
module CardScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_card, :set_board
  end

  private
    def set_card
      @card = Current.user.accessible_cards.find_by!(number: params[:card_id])
    end

    def set_board
      @board = @card.board
    end

    def render_card_replacement
      render turbo_stream: turbo_stream.replace([ @card, :card_container ],
        partial: "cards/container", method: :morph, locals: { card: @card.reload })
    end
    ...
end
```

The associations that make it work are plain `has_many :through`:

```ruby
module User::Accessor
  included do
    has_many :accesses, dependent: :destroy
    has_many :boards, through: :accesses
    has_many :accessible_columns, through: :boards, source: :columns
    has_many :accessible_cards, through: :boards, source: :cards
    has_many :accessible_comments, through: :accessible_cards, source: :comments
  end
end
```

Stricter checks are named before_actions backed by a predicate on the user:

```ruby
module BoardScoped
  included { before_action :set_board }

  private
    def set_board
      @board = Current.user.boards.find(params[:board_id])
    end

    def ensure_permission_to_admin_board
      unless Current.user.can_administer_board?(@board)
        head :forbidden
      end
    end
end

class Boards::PublicationsController < ApplicationController
  include BoardScoped
  before_action :ensure_permission_to_admin_board
  ...
end
```

One action, two clients. The API shares the controller, the strong params, and the
model call; only the response differs:

```ruby
class Cards::CommentsController < ApplicationController
  wrap_parameters :comment, include: %i[ body created_at ]
  include CardScoped

  before_action :set_comment, only: %i[ show edit update destroy ]
  before_action :ensure_creatorship, only: %i[ edit update destroy ]

  def create
    @comment = @card.comments.create!(comment_params)

    respond_to do |format|
      format.turbo_stream
      format.json { render :show, status: :created, location: card_comment_path(@card, @comment, format: :json) }
    end
  end

  private
    def set_comment
      @comment = @card.comments.find(params[:id])     # child loaded through the scoped parent
    end

    def ensure_creatorship
      head :forbidden if Current.user != @comment.creator
    end

    def comment_params
      params.expect(comment: [ :body, :created_at ])
    end
end
```

When HTML and JSON genuinely differ, each branch says so inline:

```ruby
def create                                  # CardsController
  respond_to do |format|
    format.html do
      card = Current.user.draft_new_card_in(@board)
      redirect_to card_draft_path(card)
    end

    format.json do
      @card = @board.cards.create! card_params.merge(creator: Current.user, status: "published")
      render :show, status: :created, location: card_path(@card, format: :json)
    end
  end
end
```

## Why

- **Scoping is authorization.** Loading through `Current.user` means the access rule is
  defined once (in `Access` rows and `has_many :through`) and enforced by every lookup.
  There's no policy layer. DHH's 366fe0611 "Access control has already been done
  through the card" replaced `Current.user.collections.find(@card.collection_id)` with
  `@card.collection`: once the card loaded through the user, its parent is safe.
- **404, not 403, for things you can't see.** `find`/`find_by!` raise `RecordNotFound`,
  so an inaccessible card is indistinguishable from a missing one
  (`test/controllers/cards_controller_test.rb`: "users can only see cards in boards they
  have access to" → `assert_response :not_found`). 403 is reserved for "you can see it
  but can't do this" (`ensure_creatorship`, `ensure_permission_to_admin_board`). (inference
  on intent; the behavior is in the tests)
- **One loader per parent, shared by every child controller.** DHH's f5977522c "Use
  shared callback to set card" moved inline `@card = ...` lines into a `set_card`
  before_action; fcad4518d "Split callbacks for easier overwriting" split
  `set_collection_and_card` into two so a subclass can override one. 65d04f681 "DRY up
  the public controllers by introducing a shared base class" replaced
  `PublicCardScoped`/`PublicCollectionScoped` with `Public::BaseController`: when every
  controller in a namespace shares the loader *and* auth mode, a base class beats a concern.
- **A stack of unshared before_actions means a missing controller.** DHH's 43069b1ea
  "Extract Users::JoinsController from overloaded UsersController", body: *"Good code
  smell is when the before_action callbacks stack up but can't be shared across
  actions"*. See [[patterns/state-as-resource]].
- **Re-render the thing, don't redirect.** DHH's 7adbd8d63 "Use card rerendering instead
  of redirects" replaced `redirect_to @card` with a turbo-stream replace in closures,
  assignments, engagements; 62088b66d "Suffix qualifier is unnnecessary" and ac9cbad4f "I
  like this even better" settled the name `render_card_replacement`. Jorge's 3e1a2bcc7
  "Use morphing to replace the card and exclude turbo frames from being replaced" added
  `method: :morph` (body: *"Reconnecting the frames result in a visible flickering."*).
  When a mutation affects more than the card (closing moves it between columns), the
  action uses a `.turbo_stream.erb` template instead. See [[patterns/turbo-and-caching]].
- **URLs use the human number, not the UUID.** Mike Dalessio's f5305b2fe "Use Card
  `number` as the model param": `Card#to_param` returns `number.to_s`, and every loader
  is `find_by!(number:)`. Fizzy-specific (cards have per-account sequential numbers),
  but the trick — override `to_param`, change the finder in one concern — is general.
- **The API is the same controllers.** DHH started it in 983a19fd8 "Create cards via
  API" (a `format.json` branch next to `format.html`, plus `show.json.jbuilder`), then
  f0c0a87c7 "Return json URLs for API actions" (`location: board_path(@board, format:
  :json)`) and efbd2cc3d "Allow API JSON requests to sidestep csrf protection". Jeremy
  Daer's 723c8180b "Add JSON response format for full SDK/CLI coverage (#2675)" filled in
  the rest: *"Add respond_to blocks with JSON format to 14 controllers"*, with JSON
  callers getting `head :no_content` (or `:created`). Today 57 of 102 controllers have
  `format.json`.
- **Flat JSON must work too.** Jeremy's 71a1ee703 "Wrap comment params for flat JSON
  payloads (#2679)": `wrap_parameters` auto-detection misses virtual attributes like an
  Action Text `body`, so controllers declare `wrap_parameters :comment, include: [...]`
  explicitly and keep `params.expect(comment: [...])`.
- **Concerns are for loading, not for logic.** Controller concerns hold `set_*`,
  `ensure_*`, and response helpers that need those ivars. Behavior stays in the model
  (`@card.close`). STYLE.md: *"thin controllers directly invoking a rich domain model"*.

## Testing

- Integration tests (`ActionDispatch::IntegrationTest`) sign in a fixture user
  (`sign_in_as :kevin`) and hit real routes. `test_helper.rb` sets
  `default_url_options` with the account `script_name`, so `card_closure_path(card)`
  works as in the app.
- Every mutation is tested twice: `post card_closure_path(card), as: :turbo_stream` with
  `assert_card_container_rerendered(card)`, and `as: :json` with `assert_response
  :no_content` (`test/controllers/cards/closures_controller_test.rb`).
- Access: revoke the fixture user's access, then assert `:not_found`
  (`test/controllers/cards_controller_test.rb`). Permission: assert `:forbidden`
  (`test/controllers/boards/publications_controller_test.rb`).
- API auth and Location headers: `test/controllers/api_test.rb` (bearer tokens,
  `assert_equal card_path(Card.last, format: :json), @response.headers["Location"]`);
  flat payloads: `test/controllers/api/flat_json_params_test.rb`.

## Reuse recipe

1. Give `User` `has_many :accessible_<things>, through:` associations that encode visibility.
2. For each parent resource, write `app/controllers/concerns/<parent>_scoped.rb`: `before_action :set_<parent>` that does `Current.user.accessible_<parents>.find(params[:<parent>_id])`. Derive grandparents from the record (`@board = @card.board`), don't re-query.
3. Load children through the parent: `@comment = @card.comments.find(params[:id])`.
4. Extra rules → `ensure_<rule>` private before_action returning `head :forbidden`, backed by `Current.user.can_<verb>?(record)` on the model.
5. Put shared response helpers for that parent in the same concern (`render_card_replacement`).
6. Actions: one model call, then `respond_to` with `format.turbo_stream` (template by default) and `format.json` (`render :show, status: :created, location: ..._path(format: :json)` or `head :no_content`).
7. Declare `wrap_parameters` with an explicit `include:` on API-facing controllers; use `params.expect`.
8. If a namespace shares both loader and auth mode (public pages), use a base controller instead of a concern.

## Related

[[patterns/state-as-resource]] · [[patterns/turbo-and-caching]] · [[patterns/current-attributes]] ·
[[components/access]] · [[components/authentication]] · [[patterns/model-concerns]] ·
[[testing/controller-and-system]] · [[voice/dhh-refactors]]
