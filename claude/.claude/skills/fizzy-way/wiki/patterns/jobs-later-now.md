---
title: Background jobs — _later methods and one-line jobs
use_when: [background job, async, sidekiq, active job, perform_later, where does job logic go, job naming, recurring task, cron, scheduled job, queue priority, renaming a job, deploy-safe job, enqueue after commit, fan out jobs, perform_all_later, discard_on]
sources:
  - STYLE.md ("Run async operations in jobs")
  - app/jobs/**/*.rb, app/jobs/concerns/account_tenanted.rb
  - config/initializers/active_job.rb, config/queue.yml, config/recurring.yml
  - app/models/concerns/notifiable.rb, app/models/concerns/mentions.rb
  - app/models/notification/pushable.rb, app/models/notification/bundle.rb
  - app/models/card/{readable,accessible,commentable,stallable,pinnable,entropic}.rb, app/models/export.rb
  - test/test_helper.rb, test/models/notification/pushable_test.rb, test/models/access_test.rb, test/jobs/storage/materialize_job_test.rb
  - commits 2c2a1c4b4, 142a342e5, e51f0bfee, dbfb141b6, 3621df8f0, a9444caf1, 966aa51a3, 4d0dddec4, 329e9ef7c, 6aebc0cea, aa27937ac
snapshot: 27d0d2e6b
---

# Background jobs — `_later` methods and one-line jobs

## Answer

The model owns the work; the job is a one-line trampoline. A model method `foo` does
the work synchronously, `foo_later` enqueues `Model::FooJob`, and the job's `perform`
calls `record.foo`. Callbacks call the `_later` method (`after_create_commit
:notify_recipients_later`). Jobs are named after the method, namespaced under the model,
and almost all say `discard_on ActiveJob::DeserializationError`. Scheduled work lives in
`config/recurring.yml` as a `command:` that calls a model class method. Every job
carries `Current.account` with it, and nothing is enqueued until the transaction commits.

## Shape

```
app/jobs/
  application_job.rb                    # prepend AccountTenanted
  concerns/account_tenanted.rb          # serialize/restore Current.account
  concerns/smtp_delivery_error_handling.rb
  notify_recipients_job.rb              # notifiable.notify_recipients
  push_notification_job.rb              # deploy shim → notification.push
  notification/push_job.rb              # notification.push
  notification/bundle/deliver_job.rb    # bundle.deliver          (queue :backend)
  notification/bundle/deliver_all_job.rb# Bundle.deliver_all      (queue :backend)
  mention/create_job.rb                 # record.create_mentions(mentioner:)
  card/remove_inaccessible_notifications_job.rb, card/clean_inaccessible_data_job.rb,
  card/reindex_comments_job.rb, card/broadcast_pin_updates_job.rb,
  card/activity_spike/detection_job.rb
  board/clean_inaccessible_data_job.rb  # board.clean_inaccessible_data_for(user)
  event/webhook_dispatch_job.rb         # Continuable fan-out     (queue :webhooks)
  webhook/delivery_job.rb               # delivery.deliver        (queue :webhooks)
  data_export_job.rb, account/data_import_job.rb, account/incinerate_due_job.rb
  storage/materialize_job.rb, storage/reconcile_job.rb   # limits_concurrency per owner
config/
  initializers/active_job.rb   # enqueue_after_transaction_commit; AccountTenanted on mailer + Turbo jobs
  queue.yml                    # queues: [ "default", "solid_queue_recurring", "backend", "webhooks", "*" ]
  recurring.yml                # command: "Card.auto_postpone_all_due", etc.
```

## Key code

The STYLE.md template (its example is Basecamp's `Event::Relaying`; Fizzy uses the
`_later` half everywhere):

```ruby
module Event::Relaying
  included do
    after_create_commit :relay_later
  end

  def relay_later
    Event::RelayJob.perform_later(self)
  end

  def relay_now
    # ...
  end
end

class Event::RelayJob < ApplicationJob
  def perform(event)
    event.relay_now
  end
end
```

The Fizzy shape: public worker method, private `_later`, one-line job.

```ruby
module Card::Readable
  def remove_inaccessible_notifications
    accessible_user_ids = board.accesses.pluck(:user_id)
    ...
  end

  private
    def remove_inaccessible_notifications_later
      Card::RemoveInaccessibleNotificationsJob.perform_later(self)
    end
end

class Card::RemoveInaccessibleNotificationsJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(card)
    card.remove_inaccessible_notifications
  end
end
```

Fan-out: a class-level `_later` for the schedule, a class method that batches and
enqueues one job per record with `perform_all_later`:

