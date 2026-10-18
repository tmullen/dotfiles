---
title: Access, roles and authorization
use_when: [permissions, authorization, who can see this, per-record access, board membership, roles, admin, owner, pundit alternative, cancan alternative, policy objects, forbidden, IDOR, scoping finds, accessible_cards, watching level, involvement, revoke access cleanup, all access]
sources:
  - app/models/access.rb, app/models/board/accessible.rb, app/models/card/accessible.rb
  - app/models/user/accessor.rb, app/models/user/role.rb, app/models/user.rb
  - app/controllers/concerns/authorization.rb, app/controllers/concerns/board_scoped.rb, app/controllers/concerns/card_scoped.rb, app/controllers/concerns/column_scoped.rb
  - app/controllers/boards_controller.rb, app/controllers/boards/accesses_controller.rb, app/controllers/boards/involvements_controller.rb, app/controllers/users/roles_controller.rb
  - app/jobs/board/clean_inaccessible_data_job.rb, app/jobs/card/clean_inaccessible_data_job.rb
  - app/models/notifier.rb (accessible_recipients), app/controllers/public/base_controller.rb
  - test/models/access_test.rb, test/models/board/accessible_test.rb, test/models/user/role_test.rb
  - commits c09a02fa9, 0820badcc, e68b344cc, 5a9f9692f, c621cc6cc, 53ae8a33e, 9f6a4f1cc, 77f111002, edf6b5346, 44888eae0, 9e0b9c08c, 4b61c3ae3; PRs #1499, #1841, #3088
snapshot: 55bb38335
---

# Access, roles and authorization

## Answer

Authorization has three layers, and none of them uses a policy library.
**(1) Account membership:** the `Authorization` concern checks that `Current.user`
exists and is active in `Current.account`. **(2) Record visibility:** an `Access`
row (`board_id`, `user_id`) grants a user a board. Controllers load every record
**through the user's associations** (`Current.user.boards.find`,
`Current.user.accessible_cards.find_by!(number:)`), so a record you can't see is
simply a 404. **(3) Capability:** a `role` enum on `User` (`owner admin member
system`) with plain predicates (`admin?`, `can_administer_board?(board)`), checked
in a `before_action` that returns `head :forbidden`. The `Access` row also stores
the user's **involvement** (`access_only` or `watching`), which drives
notifications. Losing access triggers a job that deletes the user's
now-inaccessible mentions, notifications, watches, pins and assignments.

## Shape

```
app/models/
  access.rb                 # board, user, account; enum involvement; accessed; after_destroy_commit cleanup
  board/accessible.rb       # has_many :accesses (with revise/grant_to/revoke_from extension), :users, watchers,
                            # all_access scope, accessible_to?, clean_inaccessible_data_for(user)
  card/accessible.rb        # delegates accessible_to? to board; publicly_accessible?; clean_inaccessible_data
  user/accessor.rb          # has_many :accesses, :boards, :accessible_columns, :accessible_cards, :accessible_comments
  user/role.rb              # enum role; admin?; can_change?, can_administer?, can_administer_board?, can_administer_card?
app/controllers/
  concerns/authorization.rb # ensure_can_access_account (default), ensure_admin, ensure_staff, allow_unauthorized_access
  concerns/board_scoped.rb  # @board = Current.user.boards.find(params[:board_id]); ensure_permission_to_admin_board
  concerns/card_scoped.rb   # @card = Current.user.accessible_cards.find_by!(number: params[:card_id])
  concerns/column_scoped.rb # @column = Current.user.accessible_columns.find(params[:column_id])
  boards_controller.rb      # update: @board.accesses.revise granted:, revoked:
  boards/accesses_controller.rb     # index (the people picker)
  boards/involvements_controller.rb # update my involvement
  users/roles_controller.rb         # update member ↔ admin
app/jobs/board/clean_inaccessible_data_job.rb, card/clean_inaccessible_data_job.rb
```

Routes:

```ruby
resources :boards do
  scope module: :boards do
    resources :accesses, only: :index
    resource :involvement
  end
end

resources :users do
  scope module: :users do
    resource :role
  end
end
```

Schema: `accesses` has a unique index on `[board_id, user_id]`, an `involvement`
string defaulting to `"access_only"`, and `accessed_at`. `boards.all_access` is a
boolean.

## Key code

Visibility is a chain of `has_many :through` on the user:

