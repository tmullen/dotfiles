---
title: Comments
use_when: [comments, comment thread, discussion on a record, rich text body, system comments, activity in the thread, "X changed the title", who can edit a comment, comment permalink, commentable, comment on drafts]
sources:
  - app/models/comment.rb, app/models/comment/*.rb
  - app/models/card/commentable.rb
  - app/models/card/eventable.rb, app/models/card/eventable/system_commenter.rb
  - app/controllers/cards/comments_controller.rb
  - app/views/cards/comments/*, app/views/cards/_messages.html.erb
  - app/views/layouts/shared/_user_css.html.erb
  - config/routes.rb (resources :comments, resolve "Comment")
  - test/models/comment_test.rb, test/models/card/commentable_test.rb
  - test/models/card/eventable/system_commenter_test.rb, test/controllers/cards/comments_controller_test.rb
  - commits 2b98db9e6, 4ff55df2e, c6c9e0d5f, 83360ec6f, 81f431d94, 255435a38, 9aa15e9fb
snapshot: 55bb38335
---

# Comments

## Answer

A `Comment` is a plain row (`card_id`, `creator_id`, `account_id`) with an Action
Text `has_rich_text :body`. It's nested under its parent in both code and routes
(`Cards::CommentsController`, `resources :cards { resources :comments }`). Every
side effect lives in the comment's own callbacks and concerns: the creator starts
watching, an event is tracked, mentions get scanned, search is indexed. The parent
only owns the association and a `commentable?` predicate. **System comments** are
ordinary comments written by a per-account system user, created from card events by a
small PORO, `Card::Eventable::SystemCommenter`. So the thread shows both talk and
activity, and nothing special renders it.

## Shape

```
app/models/
  comment.rb                      # belongs_to card/creator, has_rich_text :body, reactions, search, after_create_commit watch
  comment/
    eventable.rb                  # track "comment_created" unless creator.system?
    mentions.rb                   # include ::Mentions; mentionable? = card.published?
    promptable.rb                 # to_prompt for AI features (Fizzy-specific)
  card/
    commentable.rb                # has_many :comments; commentable? = published?; reindex_comments
    eventable.rb                  # event_was_created → SystemCommenter
    eventable/system_commenter.rb # PORO: event.action → HTML sentence → comments.create!
  account.rb                      # system_user: users.find_by!(role: :system)
app/controllers/cards/
  comments_controller.rb          # full CRUD, JSON + turbo_stream, ensure_creatorship
  comments/reactions_controller.rb
app/views/cards/comments/
  _comment.html.erb               # cached; system comments get .comment-by-system
  create/update/destroy.turbo_stream.erb, _new, edit, show, *.json.jbuilder
  _watchers.html.erb              # "N people will be notified when someone comments"
app/jobs/card/reindex_comments_job.rb
```

Routes:

```ruby
resources :cards do
  scope module: :cards do
    resources :comments do
      resources :reactions, module: :comments
    end
  end
end

resolve "Comment" do |comment, options|
  options[:anchor] = ActionView::RecordIdentifier.dom_id(comment)
  route_for :card, comment.card, options
end
```

`resolve` makes `link_to comment` and `polymorphic_url(comment)` go to the card page
with `#comment_<id>`. A comment has no standalone page.

## Key code

The model is a list of declarations plus two private methods:

```ruby
class Comment < ApplicationRecord
  include Attachments, Eventable, Mentions, Promptable, Storage::Tracked

  belongs_to :account, default: -> { card.account }
  belongs_to :card, touch: true
  belongs_to :creator, class_name: "User", default: -> { Current.user }
  has_many :reactions, -> { order(:created_at) }, as: :reactable, dependent: :delete_all

  has_rich_text :body

  validate :card_is_commentable

  scope :chronologically, -> { order created_at: :asc, id: :desc }
  scope :preloaded, -> { with_rich_text_body.includes(reactions: :reacter) }
  scope :by_system, -> { joins(:creator).where(creator: { role: :system }) }
  scope :by_user, -> { joins(:creator).where.not(creator: { role: :system }) }

  after_create_commit :watch_card_by_creator

  delegate :publicly_accessible?, :accessible_to?, :board, :watch_by, to: :card

  def to_partial_path
    "cards/#{super}"
  end
  ...
end
```

*(Search declaration omitted. See [[components/search]].)*

The parent's trait stays thin:

```ruby
module Card::Commentable
  included do
    has_many :comments, dependent: :destroy
  end

  def commentable?
    published?
  end
end
```

The controller calls the association directly. There's no `card.comment!(...)`:

```ruby
def create
  @comment = @card.comments.create!(comment_params)
  respond_to do |format|
    format.turbo_stream
    format.json { render :show, status: :created, location: card_comment_path(@card, @comment, format: :json) }
  end
end

private
  def ensure_creatorship
    head :forbidden if Current.user != @comment.creator
  end
```

System comments hook into the event spine. `Card::Eventable#event_was_created` calls
`SystemCommenter.new(self, event).comment`:

```ruby
class Card::Eventable::SystemCommenter
  include ERB::Util

  def comment
    return unless comment_body.present?

    card.comments.create! creator: card.account.system_user, body: comment_body, created_at: event.created_at
  end

  private
    def comment_body
      case event.action
      when "card_assigned" then "#{creator_name} <strong>assigned</strong> this to #{assignee_names}."
      when "card_closed"   then "<strong>Moved</strong> to “Done” by #{creator_name}"
      ...
      end
    end

    def creator_name
      h event.creator.name
    end
end
```

*(Condensed. The real `case` has ten actions.)* `Comment::Eventable` closes the loop:
`should_track_event?` returns `!creator.system?`, so a system comment never creates
an event of its own. Without that check, each system comment would track an event,
which would create another system comment.

The view is cached per comment and shared by every viewer. The edit button is shown
or hidden by CSS keyed to the current user. The partial doesn't branch on the user:

```erb
<%# _comment.html.erb %>
<div id="<%= dom_id(comment) %>" data-creator-id="<%= comment.creator_id %>" class="comment ...">
  <%= link_to edit_card_comment_path(comment.card, comment), data: { only_visible_to_you: true } ... %>

<%# layouts/shared/_user_css.html.erb %>
[data-creator-id]:not([data-creator-id="<%= Current.user.id %>"]) {
  [data-only-visible-to-you] { display: none; }
}
```

## Why

- **Comments are flat rows, not delegated types.** Early Fizzy put comments and event
  summaries behind a `Message` delegated type (`Messageable`, `EventSummary`). DHH
  left a FIXME on the resulting scope in 9f1c3ae04 "Note my discontent": *"Not a
  fan of this. Think all references to comment should come directly from the
  message."* In 2b98db9e6 "Flatten out comments and messages" (PR #445), Jorge
  deleted `Message`, `Messageable`, `EventSummary` and `Card::Messages` and gave
  `Comment` a plain `belongs_to :card`. The flattening removed 251 lines and added 120.
  Delegated types are a Basecamp staple (see the RECORDABLES episode in sources.md),
  but here only one type ever carried real weight. (inference)
- **Activity is shown as comments.** 4ff55df2e "Create system comments on events"
  arrived in the same PR as the flattening. It replaced the event summaries with real
  `Comment` rows written by the system user. Search, export, caching and rendering all
  handle them for free. (inference)
- **History beats tidiness.** The first SystemCommenter merged consecutive related
  events (assign then unassign) into one edited comment. Jason Zimdars removed that in
  c6c9e0d5f "Rework system events": *"Walk back system comment replacement. Yes, it
  potentially avoids embarassing people when they change their mind, it's also losing
  data."* The same commit restyled system comments so they *"don't look like comments
  and aren't attributed to the system user"* (the `.comment-by-system` class).
- **Escape what you interpolate into HTML.** 83360ec6f "Escape the names used to
  generate system comments" (PR #2053) added `include ERB::Util` and `h` around every
  user-controlled value. The comment body is HTML (`<strong>`), so names must be escaped.
- **The system actor is per-account data.** e0aa1d257 "Drop User.system and replace
  with Account#system_user" replaced a `find_or_create_by!` class method that read
  `Current.account` with an explicit `account.system_user`. The system user is created
  with the account.
- **Comment behavior lives in the comment.** DHH, 81f431d94 "Comment-specific
  behavior needs to live in the comment": *"This really is a bit of a tangled mess.
  Everyone knows everything about everyone else."* Watching the card on create
  and tracking the event are `Comment` callbacks, not `Card` methods. In 2025-04-12
  DHH made a run of commits removing comment knowledge from the card (27d90abbd
  "Reduce the direct knowledge of comments inside the card", fb733b9a6 "No more
  tracking commenting as an activity for sorting").
- **No factory method for a one-liner.** DHH, 255435a38 "No need for a non-standard
  factory method for something this simple": `@bubble.comment!(body)` became
  `@bubble.comments.create!(body:)`. See [[voice/dhh-refactors]] §1.
- **The rule is enforced at two layers.** 9aa15e9fb "Forbid comments on draft cards"
  (PR #2423) added `Card#commentable?`, a model validation, and a controller
  `before_action` that returns `403`. Account import later validated rows before their
  card existed, so ccbf571be "Fix crash on commentable check" added `card&.`. Then
  d7dcf6431 "Remove model validation" stopped validating during import and put
  `card.commentable?` back without the guard. Removing the code path that reached
  the nil was preferred to keeping a defensive `&.`
  ([[voice/dhh-refactors]] §3, "Be confident").
- **Callbacks keep side effects on the side.** *"Callbacks are a powerful technique
  for making that which isn't essential to a primary flow live on the side."* DHH,
  [On Writing Software Well #2](https://www.youtube.com/watch?v=m1jOWu7woKM). And the
  creator default: `belongs_to :creator, default: -> { Current.user }` is the
  `Current.person` pattern from [Globals, callbacks and other sacrileges](https://dev.37signals.com/globals-callbacks-and-other-sacrileges/).
- **API clients can backdate.** `comment_params` permits `created_at`, from 477b4d65f
  "API: Support `created_at` for API card and comment creation (#2056)". That serves
  importers migrating from other tools. (Fizzy-specific)

**Reusable vs Fizzy-specific.** The reusable parts: a flat comment row, rich text,
nesting under the parent, `commentable?` on the parent, side effects in the comment's
callbacks, system comments from events, and per-user CSS on a shared cache. These are
Fizzy product choices: drafts can't be commented on, `Promptable` (AI), the
"Subscribers" footer, and the `Storage::Tracked` storage accounting.

## Testing

- `test/models/card/eventable/system_commenter_test.rb` drives real domain verbs
  (`@card.toggle_assignment users(:kevin)`, `@card.close`) and checks the text with a
  local `assert_system_comment "David assigned this to Kevin" do ... end` helper. It
  includes an injection test (`users(:david).update! name: "<em>Injected</em>"`) and
  "don't notify on system comments" (`assert_no_difference -> { Notification.count }`).
- `test/models/card/commentable_test.rb`: creating a comment makes the creator watch
  the card, and `commentable?` is true only for published cards.
- `test/models/comment_test.rb`: a draft card rejects comments on both `valid?` and
  `create!`.
- `test/controllers/cards/comments_controller_test.rb`: CRUD in both `as: :turbo_stream`
  and `as: :json`, "update another user's comment" → `:forbidden`, and the draft →
  `:forbidden` case.

## Reuse recipe

1. `rails g model Comment parent:references creator:references` plus `has_rich_text :body`. Default the creator with `default: -> { Current.user }`.
2. On the parent, add a `Parent::Commentable` trait with `has_many :comments, dependent: :destroy` and a `commentable?` predicate.
3. Nest the routes under the parent and add `resolve "Comment"` so links go to the parent page with an anchor.
4. Put side effects in comment callbacks: `after_create_commit` to subscribe the author, and an `Eventable` concern to track `comment_created`. Keep them off the parent.
5. For system comments, give each account a `role: :system` user. Write a PORO under the parent's eventable namespace that maps `event.action` to an escaped sentence and calls `comments.create!`. Skip event tracking when `creator.system?`.
6. Authorize edits with `before_action :ensure_creatorship` → `head :forbidden`. Cache the comment partial for everyone, and use `data-creator-id` plus a per-user `<style>` for author-only controls.
7. Respond with turbo stream templates (`create.turbo_stream.erb` does `before [card, :new_comment]` and resets the form) plus JSON.

## Related

[[components/mentions]] · [[components/reactions]] · [[components/watching]] ·
[[components/notifications]] · [[components/events]] · [[patterns/events-as-spine]] ·
[[patterns/model-concerns]] · [[patterns/turbo-and-caching]] · [[patterns/current-attributes]]
