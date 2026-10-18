---
title: Filters and saved filters
use_when: [filter, saved filter, saved view, custom view, query params to scopes, filter form, faceted search, index page params, list filtering, remember filter, filter chips]
sources:
  - app/models/filter.rb, app/models/filter/fields.rb, app/models/filter/params.rb
  - app/models/filter/resources.rb, app/models/filter/summarized.rb
  - app/models/concerns/filterable.rb, app/models/user/filtering.rb, app/models/time_window_parser.rb
  - app/models/card.rb (indexed_by, sorted_by, mentioning scopes)
  - app/controllers/filters_controller.rb, app/controllers/filters/settings_refreshes_controller.rb
  - app/controllers/concerns/filter_scoped.rb, app/controllers/cards_controller.rb, app/controllers/boards_controller.rb
  - test/models/filter_test.rb, test/models/filter/search_test.rb, test/controllers/filters_controller_test.rb, test/fixtures/filters.yml
  - commits 3d9d16947, d455b7290, 1cb9ccdf1, 378705a30, 2713913f0, 134333ae4, 5048e9c97, cac0ca165
snapshot: 27d0d2e6b
---

# Filters and saved filters

## Answer

A filter is a database record, even before anyone saves it. `Filter` belongs to a creator
(the user). Scalar settings live in a JSON `fields` column through `store_accessor`, and
references to tags, boards and users use plain HABTM join tables. The URL query string is the
filter's serialized form. `Filter.from_params(params)` finds the saved filter with the same
**MD5 digest of normalized params**, or builds an unsaved one. `Filter#cards` turns the
filter into one chain of named scopes, starting from `creator.accessible_cards`. "Saving a
filter" is `filters.remember(params)`: create, and on a unique-index collision touch the
existing row. Records that a filter can point to include `Filterable`, which keeps saved
filters valid when those records change or are deleted.

## Shape

```
app/models/
  filter.rb               # Filter: from_params, remember, #cards (params → scope chain)
  filter/
    fields.rb             # store_accessor :fields (indexed_by, sorted_by, terms, creation, closure...), defaults, inquiry
    params.rb             # PERMITTED_PARAMS, normalize_params, digest_params, as_params, used?
    resources.rb          # HABTM tags/boards/assignees/creators/closers; resource_removed
    summarized.rb         # #summary → "Golden, assigned to JZ, matching "haggis""
  concerns/filterable.rb  # on Tag and Board: has_and_belongs_to_many :filters; touch/remove
  user/filtering.rb       # PORO view model for the filter menu: options, show_*?, cache_key
  time_window_parser.rb   # "thisweek" → Range
app/controllers/
  concerns/filter_scoped.rb             # before_action: @filter (by id or params), @user_filtering
  filters_controller.rb                 # create (remember) / destroy; turbo_stream
  filters/settings_refreshes_controller.rb  # re-render the menu as you change it
  cards_controller.rb, boards_controller.rb # include FilterScoped; set_page_and_extract_portion_from @filter.cards
tables: filters (creator_id, account_id, fields json, params_digest; unique [creator_id, params_digest])
        boards_filters, filters_tags, assignees_filters, creators_filters, closers_filters
```

Routes:

```ruby
resources :filters do
  scope module: :filters do
    collection do
      resource :settings_refresh, only: :create
    end
  end
end
```

There's no separate "filtered cards" endpoint. `GET /cards?tag_ids[]=…&indexed_by=closed` or
`GET /cards?filter_id=…` goes to `CardsController#index` through `FilterScoped`.

## Key code

Params go in and scopes come out. Each line names one domain scope that already exists on
`Card`:

```ruby
class Filter < ApplicationRecord
  include Fields, Params, Resources, Summarized

  belongs_to :creator, class_name: "User", default: -> { Current.user }
  belongs_to :account, default: -> { creator.account }

  class << self
    def from_params(params)
      find_by_params(params) || build(params)
    end

    def remember(attrs)
      create!(attrs)
    rescue ActiveRecord::RecordNotUnique
      find_by_params(attrs).tap(&:touch)
    end
  end

  def cards
    @cards ||= begin
      result = creator.accessible_cards.preloaded.published
      result = result.indexed_by(indexed_by)
      result = result.sorted_by(sorted_by)
      result = result.open unless include_closed_cards?
      result = result.unassigned if assignment_status.unassigned?
      result = result.assigned_to(assignees.ids) if assignees.present?
      result = result.tagged_with(tags.ids) if tags.present?
      result = result.closed_at_window(closure_window) if closure_window
      result = terms.reduce(result) { |result, term| result.mentioning(term, user: creator) }
      ...
      result.distinct
    end
  end
end
```

