---
title: Turbo and caching — stream templates, morphing, broadcasts, etags
use_when: [turbo stream, turbo_stream.erb, render turbo_stream inline, morph, page refresh, broadcasts_refreshes, broadcast from model, real-time updates, action cable, fresh_when, etag, 304, HTTP caching, fragment caching, russian doll, cache key, lazy turbo frame, per-user content in cached page, slow page]
sources:
  - app/views/**/*.turbo_stream.erb (38 templates), app/views/layouts/shared/_head.html.erb
  - app/controllers/concerns/card_scoped.rb, app/controllers/application_controller.rb
  - app/controllers/cards/{closures,pins,watches}_controller.rb, app/controllers/notifications/trays_controller.rb, app/controllers/boards_controller.rb, app/controllers/my/menus_controller.rb
  - app/models/card/broadcastable.rb, app/models/board/broadcastable.rb, app/models/card/pinnable.rb, app/models/notification.rb, app/models/card.rb
  - app/views/cards/_container.html.erb, app/views/cards/container/footer/_published.html.erb, app/views/cards/show.html.erb, app/views/my/_menu.html.erb
  - app/javascript/initializers/current.js
  - test/test_helpers/card_test_helper.rb, test/controllers/my/menus_controller_test.rb, test/models/notification_test.rb, test/models/card/pinnable_test.rb, test/system/card_refresh_test.rb
  - commits cf503bfba, 3116cea6a, 887559d1a, 7adbd8d63, 3e1a2bcc7, 5a740a425, 418548b9b, 6570f5fc0, 690d6ced4, 66d397fa8, b8c3ac814, 9312f6b35, 2527f0736, d37480d06, 966aa51a3, 4d0dddec4, b2e2a5d95
snapshot: 55bb38335
---

# Turbo and caching — stream templates, morphing, broadcasts, etags

## Answer

Fizzy gets its speed from HTTP and HTML caching, and its liveliness from **morphing
refreshes** rather than hand-written DOM updates.
- **Responses:** a mutation renders a `.turbo_stream.erb` template (not inline
  `render turbo_stream:`), usually `turbo_stream.replace(..., method: :morph)` of the
  surrounding container.
- **Other viewers:** models declare `broadcasts_refreshes`; pages subscribe with
  `turbo_stream_from @record`; the layout sets `turbo_refreshes_with method: :morph,
  scroll: :preserve`. A change tells subscribers "refresh", and Turbo morphs the page.
- **Reads:** `fresh_when etag: ...` on almost every GET; fragment `cache record` on
  shared partials; `touch: true` chains keep keys honest.
- **Per-user bits** never go inside a shared cached fragment. They're lazy
  `turbo_frame_tag ... src:` requests to small etagged `show` actions, or JS that reads
  `<meta name="current-user-id">`.

## Shape

```
app/views/layouts/shared/_head.html.erb   # turbo_refreshes_with method: :morph, scroll: :preserve
app/views/cards/
  show.html.erb                 # turbo_stream_from @card; turbo_stream_from @card, :activity
  _container.html.erb           # <% cache card do %> ... shared by every viewer
  container/footer/_published.html.erb   # turbo_frame_tag card, :watch / :pin, src:, refresh: :morph
  closures/create.turbo_stream.erb       # replaces closed column, source column, card container
  watches/_refresh.turbo_stream.erb      # shared partial for create + destroy templates
app/views/boards/show.html.erb  # turbo_stream_from @board
app/views/notifications/_tray.html.erb   # turbo_stream_from Current.user, :notifications
app/models/
  card/broadcastable.rb         # broadcasts_refreshes
  board/broadcastable.rb        # broadcasts_refreshes + broadcasts_refreshes_to [account, :all_boards]
  notification.rb               # targeted broadcast_prepend_later_to / broadcast_remove_to
  card/pinnable.rb              # broadcast_pin_updates_later → job → per-user replace
app/controllers/
  application_controller.rb     # etag { "v1" }; stale_when_importmap_changes
  concerns/card_scoped.rb       # render_card_replacement (the one blessed inline stream)
```

## Key code

Template, not inline. The controller says *what happened*; the template says *what to
redraw*:

```ruby
class Cards::ClosuresController < ApplicationController
  include CardScoped

  def create
    capture_card_location
    @card.close
    refresh_stream_if_needed

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end
end
```

```erb
<%# app/views/cards/closures/create.turbo_stream.erb %>
<%= turbo_stream.replace("closed-cards", partial: "boards/show/closed", method: :morph, locals: { board: @card.board }) %>

<% if @source_column %>
  <%= turbo_stream.replace(dom_id(@source_column), partial: "boards/show/column", method: :morph, locals: { column: @source_column }) %>
<% elsif @was_in_stream %>
  <%= turbo_stream.replace("maybe", partial: "boards/show/stream", method: :morph, locals: { board: @card.board, page: @page }) %>
<% end %>

<%= turbo_stream.replace([ @card, :card_container ], partial: "cards/container", method: :morph, locals: { card: @card.reload }) %>
```

