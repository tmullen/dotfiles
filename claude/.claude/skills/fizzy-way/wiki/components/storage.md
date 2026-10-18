---
title: Storage accounting and Active Storage
use_when: [storage quota, storage usage, bytes used, attachment accounting, storage limit, ledger, counter cache deadlock, Active Storage, blob authorization, direct upload, purge, blob reuse, multi-tenant attachments]
sources:
  - app/models/storage.rb, app/models/storage/entry.rb, app/models/storage/total.rb, app/models/storage/attachment_tracking.rb
  - app/models/concerns/storage/tracked.rb, app/models/concerns/storage/totaled.rb
  - app/models/account/storage.rb, app/models/board/storage.rb, app/models/card/commentable.rb
  - app/jobs/storage/materialize_job.rb, app/jobs/storage/reconcile_job.rb
  - config/initializers/active_storage.rb, config/initializers/active_storage_no_reuse.rb, config/initializers/active_storage_purge_on_last_attachment.rb
  - config/initializers/action_text.rb, config/initializers/uuid_framework_models.rb, lib/rails_ext/active_storage_authorization.rb
  - config/storage.oss.yml, script/migrations/backfill-storage-ledger.rb
  - saas/app/models/account/storage_limited.rb, saas/app/controllers/concerns/card/storage_limited.rb
  - test/models/storage/*, test/jobs/storage/*, test/integration/active_storage_authorization_test.rb
  - commits 761d0b4a7 (PR #2026), bd6c1cf34 (PR #2096), 006e61ea5 (PR #2346), 196d685f8
snapshot: 27d0d2e6b
---

# Storage accounting and Active Storage

## Answer

Fizzy uses stock Active Storage (Disk when self-hosted, S3 for SaaS) and adds two things.
**Storage accounting** is an append-only ledger. Every attach and detach writes a
`Storage::Entry` row (`delta`, `operation`, who, which request) from a hook on
`ActiveStorage::Attachment`. `Account` and `Board` each roll the ledger up into their own
`Storage::Total` snapshot, in a per-owner, concurrency-limited job, using a cursor
(`last_entry_id`). Reads are `bytes_used` (the snapshot, maybe slightly stale) or
`bytes_used_exact` (snapshot plus pending entries). `reconcile_storage` checks the ledger
against the real blobs. **Hardening** is the second addition: each blob, attachment and rich
text row carries `account_id`, blob URLs are authorized through the record a blob is attached
to, and a blob is purged only when its last attachment is gone. The SaaS engine adds quotas
on top of `bytes_used`.

## Shape

```
app/models/
  storage.rb                        # module Storage: table_name_prefix "storage_", TRACKED_RECORD_TYPES
  storage/entry.rb                  # the ledger row; Entry.record(...) is the only writer
  storage/total.rb                  # polymorphic owner snapshot: bytes_stored, last_entry_id
  storage/attachment_tracking.rb    # included into ActiveStorage::Attachment: attach/detach entries
  concerns/storage/tracked.rb       # on Card, Comment, Board: "I own attachments"; board transfers
  concerns/storage/totaled.rb       # on Account, Board: bytes_used, materialize, reconcile
  account/storage.rb                # Account::Storage < Totaled: real bytes = sum of boards
  board/storage.rb                  # Board::Storage < Totaled: real bytes = images + embeds, batched
app/jobs/storage/
  materialize_job.rb                # limits_concurrency to: 1, key: owner
  reconcile_job.rb                  # retry_on ReconcileAborted
config/initializers/
  active_storage.rb                 # include Storage::AttachmentTracking; same DB pool; url_options
  active_storage_no_reuse.rb        # validations: blob.account == record.account; no tracked reuse
  active_storage_purge_on_last_attachment.rb  # purge via destroy, only when last attachment
  action_text.rb                    # RichText#storage_tracked_record → parent record
  uuid_framework_models.rb          # belongs_to :account defaults on Blob/Attachment/RichText/VariantRecord
lib/rails_ext/active_storage_authorization.rb  # Blob#accessible_to?, ensure_accessible, inline type guard
saas/ … account/storage_limited.rb  # storage_limit, exceeding_storage_limit? (SaaS only)
tables: storage_entries (account_id, board_id, recordable, blob_id, delta, operation, user_id, request_id)
        storage_totals (owner polymorphic unique, bytes_stored, last_entry_id)
```

There are no routes of its own. Blob routes are Rails' built-in ones, wrapped with
authorization.

## Key code

The hook. Attachments know nothing about quotas; they ask their record whether it's tracked:

```ruby
# config/initializers/active_storage.rb
ActiveSupport.on_load(:active_storage_attachment) do
  include Storage::AttachmentTracking
end

module Storage::AttachmentTracking
  included do
    before_destroy :snapshot_storage_context      # parent may be gone by after_destroy_commit
    after_create_commit :record_storage_attach
    after_destroy_commit :record_storage_detach
  end

  private
    def record_storage_attach
      return unless storage_tracked_record
      Storage::Entry.record account: storage_tracked_record.account, board: storage_tracked_record.board_for_storage_tracking,
        recordable: storage_tracked_record, blob: blob, delta: blob.byte_size, operation: "attach"
    end

    def storage_tracked_record = record.try(:storage_tracked_record)
end
```

*(Condensed.)* Rich text embeds find their way back to the card through
`ActionText::RichText#storage_tracked_record → record.try(:storage_tracked_record)`.

A model opts in with one include. Board transfers move bytes between boards:

```ruby
class Card < ApplicationRecord
  include ..., Storage::Tracked, ...
end

module Storage::Tracked
  included do
    before_update :track_board_transfer, if: :board_transfer?   # transfer_out / transfer_in entries
  end

  def storage_tracked_record = self
  def board_for_storage_tracking = board
end
```

The ledger write is the single entry point. It can be suppressed during account teardown:

```ruby
class Storage::Entry < ApplicationRecord
  thread_mattr_accessor :recording, default: true

  def self.record(delta:, operation:, account:, board: nil, recordable: nil, blob: nil)
    return if delta.zero?
    return if account.destroyed?
    return unless recording

    entry = create! account_id: account.id, board_id: board&.id, ..., delta: delta, operation: operation,
      user_id: Current.user&.id, request_id: Current.request_id

    account.materialize_storage_later
    board&.materialize_storage_later unless board&.destroyed?
    entry
  end
end

# app/models/account/incineratable.rb
Storage::Entry.suppressing_recording { account.destroy }
```

Materializing rolls forward from a cursor under a row lock:

```ruby
def materialize_storage
  total = create_or_find_storage_total
  total.with_lock do
    latest_entry_id = storage_entries.maximum(:id)
    if latest_entry_id && total.last_entry_id != latest_entry_id
      scope = storage_entries.where(id: ..latest_entry_id)
      scope = scope.where.not(id: ..total.last_entry_id) if total.last_entry_id
      total.update! bytes_stored: total.bytes_stored + scope.sum(:delta), last_entry_id: latest_entry_id
    end
  end
end
```

Quotas sit on top in the SaaS engine and change nothing in core:

```ruby
module Account::StorageLimited          # saas/
  DEFAULT_STORAGE_LIMIT = 1.gigabyte
  def exceeding_storage_limit? = bytes_used > storage_limit
end
# saas engine: CardsController.include(Card::StorageLimited::Creation) → before_action :ensure_within_storage_limit
```

Blob access is decided by the record the blob is attached to:

```ruby
ActiveSupport.on_load :active_storage_blob do
  def accessible_to?(user)
    attached = attachments.includes(:record).to_a
    attached.any? ? attached.any? { it.accessible_to?(user) } : unattached_accessible_to?(user)
  end
end
ActiveSupport.on_load :active_storage_attachment do
  def accessible_to?(user) = record.try(:accessible_to?, user)
end
```

*(Condensed from `lib/rails_ext/active_storage_authorization.rb`.)*

## Why

- **A ledger instead of counters.** From 761d0b4a7 "Speedy, auditable, deadlock-resistant storage
  tracking (#2026)": *"An append-only storage ledger replaces deadlock-prone synchronous counter
  updates and drift-prone async updates."* And: *"Both consume the same event stream
  independently: no bubble-up storage bumps triggering deadlocks due to lock sequencing."*
  Account and Board each keep their own cursor, so neither one locks the other.
- **Fast versus exact, both named.** `bytes_used` reads the snapshot and serves quotas and UI.
  `bytes_used_exact` adds pending entries when correctness matters. Each entry records
  `user_id` and `request_id` from `Current` ([[patterns/current-attributes]]), so every byte
  has an audit trail.
- **A cursor over UUIDs.** `where(id: ..last_entry_id)` only works because primary keys are
  UUIDv7 and sort by time (*inference*; see AGENTS.md "UUID primary keys").
- **Reconcile without races.** bd6c1cf34 "Storage: harden reconcile for concurrent writes and fix
  board transfer (#2096)": *"Reconcile now uses two-cursor approach: captures cursor before and
  after the storage scan, aborting if they differ"*. The job retries on abort.
  `Account::Import#process` calls `reconcile_storage` and `materialize_storage` once rows are
  in, instead of importing ledger totals ([[components/export-import]]).
- **Count attachments, not physical bytes.** The comment on `Storage::Tracked`: *"Storage
  tracking is a business abstraction - we count what users upload. Original upload bytes only;
  variants/previews/derivatives excluded."* `Board::Storage` warns: *"Do NOT remove the join
  thinking it's a performance optimization - it's required for correct per-attachment
  counting."*
- **No blob reuse in tracked contexts, with one exception.** bd6c1cf34 added the validation.
  The initializer's comment says it is *"a product/control decision"*: a *"Simpler mental model
  (one blob = one attachment)"*, and it *"Prevents accidental quota manipulation via direct
  blob_id reuse"*. 006e61ea5 "Allow ActionText embed reuse and safe purge (#2346)" then let
  embeds reuse blobs (copy and paste), which required purge-on-last-attachment. Rails' default
  purge uses `delete`, which skips callbacks, so Fizzy overrides it to `destroy`. That way the
  detach entries get written.
- **Snapshot before destroy.** In a cascade the parent may already be gone when
  `after_destroy_commit` runs, so `before_destroy` copies what the entry needs. 5d181af39
  "Storage: ignore jobs for now-deleted targets" makes jobs for deleted owners harmless.
- **Tenancy reaches into framework tables.** `uuid_framework_models.rb` gives framework records
  account defaults: `ActiveStorage::Blob.belongs_to :account, default: -> { Current.account }`,
  `Attachment`'s from `record.account`, and so on. The no-reuse initializer also rejects a blob
  from another account. Active Storage is put on the app's connection pool *"for transactional
  integrity, proper callback invocation, joins, etc."* (comment in `active_storage.rb`).
- **Blob URLs are not capability URLs.** 196d685f8 "Implement authorization for Active Storage
  endpoints": a blob is accessible when the record it's attached to is accessible, or public
  (*"Consider blobs attached to any public records accessible to anyone with the URL."*).
  Later commits tightened it: unattached blobs are visible only within their own account, and
  HTML/SVG-ish content types are forced to download (HackerOne references in the file's
  comments).
- **Quota enforcement is a SaaS plug-in.** The open-source app tracks usage but never blocks.
  The SaaS engine includes `Account::StorageLimited` and `before_action`s into core
  controllers. This is the same registry-style seam as push targets
  ([[components/notifications]]).
- **Large comment sets are streamed.** `Card::Commentable#storage_transfer_records` walks
  comments `in_batches(of: 1000)` and loads only the ones that have attachments. From the code:
  *"Cards can have thousands of comments; most won't have attachments."*

*Reusable shape:* ledger + per-owner snapshot with cursor + materialize job with
`limits_concurrency` + two-cursor reconcile; `Tracked`/`Totaled` concern pair; attachment
callbacks installed via `on_load`; record-based blob authorization. *Fizzy-specific:* Board
as a second owner, transfer entries on board move, the embed-reuse exception, the 1 GB SaaS
default.

## Testing

- `test/models/storage/attachment_tracking_test.rb` attaches real files to fixture cards,
  comments and boards. It asserts entry deltas, `assert_enqueued_with(job: Storage::MaterializeJob)`,
  and that tracking survives cascading deletes.
- `test/models/storage/tracked_test.rb` covers board transfers (card image, description embeds,
  many comments) as balanced `transfer_out`/`transfer_in` pairs.
- `test/models/storage/totaled_test.rb` and `total_test.rb` cover cursor math, pending entries
  and reconcile drift. `entry_test.rb` checks that a zero delta writes nothing and that entries
  can still be recorded for already-destroyed records.
- `test/models/storage/no_reuse_test.rb` checks reuse rejection, the embed exception,
  cross-account rejection, and purge-only-when-last.
- `test/jobs/storage/reconcile_job_test.rb` covers drift correction both ways, the per-owner
  concurrency limit, and raising `ReconcileAborted`.
  `test/integration/active_storage_authorization_test.rb` hits `rails_blob_path` as a member, a
  non-member and a bearer token.
- SaaS quotas are tested in `saas/test/models/account/storage_limited_test.rb` and
  `saas/test/controllers/card/storage_limited_test.rb`.

## Reuse recipe

1. Add `belongs_to :account` defaults to Active Storage and Action Text models in an initializer.
   Validate `blob.account == record.account` on attachment create.
2. Authorize blob endpoints by delegating `accessible_to?` from blob to attachment to record.
   Let public records opt in with `publicly_accessible?`.
3. Create `storage_entries` (append-only: `delta`, `operation`, `account_id`, optional container,
   `recordable`, `blob_id`, `user_id`, `request_id`) and `storage_totals` (polymorphic owner,
   `bytes_stored`, `last_entry_id`).
4. Write one `Storage::Entry.record(...)` writer. Call it from `ActiveStorage::Attachment`
   callbacks added via `ActiveSupport.on_load`, and snapshot the context in `before_destroy`.
5. Include a `Storage::Tracked` concern in models that own attachments, and a
   `Storage::Totaled` concern in models that report usage. Give each owner its own
   materialize job with `limits_concurrency to: 1, key: owner`.
6. Add `reconcile_storage` using the two-cursor check, and run it after bulk operations such as
   imports.
7. Put quotas behind a concern that only the paid edition includes. Enforce them with
   `before_action` on create endpoints.
8. If blobs can be shared (embeds), override purge so the blob is deleted only with its last
   attachment, and route deletes through `destroy` so the ledger sees them.

## Related

[[components/export-import]] · [[components/accounts-tenancy]] · [[components/access]] ·
[[patterns/model-concerns]] · [[patterns/current-attributes]] · [[patterns/jobs-later-now]] ·
[[components/notifications]]