*(Condensed. The full method has 15 steps plus an index hint for the board case.)*

Identity comes from a digest of normalized params. Blank values and defaults are dropped and
keys are sorted, so equivalent URLs map to the same row:

```ruby
module Filter::Params
  class_methods do
    def find_by_params(params) = find_by(params_digest: digest_params(params))
    def digest_params(params)  = Digest::MD5.hexdigest(normalize_params(params).to_json)

    def normalize_params(params)
      params.to_h.compact_blank.reject(&method(:default_value?))
        .collect { |name, value| [ name, value.is_a?(Array) ? value.collect(&:to_s) : value.to_s ] }
        .sort_by { |name, _| name.to_s }.to_h
    end
  end

  included do
    before_save { self.params_digest = self.class.digest_params(as_params) }
  end
end
```

*(Condensed to endless methods; the source uses regular `def`s.)*

Scalar fields are inquiries, so call sites read as prose (`indexed_by.closed?`,
`assignment_status.unassigned?`):

```ruby
store_accessor :fields, :assignment_status, :indexed_by, :sorted_by, :terms, :card_ids, :creation, :closure, :column_ids

def indexed_by
  (super || default_indexed_by).inquiry
end
```

A filterable record keeps saved filters correct:

```ruby
module Filterable                       # included by Tag and Board
  included do
    has_and_belongs_to_many :filters
    after_update { filters.touch_all }  # bust caches keyed on the filter
    before_destroy :remove_from_filters
  end
end

# Filter::Resources
def resource_removed(resource)
  kind = resource.class.model_name.plural
  send "#{kind}=", send(kind).without(resource)
  empty? ? destroy! : save!
rescue ActiveRecord::RecordNotUnique
  destroy!                               # now identical to another saved filter
end
```

The controller concern builds the filter for every index-like screen:

```ruby
module FilterScoped
  def set_filter
    if params[:filter_id].present?
      @filter = Current.user.filters.find(params[:filter_id])
    else
      @filter = Current.user.filters.from_params filter_params
    end
  end
end

class CardsController < ApplicationController
  include FilterScoped, SearchRateLimiting
  def index
    set_page_and_extract_portion_from @filter.cards
  end
end
```

## Why

- **A filter is a model, not a query object or a form object.** It has an owner, it persists,
  and it owns its own translation into scopes. This is the vanilla-Rails stance applied to
  search params: *"we don't default to create services, actions, commands, or interactors to
  implement controller actions."* ([Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/))
  `Filter#cards` only composes scopes that the `Card` traits already expose (`Card::Closeable#closed_by`,
  `Card::Taggable#tagged_with`). → [[patterns/model-concerns]]
- **Real associations, not ids in JSON.** 3d9d16947 "Many-to-many relationship for filters and
  filterables" replaced per-kind filter code (`filter/assignments.rb`, `filter/buckets.rb`) with
  HABTM tables, which gives referential cleanup and `filters.touch_all` for cache busting.
- **Identity by digest.** d455b7290 "Hash filter params" moved the uniqueness lookup from raw
  `params` to `params_digest`. Uniqueness is a database index, and `remember` treats
  `RecordNotUnique` as "already saved" rather than checking first (race-safe; see
  [[voice/dhh-refactors]] §3).
- **Link saved filters by id.** 1cb9ccdf1 "Comparing params is fragile, use `id` for saved
  filters" changed links to `cards_path(filter_id: filter.id)` and made the settings menu ask
  `filter.persisted?`.
- **Authorization lives at the root of the chain.** Every result starts from
  `creator.accessible_cards`, and `Filter#boards` is `creator.boards.where(id: …)`, so a crafted
  `board_ids[]` can't widen access. cac0ca165 "Scope the single-board case to just the
  creator's boards (#1880)" closed the one place that used the global `Board`. The test
  "board-scoped cards never leak cards from an inaccessible board in the same account" pins
  it.