Broadcasts are declarations on a trait, not code in controllers:

```ruby
module Card::Broadcastable
  included do
    broadcasts_refreshes
    ...
  end
end

module Board::Broadcastable
  included do
    broadcasts_refreshes
    broadcasts_refreshes_to ->(board) { [ board.account, :all_boards ] }
  end
end
```

The chain that makes "close a card" refresh the board for everyone: `Closure belongs_to
:card, touch: true` → `Card after_touch -> { board.touch }, if: :published?` →
`Board broadcasts_refreshes`. The same touches change `updated_at`, which is every
cache key and etag below. (inference: the chain is assembled from `closure.rb`,
`card.rb`, `board/broadcastable.rb`)

Targeted broadcasts exist where a refresh would be wrong (a per-user tray):

```ruby
class Notification < ApplicationRecord
  after_create_commit  -> { broadcast_prepend_later_to user, :notifications, target: "notifications" }
  after_update_commit  -> { broadcast_update }
  after_destroy_commit -> { broadcast_remove_to user, :notifications }
end
```

HTTP caching — the collection you render is the etag:

```ruby
def show_columns                                   # BoardsController
  cards = @board.cards.awaiting_triage.latest.with_golden_first.preloaded
  set_page_and_extract_portion_from cards
  fresh_when etag: [ @board, @page.records, @user_filtering, Current.account ]
end

def show                                           # Notifications::TraysController
  ...
  # Invalidate on the whole set instead of the unread set since the max updated at in the unread set
  # can stay the same when reading old notifications.
  fresh_when etag: [ Current.user.notifications, include_read? ]
end

class ApplicationController < ActionController::Base
  etag { "v1" }                     # bump to invalidate every client's HTTP cache
  stale_when_importmap_changes
end
```

Per-user state outside the shared fragment:

```erb
<%# cards/_container.html.erb %>
<% cache card do %> ... <% end %>

<%# cards/container/footer/_published.html.erb (condensed) %>
<%= turbo_frame_tag card, :watch, src: card_watch_path(card), target: "_top", refresh: :morph do %>
  <%= button_to card_watch_path(card), class: "btn" do %>...<% end %>   <%# placeholder %>
<% end %>
```

```ruby
def show                                           # Cards::WatchesController
  fresh_when etag: @card.watch_for(Current.user) || "none"
end
```

Lazy frames for anything expensive and not immediately visible:

```erb
<%= turbo_frame_tag card, :assignment, src: new_card_assignment_path(card), loading: :lazy, refresh: "morph" %>
<%= turbo_frame_tag "my_menu", src: my_menu_path, loading: :lazy, target: "_top" do %>
  <%= render "my/menus/navigation" %>
<% end %>
```

## Why

- **Templates for every stream.** DHH did a sweep: cf503bfba "Prefer templates for
  turbo streams in all but the very simplest cases" (body: *"(And probably even
  then)"*), 39dc2b6ab "Prefer explicit turbo stream templates", aeb23b691 "Always use
  templates for turbo streaming to stay consistentn", 3116cea6a "Stick with turbo stream
  templates for everything", 887559d1a "Be consistent about using turbo stream
  templates". Snapshot: 38 `.turbo_stream.erb` files; two inline `render turbo_stream:`
  left (`render_card_replacement` and the pin button), both one-liners reused by many
  actions.
- **Re-render, don't redirect.** DHH's 7adbd8d63 "Use card rerendering instead of
  redirects". Jorge's 3e1a2bcc7 "Use morphing to replace the card and exclude turbo
  frames from being replaced" added `method: :morph` because *"Reconnecting the frames
  result in a visible flickering."*
- **Morph refreshes beat bespoke broadcasts.** Jorge's 5a740a425 "Enable page refreshes
  with morphing" turned it on app-wide; boards and cards then only need
  `broadcasts_refreshes`. Hand-written broadcast partials survive only where the target
  is per user (notification tray, pins tray). Mike Dalessio's d37480d06 "Morph card title
  and description on broadcast refreshes" shows the gotcha: a blanket
  `data-turbo-permanent` made morphs skip content; permanence is now applied only while
  an editor is open.
- **Broadcasts cost something; drop the ones nobody hears.** DHH: eeeff7a19 "Can't find
  any record of this to any turbo_stream_from" (removed a `broadcasts_refreshes_to` with
  no subscriber), 397fc1d2b "Only broadcast creations", 9cbb6b456 "Broadcasts are
  slowing things down" (wrap bulk inserts in `suppressing_turbo_broadcasts`). 4d0dddec4
  "No need to loop through a job when this is the sole point of the action" made the
  acting user's own pin broadcast synchronous.
