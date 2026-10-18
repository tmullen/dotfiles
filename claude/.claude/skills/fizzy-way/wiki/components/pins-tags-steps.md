---
title: Pins, tags and steps — small card traits
use_when: [pin, bookmark, favorite, star, tags, labels, tagging, hashtag, checklist, steps, subtasks, to-do items on a record, per-user join, toggle tag, my/ namespace]
sources:
  - app/models/pin.rb, app/models/card/pinnable.rb, app/jobs/card/broadcast_pin_updates_job.rb
  - app/controllers/cards/pins_controller.rb, app/controllers/my/pins_controller.rb
  - app/models/tag.rb, app/models/tagging.rb, app/models/card/taggable.rb, app/jobs/delete_unused_tags_job.rb
  - app/controllers/cards/taggings_controller.rb, app/controllers/tags_controller.rb
  - app/models/step.rb, app/models/card/multistep.rb, app/controllers/cards/steps_controller.rb
  - app/models/card/accessible.rb (clean_inaccessible_data)
  - config/routes.rb, config/recurring.yml
  - test/models/card/pinnable_test.rb, test/models/card/taggable_test.rb, test/models/tag_test.rb
  - test/controllers/cards/{pins,taggings,steps}_controller_test.rb, test/controllers/my/pins_controller_test.rb, test/jobs/delete_unused_tags_job_test.rb
  - commits bfb7ed121, e4c6fe4b5, 4d0dddec4, c89db89f2, 0053e7145, 253881fd7, 3068c2a74, f403ed070, 2f9a0bbe7, 4a30663df, f02215c5b, aff0a38b3
snapshot: 55bb38335
---

# Pins, tags and steps — small card traits

*One page for three thin features: each is a join or child table plus a one-screen
concern. Together they show the three shapes a "small trait" takes.*

## Answer

- **Pin** = per-user join (`pins(user, card)`). The card gets `Card::Pinnable`
  (`pin_by`, `unpin_by`, `pinned_by?`); the toggle is `resource :pin` under the card;
  the user's list is `My::PinsController` in the `my/` namespace. Reads filter through
  current board access.
- **Tag** = account-wide vocabulary (`tags(account, title)`) joined by `taggings`.
  One verb, `card.toggle_tag_with(title)`, finds-or-creates the tag and flips the
  join. Unused tags are deleted by a daily recurring job.
- **Step** = plain child rows (`steps(card, content, completed)`) with full nested
  CRUD (`resources :steps`). `Card::Multistep` is one `has_many`.

None of the three tracks events. They are personal or descriptive state, not
"something happened" (inference: no commit states it).

## Shape

```
app/models/
  pin.rb                       # belongs_to card, user; scope :ordered, :accessible
  card/pinnable.rb             # has_many :pins; pin_by/unpin_by/pinned_by?/pin_for; broadcast_pin_updates
  tag.rb                       # Filterable; normalizes downcase; no leading "#"; scope :unused
  tagging.rb                   # belongs_to tag, card (touch: true)
  card/taggable.rb             # has_many :tags, through: :taggings; toggle_tag_with; scope :tagged_with
  step.rb                      # belongs_to card (touch: true); scope :completed; validates content
  card/multistep.rb            # has_many :steps, dependent: :destroy
app/jobs/
  card/broadcast_pin_updates_job.rb
  delete_unused_tags_job.rb
app/controllers/
  cards/pins_controller.rb     # show (etag) / create / destroy — singular resource
  my/pins_controller.rb        # index: Current.user.pins.accessible
  cards/taggings_controller.rb # new (picker) / create (toggle)
  tags_controller.rb           # index (account tags, paginated)
  cards/steps_controller.rb    # full CRUD, turbo_stream + json
```

Routes:

```ruby
resources :cards do
  scope module: :cards do
    resource :pin
    resources :steps
    resources :taggings
  end
end

resources :tags, only: :index

namespace :my do
  resources :pins
end
```

