---
title: Events as the spine
use_when: [where do side effects go, after X happens notify and log and send webhook, audit log, activity feed and notifications share data, system messages, fan-out, observer, pub-sub in Rails, domain events, event sourcing temptation]
sources:
  - app/models/event.rb, app/models/concerns/eventable.rb, app/models/concerns/notifiable.rb
  - app/models/card/eventable.rb, app/models/comment/eventable.rb, app/models/card/eventable/system_commenter.rb
  - app/models/notifier.rb, app/models/notifier/card_event_notifier.rb
  - app/jobs/event/webhook_dispatch_job.rb, app/jobs/notify_recipients_job.rb
  - app/models/user/day_timeline.rb, app/models/event/description.rb
  - app/models/card/stallable.rb, app/models/card/activity_spike/detector.rb, app/models/card/entropic.rb
  - commits ec7fc7505, b74698771, 905ccb9b4, 4ff55df2e, ab54cafd8, 9d717239e, c926d7ad6, 2ac2d4e0d
snapshot: 55bb38335
---

# Events as the spine

## Answer

Domain verbs do their work and record **one `Event` row** (`track_event :closed`).
Everything that is a *consequence* hangs off that row instead of off the verb:
system comments, the "last active" timestamp, the activity feed, notifications,
webhooks, and decay/stall detection. Local, same-transaction effects run from
`after_create` through a hook on the eventable (`event_was_created`); effects that
leave the process run from `after_create_commit` as jobs. Adding a destination
means adding a callback or a reader on `Event` — the verbs never change. This is not
event sourcing: state lives in normal tables; events are a log plus a trigger.

## Shape

```
          card.close / assign / postpone / comments.create ...
                              │  (in the verb's transaction)
                              ▼
                 Eventable#track_event(action, creator:, **particulars)
                              │
                      board.events.create!
                              │
      ┌───────── after_create (same transaction) ─────────┐
      │  eventable.event_was_created(event)               │
      │    Card    → SystemCommenter (system-user Comment) │
      │             → touch_last_active_at ──► Entropy sweep, Stallable detector
      │    Comment → card.touch_last_active_at            │
      └───────────────────────────────────────────────────┘
      ┌───────── after_create_commit (jobs) ──────────────┐
      │  Notifiable → NotifyRecipientsJob → Notifier.for(event) → Notification rows
      │  dispatch_webhooks → Event::WebhookDispatchJob → Webhook::Delivery rows
      └───────────────────────────────────────────────────┘
      ┌───────── readers (no callbacks) ──────────────────┐
      │  User::DayTimeline / ActivitiesController (Event.preloaded)
      │  Event::Description → HTML feed, plain-text API & webhooks
      │  Card::ActivitySpike::Detector reads card.events  │
      └───────────────────────────────────────────────────┘
```

Files that make up the spine:

```
app/models/event.rb                     # include Notifiable; after_create; after_create_commit
app/models/concerns/eventable.rb        # track_event + hooks (event_was_created, should_track_event?)
app/models/concerns/notifiable.rb       # after_create_commit :notify_recipients_later
app/models/<model>/eventable.rb         # per-model hook overrides
```

## Key code

The whole fan-out is five lines on `Event`:

```ruby
class Event < ApplicationRecord
  include Notifiable, Particulars, Promptable

  after_create -> { eventable.event_was_created(self) }
  after_create_commit :dispatch_webhooks
end

module Notifiable
  included do
    has_many :notifications, as: :source, dependent: :destroy
    after_create_commit :notify_recipients_later
  end
end
```

Destinations decide relevance by `action`, not by being called from the right verb:

```ruby
class Notifier::CardEventNotifier < Notifier
  private
    def recipients
      case source.action
      when "card_assigned"  then source.assignees.excluding(creator)
      when "comment_created" then card.watchers.without(creator, *source.eventable.scan_mentionees)
      else board.watchers.without(creator)
      end
    end
end

module Webhook::Triggerable
  included do
    scope :triggered_by, ->(event) { where(board: event.board).triggered_by_action(event.action) }
  end
end
```

*(Notifier condensed; see [[components/notifications]].)*

Guards live on the source, once:

```ruby
module Card::Eventable
  private
    def should_track_event? = published?        # drafts emit nothing anywhere
end

module Comment::Eventable
  private
    def should_track_event? = !creator.system?  # system comments don't re-enter the spine
end
```

## Why

