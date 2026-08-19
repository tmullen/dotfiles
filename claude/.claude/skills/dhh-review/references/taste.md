# The taste catalog

Ordered as the seven lenses in `SKILL.md`. Check every finding against `conflicts.md` before reporting it. Shape (lens 1) is covered in `SKILL.md`.

Provenance, because it decides how you cite:

- **[STYLE]** — 37signals' own rule, from `~/Work/Vendor/fizzy/STYLE.md`. Their law; taste here.
- **[DHH]** — his broader published positions. Weighty, not law.
- **[OURS]** — already our rule. Cite ours: compliance, not preference.

---

## Organization — does it live where Rails already has a place?

### Vanilla Rails is plenty **[STYLE][DHH][OURS: P18]**

Thin controllers invoking a rich domain model. No services, no interactors, no repositories around Active Record.

```ruby
# Bad — a layer invented to avoid putting behavior on the model
class CardClosingService
  def initialize(card, user)
    @card, @user = card, user
  end

  def call
    @card.update!(closed_at: Time.current, closed_by: @user)
    CardMailer.closed(@card).deliver_later
    Event.create!(action: "card_closed", recording: @card)
  end
end

# Good — the model owns its own behavior
class Card < ApplicationRecord
  def close
    update! closed_at: Time.current, closed_by: Current.user
    notify_closed_later
    record_event :card_closed
  end
end
```

A `Service`/`Manager`/`Interactor`/`Command`/`Handler` that only calls two model methods is the finding. Ask what the model method should have been named.

Plain Active Record in a controller is fine, not a smell **[STYLE]**:

```ruby
class Cards::CommentsController < ApplicationController
  def create
    @comment = @card.comments.create!(comment_params)
  end
end
```

Service and form objects are allowed **when justified** — as ordinary objects, not a tier every feature passes through **[STYLE]**: `Signup.new(email_address: email_address).create_identity`.

### Concerns organize a rich model **[DHH]**

A fat model is fine; a disorganized one isn't. Extract behavior into concerns named for the behavior, namespaced under the model. `Card::Helpers` is a junk drawer, not an extraction.

```ruby
# app/models/card/closable.rb
module Card::Closable
  extend ActiveSupport::Concern

  included do
    scope :closed, -> { where.not(closed_at: nil) }
  end

  def close
    # ...
  end
end
```

### Shallow jobs; the model does the work **[STYLE][OURS: Thin Jobs]**

`_later` enqueues, `_now` performs, the job body is one line. Logic inside `perform` is the finding — it can't run from a console or a test without the queue.

```ruby
module Event::Relaying
  extend ActiveSupport::Concern

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

---

## Naming **[DHH][OURS: P14]**

Naming is the work. Reach for the domain's word before a technical one: `card.gild` over `CardGoldStatusApplier.new(card).apply`; `entropy` over `inactivity_based_auto_postponement_period`; `Access` over `BoardPermissionAssignment`.

Strike unless they carry meaning: `_data`, `_info`, `_object`, `_item`, `_manager`, `_helper`, `_util`, `_wrapper`, `perform_`, `do_`, `handle_`.

Read the name where it lands — an import line, a stack trace, a grep result. `GalleryPage` inside `gallery/` stutters; `Page` doesn't.

Booleans read as assertions: `card.closed?`, never `card.get_closed_status`. A name needing a comment to be understood is usually the name's fault.

---

## Abstraction — to abstract or not **[DHH][OURS: P3, P19]**

The call he's most opinionated about, and the one missed in both directions.

**Don't.** Delete on sight: an abstraction with one caller and no second in sight; a parameter no caller passes; a flag only ever passed one way; a wrapper that only forwards; a stateless class with one method (that's a model method); structure for a feature that doesn't exist.

**Do.** A missing *name*, not a missing layer: three sites that must agree on one value or rule (P19); a concept the domain has a word for that the code spells longhand; a three-line private method with one caller, when its name says what those lines mean.

That last one is the whole distinction: **extract to name a concept, not to satisfy a rule.** The same extraction is noise when the name restates the body.

Conceptual compression **[DHH]**: the better design has fewer moving parts, not more indirection. Count the concepts a new reader must hold, not the lines.

---

## Routing and resource design **[STYLE][OURS: P13]**

When an action doesn't map to a CRUD verb, introduce a resource. Don't bolt a verb onto a controller.

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

`POST /cards/:id/closure` closes, `DELETE` reopens — the inverse comes free and no caller can construct an invalid verb. The controller says what happens, not how: `def create; @card.gild; end`.

---

## Readability

### Ordering **[STYLE]**

Class methods, then public with `initialize` first, then private. Order methods by when they're called, so the file reads as the flow: a private method below its caller, its own helpers below it.

```ruby
class SomeClass
  def some_method
    method_1
    method_2
  end

  private

  def method_1
    method_1_1
  end

  def method_1_1
  end

  def method_2
  end
end
```

> Fizzy indents these under `private`; we are flat, 50 files of 50 (`conflicts.md`). Never flag indentation under a visibility modifier, either direction.

### Expanded conditionals over guard clauses **[STYLE]** — taste, not law here

The opposite of what most linters want. `Style/GuardClause` is off in omakase, so neither form fails CI. Raise it once as his preference; never as compliance.

```ruby
def todos_for_new_group
  if ids = params.require(:todolist)[:todo_ids]
    @bucket.recordings.todos.find(ids.split(","))
  else
    []
  end
end
```

Assignment inside the condition is idiomatic to him, not a typo for `==`. A guard clause is right when both hold: the return is at the very start, and the body is non-trivial.

```ruby
def after_recorded_as_commit(recording)
  return if recording.parent.was_created?

  if recording.was_created?
    broadcast_new_column(recording)
  else
    broadcast_column_change(recording)
  end
end
```

### Bangs **[STYLE]**

`!` only where a non-bang counterpart exists. It doesn't mean "destructive" — plenty of destructive Rails methods have no bang. A lone `destroy_everything!` is wrong.

### Rails idioms before hand-rolling **[DHH]**

`scope`, `delegate`, `has_many` with a lambda, `enum`, `Current`, `after_create_commit`, `presence`, `dig`, `then`. A hand-written loop where a scope belongs is a finding.

---

## Comments **[DHH][OURS: P16]**

The code carries the *what*. A comment paraphrasing the next line is deleted on sight. One earns its place only for a *why* the code can't hold — a non-obvious decision, an external bug with a link, a regulatory invariant — and then it's one line. If a method needs a comment to be understood, the fix is a better name or an extraction.

---

## Tests **[DHH]**

Minitest, fixtures over factories — fixtures are a shared readable vocabulary; factory cascades hide what a test needs. Test through the public interface: asserting a private method was called tests the arrangement, not the behavior. Few mocks; a mock of your own object mostly asserts you wrote the mock. System tests for journeys that matter, not every branch.

---

## Beyond Ruby

Transfers to any language, our TypeScript included: read it aloud and rename if it doesn't say what it does; no layer the framework already provides; fewer parts over more indirection; the domain's vocabulary, not the pattern catalog's; and the shape lens works on any file with functions in it.

Doesn't transfer: the Ruby texture rules — bangs, expanded conditionals, visibility layout. Don't flag a `.tsx` for those, and never review our frontend for *being* React or TypeScript (`conflicts.md` §2).
