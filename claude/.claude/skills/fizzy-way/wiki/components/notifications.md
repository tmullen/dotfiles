---
title: Notifications
use_when: [notifications, inbox, notification tray, email digest, bundling, web push, mentions notify, unsubscribe link, who gets notified]
sources:
  - app/models/concerns/notifiable.rb
  - app/models/notifier.rb, app/models/notifier/*.rb
  - app/models/notification.rb, app/models/notification/*.rb
  - app/models/user/notifiable.rb
  - app/jobs/notify_recipients_job.rb, app/jobs/notification/**
  - app/controllers/notifications_controller.rb, app/controllers/notifications/*.rb
  - config/initializers/push_notifications.rb, config/recurring.yml
  - test/models/notifier/*, test/models/notification/*
snapshot: 55bb38335
---

# Notifications

## Answer

Two record types do the work. **Things that happen** (`Event`, `Mention`) include a
`Notifiable` concern that, after commit, enqueues one job. The job asks a
**`Notifier`** — a tiny class hierarchy, one per source type — *who* should hear
about it, and writes one `Notification` row per recipient. The `Notification`
model then fans out on its own callbacks: Turbo broadcast to the tray, an email
**bundle** for digesting, and **push targets** registered at boot. Reading is a
singular resource (`resource :reading`), not a `mark_read` action.

## Shape

```
app/models/
  concerns/notifiable.rb        # include on any source: has_many :notifications, after_create_commit → job
  notifier.rb                   # Notifier.for(source) → subclass; #notify writes rows
  notifier/
    card_event_notifier.rb      # only defines private #recipients (+ creator)
    comment_event_notifier.rb
    mention_notifier.rb
  notification.rb               # the row: user, card, creator, polymorphic source, read_at, unread_count
  notification/
    pushable.rb                 # concern: push target registry + push_later
    push_target.rb              # abstract: self.process(notification)
    push_target/web.rb          # saas adds push_target/native.rb
    bundle.rb                   # email digest window (pending → processing → delivered)
    default_payload.rb          # title/body/url for push
    event_payload.rb            # subclass per source type
    mention_payload.rb
  user/notifiable.rb            # has_many :notifications, :notification_bundles; #bundle(notification)
app/jobs/
  notify_recipients_job.rb      # perform: notifiable.notify_recipients
  notification/push_job.rb      # perform: notification.push
  notification/bundle/deliver_job.rb, deliver_all_job.rb
app/controllers/
  notifications_controller.rb           # index (unread + paginated read)
  notifications/readings_controller.rb  # create = read, destroy = unread
  notifications/bulk_readings_controller.rb
  notifications/trays_controller.rb     # show, HTTP-cached with fresh_when
  notifications/settings_controller.rb
  notifications/unsubscribes_controller.rb  # token-auth, no login
```

Routes:

```ruby
namespace :notifications do
  resource :settings
  resource :unsubscribe
end

resources :notifications do
  scope module: :notifications do
    get "tray", to: "trays#show", on: :collection
    resource :reading
    collection do
      resource :bulk_reading, only: :create
    end
  end
end

resolve "Notification" do |notification, options|
  polymorphic_url(notification.notifiable_target, options)
end
```

## Key code

The whole entry point — a concern any model can include:

```ruby
module Notifiable
  extend ActiveSupport::Concern

  included do
    has_many :notifications, as: :source, dependent: :destroy
    after_create_commit :notify_recipients_later
  end

  def notify_recipients
    Notifier.for(self)&.notify
  end

  def notifiable_target
    self
  end

  private
    def notify_recipients_later
      NotifyRecipientsJob.perform_later self
    end
end
```

The job is one line; the model does the work (`_later` enqueues, plain name does it):

```ruby
class NotifyRecipientsJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(notifiable)
    notifiable.notify_recipients
  end
end
```

`Notifier` is a template method. The base owns *how* to notify; subclasses only
answer *who*:

```ruby
class Notifier
  def self.for(source)
    case source
    when Event   then "Notifier::#{source.eventable.class}EventNotifier".safe_constantize&.new(source)
    when Mention then MentionNotifier.new(source)
    end
  end

  def notify
    if should_notify?
      accessible_recipients.sort_by(&:id).map do |recipient|   # sorted: avoids deadlocks
        Notification.create_or_find_by(user: recipient, card: source.card) { ... }
        # existing row → bump unread_count, re-point source, clear read_at
      end
    end
  end

  private
    def should_notify? = !creator.system?
    def accessible_recipients = ...  # filtered by current board access
end

class Notifier::MentionNotifier < Notifier
  alias mention source

  private
    def recipients
      mention.self_mention? ? [] : [ mention.mentionee ]
    end

    def creator
      mention.mentioner
    end
end
```

*(Lightly condensed; see `app/models/notifier.rb` for the full race-condition handling.)*

Push is an open registry, so the SaaS engine adds native push without touching core:

```ruby
# config/initializers/push_notifications.rb
Notification.register_push_target(:web)

# saas/lib/fizzy/saas/engine.rb
Notification.register_push_target(:native)
```

Reading is CRUD on a singular resource:

```ruby
class Notifications::ReadingsController < ApplicationController
  def create
    @notification = Current.user.notifications.find(params[:notification_id])
    @notification.read
    ...
  end

  def destroy
    @notification = Current.user.notifications.find(params[:notification_id])
    @notification.unread
    ...
  end
end
```

## Why

- **Events are the spine.** Notifications, the activity feed, system comments and
  webhooks all hang off `Event` (`after_create_commit :dispatch_webhooks`,
  `eventable.event_was_created(self)`). A new notifiable thing is usually "track an
  event", not "build a notification". → [[patterns/events-as-spine]]
  This is the same design as Basecamp's: *"the system creates events, and those
  events are relayed to several destinations, such as the activity timeline or
  webhooks."* ([Fractal journeys](https://dev.37signals.com/fractal-journeys/))
- **Notifying lives on the side, in callbacks.** Creating a comment knows nothing
  about notifications. `after_create_commit` takes care of them. DHH: *"Callbacks are
  a powerful technique for making that which isn't essential to a primary flow live
  on the side."* ([On Writing Software Well #2](https://www.youtube.com/watch?v=m1jOWu7woKM),
  whose example is Basecamp mentions). The limit, from Jorge: *"you don't want to
  orchestrate complex flows using callbacks."* ([Globals, callbacks and other sacrileges](https://dev.37signals.com/globals-callbacks-and-other-sacrileges/))
  Here the callback only enqueues a job, and the flow is explicit in `Notifier#notify`.
- *No 37signals post or episode is devoted to notification design. The reasoning below
  comes from Fizzy's commits.*
- **One notification per user per card, stacked.** `create_or_find_by(user:, card:)`
  plus `unread_count`. Commit 36ee253a1 "Stack notifications everywhere": *"We had
  client-side notification stacking in the tray since launch, but now we want to
  stack notifications in the notifications page, in API responses and in email
  bundles."* The JS stacking (89 lines of Stimulus) was deleted in favor of a
  data-model change plus a data migration.
- **Subclasses are inlined, not exploded.** Jorge Manrubia's ab54cafd8 "Inline
  event notifiers" collapsed `notifier/events/{assigned,closed,commented,published,base}.rb`
  into one class with a `case` on the action — five files of one-liners became one
  readable method. Later split again only along a real seam: card vs comment
  (40368032f "Split notifiers for comments and cards").
- **Registry over conditionals for push.** Rosa Gutierrez's 05819f84a "Refactor
  notification push system with registry pattern" and 3621df8f0 consolidated
  `WebPushJob`/`NativePushJob` into one `Notification::PushJob` calling
  `notification.push`. The open-source app knows nothing about native push.
- **Deploy-safe job renames.** dbfb141b6 restored `PushNotificationJob` as a shim:
  *"In-flight jobs queued before deploy would fail if the old class is missing."*
  Keep the old job class delegating to the new method for a release.
- **Correctness by ordering, not locking everything.** bc73cf692 "Process
  notification recipients in consistent order" (deadlocks), 95114b1d6 (dirty
  tracking race between concurrent notifier jobs — explained in the one long comment
  in the file). Comments are reserved for exactly this kind of non-obvious *why*.
- **System actors are silent.** `should_notify?` and `pushable?` both check
  `creator.system?` (6f1f819ad "Suppress notifications for system-generated events").
- **Digest email is a model with a time window**, not a cron that scans
  notifications. `Notification::Bundle` has `starts_at..ends_at`, a status enum,
  overlap validation, and `deliver_all` run from `config/recurring.yml`. Delivery
  wraps `user.in_time_zone` and `Current.with_account`.
- **Unsubscribe without login** uses `generates_token_for :unsubscribe, expires_in: 1.month`
  on the user and `allow_unauthenticated_access` on a singular resource controller
  (e4ab1366b "Add unsubscribe links and headers for emails").
- **HTTP caching on the tray**: `fresh_when etag: [ Current.user.notifications, include_read? ]`,
  with a comment explaining why the whole set, not the unread set, is the key.

## Testing

- `test/models/notifier/event_notifier_test.rb` drives the real `Notifier.for(events(:fixture)).notify`
  against fixtures and asserts on returned recipients — no mocks:
  `assert_equal [ users(:kevin) ], notifications.map(&:user)`.
- Setup mutates fixture state through domain methods (`cards(:logo).drafted!`,
  `boards(:writebook).access_for(users(:kevin)).watching!`), not factories.
- Negative cases use `assert_no_difference -> { Notification.count }`.

## Reuse recipe

1. Have an `Event` (or equivalent) table first. Make things that happen create events.
2. Add `Notifiable` to the event model (and to any directly-notifiable thing like `Mention`).
3. Write `Notifier` with `self.for`, `notify`, `should_notify?`; subclasses implement only `recipients` (and `creator` if it differs).
4. `Notification` row: `user`, polymorphic `source`, `creator`, `read_at`. Add a target record (card) if you want stacking.
5. `resource :reading` under `resources :notifications`; `read`/`unread` on the model.
6. Broadcasts via `after_*_commit` on the model; push via a registry concern; emails via a windowed bundle record if you digest.
7. Watching/subscription rules live on the domain (`card.watchers`, `board.watchers`), not in the notifier.

## Related

[[patterns/model-concerns]] · [[patterns/events-as-spine]] · [[patterns/jobs-later-now]] ·
[[patterns/state-as-resource]] · [[components/mentions]] · [[components/watching]] ·
[[components/webhooks]] · [[voice/dhh-refactors]]