- **This is the 37signals house design.** *"the system creates events, and those
  events are relayed to several destinations, such as the activity timeline or
  webhooks."* (Jorge, [Fractal journeys](https://dev.37signals.com/fractal-journeys/),
  describing Basecamp's `Event` + `Relaying`). *"if you want to have a history of what
  are all the recordables that it ever pointed to, we track that in an event model."*
  (Jeffrey Hardy, [RECORDABLES: The Rails Delegated Type Pattern](https://dev.37signals.com/the-rails-delegated-type-pattern/))
- **Callbacks for the secondary, explicit code for the primary.** *"Callbacks are a
  powerful technique for making that which isn't essential to a primary flow live
  on the side."* (DHH, [On Writing Software Well #2](https://www.youtube.com/watch?v=m1jOWu7woKM))
  and the limit: *"you don't want to orchestrate complex flows using callbacks."*
  (Jorge, [Globals, callbacks and other sacrileges](https://dev.37signals.com/globals-callbacks-and-other-sacrileges/)).
  Fizzy's callbacks only enqueue or delegate; the flows (`Notifier#notify`,
  `Delivery#deliver`, `SystemCommenter#comment`) are explicit methods.
- **Built up in steps.** ec7fc7505 "Spike events system" (Oct 2024) → Kevin
  McConnell's a082eb75f "Track events for new comments too" and 196575c0a "Use a job
  to generate notifications" → Jorge's events revamp (PR #431): b74698771 "Make
  eventable a generic concern and create a card's especialization for it",
  905ccb9b4 "Make comments the event's host", 4ff55df2e "Create system comments on
  events" → Stanko's 9d717239e "Dispatch Webhooks on event creation" (PR #1083).
  Each new destination was additive.
- **New actions flow everywhere for free.** 2ac2d4e0d "Add postpone and
  auto-postpone as Webhook triggers" touched `postponable.rb` to track the event and
  added the action to whitelists; notifications, feed and system comments needed only
  their `case` branch.
- **Sync vs async split by blast radius.** `event_was_created` runs inside the
  transaction because a system comment or `last_active_at` must not exist without
  the event (and vice versa). Notifications and webhooks run after commit because they
  touch other users, the network, and must never see a rolled-back event (inference
  from the `after_create` / `after_create_commit` choice).
- **One renderer of meaning.** `Event::Description` (c926d7ad6 "Extract description
  object to remove the helper salad") is shared by the HTML feed, the JSON activity
  API, and webhook payloads, so a sentence changes in one place.
- **Not every state change is an event.** Pins, tags, steps, reactions and gilding
  don't track events; title changes are tracked but filtered from the timeline. The
  spine carries "things others care about", not every write (inference). See
  [[components/pins-tags-steps]].

**Contrast — Mentions.** `Mention` includes `Notifiable` directly instead of going
through `Event`. A mention is addressed to one person and has no feed or webhook
destination, so it skips the spine. The rule this suggests: route through `Event`
when there's more than one destination (inference).

## Testing

- Test each destination from the verb, end to end, with fixtures: closing a card
  and asserting the system comment (`test/models/card/eventable/system_commenter_test.rb`),
  `last_active_at` (`test/models/card/eventable_test.rb`), notification rows
  (`test/models/notifier/*`), and deliveries (`test/models/webhook/triggerable_test.rb`).
- Destination tests can also create an event directly
  (`@board.events.create!(creator:, eventable:, action: "card_published")`) and
  call the destination (`@webhook.trigger(@event)`), skipping the verb.
- Job fan-out is asserted with `assert_enqueued_with` / `perform_enqueued_jobs` only
  where the job is the behavior under test.

## Reuse recipe

1. Create an `events` table and a shared `Eventable` concern with
   `track_event(action, creator: Current.user, **particulars)` and no-op hooks.
2. In each verb, inside its transaction, call `track_event :verb`. Gate noisy sources
   with `should_track_event?` (drafts, system actors).
3. Same-transaction consequences go in `Model::Eventable#event_was_created`.
4. Cross-boundary consequences go on `Event` as `after_create_commit` → one job per
   destination. Each destination filters by `action`.
5. Readers (feeds, APIs, digests) query `Event` with a preloaded scope; share one
   description object for human-readable text.
6. When adding a feature, ask "is this a new event action, or a new destination?"
   before writing a callback anywhere else.
7. Don't event-source: keep real state in its own tables (`Closure`, `NotNow`), and
   treat events as an append-only log plus trigger.

## Related

[[components/events]] · [[components/notifications]] · [[components/webhooks]] ·
[[components/entropy]] · [[components/comments]] · [[components/mentions]] ·
[[patterns/model-concerns]] · [[patterns/jobs-later-now]] ·
[[patterns/current-attributes]] · [[sources]]
