---
title: Concerns as traits of a rich model
use_when: [fat model, god object, where does this method go, service object, organize a big model, concern, mixin, extract module, model too long, has_one state record]
sources:
  - app/models/card.rb, app/models/card/*.rb
  - app/models/board.rb, app/models/user.rb
  - app/models/concerns/*.rb
  - app/controllers/concerns/*.rb
  - commits 22abf0ba4, 9913853cc, fb395c8b0, 78369725c, 7a46fd094
snapshot: 55bb38335
---

# Concerns as traits of a rich model

## Answer

A domain model is the sum of its **traits**, each one a concern named as an adjective
or capability (`Closeable`, `Golden`, `Watchable`, `Postponable`) and stored under the
model's namespace (`app/models/card/closeable.rb` → `Card::Closeable`). Each concern
is a *complete slice of behavior*: its associations, scopes, callbacks, predicates and
verbs, all together. The model file is a table of contents. There are no service
objects. When a trait carries state, the state is its **own small record**
(`Card::Goldness`, `Closure`, `Card::NotNow`) rather than a boolean column, and that
record is exposed as a singular REST resource.

## Shape

```
app/models/
  card.rb                 # 112 lines: one include line with 23 traits, then associations, search, scopes
  card/
    closeable.rb          # trait
    golden.rb             # trait
    goldness.rb           # the state record Golden manages
    postponable.rb        # trait
    not_now.rb            # the state record Postponable manages
    eventable.rb          # specializes the shared ::Eventable
    eventable/system_commenter.rb   # PORO that belongs only to this trait
    ...
  concerns/               # only 5 files: traits shared across *different* models
    eventable.rb  notifiable.rb  mentions.rb  attachments.rb  filterable.rb
app/controllers/concerns/
  card_scoped.rb  board_scoped.rb  column_scoped.rb ...   # "load the parent" concerns
```

Snapshot counts: 65 namespaced model concerns and 5 shared ones. `Board` is 15
lines including 10 traits. `User` is 42 lines.

```ruby
class Card < ApplicationRecord
  include Accessible, Assignable, Attachments, Broadcastable, Closeable, Colored, Commentable,
    Entropic, Eventable, Exportable, Golden, Mentions, Multistep, Pinnable, Postponable, Promptable,
    Readable, Stallable, Statuses, Storage::Tracked, Taggable, Triageable, Watchable
  ...
end
```

## Key code

A full trait. It contains the association, scopes, predicate, and the verb pair:

```ruby
module Card::Golden
  extend ActiveSupport::Concern

  included do
    has_one :goldness, dependent: :destroy, class_name: "Card::Goldness"

    scope :golden, -> { joins(:goldness) }
    scope :with_golden_first, -> { left_outer_joins(:goldness).prepend_order("card_goldnesses.id IS NULL").preload(:goldness) }
  end

  def golden?
    goldness.present?
  end

  def gild
    create_goldness! unless golden?
  end

  def ungild
    goldness&.destroy
  end
end

class Card::Goldness < ApplicationRecord
  belongs_to :account, default: -> { card.account }
  belongs_to :card, touch: true
end
```

A trait whose verb does several things uses a transaction and tracks an event. It
takes the actor as a keyword that defaults to `Current.user`:

```ruby
module Card::Closeable
  ...
  def close(user: Current.user)
    unless closed?
      transaction do
        not_now&.destroy
        create_closure! user: user
        track_event :closed, creator: user
      end
    end
  end
end
```

A shared concern exposes hook methods, and the per-model concern overrides them. This
is the template method pattern applied to modules:

```ruby
module Eventable                     # app/models/concerns
  def track_event(action, creator: Current.user, board: self.board, **particulars)
    if should_track_event?
      board.events.create!(action: "#{eventable_prefix}_#{action}", creator:, board:, eventable: self, particulars:)
    end
  end

  def event_was_created(event); end

  private
    def should_track_event? = true
end

module Card::Eventable               # app/models/card
  include ::Eventable

  def event_was_created(event)
    transaction do
      create_system_comment_for(event)
      touch_last_active_at unless was_just_published?
    end
  end

  private
    def should_track_event?
      published?
    end
end
```

The controller drives the trait through a singular resource. A shared controller
concern loads the parent record:

```ruby
# routes: resources :cards { scope module: :cards { resource :goldness; resource :closure; resource :pin; resource :watch } }
class Cards::GoldnessesController < ApplicationController
  include CardScoped

  def create
    @card.gild
    ...
  end

  def destroy
    @card.ungild
    ...
  end
end
```

## Why

- **This is DHH's direct answer to "fat models".** A big model is fine when it is
  organized, and concerns are the organizing tool. DHH, 2012: *"These concerns
  encapsulate both data access and domain logic about a certain slice of
  responsibility."* ([Put chubby models on a diet with concerns](https://signalvnoise.com/posts/3372-put-chubby-models-on-a-diet-with-concerns))
  Jorge: *"we don't default to create services, actions, commands, or interactors to
  implement controller actions."* ([Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/))
- **A concern is a trait, not a drawer.** *"each concern should be a cohesive unit
  that captures a trait of the host model"* and *"You should not treat concerns as
  arbitrary containers of behavior and structure to split a large model into smaller
  parts."* ([Good concerns](https://dev.37signals.com/good-concerns/)) That post also
  gives the folder rule Fizzy follows: model-specific concerns go in
  `app/models/<model_name>/`, shared ones in `app/models/concerns`.
- **Heavy behavior hides behind the trait.** Jorge again: *"rich internal object
  models hidden behind high-level APIs on domain models."* The concern is the door,
  and POROs such as `SystemCommenter` do the work behind it.
- **A concern has to earn its file.** DHH removed `Colorable` in 22abf0ba4 "Remove
  anemic concern": it held only two constants and no behavior, so the constants
  moved into `Card::Colored`, the one trait that used them. He made the same cut on
  the controller side in 9913853cc: `Search::QueryTermsScoped` existed only to set
  `@query_terms = params[:q]`, so it was inlined to `params[:q]`. "Anemic" appears
  in 19 of his 548 commit subjects.
- **Keep everything about a trait inside the trait.** In fb395c8b0 "Keep all entropy
  definitions together in the concern", DHH moved a stray line from `collection.rb`
  into `Collection::Entropic`. In 78369725c, "Move card concern logic into those
  concerns".
- **Name verb pairs consistently.** In 7a46fd094 "Stick with open/close as a
  consistent pair instead of active/close", DHH renamed `active`/`active?` to
  `open`/`open?` in every scope and caller.
- **State as a record, not a boolean.** A `Closure` row records who closed the card
  and when (`closed_by`, `closed_at` come from it). `closed`/`open` scopes become
  `joins` and `where.missing`. Toggling the state maps to creating and destroying a
  record, which maps to `resource :closure`. See [[patterns/state-as-resource]].
- **Shared concerns are rare.** Only behavior that genuinely crosses unrelated models
  (events, notifications, mentions, attachments) goes in `app/models/concerns`.
  Everything else is namespaced, so a grep for `Card::` finds all of a card. This is
  the folder rule from *Good concerns* (above). Snapshot counts: 5 shared vs 65 namespaced.
- **POROs live with the trait that needs them.** `Card::Eventable::SystemCommenter`
  is a plain object nested under the concern that uses it. It is not a top-level
  "service". Jorge: *"You can find many POROs in our app/models folders."*
  ([Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/)) Nesting
  them under the trait is Fizzy's habit (inference from the code layout).

## Testing

Tests mirror the namespace: `test/models/card/colored_test.rb`, `test/models/card/closeable_test.rb`.
Each test exercises the trait through the real model and fixtures (`cards(:logo).close`),
never by testing the module in isolation with a dummy class.

## Reuse recipe

1. When a model grows, group its methods by capability and name each group with an adjective or "‑able": `Closeable`, `Archivable`, `Publishable`.
2. Move everything about that capability into `app/models/<model>/<trait>.rb`, including associations, scopes and callbacks.
3. If the trait has on/off state worth auditing, make it a `has_one` record. Expose `thing?`, `verb`, `unverb`, and a `resource :thing` controller.
4. Put a concern in `app/models/concerns` only when two unrelated models need it. Give it hook methods so the models can specialize it.
5. Delete any concern that holds only constants or wraps a single line.
6. Load the parent in controllers with `XScoped` concerns (`before_action :set_card`), scoped through `Current.user`.

## Related

[[patterns/state-as-resource]] · [[patterns/events-as-spine]] · [[components/notifications]] ·
[[voice/dhh-refactors]] · [[testing/fixtures]]
