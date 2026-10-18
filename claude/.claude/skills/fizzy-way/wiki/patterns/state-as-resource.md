---
title: State as a singular resource
use_when: [toggle, close/reopen, archive, mark as done, pin, star, favorite, watch/follow, mark read, publish/unpublish, custom controller action, member route, post :close, boolean flag vs record, has_one state record, CRUD-only controllers]
sources:
  - STYLE.md ("CRUD controllers")
  - config/routes.rb
  - app/controllers/cards/{closures,goldnesses,not_nows,pins,watches,readings,publishes,triages,drafts}_controller.rb
  - app/controllers/boards/{publications,involvements}_controller.rb, app/controllers/webhooks/activations_controller.rb
  - app/controllers/notifications/{readings,bulk_readings}_controller.rb
  - app/models/card/{closeable,golden,goldness,postponable,not_now,pinnable,watchable,readable}.rb
  - app/models/closure.rb, app/models/pin.rb, app/models/watch.rb, app/models/board/publishable.rb
  - test/controllers/cards/closures_controller_test.rb, test/models/card/golden_test.rb
  - commits e50144d97, 384de2413, e4c6fe4b5, 3d2820322, 73f272f13, d533f05c7, 72d0008df, d836a1c6c
snapshot: 27d0d2e6b
---

# State as a singular resource

## Answer

An action that isn't create/read/update/destroy becomes a **new noun** that is. "Close a
card" is `POST /cards/:id/closure`; "reopen" is `DELETE` of the same URL. The noun is
a `resource` (singular) nested under its parent with `scope module:`, and its controller
has only `create`/`destroy` (plus `show` when the UI needs to load per-user state).
When the state is worth remembering *who/when*, it is backed by a **`has_one` record**
(`Closure`, `Card::Goldness`, `Card::NotNow`, `Board::Publication`); otherwise the
resource still exists but writes a column or a join row (`Watch`, `Pin`, `Access#involvement`).
The model exposes a verb pair (`close`/`reopen`, `gild`/`ungild`) and a predicate.

## Shape

```
app/models/
  closure.rb                 # belongs_to :card, touch: true; belongs_to :user, optional
  card/closeable.rb          # has_one :closure; closed?/open?; close/reopen; scopes closed/open
  card/golden.rb + goldness.rb
  card/postponable.rb + not_now.rb
  board/publishable.rb + publication.rb   # has_secure_token :key
app/controllers/cards/
  closures_controller.rb     # create → @card.close, destroy → @card.reopen
  goldnesses_controller.rb   # create → gild, destroy → ungild
  not_nows_controller.rb     # create → postpone (un-postponing is triage/closure)
  pins_controller.rb         # show (frame) / create / destroy, per user
  watches_controller.rb      # show (frame) / create / destroy, per user
  readings_controller.rb     # create → read_by, destroy → unread_by
  publishes_controller.rb    # create → publish (status enum, no record)
  triages_controller.rb      # create → triage_into(column), destroy → send_back_to_triage
  drafts_controller.rb       # show only: a second *view* of the card
app/controllers/notifications/bulk_readings_controller.rb   # collection-level "mark all read"
app/controllers/webhooks/activations_controller.rb          # create → @webhook.activate
app/controllers/columns/left_positions_controller.rb        # create → @column.move_left
```

Routes (verbatim excerpt):

```ruby
resources :cards do
  scope module: :cards do
    resource :draft, only: :show
    resource :closure
    resource :goldness
    resource :not_now
    resource :pin
    resource :publish
    resource :reading
    resource :triage
    resource :watch
    resource :self_assignment, only: :create
    resources :assignments
    resources :taggings
  end
end

resources :boards do
  scope module: :boards do
    resource :involvement
    resource :publication
    resource :entropy
  end
end

resources :columns, only: [] do
  resource :left_position, module: :columns
  resource :right_position, module: :columns
end

resources :notifications do
  scope module: :notifications do
    resource :reading
    collection do
      resource :bulk_reading, only: :create
    end
  end
end
```

## Key code

STYLE.md states the rule outright:

```ruby
# Bad
resources :cards do
  post :close
  post :reopen
end

# Good
resources :cards do
  resource :closure
end
```

The state record and the trait that manages it:

```ruby
class Closure < ApplicationRecord
  belongs_to :account, default: -> { card.account }
  belongs_to :card, touch: true
  belongs_to :user, optional: true
end

module Card::Closeable
  included do
    has_one :closure, dependent: :destroy

    scope :closed, -> { joins(:closure) }
    scope :open, -> { where.missing(:closure) }
    scope :closed_by, ->(users) { closed.where(closures: { user_id: Array(users) }) }
  end

  def closed? = closure.present?        # (condensed)
  def closed_by = closure&.user
  def closed_at = closure&.created_at

  def close(user: Current.user)
    unless closed?
      transaction do
        not_now&.destroy
        create_closure! user: user
        track_event :closed, creator: user
      end
    end
  end

  def reopen(user: Current.user)
    if closed?
      transaction do
        closure&.destroy
        track_event :reopened, creator: user
      end
    end
  end
end
```

The controller is two verbs and a format switch. HTML clients get Turbo Streams; API
clients get `204`:

```ruby
class Cards::GoldnessesController < ApplicationController
  include CardScoped

  def create
    @card.gild

    respond_to do |format|
      format.turbo_stream { render_card_replacement }
      format.json { head :no_content }
    end
  end

  def destroy
    @card.ungild
    ...
  end
end
```

Per-user state uses `show` too, so it can live in its own lazily loaded,
HTTP-cached frame next to a shared, fragment-cached card:

```ruby
class Cards::WatchesController < ApplicationController
  include CardScoped

  def show
    fresh_when etag: @card.watch_for(Current.user) || "none"
  end

  def create  = @card.watch_by(Current.user)     # (condensed; real code has respond_to)
  def destroy = @card.unwatch_by(Current.user)
end
```

```erb
<%# app/views/cards/container/footer/_published.html.erb (condensed) %>
<%= turbo_frame_tag card, :watch, src: card_watch_path(card), target: "_top", refresh: :morph do %>
  ...default button...
<% end %>
```

## Why

- **It's the house rule.** Jorge added the "CRUD controllers" section to STYLE.md in
  d836a1c6c "Add note on CRUD controllers": *"When an action doesn't map cleanly to a
  standard CRUD verb, we introduce a new resource rather than adding custom actions."*
- **It was there from day one, as a record.** The very first "close" was Kevin
  McConnell's `Pop` model in e50144d97 "Add modelling for "popped" bubbles": `has_one
  :pop`, `scope :popped, -> { joins(:pop) }`, `scope :not_popped, -> { where.missing(:pop) }`,
  and a day later 416186296 "Add pop/restore button to bubble" added `resource :pop`
  with a two-action controller. The 2025 rename to cards (723e6d94f "Rename bubbles =>
  cards") turned `Pop` into `Closure` without changing the shape.
- **Toggles are not a concept.** DHH's 384de2413 "Get rid of odd toggles concept"
  (body: *"This is just assignments."*) replaced `namespace :assignments { resources
  :toggles }` with `resources :assignments`; 7494dad91 "Drop the toggles scope for
  taggings as well" did the same for tags. In e4c6fe4b5 "Shape up pinning API and
  broadcast in the controller", `set_pinned(user, true/false)` became `pin_by`/`unpin_by`,
  one method per HTTP verb. In 3d2820322 "Use singular staging resource and beef up
  testing", `resources :stagings` + `toggle_stage` became `resource :staging` + `update`
  + `change_stage_to`.
- **Custom member/collection routes get folded back into resources.** Notifications
  went from `post :mark_read` (member) to DHH's 73f272f13 "Use one controller for all
  notification readings" (still with `create_all`), then to Jorge's d533f05c7 "Use
  vanilla resources for handling notifications": `resource :reading` plus a
  `bulk_reading` resource for the collection-level action.
- **Don't restrict actions without a reason.** DHH's 72d0008df "Only restrict resource
  actions when there's a specific story to tell" changed `resource :reading, only:
  %i[ create destroy ]` to plain `resource :reading`. Fizzy keeps `only:` for real
  stories (`resource :draft, only: :show`, `bulk_reading, only: :create`).
- **A record gives you the audit trail and the query for free.** `closed_by`,
  `closed_at`, `postponed_by` come from the row; `closed`/`open` are `joins` and
  `where.missing`. When the workflow changed, the record changed with it: Jorge's
  b63a6b3e9 "Add postponable concern" deleted `Card::Engageable` (a `Card::Engagement`
  record with doing/on-deck status) and added `Card::NotNow`, and 9263cff3d "Store and
  show the user that postpones cards" put a `user` on it. The
  `touch: true` on the state record busts the card's caches and (via `after_touch`) the
  board's. Rob Zolkos's a896b0a9e "Touch board when publication is created or destroyed
  (#2674)" fixed a stale `json.cache! board` because `Board::Publication` forgot it.
- **Name the noun after the domain, then match it everywhere.** 7406a1039 "Add models
  to track gold cards and implement basic toggle behavior" shipped
  `GoldenessesController`; the next day 4f3f32252 "Rename inconsistency: go with
  goldness". DHH renamed the `_closure_toggle` partial to `_closure` in b788ef163
  "Match domain language". See [[patterns/naming]].
- **`show` on a state resource is a caching tool.** DHH's 418548b9b "More efficient
  query for watched_by? and use etag for the status" added `WatchesController#show`
  with `fresh_when`. The card container is fragment-cached and shared by every viewer,
  so anything that depends on `Current.user` is pulled out into its own frame. Mike
  Dalessio's 2527f0736 "Fix "M" hotkey using stale user from fragment cache" added
  `resource :self_assignment` for the same reason: resolve the user at request time,
  not inside a cached URL.