```ruby
module User::Accessor
  included do
    has_many :accesses, dependent: :destroy
    has_many :boards, through: :accesses
    has_many :accessible_columns, through: :boards, source: :columns
    has_many :accessible_cards, through: :boards, source: :cards
    has_many :accessible_comments, through: :accessible_cards, source: :comments

    after_create_commit :grant_access_to_boards, unless: :system?
  end
end

module CardScoped
  included { before_action :set_card, :set_board }

  private
    def set_card
      @card = Current.user.accessible_cards.find_by!(number: params[:card_id])
    end
end
```

Capabilities are predicates on the user, named for the question being asked:

```ruby
module User::Role
  included do
    enum :role, %i[ owner admin member system ].index_by(&:itself), scopes: false

    scope :admin,  -> { where(active: true, role: %i[ owner admin ]) }
    scope :active, -> { where(active: true, role: %i[ owner admin member ]) }

    def admin?
      super || owner?
    end
  end

  def can_administer?(other)     = admin? && !other.owner? && other != self
  def can_administer_board?(board) = admin? || board.creator == self
  def can_administer_card?(card)   = admin? || card.creator == self
end
```

*(Condensed to endless methods. In the source they are normal `def ... end`.)*
Controllers check them with a `before_action`:

```ruby
class BoardsController < ApplicationController
  before_action :set_board, except: %i[ index new create ]
  before_action :ensure_permission_to_admin_board, only: %i[ update destroy ]

  def update
    @board.update! board_params
    @board.accesses.revise granted: grantees, revoked: revokees if grantees_changed?
    ...
  end
end
```

Granting and revoking are verbs on the association itself, through an association
extension:

```ruby
module Board::Accessible
  included do
    has_many :accesses, dependent: :delete_all do
      def revise(granted: [], revoked: [])
        transaction do
          grant_to granted
          revoke_from revoked
        end
      end

      def grant_to(users)
        Access.insert_all Array(users).collect { |user| { id: ActiveRecord::Type::Uuid.generate, board_id: proxy_association.owner.id, user_id: user.id, account_id: proxy_association.owner.account.id } }
      end

      def revoke_from(users)
        destroy_by user: users unless proxy_association.owner.all_access?
      end
    end

    after_create :grant_access_to_creator          # creator gets involvement: :watching
    after_save_commit :grant_access_to_everyone    # when all_access flips to true
  end

  def accessible_to?(user) = access_for(user).present?
  def watchers = users.active.where(accesses: { involvement: :watching })
end
```

Losing access cleans up after itself, in the background:

```ruby
class Access < ApplicationRecord
  belongs_to :account, default: -> { user.account }
  belongs_to :board, touch: true
  belongs_to :user, touch: true

  enum :involvement, %i[ access_only watching ].index_by(&:itself), default: :access_only

  after_destroy_commit :clean_inaccessible_data_later

  def accessed
    touch :accessed_at unless recently_accessed?      # throttled to 5 minutes
  end

  private
    def clean_inaccessible_data_later
      Board::CleanInaccessibleDataJob.perform_later(user, board) unless user.destroyed?
    end
end
```

The account-level gate is the default for every controller:

```ruby
module Authorization
  included do
    before_action :ensure_can_access_account, if: :authenticated_account_access?
  end

  private
    def ensure_admin = (head :forbidden unless Current.user.admin?)

    def ensure_can_access_account
      unless Current.account.active? && Current.user&.active?
        respond_to do |format|
          format.html { redirect_to session_menu_path(script_name: nil) }
          format.json { head :forbidden }
        end
      end
    end
end
```

*(Condensed.)*

## Why

