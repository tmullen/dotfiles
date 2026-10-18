---
title: Events and the activity feed
use_when: [activity feed, audit trail, track what happened, timeline, history of a record, event log, system comments, "X did Y" sentences, activity API, particulars, eventable]
sources:
  - app/models/event.rb, app/models/event/*.rb
  - app/models/concerns/eventable.rb
  - app/models/card/eventable.rb, app/models/card/eventable/system_commenter.rb
  - app/models/comment/eventable.rb
  - app/models/user/timelined.rb, app/models/user/day_timeline.rb, app/models/user/day_timeline/*.rb
  - app/controllers/events_controller.rb, app/controllers/events/**, app/controllers/activities_controller.rb
  - app/controllers/users/events_controller.rb, app/controllers/concerns/day_timelines_scoped.rb
  - app/views/events/_event.html.erb, app/views/events/event/**
  - test/models/event_test.rb, test/models/event/description_test.rb, test/models/card/eventable_test.rb
  - commits b74698771, 18cc24e1d, 905ccb9b4, 4ff55df2e, c926d7ad6, 0ab3aaca7, 0df667f4f, 676c2a42f
snapshot: 55bb38335
---

# Events and the activity feed

## Answer

One table, `events`, records every meaningful thing that happens: `action` (a string
like `card_closed`), `creator`, `board`, a polymorphic `eventable` (Card or Comment),
and a JSON `particulars` bag for the details. Models opt in with the shared
`Eventable` concern and call `track_event :closed` inside their verbs. The event
then calls back into its eventable (`event_was_created`) for local side effects —
system comments, `last_active_at` — and fans out after commit to notifications and
webhooks. The activity feed is just a filtered, preloaded query over events, wrapped
in a PORO (`User::DayTimeline`). Sentences are rendered by `Event::Description`.

## Shape

```
app/models/
  event.rb                       # Notifiable, Particulars, Promptable; scopes; callbacks
  event/
    particulars.rb               # store_accessor :particulars, :assignee_ids; #api_particulars
    description.rb               # PORO: event + viewing user → to_html / to_plain_text
    promptable.rb                # to_prompt (vestigial since AI removal, aa1ffb335)
  concerns/eventable.rb          # shared: has_many :events; track_event; hooks
  card/eventable.rb              # Card specialization: publish-gated, system comments
  card/eventable/system_commenter.rb   # PORO: event → system-user Comment
  comment/eventable.rb           # Comment specialization: track :created, skip system user
  user/timelined.rb              # has_many :accessible_events, through: :boards
  user/day_timeline.rb           # PORO: one day of events in three columns
  user/day_timeline/column.rb    # PORO: one column, limited to 100, grouped by hour
  user/day_timeline/serializable.rb   # GlobalID so the PORO can travel through jobs
app/controllers/
  events_controller.rb                     # root "events#index" — the home page
  events/days_controller.rb                # pagination by day
  events/day_timeline/columns_controller.rb  # one column expanded
  users/events_controller.rb               # one person's timeline
  activities_controller.rb                 # JSON activity API, paginated
  concerns/day_timelines_scoped.rb         # builds @day_timeline from params[:day] + filter
app/views/events/
  _event.html.erb                          # cache event; picks partial by action, then by eventable type
  event/_layout.html.erb
  event/eventable/_card.html.erb, _card_published.html.erb, _comment.html.erb
```

Routes:

```ruby
root "events#index"

resources :activities, only: :index
resources :events, only: :index
namespace :events do
  resources :days
  namespace :day_timeline do
    resources :columns, only: :show
  end
end

resources :users do
  scope module: :users do
    resource :events
  end
end
```

Schema (verbatim names): `events(account_id, action, board_id, creator_id,
eventable_type, eventable_id, particulars json default {}, timestamps)`, indexed on
`[board_id, action, created_at]` — the feed query's shape.

## Key code

The shared concern. Action names are prefixed with the model name, so the same
`track_event :created` reads `comment_created` in the table:

```ruby
module Eventable
  extend ActiveSupport::Concern

  included do
    has_many :events, as: :eventable, dependent: :destroy
  end

  def track_event(action, creator: Current.user, board: self.board, **particulars)
    if should_track_event?
      board.events.create!(action: "#{eventable_prefix}_#{action}", creator:, board:, eventable: self, particulars:)
    end
  end

  def event_was_created(event)
  end

  private
    def should_track_event? = true          # (condensed)
    def eventable_prefix = self.class.name.demodulize.underscore
end
```

Callers are one line inside the domain verb, in the same transaction:

```ruby
def close(user: Current.user)
  unless closed?
    transaction do
      not_now&.destroy
      create_closure! user: user
      track_event :closed, creator: user
    end
  end
end

track_event :assigned, assignee_ids: [ user.id ]                                   # top-level particular
track_event "title_changed", particulars: { old_title: title_before_last_save, new_title: title }  # nested
```

The event model. Synchronous `after_create` for same-transaction local effects;
`after_create_commit` for anything that leaves the process:

```ruby
class Event < ApplicationRecord
  include Notifiable, Particulars, Promptable

  belongs_to :account, default: -> { board.account }
  belongs_to :board
  belongs_to :creator, class_name: "User"
  belongs_to :eventable, polymorphic: true

  scope :preloaded, -> {
    includes(:creator, :board, {
      eventable: [
        :creator, :goldness, :closure, :image_attachment,
        { rich_text_body: :embeds_attachments },
        { rich_text_description: :embeds_attachments },
        { card: [ :goldness, :closure, :image_attachment ] }
      ]
    })
  }

  after_create -> { eventable.event_was_created(self) }
  after_create_commit :dispatch_webhooks

  def action
    super.inquiry          # event.action.comment_created?
  end

  def description_for(user)
    Event::Description.new(self, user)
  end
end
```

Each eventable overrides the hooks:

```ruby
module Card::Eventable
  include ::Eventable

  def event_was_created(event)
    transaction do
      create_system_comment_for(event)            # SystemCommenter.new(self, event).comment
      touch_last_active_at unless was_just_published?
    end
  end

  private
    def should_track_event? = published?          # drafts are silent
end

module Comment::Eventable
  include ::Eventable
  included { after_create_commit :track_creation }

  def event_was_created(event) = card.touch_last_active_at

  private
    def should_track_event? = !creator.system?    # system comments don't echo as events
end
```

The feed is a PORO over a scope, cached by a computed key:

```ruby
class User::DayTimeline
  def events
    filtered_events.where(created_at: window).order(created_at: :desc)
  end

  def added_column   = build_column(:added,   "Added",   1, events.where(action: %w[card_published card_reopened]))
  def updated_column = build_column(:updated, "Updated", 2, events.where.not(action: %w[card_published card_closed card_reopened]))
  def closed_column  = build_column(:closed,  "Done",    3, events.where(action: "card_closed"))

  def cache_key
    ActiveSupport::Cache.expand_cache_key [ user, filter, day.to_date, Time.zone.name, events ], "day-timeline"
  end

  private
    def timelineable_events
      Event.preloaded.where(board: boards).where(action: TIMELINEABLE_ACTIONS)
    end
end

class EventsController < ApplicationController
  include DayTimelinesScoped
  def index
    fresh_when @day_timeline
  end
end
```

*(Condensed; memoization and the `TIMELINEABLE_ACTIONS` list elided.)*

Rendering picks a partial by action, then falls back to eventable type:

```erb
<% cache event do %>
  <% if lookup_context.exists?("events/event/eventable/_#{event.action}") %>
    <%= render "events/event/eventable/#{event.action}", event: event %>
  <% else %>
    <%= render "events/event/eventable/#{event.eventable_type.demodulize.underscore}", event: event %>
  <% end %>
<% end %>
```

## Why

- **Events are generic; specializations are concerns.** Jorge's events revamp
  (PR #431) made `Eventable` shared and card-specific behavior a specialization:
  b74698771 "Make eventable a generic concern and create a card's especialization
  for it", then 18cc24e1d "Add an event prefix named after the model now that events
  are generic", then 905ccb9b4 "Make comments the event's host". This is the
  template-method-on-modules pattern from [[patterns/model-concerns]].
- **Event tracking is the canonical callback use case.** *"An auditing concern is
  orthogonal to creating projects."* and *"the combination of callbacks with
  CurrentAttributes achieves something powerful: you can create a project normally,
  and the operation gets seamlessly audited."* (Jorge, [Globals, callbacks and other
  sacrileges](https://dev.37signals.com/globals-callbacks-and-other-sacrileges/)).
  Fizzy follows it: `creator:` defaults to `Current.user`; `Comment` tracks in
  `after_create_commit`. Card verbs call `track_event` explicitly because the
  event's action depends on which verb ran (inference).
- **Basecamp precedent.** *"if you want to have a history of what are all the
  recordables that it ever pointed to, we track that in an event model."* (Jeffrey
  Hardy, [RECORDABLES: The Rails Delegated Type Pattern](https://dev.37signals.com/the-rails-delegated-type-pattern/))
- **System comments come from events, not from verbs.** 4ff55df2e "Create system
  comments on events" added `Card::Eventable::SystemCommenter`, a PORO nested under
  the concern that needs it. One `case event.action` maps actions to comment HTML.
  `Comment::Eventable#should_track_event?` (`!creator.system?`) prevents the
  system comment from generating its own event loop.
- **Description is an object, not helpers.** c926d7ad6 "Extract description object
  to remove the helper salad" (body: *"Lots of repetition with the helpers and
  params"*) moved ~100 lines out of `EventsHelper` into `Event::Description`. It
  takes the viewing user so the sentence can say "You" / "will handle" for them.
  676c2a42f "Always use the creator name for the plain text form" (*"You does not
  make sense for webhooks"*). 0df667f4f "Fix HTML injection in webhooks through
  card titles": every interpolated value goes through `h`.
- **One query shape, preloaded once.** 0ab3aaca7 "Preload Event to avoid N+1s on the
  timeline" added `Event.preloaded`, reused by `User::DayTimeline` and
  `ActivitiesController`. The index `[board_id, action, created_at]` matches the
  feed's `where(board:, action:)` + time window.
- **Access through boards.** `User::Timelined` is one line:
  `has_many :accessible_events, through: :boards, source: :events`. Events carry
  `board_id` so access scoping is a join, never a per-row check (inference).
- **Each consumer chooses its actions.** Three explicit lists exist:
  `User::DayTimeline::TIMELINEABLE_ACTIONS`, `ActivitiesController::ACTIONS`,
  `Webhook::PERMITTED_ACTIONS`. Title changes are tracked (for system comments) but
  kept off the timeline: 41a23b563 "Reapply "Don't relay name change events to the
  timeline"". This is Fizzy-specific; the reusable idea is that tracking an event
  and showing it are separate decisions.
- **Drafts don't happen.** `Card::Eventable#should_track_event?` returns
  `published?`. 31007c7bd "Create a "published" event if a card is created
  published" covers programmatic creation (seeds, API).
- **Events feed entropy.** `event_was_created` touches `last_active_at`, which is
  what auto-postpone and activity-spike detection read. See [[components/entropy]].
  `touch_last_active_at` uses `update!` not `touch` (comment: *"so that we can
  detect attribute change on callbacks"*).

**Fizzy-specific vs reusable.** Reusable: the table, `Eventable` + hooks,
prefixed actions, `particulars` JSON, `Description` PORO, `preloaded` scope,
feed-as-PORO with `cache_key`. Fizzy-specific: the three-column day layout, the
action lists, the card/comment eventables.

**Quirk to not copy.** `track_event(..., **particulars)` captures keyword args, so
`particulars: { old_title: ... }` is stored *nested* as
`{"particulars": {"old_title": ...}}` while `assignee_ids:` is stored at top level.
Readers compensate with `particulars.dig("particulars", "old_title")`, and
`Event::Particulars#api_particulars` flattens it for the API. In a new app, pick
one shape (inference: accidental, kept for data compatibility).

## Testing

- `test/models/card/eventable/system_commenter_test.rb` drives real verbs
  (`@card.close`, `@card.toggle_assignment users(:kevin)`) and asserts the system
  comment text, including an HTML-escaping case.
- `test/models/event/description_test.rb` asserts `to_html`/`to_plain_text` are
  `html_safe?` and contain the expected words for fixture events
  (`events(:logo_published).description_for(users(:david))`).
- `test/models/card/eventable_test.rb`: "tracking events update the last activity
  time" with `travel_to` and `cards(:logo).close`.
- `test/models/event_test.rb` covers `for_creators`/`for_boards` with blank ids and
  `api_particulars` with missing nested values.
- Controllers: `test/controllers/events_controller_test.rb`,
  `test/controllers/events/days_controller_test.rb`,
  `test/controllers/activities_controller_test.rb` (JSON envelope, ordering),
  `test/controllers/users/events_controller_test.rb`.
- Fixtures (`test/fixtures/events.yml`) set `particulars` via
  `<%= { assignee_ids: [...] }.to_json %>`.

## Reuse recipe

1. Create `events`: `account`, `board` (or whatever scopes access), `creator`,
   polymorphic `eventable`, `action` string, `particulars` JSON. Index
   `[scope_id, action, created_at]`.
2. Write a shared `Eventable` concern with `track_event(action, creator: Current.user, **particulars)`,
   `event_was_created(event)` (no-op), and private `should_track_event?`.
   Prefix the action with the model name.
3. Call `track_event :verb` inside each domain verb's transaction. Use a callback
   only when the event is simply "this record was created".
4. In each model, specialize with `Model::Eventable` overriding the hooks. Put
   local consequences (system comments, activity timestamps) in
   `event_was_created`; put external fan-out in `Event`'s `after_create_commit`.
5. Add `Event::Description` (event + viewer → html/plain) instead of helpers. Escape
   everything interpolated.
6. Add `Event.preloaded` and build feeds as POROs over it with a `cache_key`; use
   `fresh_when` in the controller.
7. Each consumer (feed, API, webhooks) whitelists the actions it shows.

## Related

[[patterns/events-as-spine]] · [[components/notifications]] · [[components/webhooks]] ·
[[components/entropy]] · [[components/comments]] · [[patterns/model-concerns]] ·
[[patterns/turbo-and-caching]] · [[patterns/current-attributes]]