```ruby
class Notification::Bundle < ApplicationRecord
  class << self
    def deliver_all
      due.in_batches do |batch|
        jobs = batch.collect { DeliverJob.new(it) }
        ActiveJob.perform_all_later jobs
      end
    end

    def deliver_all_later
      DeliverAllJob.perform_later
    end
  end

  def deliver_later
    DeliverJob.perform_later(self)
  end
end
```

```yaml
# config/recurring.yml (excerpt)
production: &production
  deliver_bundled_notifications:
    command: "Notification::Bundle.deliver_all_later"
    schedule: every 30 minutes
  auto_postpone_all_due:
    command: "Card.auto_postpone_all_due"
    schedule: every hour at minute 50
  delete_unused_tags:
    class: DeleteUnusedTagsJob
    schedule: every day at 04:02
  cleanup_magic_links:
    command: "MagicLink.cleanup"
    schedule: every 4 hours
```

Tenancy and timing are framework-level, set once:

```ruby
# config/initializers/active_job.rb
ActiveSupport.on_load(:active_job) do
  self.enqueue_after_transaction_commit = true
end

ActiveSupport.on_load(:action_mailer) do
  ActionMailer::MailDeliveryJob.prepend AccountTenanted
end

Rails.application.config.after_initialize do
  Turbo::Streams::ActionBroadcastJob.prepend AccountTenanted
  ...
end

# app/jobs/concerns/account_tenanted.rb (condensed)
module AccountTenanted
  prepended { around_perform :with_account_context }
  def initialize(...) = (super; @account = Current.account)
  def serialize = super.merge({ "account" => @account&.to_gid })
  # resolve in around_perform so a missing account raises DeserializationError → discard_on
end
```

The deploy shim, kept after a rename:

```ruby
class PushNotificationJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(notification)
    notification.push
  end
end
```

## Why

- **Logic in the model, so it's callable from anywhere.** STYLE.md: *"we write shallow
  job classes that delegate the logic itself to domain models"*. The same
  `card.remove_inaccessible_notifications` runs from a job, a console, or a test without
  ActiveJob in the way. Jorge: *"we don't default to create services, actions, commands,
  or interactors"* ([Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/)); a
  job is not a place for business logic either. (inference for the second half)
- **The suffix says it's async.** STYLE.md: *"We typically use the suffix `_later` to
  flag methods that enqueue a job"* and `_now` *"for the regular synchronous method"*
  when the model enqueues a job that calls back into itself. Fizzy, in practice, never
  needed `_now`: the plain verb (`deliver`, `push`, `notify_recipients`) is the sync
  one. Use `_now` only to disambiguate (e.g. if `relay` would read as the async entry
  point). (inference from grep: no `def *_now` in `app/`)
