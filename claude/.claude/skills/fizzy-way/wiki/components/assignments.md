---
title: Assignments
use_when: [assign, assignee, assignees, assign to me, owner of a task, responsible person, assignment limit, filter by assignee, toggle assignment, unassign, multiple assignees]
sources:
  - app/models/assignment.rb, app/models/card/assignable.rb, app/models/user/assignee.rb
  - app/models/event/particulars.rb (assignee_ids), app/models/card/accessible.rb
  - app/models/notifier/card_event_notifier.rb, app/models/card/eventable/system_commenter.rb
  - app/controllers/cards/assignments_controller.rb, app/controllers/cards/self_assignments_controller.rb
  - app/views/cards/assignments/*, app/javascript/controllers/assignment_limit_controller.js
  - app/models/filter.rb, app/models/filter/resources.rb
  - test/models/assignment_test.rb, test/models/card/assignable_test.rb
  - test/controllers/cards/assignments_controller_test.rb, test/controllers/cards/self_assignments_controller_test.rb
  - commits 044117f9c, 3e1b2c74e, a9f845ed4, d237885bd, b4c0fec7a, 513498541, eb0614c44, 15daa2bf0, b0f9960b8, 2527f0736, 6570f5fc0, 7bfcfb57c
snapshot: 55bb38335
---

# Assignments

## Answer

`Assignment` is a join row (`card`, `assignee`, `assigner`) with a unique index on
`[assignee_id, card_id]`. `Card::Assignable` gives the card `assignees` through it,
plus `unassigned` / `assigned_to` / `assigned_by` scopes. It exposes one public verb,
`toggle_assignment(user)`. The private `assign` creates the row, makes the assignee
watch the card, and tracks a `card_assigned` event carrying `assignee_ids`. From that
event come the notification, the system comment, and the activity feed. The user side
is a one-file role concern, `User::Assignee`. Assigning yourself has its own singular
resource, so a cached page never bakes in a user id.

## Shape

```
app/models/
  assignment.rb           # belongs_to card (touch), assignee, assigner; LIMIT = 100; validate :within_limit
  card/assignable.rb      # has_many :assignments, :assignees; scopes; toggle_assignment; private assign/unassign
  user/assignee.rb        # has_many :assignments, :assignings, :assigned_cards
  event/particulars.rb    # store_accessor :particulars, :assignee_ids; def assignees
  card/accessible.rb      # grant_access_to_assignees on board move; clean_inaccessible_data
app/controllers/cards/
  assignments_controller.rb        # new (picker, etag), create (toggle by assignee_id)
  self_assignments_controller.rb   # create: toggle Current.user
app/views/cards/assignments/
  new.html.erb  _user.html.erb  create.turbo_stream.erb   # morph-replace the card's meta area
app/javascript/controllers/assignment_limit_controller.js  # hides unassigned users at LIMIT
```

Routes:

```ruby
resources :cards do
  scope module: :cards do
    resources :assignments
    resource :self_assignment, only: :create
  end
end
```

Schema: `assignments(account_id, card_id, assignee_id, assigner_id)`, with a unique
index on `[assignee_id, card_id]`.

## Key code

```ruby
module Card::Assignable
  extend ActiveSupport::Concern

  included do
    has_many :assignments, dependent: :delete_all
    has_many :assignees, through: :assignments

    scope :unassigned, -> { where.missing :assignments }
    scope :assigned_to, ->(users) { joins(:assignments).where(assignments: { assignee: users }).distinct }
    scope :assigned_by, ->(users) { joins(:assignments).where(assignments: { assigner: users }).distinct }
  end

  def toggle_assignment(user)
    assigned_to?(user) ? unassign(user) : assign(user)
  end

  def assigned_to?(user)
    assignments.any? { |a| a.assignee_id == user.id }
  end

  private
    def assign(user)
      assignment = assignments.create assignee: user, assigner: Current.user

      if assignment.persisted?
        watch_by user
        track_event :assigned, assignee_ids: [ user.id ]
      end
    rescue ActiveRecord::RecordNotUnique
      # Already assigned
    end

    def unassign(user)
      destructions = assignments.destroy_by assignee: user
      track_event :unassigned, assignee_ids: [ user.id ] if destructions.any?
    end
end
```

```ruby
class Assignment < ApplicationRecord
  LIMIT = 100

  belongs_to :account, default: -> { card.account }
  belongs_to :card, touch: true
  belongs_to :assignee, class_name: "User"
  belongs_to :assigner, class_name: "User"

  validate :within_limit, on: :create

  private
    def within_limit
      if card.assignments.count >= LIMIT
        errors.add(:base, "Card already has the maximum of #{LIMIT} assignees")
      end
    end
end
```

The controller resolves the assignee through the board, so you can only assign people
who have access:

```ruby
def create
  if @card.toggle_assignment @board.users.active.find(params[:assignee_id])
    respond_to { |f| f.turbo_stream; f.json { head :no_content } }
  else
    respond_to { |f| f.turbo_stream; f.json { head :unprocessable_entity } }
  end
end
```

*(Condensed.)* `SelfAssignmentsController#create` is the same with `Current.user` and
renders `"cards/assignments/create"`.

The event carries ids. The consumers read them back:

```ruby
module Event::Particulars
  included { store_accessor :particulars, :assignee_ids }
  def assignees = @assignees ||= User.where(id: assignee_ids)
end

# Notifier::CardEventNotifier
when "card_assigned" then source.assignees.excluding(creator)
```

*(Condensed. `assigned?` is omitted, and the `included` block and `assignees` are
shortened to one line each.)*

## Why

- **Name the role after the domain.** Jeffrey Hardy, 044117f9c "Extract
  Bucket::Assignable and rename Assignment#user to #assignee". DHH, d237885bd
  "Extract User::Assignee role": *"Keep slimming down that User"*. The user side is
  three associations in its own role concern.
- **One public verb.** Jose Farias, 3e1b2c74e "Make one-way assignment and tagging
  methods private". The UI only toggles, so `assign`/`unassign` are private and
  callers can't skip the event or the watch.
- **The actor is ambient.** a9f845ed4 "Assigner is always Current.user", which
  removed the `assigner` argument.
- **Nest by what's being assigned.** DHH, b4c0fec7a "Move Assignments under Bubble":
  *"Since that what we are assigning"*. In d0953d6f8 "Pull assignments out of the
  double nesting", he made the route one level deep.
- **Submit on every click.** DHH, 513498541 "Simplify the assignments flow": *"We now
  submit on every selection, so we dont need a whole form and checkboxes to do it."*
  Each picker row is a `button_to card_assignments_path(card, params: { assignee_id: })`.
- **A separate resource for "assign to me".** Mike Dalessio, 2527f0736 "Fix "M"
  hotkey using stale user from fragment cache" (PR #2383): *"Add a
  SelfAssignmentsController to resolve the current user at request time, avoiding
  the use of an incorrect user id baked into a cached URL."* Cached markup must never
  contain the viewer's identity. Give the current user's action its own URL.
- **Limits go in the model, and the UI mirrors them.** 15daa2bf0 "Limit asignees to 10
  per card" (PR #2153) added the validation and the `persisted?` check, so a rejected
  create doesn't watch or track. b0f9960b8 "Raise the limit to 100". The Stimulus
  `assignment-limit` controller reads `Assignment::LIMIT` from a data attribute.
- **Uniqueness is the index's job.** A duplicate assign is caught with `rescue
  ActiveRecord::RecordNotUnique`, not a uniqueness validation. Under concurrency only
  the index is correct. See [[voice/dhh-refactors]] §3.
- **Predicates should read preloaded rows.** Mike Dalessio, 79c9ea2ce "Remove a bunch
  of N+1s": `assignments.exists? assignee: user` → `assignments.any? { |a| a.assignee_id == user.id }`.
  When the assignments are already loaded, for example by preloading assignees for
  a whole board, the check runs in memory without a query. (inference)
- **The picker is HTTP-cached.** DHH, 6570f5fc0 "Use etag for assignments/new". Jorge
  fixed the key in 7bfcfb57c "Fix: invalidate http cache when selecting assignees":
  `fresh_when @users` → `fresh_when etag: [ @users, @card.assignees ]`. The etag
  has to include everything the view renders.
- **Assigning means watching.** 6157d8b4b "Start watching when participating on a
  bubble", with the verb from DHH's eb0614c44 "Use a more ergonomic API for
  watching". See [[components/watching]].
- **Access follows assignees.** When a card moves boards, `grant_access_to_assignees`
  runs, but only if `Current.user&.can_administer_board?`. When access is lost,
  `clean_inaccessible_data` deletes the stale assignments. (Fizzy-specific policy)

**Reusable vs Fizzy-specific.** The reusable parts: the join row with `assigner`, a
unique index plus `rescue RecordNotUnique`, `toggle_assignment` as the only public
verb, an event with `assignee_ids`, the `User::Assignee` role, and the self-assignment
resource. These are Fizzy product choices: multiple assignees (up to 100), auto-watch,
and granting board access on move.

## Testing

- `test/models/card/assignable_test.rb`: "assigning a user makes them watch the card"
  runs inside `with_current_user(:jz) do ... end`. "toggle_assignment does not add
  assignee when at limit" builds `Assignment::LIMIT` real users in a loop. It doesn't
  stub the constant.
- `test/models/assignment_test.rb` checks `create` and the limit error message on `errors[:base]`.
- `test/models/card/eventable/system_commenter_test.rb` checks the visible output
  ("David assigned this to Kevin").
- `test/controllers/cards/self_assignments_controller_test.rb` checks the toggle on/off
  and JSON `:no_content`.
- Filters by assignee are tested through `Filter` (`assigned_to(assignees.ids)`). See
  [[components/filters]].

## Reuse recipe

1. `create_table :assignments` with `record_id`, `assignee_id`, `assigner_id`, and `add_index [:assignee_id, :record_id], unique: true`.
2. `Assignment` with `belongs_to :record, touch: true` and two `belongs_to ..., class_name: "User"`.
3. Add a `Record::Assignable` trait with `has_many :assignees, through: :assignments`, the `unassigned`/`assigned_to`/`assigned_by` scopes, a public `toggle_assignment`, and private `assign`/`unassign` that track `:assigned`/`:unassigned` events with `assignee_ids`.
4. Add a `User::Assignee` role with `assignments` (`foreign_key: :assignee_id`), `assignings`, and `assigned_cards`.
5. Use `resources :assignments` under the record for the picker (`new`) and the toggle (`create`). Add a separate `resource :self_assignment, only: :create` for "assign to me".
6. Look up assignees through the container's members (`@board.users.active.find`). Use a turbo stream template that morphs the record's meta area.
7. Hang notifications and system comments off the event. Don't call them from `assign`.

## Related

[[components/watching]] · [[components/notifications]] · [[components/comments]] ·
[[components/events]] · [[components/filters]] · [[components/access]] ·
[[patterns/model-concerns]] · [[patterns/turbo-and-caching]] · [[voice/dhh-refactors]]
