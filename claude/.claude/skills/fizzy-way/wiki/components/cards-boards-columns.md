---
title: Cards, boards and columns — modeling the core domain
use_when: [core domain model, main model, god model, the central record of the app, kanban, board/column/card, lanes, workflow stages, move between containers, lifecycle states, draft and publish, per-account numbering, drag and drop, reorder, position, model too big, deal model, project model, ticket model]
sources:
  - app/models/card.rb, app/models/card/*.rb
  - app/models/board.rb, app/models/board/*.rb
  - app/models/column.rb, app/models/column/*.rb
  - app/models/user/accessor.rb
  - app/controllers/cards/*, app/controllers/columns/**, app/controllers/boards/**
  - config/routes.rb (resources :boards, :cards, :columns)
  - test/models/card/*, test/models/column/*, test/models/board/*
snapshot: 55bb38335
---

# Cards, boards and columns

## Answer

This is the app's central object, the analog of a Deal, Project or Ticket in other
apps. Fizzy keeps it small by spreading it out. `Card` is **112 lines** plus **23
traits** (about 830 lines across `app/models/card/`). Each trait is one capability:
`Closeable`, `Triageable`, `Postponable`, `Golden`, `Statuses` and so on. Its
containers are equally thin: `Board` is 15 lines over 10 traits, and `Column` is 10
lines over 2. The lifecycle isn't a state machine. Each state is either a record
(`Closure`, `NotNow`, `Goldness`), an association (`column` present means triaged),
or a two-value enum (`drafted`/`published`). Every transition is a domain verb
(`close`, `triage_into`, `postpone`, `move_to`) exposed as a singular resource. The
reusable lesson is the decomposition. The kanban specifics are Fizzy's product.

## Shape

```
app/models/
  card.rb                 # 112 lines: include line (23 traits), associations, search, scopes, move_to, numbering
  card/
    statuses.rb           # enum drafted/published + publish
    triageable.rb         # belongs_to :column (optional); triage_into, send_back_to_triage
    closeable.rb          # has_one :closure; close, reopen
    postponable.rb        # has_one :not_now; postpone, resume, auto_postpone
    golden.rb             # has_one :goldness; gild, ungild
    assignable.rb, watchable.rb, taggable.rb, pinnable.rb, readable.rb, commentable.rb,
    mentions.rb, multistep.rb, entropic.rb, stallable.rb, eventable.rb, exportable.rb, ...
  board.rb                # 15 lines: Accessible, AutoPostponing, Cards, Entropic, Publishable, Triageable, ...
  board/triageable.rb     # has_many :columns — the board's lanes
  board/publishable.rb    # has_one :publication; publish, unpublish
  column.rb               # include Colored, Positioned; belongs_to :board; has_many :cards (nullify)
  column/positioned.rb    # position integer; move_left, move_right, left_column, right_column
  user/accessor.rb        # has_many :accessible_cards, through: :boards
```

Routes are nouns all the way down: every transition is a singular resource under the card.

```ruby
resources :boards do
  scope module: :boards do
    namespace :columns do            # virtual lanes that aren't Column rows
      resource :not_now
      resource :stream               # "Maybe?" — awaiting triage
      resource :closed
    end
    resources :columns
  end
  resources :cards, only: :create
end

resources :columns, only: [] do      # reordering lanes
  resource :left_position, module: :columns
  resource :right_position, module: :columns
end

resources :cards do
  scope module: :cards do
    resource :board        # move to another board
    resource :closure      # close / reopen
    resource :goldness     # gild / ungild
    resource :not_now      # postpone / resume
    resource :publish      # drafted → published
    resource :triage       # into a column / back to the stream
    resource :pin, :watch, :reading ...
  end
end

namespace :columns do                # drag and drop: dropping a card creates the target state
  resources :cards, only: [] do
    scope module: :cards do
      namespace :drops do
        resource :not_now
        resource :stream
        resource :closure
        resource :column
      end
    end
  end
end
```

## Key code

The model file is a table of contents, plus the few things that belong to the card
as a whole:

```ruby
class Card < ApplicationRecord
  include Accessible, Assignable, Attachments, Broadcastable, Closeable, Colored, Commentable,
    Entropic, Eventable, Exportable, Golden, Mentions, Multistep, Pinnable, Postponable, Promptable,
    Readable, Stallable, Statuses, Storage::Tracked, Taggable, Triageable, Watchable

  belongs_to :board
  before_create :assign_number

  def to_param
    number.to_s                    # /cards/42, not a UUID
  end

  def move_to(new_board)
    transaction do
      card.update!(board: new_board)
      card.events.update_all(board_id: new_board.id)
      Event.where(eventable: card.comments).update_all(board_id: new_board.id)
    end
  end

  private
    def assign_number
      self.number ||= account.with_lock { account.increment!(:cards_count).cards_count }
    end
end
```

A lifecycle state as an association, with a guarded verb pair:

```ruby
module Card::Triageable
  included do
    belongs_to :column, optional: true, touch: true

    scope :awaiting_triage, -> { active.where.missing(:column) }
    scope :triaged, -> { active.joins(:column) }
  end

  def triage_into(column)
    raise "The column must belong to the card board" unless board == column.board

    transaction do
      resume
      update! column: column
      track_event "triaged", particulars: { column: column.name }
    end
  end

  def send_back_to_triage(skip_event: false) ...
end
```

Ordering is an integer position, and moves are singular resources that swap positions:

```ruby
module Column::Positioned
  def move_left  = swap_position_with(left_column)
  def move_right = swap_position_with(right_column)
end

class Columns::LeftPositionsController < ApplicationController
  include ColumnScoped

  def create
    @left_column = @column.left_column
    @column.move_left
    ...
  end
end
```

A drag-and-drop target is a controller whose `create` calls the domain verb:

```ruby
class Columns::Cards::Drops::ColumnsController < ApplicationController
  include CardScoped

  def create
    @column = @card.board.columns.find(params[:column_id])
    @card.triage_into(@column)
  end
end
```

*(Lightly condensed. See the files for full bodies.)*

## Why

- **The nouns were renamed until they fit.** The card started as a `Splat`, became a
  `Bubble` (5aae70298 "Rename Splat to Bubble"), and then a `Card` (723e6d94f "Rename
  bubbles => cards", 333 files). The container went from Project to `Bucket`
  (4e579e5a3 "Rename Project to Bucket"), then Collection, then `Board` (391675e61
  "Rename: Collection -> Board", 39ec6cf06 "Replace collection with board in the
  code, tests green"). The team pays for a large rename instead of living with a
  name that no longer matches the product. → [[patterns/naming]]
- **Workflows and stages became plain columns.** A `Workflow`/`Stage` system
  (b0565fbf2 "Spike workflows") was replaced by `Column` rows owned by the board
  (cd025447f "Add basic column models and script to migrate"). That swapped a
  configurable process for a container, and the result is far smaller.
- **Lifecycle states as records, not a status column.** The 75-line `Card::Engageable`
  became the `Card::NotNow` record plus `Postponable` (b63a6b3e9 "Add postponable
  concern"). Closed, postponed and golden each have their own small record holding
  who and when, so a card's state is a combination of independent traits, not one
  enum. `drafted`/`published` stays an enum because there's no actor or history to
  keep (inference from the code). → [[patterns/state-as-resource]]
- **Virtual lanes are resources too.** "Not now", the triage stream, and "closed"
  aren't `Column` rows, but they still get routes (`boards/:id/columns/not_now`) and
  drop targets (`drops/closure`). The URL describes the domain concept even where
  the table doesn't exist.
- **Human-friendly numbers next to UUIDs.** Cards use `number` in URLs (f5305b2fe
  "Use Card `number` as the model param"). The number comes from a per-account
  counter taken under a row lock. Rosa's e9c30a010 "Serialize card numbering with a
  per-account row lock" explains why: a bare `increment!` handed two concurrent
  creates the same number, and about 97 production errors came from one API client.
  → [[components/accounts-tenancy]]
- **Access flows through associations.** `User#accessible_cards` is `has_many
  :accessible_cards, through: :boards`. Controllers load with
  `Current.user.accessible_cards.find_by!(number:)`, so anything outside the user's
  boards is a 404, not a policy check. → [[components/access]],
  [[patterns/controller-scoping]]
- **Moving between containers is a domain verb with consequences.** Changing
  `board_id` triggers `handle_board_change`: clear the column, record a
  `board_changed` event, grant assignees access, and enqueue cleanup of
  notifications, search and data that are no longer accessible. Callbacks handle the
  side effects. The model owns the rule.

## Testing

- `test/models/card/triageable_test.rb` drives the verbs on fixtures:
  `cards(:buy_domain).triage_into(columns(:writebook_in_progress))`. It also asserts the
  guard with `assert_raises` when the column belongs to another board.
- Each trait has its own test file (`test/models/card/*_test.rb`,
  `test/models/column/positioned_test.rb`, `test/models/board/publishable_test.rb`),
  mirroring the traits folder. → [[testing/model-tests]]

## Reuse recipe: slimming a big core model (a Deal, Project or Ticket)

1. List the model's capabilities as adjectives or "-ables" (Approvable, Fundable, Lockable, Archivable). Each becomes `app/models/<model>/<trait>.rb` with its own associations, scopes, callbacks and verbs.
2. Keep in the model file only what belongs to the record as a whole: the include line, core associations, identity (`to_param`, numbering), and moves between containers.
3. Turn each lifecycle state that has a who or when into a `has_one` record (`Deal::Approval`, `Deal::Archival`). Expose it as `deal.approve`/`approved?` and `resource :approval`. Keep an enum only for states with no actor or history.
4. Treat "is in stage X" as an association to a container row (`belongs_to :column, optional: true`), not a status string, when users can define the stages.
5. Make every transition a singular resource under the record, including drag-and-drop targets.
6. Put ordering in a `Positioned` trait with an integer `position` and `left_position`/`right_position` resources.
7. Rename the core nouns the moment the product language changes. Fizzy did it three times.

## Related

[[patterns/model-concerns]] · [[patterns/state-as-resource]] · [[patterns/naming]] ·
[[components/events]] · [[components/entropy]] · [[components/access]] ·
[[voice/team]]