- **Callbacks enqueue; they don't orchestrate.** `after_create_commit
  :notify_recipients_later` keeps notification work off the request. Jorge: *"you don't
  want to orchestrate complex flows using callbacks."* ([Globals, callbacks and other
  sacrileges](https://dev.37signals.com/globals-callbacks-and-other-sacrileges/))
- **Enqueue only after commit.** Mike Dalessio's 2c2a1c4b4 "Make sure jobs are enqueued
  only after all transactions are committed": `AnalyzeJob` ran before the blob was
  uploaded. *"This will be the Rails default at some point, but for now we still need to
  explicitly set it."* It also deleted a retry hack in `lib/rails_ext`.
- **Jobs carry the tenant.** 142a342e5 "Make sure ActiveJob preserves the current account
  context" (Mike: *"This is a pretty common pattern, something like this is in both
  ActiveRecord::Tenanted and ActsAsTenanted."*). Donal McBreen's e51f0bfee "Fix account
  destroy cascade gaps" moved it into an `AccountTenanted` concern on `ApplicationJob`,
  prepended it onto mailer and Turbo broadcast jobs, and deferred account lookup to
  `perform` *"so that missing accounts raise DeserializationError inside the execution
  path where discard_on can handle it"*.
- **Gone records are not errors.** Nearly every job has `discard_on
  ActiveJob::DeserializationError` (Jorge's a629418ee "Discard when the record was
  deleted"; Jeremy Daer's 5d181af39 "Storage: ignore jobs for now-deleted targets").
  `ApplicationJob` leaves it commented out: each job opts in.
- **Rename a job → leave a shim for one deploy.** Rosa Gutierrez's 3621df8f0
  "Consolidate push jobs into single Notification::PushJob" deleted the old classes;
  dbfb141b6 "Restore PushNotificationJob as shim for in-flight jobs during deploy":
  *"In-flight jobs queued before deploy would fail if the old class is missing."*
- **Queues are priorities, few and named for intent.** Jorge's a9444caf1 "Add a
  "backend" queue with less priorities for deliveries": Solid Queue workers take
  queues in listed order, so `default` beats `backend`. `webhooks` isolates outbound
  HTTP. Mike's 96dfcb9d4 "Add a "*" to the queues handled by the solid queue worker
  pool" so engine-defined queues (`incineration`) aren't orphaned.
- **Don't make a job when the work is cheap or is the point.** DHH's 966aa51a3 "Get rid
  of unnecessary touch jobs" (body: *"touch_all on 10K cards took 6ms in testing"*)
  replaced `Card::TouchAllJob` with an inline `-> { cards.touch_all }` callback. His
  4d0dddec4 "No need to loop through a job when this is the sole point of the action"
  changed a pin broadcast from `broadcast_prepend_later_to` to `broadcast_prepend_to`.
- **Recurring = a command on a model.** Most `recurring.yml` entries are `command:` strings
  calling a class method (`MagicLink.cleanup`, `Export.cleanup`), so there's no job class
  at all. Rosa's 329e9ef7c "Don't run application recurring jobs in betas": betas share
  the production DB but run separate Solid Queue instances, which *"can't prevent
  simultaneous runs"*. That's Fizzy-specific ops, but the lesson (recurring jobs are
  per-database singletons) is general.
- **Sweeps keep going and fail at the end.** Rosa's 6aebc0cea "Fail the auto-postpone job
  once the sweep finishes": collect per-card failures, *"raise a single error listing
  them after every account has been swept, so the job still fails and lands in the
  failed jobs queue."* aa27937ac "Fix Card.auto_postpone_all_due DB timeout" restructured
  the sweep per account so each query rides an index.
- **Long jobs resume.** `Event::WebhookDispatchJob`, `Account::DataImportJob`,
  `SearchReindexJob` use `ActiveJob::Continuable` with `step`/`cursor`. That's the one
  place jobs hold more than one line, and the loop is still over model calls.

## Testing

- `test/test_helper.rb` includes `ActiveJob::TestHelper` in every test and overrides
  `perform_enqueued_jobs` to clear `Current.account` first: *"Jobs must carry their own
  account context via AccountTenanted, not rely on Current.account leaking from the test
  setup."*
- Assert the enqueue at the model: `test/models/notification/pushable_test.rb` —
  `assert_enqueued_with(job: Notification::PushJob, args: [ @notification ]) { @notification.push_later }`
  and `assert_no_enqueued_jobs only: Notification::PushJob`.
- Run the real job through the real model: `test/models/access_test.rb` uses
  `perform_enqueued_jobs only: Board::CleanInaccessibleDataJob do ... end`;
  `test/models/card/pinnable_test.rb` uses `perform_enqueued_jobs except: ...`.
- Jobs with real logic get `ActiveJob::TestCase` tests that call `perform_now`
  (`test/jobs/storage/materialize_job_test.rb`, including an idempotency test:
  `3.times { Storage::MaterializeJob.perform_now(@account) }`). One-line jobs get no
  test of their own; the model method is the test target.

## Reuse recipe

1. Write the work as a model method with a domain verb: `deliver`, `push`, `reindex_comments`.
2. Add `verb_later` beside it (private if only a callback uses it): `Model::VerbJob.perform_later(self)`.
3. Job: `class Model::VerbJob < ApplicationJob; discard_on ActiveJob::DeserializationError; def perform(record) = record.verb; end`. Name and namespace match the method.
4. Trigger from `after_*_commit :verb_later` and set `enqueue_after_transaction_commit = true` globally.
5. Multi-tenant? Serialize `Current.account` in `ApplicationJob` (and mailer/Turbo jobs); restore with `Current.with_account` in `around_perform`.
6. Queues: `default` for user-visible latency, `backend` for mail/batch, a dedicated one for outbound HTTP. List them in priority order.
7. Schedules: `config/recurring.yml` with `command: "Model.class_method"`. For many records, enqueue per-record jobs with `ActiveJob.perform_all_later`.
8. Renaming or deleting a job class: keep the old class as a one-line shim for a deploy cycle.

## Related

[[components/notifications]] · [[patterns/events-as-spine]] · [[patterns/current-attributes]] ·
[[patterns/model-concerns]] · [[components/webhooks]] · [[components/export-import]] ·
[[components/entropy]] · [[testing/model-tests]]
