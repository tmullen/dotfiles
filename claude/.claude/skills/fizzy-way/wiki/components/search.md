---
title: Search
use_when: [full-text search, search box, has_search, ActiveSearch, search index, sharding search, MySQL FULLTEXT, SQLite FTS5, stemming, highlighting, reindex, search rate limit, search across tenants]
sources:
  - config/search.rb, config/search.yml
  - lib/active_search/store_adapters/mysql_sharded.rb, lib/active_search/store_adapters/mysql_sharded/*.rb
  - app/models/search.rb, app/models/search/query.rb, app/models/search/record.rb
  - app/models/user/searcher.rb, app/models/account/searchable.rb
  - app/models/card.rb, app/models/comment.rb, app/models/card/commentable.rb
  - app/controllers/searches_controller.rb, app/controllers/concerns/search_rate_limiting.rb
  - app/jobs/search_reindex_job.rb, app/jobs/card/reindex_comments_job.rb, lib/tasks/search.rake
  - test/test_helpers/search_test_helper.rb, test/test_helpers/search_index_test_helper.rb
  - commits 03f3bd012 (PR #3136), e8abc66eb, 3aa4a1a56, 70dd754cf, b57130338, 468fe5f16, 0d138df95, cb5ef4811, 9e3dbb085
snapshot: 55bb38335
---

# Search

## Answer

Search runs in the app's own database. There is no Elasticsearch. Models opt in with one
`has_search` declaration from the `rails-active_search` gem, which owns every write and read.
That declaration names the index, a condition (`if: :published?`), a preload scope and a
serializer lambda. One polymorphic index, `:searchable`, is defined in `config/search.rb` and
routed by `account_id`. The store depends on the database. On SQLite it is the gem's single
FTS5 table. On MySQL it is Fizzy's own `MysqlSharded` adapter, which spreads rows over 16
tables by `crc32(account_id) % 16` and stems words in Ruby. Users query through
`Current.user.search(terms)`, which always filters to the boards they can see.

## Shape

```
config/
  search.rb                       # register_adapter :mysql_sharded + define_index(:searchable, route_by: :account_id)
  search.yml                      # adapter: sqlite | mysql_sharded, picked from the connection's adapter
lib/active_search/store_adapters/
  mysql_sharded.rb                # < ActiveSearch::StoreAdapters::Mysql; SHARD_COUNT = 16; upsert writes
  mysql_sharded/stemming.rb       # Mittens stemmer; "+account<id> +(terms)" query prefix
  mysql_sharded/highlighting.rb   # marks what MATCH matched
app/models/
  search.rb                       # module Search; table_name_prefix "search_"
  search/query.rb                 # sanitizes user input (quotes, hyphens, punctuation)
  search/record.rb                # document_class; abstract on MySQL (shards set table_name)
  user/searcher.rb                # User#search / #search_relation: board_ids filter + highlight
  account/searchable.rb           # before_destroy: remove_by_filter(account_id:)
  card.rb, comment.rb             # has_search ... serializer: ->(record) { {...} }
  card/commentable.rb             # reindex_comments after a board move
app/controllers/
  searches_controller.rb          # resource :search → show
  concerns/search_rate_limiting.rb  # rate_limit for token (API) searches only
app/jobs/
  search_reindex_job.rb           # ActiveJob::Continuable repair job
  card/reindex_comments_job.rb
lib/tasks/search.rake             # search:reindex
db: search_records_0..15 (MySQL, FULLTEXT on account_key, content, title)
    search_records + search_records_fts (SQLite, fts5 tokenize='porter')
```

Routes: `resource :search` (singular; `show` only in practice). Cards also search through
`Filter#cards` → `Card.mentioning` (see [[components/filters]]).

## Key code

The whole index, in one config file:

```ruby
# config/search.rb
ActiveSearch.register_adapter :mysql_sharded, "ActiveSearch::StoreAdapters::MysqlSharded"

ActiveSearch.define_index(:searchable, polymorphic: true, route_by: :account_id,
                          document_class: "Search::Record") do
  text :title
  text :content
  string :account_id
  string :board_id
  string :card_id
  string :searchable_type
  string :searchable_id
  datetime :created_at
end
```

A model joins the index with one declaration. The serializer is where the model decides what
"its document" is:

```ruby
class Card < ApplicationRecord
  SEARCH_CONTENT_LIMIT = 32.kilobytes

  has_search index: :searchable, async: false, if: :published?,
    scope: -> { preload(:board, :creator).with_rich_text_description },
    serializer: ->(card) {
    { account_id: card.account_id, card_id: card.id, board_id: card.board_id,
      title: card.title, content: card.description.to_plain_text.truncate_bytes(SEARCH_CONTENT_LIMIT, omission: ""),
      created_at: card.created_at }
  }
end
```

`Comment` declares the same index with `title: nil` and its card's `board_id`. Both kinds of
document carry `card_id`, so a hit on either one leads back to a card.

Reading goes through the user, so access control is part of the query rather than a later
filter:

```ruby
module User::Searcher
  def search(terms)
    build_search_relation(terms)
      .highlight(title: { markers: HIGHLIGHT_MARKERS }, content: { markers: HIGHLIGHT_MARKERS, snippet: { words: 20 } })
      .sort(created_at: :desc)
  end

  private
    def build_search_relation(terms)
      query = Search::Query.wrap(terms)
      boards = query.valid? ? board_ids : []      # an unusable query matches no board

      ActiveSearch.index(:searchable)
        .search(query.to_s)
        .filter(account_id: account_id, board_id: boards)
    end
end
```

Sharding is a small subclass of the gem's MySQL adapter:

```ruby
def model_for_shard(routing)
  raise ArgumentError, "routing (account_id) required for sharded adapter" unless routing
  shard_models[Zlib.crc32(routing.to_s) % SHARD_COUNT]
end

# Must keep Search::Record's connection pool: Account::Searchable deletes by filter
# from before_destroy, and a separate pool would deadlock on the destroy's own rows.
def shard_models
  @shard_models ||= SHARD_COUNT.times.map do |shard_id|
    Class.new(Search::Record) { self.table_name = "search_records_#{shard_id}" }
  end
end
```

Stemming adds an account token so that MySQL's FULLTEXT scan stays inside one account:

```ruby
data[:account_key] = "account#{data[:account_id]}"        # on write
full_query = "+account#{routing} +(#{stemmed})"           # on read
```

The search controller treats a bare card number as "go to that card". Its rate limit applies
only to API-token callers:

```ruby
if card = Current.user.accessible_cards.find_by(number: @query)
  ...
else
  @page = Current.user.search(@query).page(windowed_page_param, per_page: SEARCH_PAGE_SIZES)
end
```

*(Condensed from `searches_controller.rb`.)*

## Why

- **The database is the search engine.** AGENTS.md: *"Full-text search runs in the database
  through ActiveSearch, not Elasticsearch."* This follows the vanilla-stack stance: *"Your
  Gemfile should be almost identical to the one that Rails generates."*
  ([A vanilla Rails stack is plenty](https://dev.37signals.com/a-vanilla-rails-stack-is-plenty/))
  Semantic and LLM search was tried and taken out. 9e3dbb085 "Remove semantic searches":
  *"we'll go with keyword search only for launch"*. Later, aa1ffb335 "Remove AI summaries and
  semantic searches" removed the rest with *"We were not using either."*
- **Shard because MySQL can't pre-filter FULLTEXT.** 3aa4a1a56 "Shard the search index into 16
  tables": *"MySQL has no ability to pre-filter fulltext indexes by another field so this is the
  best bet for improving performance."* 70dd754cf "Account key for search records" puts the
  account inside the FULLTEXT index, *"so we only need to examine rows belonging to the relevant
  account."* The adapter's comment states the division of work: the token narrows the scan, and
  the `account_id` filter is what isolates tenants.
- **Route explicitly. Don't rely on `Current`.** b57130338 "Don't use Current.account for search
  records": *"It doesn't actually work, and even if we could make it work reliably we are better
  off if the records always know to go to the right shard."* So `route_by: :account_id` comes
  from the document, and a missing routing value raises instead of falling back to a shard.
- **Two databases, one interface.** Fizzy runs on SQLite when self-hosted and on MySQL as SaaS.
  bb36b4846 "Support SQLite searching" added FTS5, and a4850fbe7 "Remove adapter specific logic
  from searchable" pushed the differences down into the store. The gem extraction (03f3bd012
  "Search with the rails-active_search gem", PR #3136) completed that move: the model declares,
  the adapter stores. The commit says it removed `Search::Record, Result, Highlighter and
  Stemmer`, the unrendered recent-searches feature, and a geared_pagination fork. The
  leftovers are visible in the code: `Search::Query` rows *"Nothing writes these any more"*.
- **Raw SQL first, Active Record once the shape settled.** e8abc66eb "MySQL search" started
  with raw SQL because sharding was coming. 28efe28f2 "Replace Search::Index with
  Search::Records" then moved to models: *"Lean on ActiveRecord models for searching and strip
  out the raw SQL."* The shards are anonymous subclasses of one class, so they share a pool.
- **Index only what users can find.** 0d138df95 "Guard search indexing with searchable? check"
  keeps drafts out. Today that is `if: :published?` on `has_search`.
- **Bound what goes in.** 468fe5f16 "Only index up to 32KB of search content": *"To prevent
  overflowing the columns in the search index tables (and also just to avoid creating massive
  indexes)"*. The reindex job also filters out rich text bodies over a limit in SQL, because *"a
  single pathological body can stall the batch query or OOM the worker during preload, which
  has happened in practice"* (comment in `search_reindex_job.rb`).
- **Denormalized fields have to follow moves.** A comment document stores its card's
  `board_id`, so moving a card triggers `reindex_comments_later`. From the code: *"A comment's
  document carries its card's board_id, so a board move strands them all."*
- **Sanitize, then quote.** cb5ef4811 "Search a hyphenated term as a phrase": once punctuation
  became spaces, `BC3-IOS-1D8B` matched every card sharing a prefix and the query slowed
  down. Words joined by punctuation are now quoted as a phrase. CJK support was merged and
  then reverted (3457c871e), so tokenization stays simple *(inference: no reason is given in
  the revert)*.
- **Rate-limit robots, not people.** `limit_searches` uses Rails' `rate_limit` and runs only
  when `Current.session.nil?`, which means bearer-token API calls (*inference from
  `searching_with_access_token?`*).

*Reusable shape:* `has_search` plus a serializer per model, one index, access filters applied
in `User#search`, a continuable reindex job. *Fizzy-specific:* 16 MySQL shards, Mittens
stemming, the `account_key` token, card-number jump, circled-text highlight markup.

## Testing

- `test/test_helpers/search_test_helper.rb` turns off transactional tests
  (`self.use_transactional_tests = false`). Full-text indexes don't see uncommitted rows, so
  each test builds its own account, identity, user and board and cleans them up in teardown.
- `test/test_helpers/search_index_test_helper.rb` hides the adapter difference.
  `search_shard_for`, `find_search_record` and `indexed_content_for` read either the MySQL shard
  row or the SQLite FTS row, so the same test runs on both databases.
- `test/models/card/searchable_test.rb` covers what gets indexed (drafts aren't, content is
  truncated, edits reindex) and `Card.mentioning` across title, comments and board access.
- `test/models/search/sharding_test.rb` finds a second account that hashes to the same shard
  and asserts that neither account can see the other's rows. It guards its own premise:
  *"the two accounts must hash to one table, or this passes without isolating anything"*.
- `test/models/active_search/store_adapters/mysql_sharded_test.rb` checks the shard modulus,
  that a missing routing value raises, and that `capabilities` still match the gem's Mysql
  adapter.
- Also: `test/controllers/searches_controller_test.rb`, `test/controllers/search_rate_limiting_test.rb`,
  `test/jobs/search_reindex_job_test.rb`, `test/tasks/search_reindex_task_test.rb`.

## Reuse recipe

1. Add `rails-active_search`. Define one index in `config/search.rb`: `text` fields to match,
   `string` fields to filter on (tenant, container, parent), `route_by:` your tenant key.
2. Pick the adapter per database in `config/search.yml`. SQLite FTS5 and plain MySQL work out
   of the box. Shard only when one FULLTEXT table gets slow across tenants.
3. On each model, write `has_search index:, if:, scope:, serializer:`. The serializer
   denormalizes the parent id and the access-control key (here `board_id`). Truncate content.
4. Put `search(terms)` on `User`. Sanitize with a small `Search::Query`, then always
   `.filter(tenant_id:, container_id: accessible_ids)`. Return a lazy relation so callers can
   paginate.
5. Remove a tenant's rows in `before_destroy` with `remove_by_filter(account_id: id)`.
6. When a parent move changes a denormalized field, reindex the children in a `_later` job.
7. Ship a continuable `SearchReindexJob` and a `search:reindex` rake task for recovering a
   lost index.
8. Test with real commits (no transactional tests), and include a cross-tenant isolation test.

## Related

[[components/filters]] · [[components/accounts-tenancy]] · [[components/access]] ·
[[patterns/model-concerns]] · [[patterns/jobs-later-now]] · [[testing/fixtures]]
