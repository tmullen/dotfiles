---
title: Entropy — auto-postpone, stalled cards, activity spikes
use_when: [stale work, auto-close, auto-archive, auto-postpone, inactivity timeout, decay, stalled, activity spike, per-account setting with per-record override, recurring job, hourly sweep, cron in Rails]
sources:
  - app/models/entropy.rb
  - app/models/account/entropic.rb, app/models/board/entropic.rb, app/models/board/auto_postponing.rb
  - app/models/card/entropic.rb, app/models/card/entropy.rb, app/models/card/postponable.rb, app/models/card/not_now.rb
  - app/models/card/stallable.rb, app/models/card/activity_spike.rb, app/models/card/activity_spike/detector.rb
  - app/jobs/card/activity_spike/detection_job.rb
  - app/controllers/account/entropies_controller.rb, app/controllers/boards/entropies_controller.rb
  - app/helpers/entropy_helper.rb, app/views/entropy/_auto_close.html.erb
  - config/recurring.yml
  - test/models/entropy_test.rb, test/models/card/entropic_test.rb, test/models/card/stallable_test.rb, test/models/card/activity_spike/detector_test.rb
  - commits 6f93d4b72, db86d1788, b3474ec97, 2c9845eb6, 966aa51a3, aa27937ac, 0e718f369, 6aebc0cea, 1bbb6d0c0, c007176ed, dbbee2c66
snapshot: 55bb38335
---

# Entropy — auto-postpone, stalled cards, activity spikes

## Answer

Cards that nobody touches decay. Each card has `last_active_at`, bumped whenever an
event is tracked on it. An `Entropy` record — polymorphic on `container`, one for the
account and optionally one per board — holds `auto_postpone_period` (seconds). An
hourly recurring command, `Card.auto_postpone_all_due`, moves cards whose
`last_active_at` is older than their board's period to "Not Now" as the account's
system user, which tracks a `card_auto_postponed` event. Separately, `Stallable`
flags cards that had an **activity spike** (a detector run in a job) and then went
quiet for 14 days. The UI shows a countdown "bubble" computed by a tiny PORO,
`Card::Entropy`.

## Shape

```
app/models/
  entropy.rb                     # the setting record: container (Account|Board), auto_postpone_period
  account/entropic.rb            # has_one :entropy, as: :container; created after account create (30 days)
  board/entropic.rb              # has_one :entropy, as: :container; #entropy falls back to account.entropy
  board/auto_postponing.rb       # before_create default period
  card/entropic.rb               # .auto_postpone_all_due, scope :postponing_soon, #entropy, #entropic?
  card/entropy.rb                # PORO: auto_clean_at, days_before_reminder (for the UI bubble)
  card/postponable.rb            # has_one :not_now; postpone / auto_postpone / resume
  card/not_now.rb                # the state record (user optional = system)
  card/stallable.rb              # has_one :activity_spike; scope :stalled; detect after update
  card/activity_spike.rb         # state record: updated_at = last spike
  card/activity_spike/detector.rb  # PORO: comments burst / just assigned / just reopened
app/jobs/card/activity_spike/detection_job.rb
app/controllers/account/entropies_controller.rb   # update, admin only
app/controllers/boards/entropies_controller.rb    # update, board admin
app/helpers/entropy_helper.rb                     # data for the JS bubble
config/recurring.yml                              # auto_postpone_all_due: every hour at minute 50
```

Routes:

```ruby
namespace :account do
  resource :entropy
end

resources :boards do
  scope module: :boards do
    resource :entropy
  end
end
```

## Key code

One settings model, two owners, fallback by method override:

```ruby
class Entropy < ApplicationRecord
  DEFAULT_AUTO_POSTPONE_PERIOD_IN_DAYS = 30
  AUTO_POSTPONE_PERIODS_IN_DAYS = [ 3, 7, 30, 90, 365, 11 ].freeze

  belongs_to :account, default: -> { container.account }
  belongs_to :container, polymorphic: true

  validates :auto_postpone_period, inclusion: { in: AUTO_POSTPONE_PERIODS_IN_SECONDS }

  after_commit -> { container.cards.touch_all if container }   # bust card caches (bubbles)

  def auto_postpone_period_in_days=(new_value)
    self.auto_postpone_period = new_value.to_i.days.to_i
  end
end

module Board::Entropic
  included do
    delegate :auto_postpone_period, :auto_postpone_period_in_days, to: :entropy
    has_one :entropy, as: :container, dependent: :destroy
  end

  def entropy
    super || account.entropy
  end
end
```

*(Condensed; `auto_postpone_period_in_days` reader and the board setter elided.)*

