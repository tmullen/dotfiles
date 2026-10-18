---
title: Naming — models, traits, verbs, scopes, controllers, jobs
use_when: [what should I call this, naming a concern, naming a model, naming a method, naming a controller, naming a scope, verb pair, bang method, service object name, -able suffix, rename, domain language, handle_ prefix, toggle method]
sources:
  - STYLE.md ("To bang or not to bang", "CRUD controllers", "Run async operations in jobs")
  - app/models/card.rb, app/models/board.rb, app/models/user.rb, app/models/account.rb
  - app/models/{card,board,user,account,identity,webhook}/*.rb, app/models/concerns/*.rb
  - app/controllers/**/*_controller.rb, app/controllers/concerns/*.rb, config/routes.rb
  - app/jobs/**/*.rb, app/models/webhook.rb (PERMITTED_ACTIONS)
  - evidence/dhh-commits.txt
  - commits 7a46fd094, b788ef163, 770029c26, 62088b66d, b3474ec97, 4f3f32252, 384de2413, e4c6fe4b5, 5e78a1dab, 2357c7506, 63c05220c, ca388c2b8, 27c73ff42, 43ab17df2, b5205ce6b, 0948533da, bfb7ed121, 723e6d94f, 39ec6cf06
snapshot: 27d0d2e6b
---

# Naming — models, traits, verbs, scopes, controllers, jobs

## Answer

Names come from the **domain**, read as **English**, and come in **pairs**. Models are
nouns (`Card`, `Closure`, `Goldness`, `NotNow`). Model concerns are **adjectives or
capabilities** of the host (`Closeable`, `Golden`, `Entropic`, `Watchable`) — or a
role noun when the host *is* something (`User::Accessor`, `User::Watcher`). Methods are
verbs with matching opposites (`close`/`reopen`, `gild`/`ungild`, `pin_by`/`unpin_by`),
predicates are adjectives (`closed?`, `golden?`, `watched_by?`), scopes are adjectives or
adverbs (`closed`, `golden`, `chronologically`, `preloaded`). Controllers are plural
nouns, often nouns invented from verbs (`ClosuresController`, `ReadingsController`,
`LeftPositionsController`). Jobs are `Model::VerbJob` mirroring the method they call.
No `Service`, `Manager`, `Handler` or `Interactor` anywhere in `app/` or `lib/`.

## Shape

The vocabulary, by kind (real names from the snapshot):