- **Etag the thing you render, load it once.** DHH's 6570f5fc0 "Use etag for
  assignments/new" loads `@users`, passes it to `fresh_when`, and uses `@users.many?` in
  the view instead of a second `count`. Then a run of etag commits on 2025-11-03
  (f3c602da2, 56e4cdabd, d3cb3a3a2, 1d00a5340, 418548b9b). Snapshot: 24 controllers call
  `fresh_when`/`stale?`.
- **Bust caches deliberately and visibly.** DHH's b8c3ac814 "Cache busting should happen
  as a comment in the partial, not as an actual key component": template digests include
  comments, so `<%# Cache bump ... %>` changes the key without polluting it. Mike's
  9312f6b35 "Bust the column cache so #3125 reaches every column (#3126)" explains why:
  the digest doesn't cover helpers, so a helper change needs a `<%# Helper Dependency
  Updated: column_tag ... %>` comment. For HTTP caches, Jorge's b2e2a5d95 "Invalidate
  HTTP cache" added `etag { "v1" }` after the big Collection → Board rename.
- **Never bake `Current.user` into a shared fragment.** Mike's 2527f0736 "Fix "M" hotkey
  using stale user from fragment cache" (a user id inside a cached URL). DHH's cdcf2500c
  "Another spot where we need to move a Current.user check to a stimulus controller to
  cache" set the direction: render the same HTML for everyone, then let JS compare
  `window.Current.user.id` (from the `current-user-id` meta tag) — see
  `reaction_delete_controller.js` — or load a per-user frame.
- **Lazy-load what isn't on screen.** DHH's 690d6ced4 "Slim down my/menu even more and
  lazy load the dynamic elements" (body: *"Then we also don't have to keep them up to
  date for filter changes"*); 66d397fa8 "Eager load lazy frames inside dialogs on hover"
  hides the latency. The lazy frame's `src` is a normal etagged action, so the second
  open is a 304.
- **Cheap work stays inline.** DHH's 966aa51a3 "Get rid of unnecessary touch jobs":
  `touch_all` on 10K cards took 6ms, so cache invalidation runs in the callback.

## Testing

- Stream responses: `assert_turbo_stream action: :replace, target: dom_id(card,
  :card_container)` via `assert_card_container_rerendered` (`test/test_helpers/card_test_helper.rb`),
  used across `test/controllers/cards/*_controller_test.rb`.
- Broadcasts: `include Turbo::Broadcastable::TestHelper` in `test_helper.rb`;
  `assert_turbo_stream_broadcasts [ kevin, :notifications ]` and
  `capture_turbo_stream_broadcasts` in `test/models/notification_test.rb`;
  `assert_turbo_stream_broadcasts(..., count: 0)` for audience rules in
  `test/models/card/pinnable_test.rb`.
- Etags: request, save `response.headers["ETag"]`, change data, re-request with
  `If-None-Match`, expect `:success` (not 304) — `test/controllers/my/menus_controller_test.rb`.
- Fragment caching is off in tests; `with_actionview_partial_caching`
  (`test/test_helpers/caching_test_helper.rb`) turns it on where a test needs it.
- Morph behavior end-to-end: `test/system/card_refresh_test.rb`,
  `test/system/column_pagination_refresh_test.rb`.

## Reuse recipe

1. Layout: `turbo_refreshes_with method: :morph, scroll: :preserve`.
2. Models users watch together: `broadcasts_refreshes` (in a `Broadcastable` trait). Pages: `turbo_stream_from @record`. Child records `belongs_to :parent, touch: true` so the parent refreshes and re-keys.
3. Mutations: `respond_to { format.turbo_stream }` + `action.turbo_stream.erb` that `replace`s containers with `method: :morph`. One shared partial if create/destroy redraw the same thing.
4. Targeted, per-user streams (`[user, :notifications]`) only where a page refresh is wrong.
5. Every GET that can: `fresh_when etag: [records you render, flags that change output]`. Paginated: `@page.records`. Add a global `etag { "v1" }` to bump after deploys that change markup broadly.
6. Shared partials: `cache record` / `cached: true`; bump with a `<%# Cache bump date reason %>` comment.
7. Anything per user inside cached HTML: a lazy `turbo_frame_tag ... src:` to a tiny etagged `show`, or a Stimulus check against a `current-user-id` meta tag.
8. Batch scripts: `Model.suppressing_turbo_broadcasts { ... }`.

## Related

[[patterns/state-as-resource]] · [[patterns/controller-scoping]] · [[patterns/jobs-later-now]] ·
[[components/notifications]] · [[components/pins-tags-steps]] · [[testing/controller-and-system]] ·
[[voice/dhh-refactors]]