The sweep: resolve periods in Ruby, query with one constant cutoff per group, keep
going past failures, fail the job at the end:

```ruby
def auto_postpone_all_due(as_of: Time.now)
  failures = {}

  Account.find_each do |account|
    account.boards.includes(:entropy).group_by(&:auto_postpone_period).each do |period, boards|
      account.cards.active
        .where(board_id: boards.map(&:id))
        .where(last_active_at: ..(as_of - period))
        .find_each do |card|
          card.auto_postpone(user: account.system_user)
        rescue => error
          failures[card.id] = error
        end
    end
  end

  raise AutoPostponeError.new(failures) if failures.any?
end
```

```yaml
# config/recurring.yml
auto_postpone_all_due:
  command: "Card.auto_postpone_all_due"
  schedule: every hour at minute 50
```

Auto-postpone is the ordinary verb with a different event name:

```ruby
def auto_postpone(**args)
  postpone(**args, event_name: :auto_postponed)
end

def postpone(user: Current.user, event_name: :postponed)
  transaction do
    send_back_to_triage(skip_event: true)
    reopen
    activity_spike&.destroy
    create_not_now!(user: user) unless postponed?
    track_event event_name, creator: user
  end
end
```

Stalling: remember a change in `before_update`, act on it after commit, detect in a job:

```ruby
module Card::Stallable
  STALLED_AFTER_LAST_SPIKE_PERIOD = 14.days

  included do
    has_one :activity_spike, class_name: "Card::ActivitySpike", dependent: :destroy
    scope :stalled, -> { open.active.with_activity_spikes.where(card_activity_spikes: { updated_at: ..STALLED_AFTER_LAST_SPIKE_PERIOD.ago }, updated_at: ..STALLED_AFTER_LAST_SPIKE_PERIOD.ago) }

    before_update :remember_to_detect_activity_spikes
    after_update_commit :detect_activity_spikes_later, if: :should_detect_activity_spikes?
  end

  private
    def remember_to_detect_activity_spikes
      @should_detect_activity_spikes = published? && last_active_at_changed?
    end
end

class Card::ActivitySpike::Detector
  def detect
    if has_activity_spike? then register_activity_spike; true else false end   # (condensed)
  end

  private
    def has_activity_spike?
      card.entropic? && (multiple_people_commented? || card_was_just_assigned? || card_was_just_reopened?)
    end

    def register_activity_spike
      Card.suppressing_turbo_broadcasts do
        Card::ActivitySpike.find_or_create_by!(card: card).touch
      end
    end
end
```

The UI countdown is a PORO, not columns:

```ruby
class Card::Entropy
  def self.for(card)
    return unless card.last_active_at
    new(card, card.auto_postpone_period)
  end

  def auto_clean_at        = card.last_active_at + auto_clean_period
  def days_before_reminder = (auto_clean_period * 0.25).seconds.in_days.round
end
```

## Why