```yaml
# config/recurring.yml
delete_unused_tags:
  class: DeleteUnusedTagsJob
  schedule: every day at 04:02
```

## Key code

Pin trait — idempotent verbs keyed by user:

```ruby
module Card::Pinnable
  included do
    has_many :pins, dependent: :destroy
    after_update_commit :broadcast_pin_updates_later, if: :preview_changed?
  end

  def pinned_by?(user) = pins.exists?(user: user)
  def pin_by(user)     = pins.find_or_create_by!(user: user)
  def unpin_by(user)   = pins.find_by(user: user).tap { it.destroy }

  # Renders the board this run has loaded, so it picks its recipients from that same board ...
  def broadcast_pin_updates
    pins.where(user: board.users).find_each do |pin|
      pin.broadcast_replace_to [ pin.user, :pins_tray ], partial: "my/pins/pin"
    end
  end
end

class Pin < ApplicationRecord
  # Cards move between boards, and a pin outlives a move to a board its owner cannot reach.
  # Only serve the pins whose owner still has access to the card's board.
  scope :accessible, -> { where(card: Card.joins(board: :accesses).where("accesses.user_id = pins.user_id")) }
end
```

*(Condensed to endless methods; the source uses ordinary `def ... end`.)*

The controller broadcasts the user's own tray inline — it is the point of the action:

```ruby
class Cards::PinsController < ApplicationController
  include CardScoped

  def create
    @pin = @card.pin_by Current.user
    @pin.broadcast_prepend_to [ Current.user, :pins_tray ], target: "pins", partial: "my/pins/pin"
    respond_to do |format|
      format.turbo_stream { render_pin_button_replacement }
      format.json { head :no_content }
    end
  end
end
```

*(Condensed: the broadcast is a private method in the source.)*

Tag toggle — the domain verb takes a title, not an id:

```ruby
module Card::Taggable
  included do
    has_many :taggings, dependent: :destroy
    has_many :tags, through: :taggings
    scope :tagged_with, ->(tags) { joins(:taggings).where(taggings: { tag: tags }) }
  end

  def toggle_tag_with(title)
    tag = account.tags.find_or_create_by!(title: title)

    transaction do
      if tagged_with?(tag)
        taggings.destroy_by tag: tag
      else
        taggings.create tag: tag
      end
    end
  end
end

class Tag < ApplicationRecord
  validates :title, format: { without: /\A#/ }
  normalizes :title, with: -> { it.downcase }
  scope :unused, -> { left_outer_joins(:taggings).where(taggings: { id: nil }) }
  def hashtag = "#" + title
end
```

Steps — the smallest possible trait:

```ruby
module Card::Multistep
  extend ActiveSupport::Concern

  included do
    has_many :steps, dependent: :destroy
  end
end

class Step < ApplicationRecord
  belongs_to :account, default: -> { card.account }
  belongs_to :card, touch: true
  scope :completed, -> { where(completed: true) }
  validates :content, presence: true
end
```

Counting in the view uses the scope directly: `card.steps.completed.count`.

## Why

- **`my/` for things hinged on `Current.user`.** DHH, bfb7ed121 "Move pins to my
  space": *"We used the my/ space in HEY to reflect anything that was primarily
  hinged off Current.user. Good to use here too."* The card-side toggle stays under
  the card (`resource :pin`) — see [[patterns/state-as-resource]].
- **Broadcast inline when it is the action's point.** DHH, 4d0dddec4 "No need to loop
  through a job when this is the sole point of the action" changed
  `broadcast_prepend_later_to` → `broadcast_prepend_to` in `PinsController`. But
  broadcasts that are a *side effect* of card edits go through a job and only when
  the preview changed: c89db89f2 "Only broadcast when the preview changes, use the
  _later variant for the broadcast, add tests".