| Kind | Form | Examples |
|---|---|---|
| Model | domain noun | `Card`, `Board`, `Column`, `Closure`, `Card::Goldness`, `Card::NotNow`, `Board::Publication`, `Account::Cancellation`, `Access`, `Pin`, `Watch`, `Mention`, `Entropy`, `Card::ActivitySpike` |
| State record | noun of the verb | close → `Closure`, gild → `Goldness`, publish → `Publication`, cancel → `Cancellation`, postpone → `NotNow` (the UI's own term) |
| Model concern (capability) | `-able` | `Closeable`, `Watchable`, `Assignable`, `Commentable`, `Pinnable`, `Postponable`, `Readable`, `Taggable`, `Triageable`, `Eventable`, `Notifiable`, `Publishable`, `Cancellable`, `Incineratable`, `Triggerable`, `Joinable`, `Transferable` |
| Model concern (quality) | adjective | `Card::Golden`, `Card::Colored`, `Card::Entropic`, `Card::Accessible`, `Card::Stallable`, `User::Named`, `Column::Positioned`, `Storage::Tracked`, `Storage::Totaled` |
| Model concern (role) | agent noun | `User::Accessor`, `User::Assignee`, `User::Watcher`, `User::Searcher`, `User::Role` |
| Model concern (collection) | plural noun | `Mentions`, `Attachments`, `Card::Statuses`, `Board::Cards`, `Filter::Fields` |
| Model concern (process) | gerund | `Board::AutoPostponing`, `User::Filtering` (PORO) |
| PORO | agent or plain noun | `Notifier`, `Card::ActivitySpike::Detector`, `Card::Eventable::SystemCommenter`, `Account::Seeder`, `Webhook::DelinquencyTracker`, `Event::Description`, `User::DayTimeline`, `Notification::PushTarget`, `Signup` |
| Command verb | bare verb, actor keyword | `close(user: Current.user)`, `postpone`, `resume`, `publish`, `incinerate`, `cancel(initiated_by:)`, `triage_into(column)`, `send_back_to_triage`, `move_to(board)` |
| Per-user verb | `verb_by(user)` | `pin_by`/`unpin_by`, `watch_by`/`unwatch_by`, `read_by`/`unread_by`, `accessed_by`, `mentioned_by(mentioner, at:)` |
| Predicate | adjective `?` | `closed?`, `open?`, `golden?`, `postponed?`, `drafted?`, `awaiting_triage?`, `watched_by?(user)`, `pinned_by?(user)`, `accessible_to?(user)`, `can_administer_board?(board)` |
| Reader of state record | `verb_ed_by` / `_at` | `closed_by`, `closed_at`, `postponed_by`, `postponed_at` |
| Scope (state) | adjective | `closed`, `open`, `golden`, `postponed`, `active`, `stalled`, `unassigned`, `published`, `unread` |
| Scope (order) | adverb / superlative | `chronologically`, `reverse_chronologically`, `alphabetically`, `latest`, `ordered`, `recently_closed_first`, `with_golden_first` |
| Scope (preload) | `preloaded`, `with_x` | `preloaded`, `with_users`, `with_avatars` |
| Scope (filter by actor/arg) | `verb_ed_by`/`_to` | `closed_by(users)`, `assigned_to(users)`, `assigned_by(users)`, `tagged_with`, `mentioning(query, user:)`, `triggered_by(event)` |
| Class-level sweep | `verb_all[_due]`, `cleanup` | `deliver_all`, `auto_postpone_all_due`, `Export.cleanup`, `MagicLink.cleanup` |
| Async | `verb_later` | `notify_recipients_later`, `push_later`, `deliver_later`, `build_later` |
| Event action | `prefix_past_tense` | `card_closed`, `card_reopened`, `card_postponed`, `card_triaged`, `card_sent_back_to_triage`, `comment_created` |
| Controller | plural noun under parent module | `Cards::ClosuresController`, `Cards::GoldnessesController`, `Cards::NotNowsController`, `Notifications::BulkReadingsController`, `Columns::LeftPositionsController`, `Users::JoinsController`, `Signups::CompletionsController` |
| Controller namespace | context noun | `My::` (things hinged on `Current.user`), `Public::` (unauthenticated), `Prompts::` (autocomplete sources), `Columns::Cards::Drops::` (drag-and-drop targets) |
| Controller concern | `ParentScoped` or capability | `CardScoped`, `BoardScoped`, `FilterScoped`; `Authentication`, `Authorization`, `CurrentRequest`, `TurboFlash` |
| Job | `Model::VerbJob` | `Card::ReindexCommentsJob`, `Notification::PushJob`, `Notification::Bundle::DeliverJob`, `Webhook::DeliveryJob`, `NotifyRecipientsJob` (shared concern → top level) |

## Key code

A trait's names line up across scope, predicate, verb pair and state record:

```ruby
module Card::Golden
  included do
    has_one :goldness, dependent: :destroy, class_name: "Card::Goldness"
    scope :golden, -> { joins(:goldness) }
    scope :with_golden_first, -> { ... }
  end

  def golden? = goldness.present?           # (condensed)
  def gild    = (create_goldness! unless golden?)
  def ungild  = goldness&.destroy
end
# route: resource :goldness → Cards::GoldnessesController#create/#destroy
```

Per-user verbs take the user explicitly and read like a sentence:

```ruby
@card.watch_by Current.user
@card.pin_by Current.user
@card.read_by(Current.user)
mentionee.mentioned_by mentioner, at: self
@board.accessed_by(Current.user)
```

Commands default the actor from `Current` but accept it:

```ruby
def close(user: Current.user) ...
def cancel(initiated_by: Current.user) ...
```

## Why

- **Domain language over UI or implementation words.** DHH renamed partials
  `_closure_toggle` → `_closure` (b788ef163 "Match domain language"), `_golden_toggle`
  → `_gild` (770029c26 "Stick with domain language"), `_doing_toggle` → `_engagement`
  (b5d6d4046 "Use domain language termn"). Jorge: *"don't be aseptic; double down on
  boldness."* ([Domain driven boldness](https://dev.37signals.com/domain-driven-boldness/))
  — hence `gild`, `Goldness`, `Entropy`, `NotNow`, `incinerate`, `ActivitySpike`.
- **Opposites must match.** DHH's 7a46fd094 "Stick with open/close as a consistent pair
  instead of active/close" renamed `active`/`active?` to `open`/`open?` in every scope
  and caller. `active` now means something else (open, published, not postponed).
- **No "toggle".** A toggle hides two verbs behind one name. DHH: 384de2413 "Get rid of
  odd toggles concept"; e4c6fe4b5 "Shape up pinning API and broadcast in the
  controller" turned `set_pinned(user, pinned)` into `pin_by`/`unpin_by`. Survivors
  (`toggle_assignment`, `toggle_tag_with`) are picker UIs where one click flips. When a
  toggle must stay, name its argument: 5e78a1dab "Make it clearer that this takes a
  title string not a tag object" (`toggle_tag` → `toggle_tag_with`).
- **Drop qualifiers the context supplies.** DHH's 62088b66d "Suffix qualifier is
  unnnecessary" (`rerender_card_container` → `rerender_card`); b3474ec97 "Rename
  Entropy::Configuration to just Entropy". `Card::NotNow` doesn't say "Card" twice;
  `Cards::ClosuresController` doesn't say "Card".
- **Pick one spelling and finish the rename.** 4f3f32252 "Rename inconsistency: go with
  goldness" (the controller had shipped as `Goldenesses`). Whole-product renames are
  done in code too: Jorge's 723e6d94f "Rename bubbles => cards" (333 files) and
  39ec6cf06 "Replace collection with board in the code, tests green", with legacy URL
  redirects kept in `config/routes.rb` and an `etag { "v1" }` bump. Don't leave the old
  word in the code because "the UI changed but the model didn't". (inference from the
  two renames)
- **Verbs first for callbacks and actions.** DHH's 2357c7506 "Reads better with a verb
  first" (`creator_watches_card` → `watch_card_by_creator`). Stanko's ca388c2b8 "Replace
  handle_ naming" (`handle_valid_code_for` → `authenticate`, `handle_sign_in_with` →
  `sign_in`). Scopes say the relation: 63c05220c "Clearer naming" (`via_card` →
  `belonging_to_card`).