- **A named domain concept.** The feature began as 6f93d4b72 "Add system to auto
  reconsider inactive bubbles after 30 days" and separate auto-close tracks. Jorge
  unified them: db86d1788 "Refactor to introduce an entropy model" — *"Instead of
  keeping two tracks of similar logic (auto-reconsider / auto-close)."* (PR #585).
  The bold name fits *"don't be aseptic; double down on boldness."* (Jorge, [Domain
  driven boldness](https://dev.37signals.com/domain-driven-boldness/)).
- **Drop qualifiers.** DHH: b3474ec97 "Rename Entropy::Configuration to just
  Entropy" and 2c9845eb6 "No need to hide that the top-level entropy is tied to the
  Account". See [[voice/dhh-refactors]] §2.
- **Polymorphic container + `super || parent` is the override pattern.** One table
  serves account defaults and board overrides; `Board#entropy` falls back in one
  line. No settings framework (inference: the reusable shape for any "account
  default, per-record override" setting).
- **Validate against an explicit menu.** 23ac76555 "Validate and normalize
  auto-postpone period to days (#2672)" added the allowed list, `*_in_days`
  virtual attributes for forms/JSON, and `wrap_parameters` so the API couldn't bypass
  normalization. (The trailing `11` in the list has no explanation in the commit;
  treat it as product-specific.)
- **Make the query indexable, even at the cost of Ruby.** aa27937ac "Fix
  Card.auto_postpone_all_due DB timeout" (Rosa Gutierrez): a single SQL
  `last_active_at <= now - COALESCE(board_period, account_period)` *"full-scans every
  active card in the system"*; grouping boards by period in Ruby gives *"a single
  constant cutoff"* that *"rides the existing index"*. Followed by fe62eb97d "Add
  (account_id, board_id, status) index to cards (#2970)". The `postponing_soon` scope
  still uses the SQL COALESCE because it is filtered per board in the UI (inference).
- **A sweep must not stop at one bad row, and must not hide it.** 0e718f369 "Keep
  auto-postponing when one card can't be postponed" then 6aebc0cea "Fail the
  auto-postpone job once the sweep finishes": *"Collect the failures instead and
  raise a single error listing them after every account has been swept, so the job
  still fails and lands in the failed jobs queue."*
- **System actor, not nil.** 0666e504d "Assign postpone_by to system when
  auto-cleaning"; later e0aa1d257 "Drop User.system and replace with
  Account#system_user". The system user also silences notifications (see
  [[components/notifications]]).
- **Recurring work is a `command:` on a model method**, not a job class, when it's a
  one-liner (`Card.auto_postpone_all_due`, `Webhook::Delivery.cleanup`). Jobs exist
  when there's an argument to serialize (`Card::ActivitySpike::DetectionJob`). (inference from `config/recurring.yml`)
- **Don't add jobs that only call a cheap method.** DHH's 966aa51a3 "Get rid of
  unnecessary touch jobs" deleted `Card::TouchAllJob` in favor of
  `after_*_commit -> { cards.touch_all }` — the form `Entropy` uses.
- **Spikes: idempotent and quiet.** 1bbb6d0c0 "Fix race condition in
  Card::ActivitySpike::DetectionJob" switched to `find_or_create_by!` plus a unique
  index. c007176ed "Don't broadcast card changes when touching activity spikes":
  *"We do this from jobs, so there is no request id to discard the page refresh in
  the client."*
- **Stalled means "spiked, then nothing touched it".** dbbee2c66 "Stalled cards are
  unstalled by anything that touches updated_at" added `updated_at` to the scope;
  children with `belongs_to :card, touch: true` (steps, comments) therefore unstall
  it (9c76002bc "Completing a step removes stalled status from UI"). The Ruby
  predicate and `bubble_controller.js` are kept in sync by a comment.
- **Events drive it.** `last_active_at` is bumped in `event_was_created`
  ([[components/events]]); the detector reads `card.events` to see "just assigned /
  just reopened". Entropy needs no hooks of its own in the verbs.

**Fizzy-specific vs reusable.** Reusable: settings record with polymorphic
container and parent fallback; activity timestamp fed by events; hourly sweep that
groups by period, uses a system actor, collects failures; state-as-record
(`NotNow`, `ActivitySpike`); detector PORO in a job. Fizzy-specific: "Not Now" as
the destination, spike heuristics (3 comments / 2 people within a third of the
period), 14-day stall window, the bubble UI.

## Testing

- `test/models/card/entropic_test.rb` sets `last_active_at` relative to fixture
  entropies (`1.day.ago - entropies("37s_account").auto_postpone_period`), runs
  `Card.auto_postpone_all_due`, and asserts with
  `assert_difference -> { Card.postponed.count }, +1` and
  `assert_equal accounts("37s").system_user, cards(:logo).postponed_by`. Includes
  cross-account and "keeps going past a card that can't be postponed, then raises".
- `test/models/card/stallable_test.rb` and
  `test/models/card/activity_spike/detector_test.rb` (including "concurrent spike
  creation should not create multiple spikes for a card").
- `test/models/entropy_test.rb`: cards touched when entropy changes; invalid period
  falls back.
- `test/helpers/entropy_helper_test.rb` covers the bubble data.

## Reuse recipe

1. Add `last_active_at` to the decaying model; bump it from your event hook, not from
   each verb.
2. Create a settings record with `belongs_to :container, polymorphic: true`. Account
   gets one on create; child scopes get `has_one ... as: :container` and
   `def setting = super || account.setting`.
3. Expose it as `resource :entropy` (or your name) under account and board; accept a
   human unit (`*_in_days`) and validate against an allowed list.
4. Write `Model.sweep_all_due(as_of: Time.now)` as a class method: iterate accounts,
   group by effective period, query with constant cutoffs, act as
   `account.system_user`, collect failures, raise once at the end.
5. Schedule it in `config/recurring.yml` with `command:`.
6. Make the decay outcome an ordinary verb with a distinct event name
   (`auto_postpone` → `postpone(event_name: :auto_postponed)`).
7. For "heating up" signals, remember the change in `before_update`, enqueue a
   detector job in `after_update_commit`, and record state with
   `find_or_create_by!` behind a unique index.

## Related

[[components/events]] · [[patterns/events-as-spine]] · [[patterns/state-as-resource]] ·
[[patterns/jobs-later-now]] · [[patterns/model-concerns]] · [[components/notifications]] ·
[[voice/dhh-refactors]]
