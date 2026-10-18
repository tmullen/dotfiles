---
title: Watching (subscriptions and involvement)
use_when: [watch, subscribe, follow a record, subscribers, watchers, notification preferences per record, involvement level, "notify me about new items", auto-subscribe on comment, unsubscribe from a thread, who gets notified]
sources:
  - app/models/watch.rb, app/models/card/watchable.rb, app/models/user/watcher.rb
  - app/models/access.rb (enum :involvement), app/models/board/accessible.rb (#watchers)
  - app/models/comment.rb, app/models/mention.rb, app/models/card/assignable.rb (auto-watch callers)
  - app/models/notifier/card_event_notifier.rb, app/models/notifier/comment_event_notifier.rb
  - app/controllers/cards/watches_controller.rb, app/controllers/boards/involvements_controller.rb
  - app/views/cards/watches/*, app/views/cards/comments/_watchers.html.erb, app/helpers/accesses_helper.rb
  - test/models/card/watchable_test.rb, test/controllers/cards/watches_controller_test.rb
  - test/controllers/boards/involvements_controller_test.rb, test/models/card/commentable_test.rb
  - commits 59144ad17, 694783e5f, 0820badcc, e68b344cc, 5e0994460, eb0614c44, 418548b9b, 6073f7919, f1d76a7cb, ad58de9e7, edcc9e327
snapshot: 55bb38335
---

# Watching (subscriptions and involvement)

## Answer

There are two levels, and each lives on the record it describes. **Container level:**
the `Access` row that already grants a user a board carries an `involvement` enum
(`access_only` | `watching`). Board watchers hear about *new* cards. **Item level:**
a `Watch` row (`user`, `card`, `watching: boolean`) says who hears about activity on
*that* card. Users get item watches automatically when they create, comment on, are
assigned to, or are mentioned on a card. The toggles are singular resources:
`resource :watch` on the card, `resource :involvement` on the board. Notifiers only
ask `card.watchers` or `board.watchers`, so they never compute subscription rules.

## Shape

```
app/models/
  watch.rb               # belongs_to user, card (touch); scopes watching/not_watching
  card/watchable.rb      # has_many :watches, :watchers; watch_by/unwatch_by/watched_by?/watch_for; after_create subscribe_creator
  user/watcher.rb        # has_many :watches (a one-line role concern)
  access.rb              # enum :involvement, %i[ access_only watching ], default: :access_only
  board/accessible.rb    # def watchers = users.active.where(accesses: { involvement: :watching })
  comment.rb             # after_create_commit :watch_card_by_creator
  mention.rb             # after_create_commit :watch_source_by_mentionee
  card/assignable.rb     # assign → watch_by user
app/controllers/
  cards/watches_controller.rb          # show (etag), create, destroy
  boards/involvements_controller.rb    # update(involvement:)
app/views/cards/watches/_refresh.turbo_stream.erb   # replaces bell + "Subscribers" list together
app/views/cards/comments/_watchers.html.erb         # "N people will be notified when someone comments on this."
```

Routes:

```ruby
resources :boards do
  scope module: :boards do
    resource :involvement
  end
end

resources :cards do
  scope module: :cards do
    resource :watch
  end
end
```

Schema: `watches(user_id, card_id, watching boolean default true NOT NULL)`, indexed on
`[user_id, card_id]`. `accesses.involvement` is a string enum.

## Key code

```ruby
module Card::Watchable
  extend ActiveSupport::Concern

  included do
    has_many :watches, dependent: :destroy
    has_many :watchers, -> { active.merge(Watch.watching) }, through: :watches, source: :user

    after_create :subscribe_creator
  end

  def watched_by?(user)
    watch_for(user)&.watching?
  end

  def watch_for(user)
    watches.find_by(user: user)
  end

  def watch_by(user)
    watches.where(user: user).first_or_create.update!(watching: true)
  end

  def unwatch_by(user)
    watches.where(user: user).first_or_create.update!(watching: false)
  end

  private
    def subscribe_creator
      # Avoid touching to not interfere with the abandon card detection system
      Card.no_touching do
        watch_by creator
      end
    end
end
```

Participation subscribes people through each participant's own callback. `Comment`
and `Mention` call `watch_by` on their source, and `Comment` delegates `watch_by` to
its card, so a mention in a comment still watches the card:

```ruby
class Comment < ApplicationRecord
  after_create_commit :watch_card_by_creator
  delegate :watch_by, to: :card
end

class Mention < ApplicationRecord
  after_create_commit :watch_source_by_mentionee
  private
    def watch_source_by_mentionee
      source.watch_by(mentionee)
    end
end
```

Notifiers read the two lists and nothing else:

```ruby
# Notifier::CardEventNotifier#recipients
when "card_published"
  board.watchers.without(creator, *card.scan_mentionees).including(*card.assignees).uniq
else
  board.watchers.without(creator)

# Notifier::CommentEventNotifier#recipients
card.watchers.without(creator, *source.eventable.scan_mentionees)
```

The watch toggle is a singular resource with an etag. A watch row that doesn't exist
yet still needs a stable etag, so the action falls back to `"none"`:

```ruby
class Cards::WatchesController < ApplicationController
  include CardScoped

  def show
    fresh_when etag: @card.watch_for(Current.user) || "none"
  end

  def create
    @card.watch_by Current.user
    ...
  end

  def destroy
    @card.unwatch_by Current.user
    ...
  end
end
```

## Why

- **Opt-out is stored as `false`, not as a deleted row.** Kevin McConnell, 694783e5f
  "Allow toggling watch preference": *"We use a true/false preference so we can tell
  the difference between disabling the watch vs never having the watch. This is so we
  can toggle off and on the preferences for a container (like the bucket) without
  losing any bubble-specific preferences."* Card watchers and board watchers are now
  separate (below), so `watching: false` and "no row" notify the same way. The
  `not_watching` scope has no callers. The boolean still records an explicit opt-out
  (inference).
- **Involvement lives on the access row; there's no subscription table.** 0820badcc "Add
  involvement types to accesses": *"This change replaces our previous concept of
  subscriptions. Where previously you'd subscribe to a collection to get notifications
  in it, now you'll simply set the notification level on your access."* The
  `Subscribable` concern and `subscriptions` table were deleted. A user who can see
  the board already has a row, so the level is a column on that row.
- **Fewer levels.** The enum started as `access_only watching everything`. Jason
  Zimdars removed the third in e68b344cc "Remove _Everything_ inolvement".
- **Card watchers and board watchers are separate.** Jorge, 5e0994460 "Separate card and
  collection watchers" (PR #1231) deleted `watchers_and_subscribers(include_only_watching:)`,
  a set computation that merged board subscribers with card watch overrides. Now
  `board.watchers` is for new-card announcements and `card.watchers` is for activity
  on the card. Each is a plain association or scope.
- **Verb pairs instead of a boolean argument.** DHH, eb0614c44 "Use a more ergonomic
  API for watching": *"Passing a boolean vs using explicit on/off methods feel too low
  level and doesnt read right in most of these cases."* `set_watching(user, true)`
  became `watch_by user` / `unwatch_by user`.
- **Look up one row, cache on it.** DHH, 418548b9b "More efficient query for
  watched_by? and use etag for the status": `watchers.include?(user)` (which loads the
  set) became `watch_for(user)&.watching?`, and the `show` action got `fresh_when`.
- **Inactive users never watch.** f1d76a7cb "Exclude inactive users": *"The system user
  should never be a subsriber but we should not serve it if it is"*. Hence `active`
  in the association scope.
- **Don't let the creator's auto-watch count as activity.** 6073f7919 "Invalidate cards
  when watching/unwatching" made `Watch` `belongs_to :card, touch: true` so the card's
  cache busts. The same commit wrapped `subscribe_creator` in `Card.no_touching`,
  because touching at creation would interfere with stale-card detection
  ([[components/entropy]]).
- **Access cleanup happens elsewhere.** ad58de9e7 "Remove access checks when watching"
  dropped access checks from `watch_by`. When access is lost,
  `Card#clean_inaccessible_data` and `Board::Accessible#clean_inaccessible_data_for`
  delete the stale `watches` in a job. The notifier also filters recipients by
  current access. See [[components/notifications]].
- **The UI shows who'll hear you.** `_watchers.html.erb` sits under the comment form
  and reads *"N people will be notified when someone comments on this."* The watch
  toggle re-renders it in the same turbo stream (`_refresh.turbo_stream.erb`).
  (Fizzy product choice)

**Reusable vs Fizzy-specific.** The reusable parts: item-level `Watch` rows with
`watch_by`/`unwatch_by`, auto-watch from participants' callbacks, container-level
involvement on the access row, notifiers that only read `*.watchers`, and singular
resources for the toggles. These are Fizzy product choices: the two involvement
levels, mentionees and assignees auto-watching, and board watchers hearing only about
newly published cards.

## Testing

- `test/models/card/watchable_test.rb` resets state in setup
  (`Watch.destroy_all; Access.all.update!(involvement: :access_only)`) and then
  asserts on `watched_by?` and on `watchers` after `watch_by`/`unwatch_by`. It also
  checks that `users(:david).system!` drops the user from `watchers.reload`.
- The auto-watch rules are tested next to the action that triggers them:
  `test/models/card/commentable_test.rb` ("creating a comment ... makes the creator
  watch"), `test/models/card/assignable_test.rb` ("assigning a user makes them watch
  the card"), and `test/models/concerns/mentions_test.rb` ("mentionees are added as
  watchers").
- Controller tests use `assert_changes -> { cards(:logo).watched_by?(users(:kevin)) },
  from: false, to: true`. Involvement uses `assert_changes -> { board.access_for(users(:kevin)).involvement }`.

## Reuse recipe

1. `create_table :watches` with `user`, the watched record, `watching: boolean, default: true, null: false`, and an index on `[user_id, record_id]`.
2. Add a `Record::Watchable` trait with `has_many :watchers, -> { active.merge(Watch.watching) }, through: :watches, source: :user`, plus `watch_by`, `unwatch_by` (`first_or_create.update!`), `watch_for`, `watched_by?`, and `after_create` to subscribe the creator.
3. Have each participant model watch in its own `after_create_commit`: comments, mentions, assignments.
4. For container-wide follow, add an `involvement` enum to the existing membership/access row and a `Container#watchers` scope. Don't add a separate subscriptions table.
5. Routes: `resource :watch` (show/create/destroy) on the item and `resource :involvement` (update) on the container. Give the show action an etag on the user's watch row.
6. Notifiers compute recipients as `watchers.without(actor, *already_notified_another_way)`.
7. When access is revoked, delete watches in a background job and keep `watch_by` itself unconditional.

## Related

[[components/notifications]] · [[components/access]] · [[components/comments]] ·
[[components/mentions]] · [[components/assignments]] · [[components/entropy]] ·
[[patterns/state-as-resource]] · [[voice/dhh-refactors]]