- **A pin is not authority.** Rosa Gutierrez's series: 0053e7145 "Only serve pins
  whose owner can still reach the card" (*"how long the pin survives stops deciding
  what the pinner can see"*), 253881fd7 "Pick the pins to broadcast where they are
  rendered" (enqueue one job per card; pick recipients and render *"in the same
  breath"*), 3068c2a74 "Broadcast to the people who can see the board being
  rendered". Stale pins are also deleted by `Card#clean_inaccessible_data` when a
  card moves. Lesson: any per-user join to a movable record must be re-checked
  against access at read and broadcast time.
- **Normalize vocabulary at the model.** f403ed070 "Downcase tag titles" (now
  `normalizes :title`), edd7e5531 "Prevent using `#` in the stored tag name"; the
  controller only strips a leading `#` from input.
- **Garbage-collect instead of reference counting.** 2f9a0bbe7 "Introduce a recurring
  job to delete unused tags" — toggling never has to decide whether to delete the tag.
- **Tenancy bugs hide in `find_or_create_by`.** 4a30663df "Scope tags by account":
  *"We missed this one when we went to MySQL. This can results in cards tagged with
  cards from other accounts."* Hence `account.tags.find_or_create_by!`.
- **Inline anemic methods into scopes.** aff0a38b3 "Move to scope and inline method"
  deleted `Card#completed_steps_count` for `steps.completed.count`.
- **`touch: true` on children** (`Tagging`, `Step`) keeps card caches and `updated_at`
  honest; it is also what unstalls a card (see [[components/entropy]]).
- **Steps use stream actions, not card re-render.** da6d1011f "Replace card
  replacement with stream actions to prevent flickering when managing steps".
- **API parity was added later, uniformly**: e82dc08f6, 8a8478505 "Add API for
  tagging cards", c517ef606 "Add API for CRUD actions on steps" — `respond_to` with
  `format.json` in the same controllers, no separate API namespace.

**Fizzy-specific vs reusable.** Reusable: per-user join + `accessible` scope + `my/`
listing; title-keyed toggle with normalization and GC job; child rows with
`touch: true` and a status scope. Fizzy-specific: account-wide (not board-wide)
tags, the pins tray broadcast target, pin limits (20 web / 100 JSON).

## Testing

- `test/models/card/pinnable_test.rb` uses `assert_turbo_stream_broadcasts([ users(:jz), :pins_tray ], count: 0)`
  inside `perform_enqueued_jobs` to prove an inaccessible pinner gets nothing.
- `test/controllers/my/pins_controller_test.rb`, `test/controllers/cards/pins_controller_test.rb`
  (turbo_stream + JSON).
- `test/models/card/taggable_test.rb`, `test/models/tag_test.rb`,
  `test/jobs/delete_unused_tags_job_test.rb`, `test/controllers/cards/taggings_controller_test.rb`.
- Steps are tested through `test/controllers/cards/steps_controller_test.rb` only;
  the model has no behavior worth a unit test.

## Reuse recipe

1. **Per-user flag on a shared record** (pin, star, bookmark): join table
   `(user, record)`; trait with `pin_by(user)`/`unpin_by(user)`/`pinned_by?(user)`;
   `resource :pin` under the record; list under `namespace :my`. Filter the list by
   current access, not by the join's existence.
2. **Vocabulary** (tags, labels): `tags(account, title)` normalized; `taggings` with
   `touch: true`; one `toggle_tag_with(title)` verb via
   `account.tags.find_or_create_by!`; daily `Tag.unused` cleanup in `recurring.yml`.
3. **Checklist** (steps, subtasks): child table with `completed` boolean,
   `belongs_to :parent, touch: true`, `scope :completed`; nested `resources :steps`
   with turbo_stream responses.
4. Don't track events for these unless someone needs to be told about them.

## Related

[[patterns/model-concerns]] · [[patterns/state-as-resource]] · [[patterns/controller-scoping]] ·
[[components/access]] · [[components/filters]] · [[components/entropy]] ·
[[patterns/turbo-and-caching]] · [[voice/dhh-refactors]]
