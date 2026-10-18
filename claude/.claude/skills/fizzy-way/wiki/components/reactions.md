---
title: Reactions
use_when: [reactions, emoji reactions, boosts, likes, react to a comment, react to a post, polymorphic reactable, short reply, applause]
sources:
  - app/models/reaction.rb
  - app/models/card.rb, app/models/comment.rb (has_many :reactions, as: :reactable)
  - app/controllers/cards/reactions_controller.rb, app/controllers/cards/comments/reactions_controller.rb
  - app/helpers/reactions_helper.rb
  - app/views/reactions/*, app/views/cards/display/preview/_boosts.html.erb
  - lib/rails_ext/string.rb
  - app/javascript/controllers/reaction_delete_controller.js
  - test/models/reaction_test.rb, test/controllers/cards/reactions_controller_test.rb
  - test/controllers/cards/comments/reactions_controller_test.rb, test/integration/card_preview_boost_count_test.rb
  - commits 1570c16f6, ffab4cad6, cb61b3671, 6f1c80229, 80bc1dd16, 0cb5b9ecd, 5aa2b7da8, 760cbb6c9
snapshot: 55bb38335
---

# Reactions

## Answer

A `Reaction` is a tiny polymorphic row: `reactable`, `reacter`, and a `content`
string of up to 16 characters. It isn't limited to a fixed emoji set. The UI calls
them **boosts**. Each parent model declares `has_many :reactions, as: :reactable`.
Each parent also gets a thin nested controller that sets `@reactable`, and both
controllers render one shared set of views in `app/views/reactions/`, which build
URLs through a small helper. The reaction has no notifications and no events. Its
only side effect is to mark the card as active.

## Shape

```
app/models/
  reaction.rb                  # belongs_to :reactable (polymorphic, touch), :reacter; after_create → card activity
  card.rb, comment.rb          # has_many :reactions, -> { order(:created_at) }, as: :reactable, dependent: :delete_all
lib/rails_ext/string.rb        # String#all_emoji? (bigger type for emoji-only reactions)
app/controllers/cards/
  reactions_controller.rb             # set_reactable: @reactable = @card
  comments/reactions_controller.rb    # set_comment; set_reactable: @reactable = @comment
app/helpers/reactions_helper.rb       # reaction_path_prefix_for(reactable) → [card] | [card, comment]
app/views/reactions/                  # shared by both controllers
  _reactions.html.erb  _reaction.html.erb  _menu.html.erb
  index.html.erb  new.html.erb  create.turbo_stream.erb  destroy.turbo_stream.erb
  index.json.jbuilder  show.json.jbuilder  _reaction.json.jbuilder
app/views/cards/display/preview/_boosts.html.erb    # count on the card tile
```

Routes (full `resources`, nested under the parent):

```ruby
resources :cards do
  scope module: :cards do
    resources :reactions
    resources :comments do
      resources :reactions, module: :comments
    end
  end
end
```

Schema: `reactions(account_id, reactable_type, reactable_id, reacter_id, content string(16) NOT NULL)`.

## Key code

```ruby
class Reaction < ApplicationRecord
  belongs_to :account, default: -> { reactable.account }
  belongs_to :reactable, polymorphic: true, touch: true
  belongs_to :reacter, class_name: "User", default: -> { Current.user }

  scope :ordered, -> { order(:created_at) }

  after_create :register_card_activity

  delegate :all_emoji?, to: :content

  private
    def register_card_activity
      reactable.card.touch_last_active_at
    end
end
```

`reactable.card` works for both parents because `Card#card` returns `self`, a small
duck-typing seam that Fizzy also uses for notifications (`def card; self; end` in
`card.rb`, from ecbe040e3 "Implement Notification#card").

The two controllers differ only in how they load the parent:

```ruby
class Cards::Comments::ReactionsController < ApplicationController
  include CardScoped

  before_action :set_comment
  before_action :set_reactable

  with_options only: :destroy do
    before_action :set_reaction
    before_action :ensure_permission_to_administer_reaction
  end

  def new
    render "reactions/new"
  end

  def create
    @reaction = @reactable.reactions.create!(params.expect(reaction: :content))
    respond_to do |format|
      format.turbo_stream { render "reactions/create" }
      format.json { render "reactions/show", status: :created }
    end
  end
  ...
  private
    def set_reactable
      @reactable = @comment
    end

    def ensure_permission_to_administer_reaction
      head :forbidden if Current.user != @reaction.reacter
    end
end
```

Shared views build URLs from a path prefix:

```ruby
module ReactionsHelper
  def reaction_path_prefix_for(reactable)
    case reactable
    when Card then [ reactable ]
    when Comment then [ reactable.card, reactable ]
    else
      raise ArgumentError, "Unknown reactable type: #{reactable.class}"
    end
  end
end
```

```erb
<%# reactions/_reactions.html.erb %>
<%= turbo_frame_tag reactable, :reacting do %>
  <%= render partial: "reactions/reaction", collection: reactable.reactions %>
  <%= turbo_frame_tag reactable, :new_reaction do %>
    <%= link_to new_polymorphic_path([ *reaction_path_prefix_for(reactable), :reaction ]), ... %>
  <% end %>
<% end %>
```

`create.turbo_stream.erb` replaces the whole `[reactable, :reacting]` frame, and
`destroy.turbo_stream.erb` is `turbo_stream.remove @reaction`. The delete button is
always rendered. A Stimulus controller shows it only when `Current.user.id` matches
`data-reaction-delete-reacter-id-value`, which keeps the partial the same for every
viewer and therefore cacheable.

## Why

- **Generalize when the second parent arrives.** Reactions began on comments only
  (`belongs_to :comment`). When boosts came to cards, Mike Dalessio made the model
  polymorphic (1570c16f6 "Make Reaction polymorphic", ffab4cad6 "Update models, views,
  and fixtures for polymorphic reactions", PR #2416). He then consolidated views in
  cb61b3671 "Allow boosts on cards (#2411)": *"Extract shared views to app/views/reactions/
  using polymorphic routing. Both card and comment reactions now render the same
  partials, with a helper to compute the correct path prefix for nested routes."*
- **One controller per nesting, not one generic controller.** Each parent keeps its
  own nested resource (`Cards::ReactionsController`, `Cards::Comments::ReactionsController`)
  that loads its parent through `CardScoped`. Only the views are shared. Routes stay
  conventional, and authorization goes through the card. (inference)
- **The database enforces presence.** DHH, 6f1c80229 "Content being required via UI
  and db constraint is enough" removed `validates_presence_of :content`
  (`null: false` plus a `pattern` on the input). See [[voice/dhh-refactors]] §3.
- **`delete_all` when there are no callbacks.** DHH, 80bc1dd16 "Reactions dont have any
  callbacks so can just be deleted": `dependent: :destroy` → `:delete_all`. Use one
  SQL delete when there's nothing to run per row.
- **Reacting counts as activity.** 0cb5b9ecd "Reactions reset entropy" added
  `register_card_activity`, so a boosted card doesn't auto-postpone. See
  [[components/entropy]]. (Fizzy-specific)
- **Don't cache tiny partials inside a cached parent.** DHH, 5aa2b7da8 "No need to
  cache individual reactions": *"its just not worth it when we are caching the
  comment."*
- **Boosts were once a counter.** `Card::Boostable` (`boosts_count`, `boost!(count)`)
  was removed in DHH's 760cbb6c9 "Drop boosts" (*"Killed by design."*). The name came
  back as the UI label for card reactions. A row per person tells you who reacted,
  which a counter can't. (inference)
- **Free-text content.** `content` is a string with a 16-character limit, so short
  words like "Nice!" work. `String#all_emoji?` in `lib/rails_ext` decides the
  presentation (larger type for emoji only). c95e8678a "Extract #all_emoji? to a
  Rails ext" moved it from the model into a core extension.

**Reusable vs Fizzy-specific.** The reusable parts: the polymorphic row, nested
per-parent controllers with shared views, the path-prefix helper, author-only
delete, and `delete_all`. These are Fizzy product choices: the "boost" naming, the
16-character free text, and the entropy touch.

## Testing

- `test/models/reaction_test.rb`: reacting to a card or a comment changes
  `cards(:logo).reload.last_active_at` (`assert_changes`), and destroying the parent
  deletes its reactions.
- `test/controllers/cards/reactions_controller_test.rb` and
  `test/controllers/cards/comments/reactions_controller_test.rb` are nearly identical:
  index/new/create/destroy, "non-owner cannot destroy reaction" → `:forbidden`, and
  JSON variants.
- `test/integration/card_preview_boost_count_test.rb` checks that the count renders
  on the tile only when reactions exist.
- Fixtures use the polymorphic label syntax: `reactable: logo_uuid (Card)`.

## Reuse recipe

1. `create_table :reactions` with `reactable` polymorphic, `reacter_id`, `content` (`null: false`, length limit), and `account_id`.
2. `Reaction` has `belongs_to :reactable, polymorphic: true, touch: true` and `belongs_to :reacter, default: -> { Current.user }`. Leave out the presence validation and let the DB enforce it.
3. Add `has_many :reactions, -> { order(:created_at) }, as: :reactable, dependent: :delete_all` to each parent.
4. Write one nested controller per parent. Each sets `@reactable` and renders shared templates (`render "reactions/new"`). Guard destroy with `head :forbidden unless reacter == Current.user`.
5. Write a `reaction_path_prefix_for(reactable)` helper. Use `polymorphic_path([*prefix, reaction])` in the shared views.
6. Wrap the list in `turbo_frame_tag reactable, :reacting`. On create, replace the frame. On destroy, remove the row.
7. Skip notifications for reactions unless your product needs them. Fizzy only records activity.

## Related

[[components/comments]] · [[components/entropy]] · [[patterns/controller-scoping]] ·
[[patterns/turbo-and-caching]] · [[voice/dhh-refactors]]