- **Scope the find, don't check afterwards.** Loading through `Current.user`'s
  associations makes "can't see it" and "doesn't exist" the same 404, and leaves
  nothing to forget. When it was forgotten, the fix was to scope the find: 9f6a4f1cc
  "Fix unauthorized column reordering" (*"Fixed by limiting ColumnScoped to
  User::Accessor#accessible_columns"*, after a HackerOne report). PR #1841 fixed
  ownership in the same spirit: 77f111002 "Allow only the owner of a reaction to
  delete it". DHH removed a one-line wrapper around this
  (`private def user_cards = Current.user.accessible_cards`) in 9e0b9c08c "Explained
  less and extracted nothing of value". The association name already says it.
- **Predicates on the model instead of policy objects.** `can_administer_board?`
  reads as English at the call site and lives in a `User::Role` trait, consistent
  with "no service layer" ([[patterns/model-concerns]]). PR #1499 ("Make sure only
  admins or collection creators can change accesses") added the board and card
  checks as `before_action`s calling these predicates (inference: no policy gem was
  ever in the Gemfile).
- **Access is a join model with state, not a habtm.** It began as a plain join
  (c09a02fa9 "Introduce projects and accesses"). It gained `involvement` in
  0820badcc "Add involvement types to accesses": *"This change replaces our previous
  concept of subscriptions. Where previously you'd subscribe to a collection to get
  notifications in it, now you'll simply set the notification level on your
  access."* Later the levels were cut to two (e68b344cc "Remove _Everything_
  inolvement"), and `accessed_at` was added for "recently visited" ordering
  (5a9f9692f "Track collection access when viewing cards"). One row answers "can I
  see it", "do I watch it", and "when did I last look".
- **The creator watches by default.** 4b61c3ae3 "Grant access to the creator and set
  their involvement to watching".
- **Revoking access cleans up dependent data.** c621cc6cc "Destroy notifications
  when losing access to collection" was later extended to mentions, watches, pins
  and assignments. 53ae8a33e "Improved performance of cleaning inaccessible data"
  rewrote the lookups as single joined queries. PR #3088 (44888eae0 "Filter
  notification recipients by current board access; reconcile stale assignments
  (#3088)") also filters recipients at notify time
  (`Notifier#accessible_recipients`), because cleanup is asynchronous.
- **Owner is a role, not a flag.** edf6b5346 "Introduce an "owner" role, and prevent
  it from being administered". `admin?` is overridden to include owners, so most
  checks don't need to know about the owner. `Users::RolesController` only accepts
  `member`/`admin` (`presence_in`).
- **`all_access` boards.** `all_access` is a column, but access rows are still
  written for everyone (`grant_access_to_everyone`, and `grant_access_to_boards` for
  new users). Queries stay uniform, with a single `joins(:accesses)` path
  (inference). `revoke_from` is a no-op on all-access boards.
- **Bulk writes skip callbacks deliberately.** `grant_to` uses `insert_all` and has
  to generate UUIDs and `account_id` by hand. That cost is accepted for granting a
  whole account at once (inference).

**Reusable vs Fizzy-specific:** reusable: the three layers, scoped finds through
`has_many :through`, role predicates in a `User::Role` concern, an association
extension for `revise`, and cleanup jobs on `after_destroy_commit`. Fizzy-specific:
boards as the unit of access (yours may be projects or buckets), the involvement
levels, and `staff?` on Identity for 37signals admins.

## Testing

- `test/models/board/accessible_test.rb`: "revising access", "grants access to
  everyone after creation/update", "board watchers". Real fixtures, asserting on
  `board.users`.
- `test/models/access_test.rb`: one test per cleanup ("event notifications are
  destroyed when access is lost", mentions, watches, assignments, pins). Each runs
  `perform_enqueued_jobs only: Board::CleanInaccessibleDataJob do kevin_access.destroy end`
  and then checks the rows are gone.
- `test/models/user/role_test.rb`: the predicate matrix ("admin cannot administer
  the owner", "can administer board?").
- Controller tests sign in as a user without access and assert `:not_found`, because
  a scoped find raises `RecordNotFound` (for example,
  `test/controllers/columns/left_positions_controller_test.rb` from 9f6a4f1cc).
  Capability failures assert `:forbidden`.

## Reuse recipe

1. Create an `accesses` join model (`container_id`, `user_id`, `account_id`, unique index) with any per-user state you need (watch level, `accessed_at`).
2. On `User`, write `has_many :containers, through: :accesses`, plus `has_many :accessible_<child>, through: :containers, source: :<child>` for every child resource.
3. In every `XScoped` controller concern, write `Current.user.<accessible association>.find(...)`. Never use `Model.find`, and never use only `Current.account.<x>` for access-controlled things.
4. Put roles in an enum in a `User::Role` concern. Write capability predicates `can_<verb>_<thing>?(thing)`, and check them in a `before_action` that calls `head :forbidden`.
5. Make the account-membership check the default `before_action` in an `Authorization` concern, with `allow_unauthorized_access` as the opt-out.
6. Write `revise(granted:, revoked:)` as an association extension, inside a transaction.
7. On `after_destroy_commit` of an access, enqueue a job that deletes the user's derived data in that container. Also filter at read or notify time, because cleanup is asynchronous.

## Related

[[components/accounts-tenancy]] · [[components/authentication]] · [[components/watching]] ·
[[components/notifications]] · [[patterns/controller-scoping]] · [[patterns/model-concerns]] ·
[[voice/dhh-refactors]]