- **A second *view* is a resource too.** f58a1aeb3 "Use a dedicated resource for showing
  cards in draft mode" (Jorge): *"this lets us get rid from some conditionals for
  handling both modes with a single template."*
- **Not every state resource has a record.** That's a Fizzy-specific call, not the
  pattern. `resource :publish` flips a `status` enum; `Webhooks::ActivationsController`
  (4da69fb69 "Move reactivation out of edit") sets an `active` boolean;
  `resource :involvement` updates an enum on the user's `Access`. The URL shape is
  constant; the backing store is chosen by whether history matters. (inference)
- **Where Fizzy still toggles.** `Cards::AssignmentsController#create` and
  `TaggingsController#create` call `toggle_assignment` / `toggle_tag_with`: a picker
  where the same click adds or removes. It's a pragmatic exception, not the model to copy (inference).

## Testing

- Controller tests assert the state flip through the predicate, in both formats.
  `test/controllers/cards/closures_controller_test.rb`:
  `assert_changes -> { card.reload.closed? }, from: false, to: true do post
  card_closure_path(card), as: :turbo_stream; assert_card_container_rerendered(card) end`,
  then `"create as JSON"` asserts `:no_content`.
- `assert_card_container_rerendered` lives in `test/test_helpers/card_test_helper.rb`
  (`assert_turbo_stream action: :replace, target: dom_id(card, :card_container)`).
- Model tests drive the verb pair and scopes on fixtures:
  `test/models/card/golden_test.rb` (`@non_golden.gild`, `assert_includes Card.golden, @golden`),
  `test/models/card/closeable_test.rb`, `postponable_test.rb`, `watchable_test.rb`.
- Fixtures include the state rows (`test/fixtures/closures.yml`, `test/fixtures/card/goldnesses.yml`),
  so `cards(:shipping)` is closed by data, not setup code.

## Reuse recipe

1. Write the verb in English ("close the card"). Turn it into a noun: closure, publication, pin, reading, activation, position.
2. Route it as `resource :noun` inside `scope module: :parent`. Don't add `only:` unless there's a story.
3. Controller: `create` = do it, `destroy` = undo it, `update` when there's a value to pick (`involvement`, `staging`). Load the parent with a `ParentScoped` concern. See [[patterns/controller-scoping]].
4. If you'll want *who/when* or a cheap `joins` scope, back it with a `has_one` record (`belongs_to :parent, touch: true`, `belongs_to :user, optional: true`). Otherwise a column is fine.
5. Model: one trait per state (`Closeable`), with predicate (`closed?`), verb pair (`close`/`reopen`), scopes (`closed`/`open`), and a `user: Current.user` keyword. Guard idempotently (`unless closed?`).
6. For per-user state on a shared page, add `show` with `fresh_when etag: record || "none"` and load it in a `turbo_frame_tag ... src:`.
7. Respond with `turbo_stream` for the app and `head :no_content` for JSON.

## Related

[[patterns/model-concerns]] · [[patterns/controller-scoping]] · [[patterns/turbo-and-caching]] ·
[[patterns/naming]] · [[patterns/events-as-spine]] · [[components/notifications]] ·
[[components/pins-tags-steps]] · [[voice/dhh-refactors]]