- **Bang only when there's a non-bang twin.** STYLE.md: *"we only use `!` for methods
  that have a correspondent counterpart without `!`. In particular, we don’t use `!` to
  flag destructive actions."* Jeremy Daer's 43ab17df2 "Update tests with final method
  naming: record! -> record". `Account::Seeder` has both `seed` and `seed!`, so the
  bang is allowed there. The 2024 `pop!` became plain `close`.
- **Don't shadow the framework.** Stanko's 27c73ff42 "Rename validate to check": *"Validate
  is an ActiveModel method, overriding it could have unintended side-effects"*.
- **A class name should make its main method read naturally.** Rosa Gutierrez's
  b5205ce6b "Rename Push to PushTarget for better readability" (*"PushTarget#push reads
  more naturally than Push#push"*) and 0948533da "Rename push to process on PushTarget
  for clearer semantics".
- **`My::` means "hinged off Current.user".** DHH's bfb7ed121 "Move pins to my space":
  *"We used the my/ space in HEY to reflect anything that was primarily hinged off
  Current.user. Good to use here too."*
- **Names are worth arguing about.** Jorge: *"With the importance of names to make code
  understandable, how can anyone consider discussing those superfluous?"* ([Minding the
  small stuff](https://dev.37signals.com/minding-the-small-stuff-in-pr-reviews/)). DHH on
  not abbreviating: *"we're not going to abbreviate."* ([Lex Fridman #474](https://lexfridman.com/dhh-david-heinemeier-hansson-transcript/))
  — `reverse_chronologically`, `ensure_permission_to_administer_card`,
  `remove_inaccessible_notifications_later` are long and fine.
- **Fizzy-specific, don't copy blindly:** `Seedeable` and `Incineratable` are
  idiosyncratic spellings; `Boards::Columns::ClosedsController` pluralizes an adjective
  because the "Closed" column is a thing in the UI; `resource :publish` is a verb where
  `Board` uses `publication`. These are tolerated inconsistencies, not rules (inference).

## Testing

Tests inherit the names: `test/models/card/golden_test.rb` → `Card::GoldenTest`,
`test/controllers/cards/goldnesses_controller_test.rb` →
`Cards::GoldnessesControllerTest`. Test names describe behavior in domain words
(`"promote and demote from golden"`, `"users can only see cards in boards they have
access to"`). When a method is renamed, test names are renamed with it (43ab17df2).

## Reuse recipe

1. Write one paragraph describing the feature in plain English. Every noun is a model or state-record candidate; every verb is a method; opposites become pairs.
2. Concern = what the host *is* or *can do*: `-able` for capabilities, adjectives for qualities, an agent noun for roles of a `User`. File it at `app/models/<model>/<trait>.rb`.
3. Give each verb its opposite (`publish`/`unpublish`, `close`/`reopen`). Predicates: `closed?`. Readers off the state record: `closed_by`, `closed_at`. Scopes: `closed`/`open`.
4. Per-user operations: `verb_by(user)`. Actor defaults: `user: Current.user`.
5. Turn non-CRUD verbs into nouns for routes and controllers (`closure`, `reading`, `left_position`).
6. Async: `verb_later` + `Model::VerbJob`. Sweeps: `verb_all`, `cleanup`.
7. Never: `toggle_*` (unless it's truly one button), `handle_*`, `*Service`, `*Manager`, `!` without a twin, names that shadow Rails (`validate` on a model).
8. When the product word changes, rename the code, keep redirects for old URLs.

## Related

[[patterns/model-concerns]] · [[patterns/state-as-resource]] · [[patterns/jobs-later-now]] ·
[[patterns/controller-scoping]] · [[voice/dhh-refactors]] · [[sources]]