- **`distinct` because joins fan out.** 378705a30 "Deduplicate filter results": *"when both a
  card and that card's comments match the search term, we don't want to show it multiple
  times."*
- **Performance is tuned in the model, with the reason written down.** 2713913f0 "Speed up the
  card list for large accounts" added a redundant `account_id` predicate and pinned an index
  (`use_index`) for the board case: *"On a 40k-active-card account filtered to 15 boards: 48ms
  -> 0.9ms of DB time, accesses join retained, no filesort."* Jorge then spent two follow-up
  commits on the name of the guard alone (e629d41da, 33d98a255 "Rename to joins_has_many?").
- **Cleanup in `before_destroy` is a known compromise.** DHH tried moving it out of the
  transaction (134333ae4 "Dont do a lot of work inside a single transaction", body: *"Especially
  with sqlite3!"*), found that callback doesn't exist (5048e9c97 "Duh, no before destroy commit,
  but this is still not right!"), and left a `FIXME` in the code. It is an open debt, not a
  pattern to copy.
- **The menu gets a view model.** `User::Filtering` is a PORO that collects the options
  (boards, tags, users, saved filters), the `show_*?` predicates, and a composite `cache_key`.
  `BoardsController` passes it to `fresh_when etag: [ @board, @page.records, @user_filtering,
  Current.account ]`. (Inference: this keeps view-only questions off the persisted model.)

*Reusable shape:* filter-as-record, `store_accessor` fields, HABTM to filterables, normalized
digest plus unique index, `XScoped` controller concern, scope chain from an access-checked root.
*Fizzy-specific:* the field list (`indexed_by` values like `golden` and `not_now`), the time
windows, the index hint, the summary sentence copy.

## Testing

- `test/models/filter_test.rb` builds unsaved filters straight from fixtures
  (`users(:david).filters.new indexed_by: "closed"`) and asserts on `filter.cards`. It covers
  remembering (equivalent params give one row and the second call bumps `updated_at`),
  `as_params` normalization, and resource removal: destroying a tag strips it from the filter,
  and destroying the only board destroys the filter.
- Access tests revoke real access (`boards(:writebook).accesses.revoke_from users(:david)`)
  and assert the result is empty.
- `test/models/filter/search_test.rb` uses `SearchTestHelper` (non-transactional) for
  term filters, and asserts deduplication with real comments.
- Fixtures compute the digest with the model's own method:
  `params_digest: <%= Filter.digest_params({ indexed_by: :all, ... }) %>` in `test/fixtures/filters.yml`.
- `test/controllers/filters_controller_test.rb` posts params `as: :turbo_stream` and inspects
  `Filter.last`.

## Reuse recipe

1. Create `filters`: `creator_id`, `account_id`, `fields` JSON, `params_digest`, with a unique
   index on `[creator_id, params_digest]`. Add HABTM join tables for each referenced model.
2. Split `Filter` into concerns: `Fields` (`store_accessor` plus `.inquiry` readers and
   defaults), `Params` (`PERMITTED_PARAMS`, `normalize_params`, `digest_params`, `as_params`),
   `Resources` (HABTM and `resource_removed`), and `Summarized` if you show a sentence.
3. `Filter.from_params` finds by digest or builds. `Filter.remember` does `create!` and rescues
   `RecordNotUnique` with a `touch`.
4. Write `#records` (here `#cards`) as `owner.accessible_things` followed by one named scope
   per field. Add scopes to the target model's traits instead of writing SQL in the filter.
   End with `.distinct` if any field joins a has-many.
5. Make filterable models `include Filterable` to touch filters on update and remove themselves
   on destroy. Move the destroy cleanup to a job if the fan-out is large.
6. Add a `FilterScoped` controller concern (`filter_id` or params) to every index that filters.
   The URL stays the source of truth, and saving is `POST /filters`.
7. Put menu and view questions in a PORO (`User::Filtering`) with its own `cache_key`, and use
   it in `fresh_when`.

## Related

[[components/search]] · [[patterns/model-concerns]] · [[patterns/controller-scoping]] ·
[[patterns/turbo-and-caching]] · [[components/access]] · [[voice/dhh-refactors]]
