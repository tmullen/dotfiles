---
title: Export and import
use_when: [data export, account export, GDPR export, download my data, import account, migrate between instances, self-hosted to SaaS, zip streaming, large file streaming, S3 multipart, zip bomb, resumable job, ActiveJob::Continuable]
sources:
  - app/models/export.rb, app/models/account/export.rb, app/models/user/data_export.rb
  - app/models/account/import.rb, app/models/card/exportable.rb
  - app/models/account/data_transfer/*.rb, app/models/account/data_transfer/active_storage/*.rb, app/models/account/data_transfer/action_text/rich_text_record_set.rb
  - app/models/zip_file.rb, app/models/zip_file/writer.rb, app/models/zip_file/reader.rb, app/models/zip_file/reader/io.rb, app/models/zip_file/remote_io.rb
  - app/jobs/data_export_job.rb, app/jobs/account/data_import_job.rb
  - app/controllers/account/exports_controller.rb, app/controllers/account/imports_controller.rb, app/controllers/users/data_exports_controller.rb
  - config/recurring.yml, script/import-account, AGENTS.md
  - test/models/zip_file_test.rb, test/models/account/import_test.rb, test/models/account/export_test.rb, test/models/account/data_transfer/**, test/jobs/account/data_import_job_test.rb
  - commits e16cc21b0, f7e2b4e0b, 00c5f7fea, 122a228ed, 992f15066, 5bbd7f633, f50d6d093, 71b99c1e1, 8fb57ace0, b742963f7, ad1b10368, 744fedbfe, c9824cf7e, dec47a32f, 0ba7b9f24, a7c9040b9 (PRs #1768, #2356, #2707, #3068)
snapshot: 55bb38335
---

# Export and import

## Answer

There are two exports and one import, all built from the same pieces. An export is an STI
record (`Export` → `Account::Export`, `User::DataExport`) with a status enum and a
`has_one_attached :file`. Its `build` runs in a job and writes a **streamed zip** through
`ZipFile.create_for(file)`. On S3 that zip goes straight into a multipart upload, and on disk
it goes to a tempfile. An account export is a **`Manifest`** of **`RecordSet`s**, one per model
in dependency order. Each record set writes `data/<table>/<id>.json` and blobs go to
`storage/<key>`. Import is the same manifest read in reverse. It runs as an
`ActiveJob::Continuable` job in two steps, `check` (validate everything, fail cleanly) and
`process` (`insert_all!` in batches). Each step keeps a cursor so a crashed import can resume.
The archive is untrusted input, so every read is bounded.

## Shape

```
app/models/
  export.rb                         # STI base: status enum, file attachment, build/build_later, cleanup
  account/export.rb                 # populate_zip: Manifest#each_record_set → record_set.export(to: zip)
  user/data_export.rb               # populate_zip: one <number>.json + attachments per accessible card
  card/exportable.rb                # Card#export_json, #export_attachments (human-readable export)
  account/import.rb                 # check / process / cleanup; failure_reason enum; storage preflight
  account/data_transfer/
    manifest.rb                     # ordered record sets; resume via start: [model_name, last_id]
    record_set.rb                   # generic: export/import/check for any model with account_id
    account_record_set.rb           # overrides for the singleton account + join code
    user_record_set.rb              # users carry email → find_or_create Identity
    entropy_record_set.rb           # upsert-ish: default entropy rows already exist
    active_storage/blob_record_set.rb        # regenerate keys, set service_name
    active_storage/attachment_record_set.rb  # skip Export/Import attachments
    active_storage/file_record_set.rb        # bytes: storage/<old key> → blob.upload(stream)
    action_text/rich_text_record_set.rb      # sgid ⇄ gid, relativize links, rewrite account slugs
  zip_file.rb                       # create_for(attachment) / read_from(blob): S3 vs disk
  zip_file/writer.rb                # ZipKit::Streamer wrapper; byte_size + MD5 checksum as it writes
  zip_file/reader.rb                # ZipKit::FileReader; per-entry and per-archive byte budgets
  zip_file/reader/io.rb             # IO over one entry: read(length) in bounded slices
  zip_file/remote_io.rb             # HTTP range requests against a presigned S3 URL
app/jobs/
  data_export_job.rb                # perform(export) → export.build
  account/data_import_job.rb        # Continuable: step :check, step :process
config/recurring.yml                # Export.cleanup, Account::Import.cleanup
script/import-account               # CLI import for self-hosters
```

Routes:

```ruby
namespace :account do
  resources :exports, only: [ :create, :show ]
  resources :imports, only: [ :new, :create, :show ]
end

resources :users do
  scope module: :users do
    resources :data_exports, only: [ :create, :show ]
  end
end
```

## Key code

The base export is a small template method. Subclasses only say what goes in the zip:

```ruby
class Export < ApplicationRecord
  has_one_attached :file, dependent: :purge_later
  enum :status, %w[ pending processing completed failed ].index_by(&:itself), default: :pending

  scope :expired, -> { where(completed_at: ...24.hours.ago) }

  def build_later = DataExportJob.perform_later(self)

  def build
    processing!
    with_context do
      ZipFile.create_for(file, filename: filename) { |zip| populate_zip(zip) }
      mark_completed
      ExportMailer.completed(self).deliver_later
    end
  rescue => e
    update!(status: :failed)
    raise e
  end
end

class Account::Export < Export
  private
    def populate_zip(zip)
      Account::DataTransfer::Manifest.new(account).each_record_set { |record_set| record_set.export(to: zip) }
    end
end
```

*(`build_later` condensed to an endless method.)*

The manifest is an explicit, ordered list in which parents come before children. A model gets
the generic record set unless it needs special handling:

```ruby
def record_sets
  [
    Account::DataTransfer::AccountRecordSet.new(account),
    Account::DataTransfer::UserRecordSet.new(account),
    *record_sets_for(::User::Settings, ::Tag, ::Board, ::Column),
    Account::DataTransfer::EntropyRecordSet.new(account),
    record_set_for(::Board::Publication, unique_keys: %w[ key ]),
    *record_sets_for(::Webhook, ::Access, ::Card, ::Comment, ..., ::Event, ::Notification),
    Account::DataTransfer::ActiveStorage::BlobRecordSet.new(account),
    ...
    Account::DataTransfer::ActiveStorage::FileRecordSet.new(account)
  ].then { set_importable_model_names(it) }
end
```

The generic record set covers most models in a few lines:

```ruby
def export_record(record)
  zip.add_file "data/#{model_dir}/#{record.id}.json", record.attributes.slice(*attributes).to_json
end

def import_batch(files)
  batch_data = files.map { |file| load(file).slice(*attributes).merge("account_id" => account.id) }
  model.insert_all!(batch_data)
end
```

*(Condensed. The real version also resets `updated_at`.)*

The streaming write to S3. ZipKit writes, and S3's transfer manager takes a writable stream:

```ruby
service.send(:upload_stream, key: blob.key, content_type: "application/zip", part_size: 100.megabytes) do |write_stream|
  write_stream.binmode
  writer.stream_to(write_stream)
  yield writer
  writer.close
end
blob.update!(byte_size: writer.byte_size, checksum: writer.checksum)
```

Blob bytes go through a block in both directions and are never held whole in memory:

```ruby
# export
zip.add_file("storage/#{blob.key}", compress: false) { |out| blob.download { |chunk| out.write(chunk) } }
# import
zip.read(file) { |stream| blob.upload(stream) }
```

The import job keeps a cursor per step and refuses to resume on errors that will repeat:

```ruby
class Account::DataImportJob < ApplicationJob
  include ActiveJob::Continuable
  TERMINAL_ERRORS = [ Account::DataTransfer::RecordSet::IntegrityError, ZipFile::InvalidFileError,
    Account::Import::InsufficientStorageSpaceError ].freeze
  discard_on(*TERMINAL_ERRORS)

  def perform(import)
    step :check do |step|
      import.check start: step.cursor, callback: ->(record_set:, file:) { step.set!([ record_set.model.name, file ]) }
    end
    step :process do |step|
      import.process start: step.cursor, callback: ->(record_set:, files:) { step.set!([ record_set.model.name, files.last ]) }
    end
  end
end
```

## Why

- **The rule is in AGENTS.md.** *"archives can exceed hundreds of gigabytes — stream, never
  buffer a whole file."* Each layer follows it. 992f15066 "Replace RubyZip with ZipKit":
  *"ZipKit can read and write files directly from S3 which makes both imports and exports way
  more efficient in terms of disk usage."* 5bbd7f633 "Process everything in chunks": the old
  reader *"loaded files into memory … e.g. a 10GB video file, into memory."* On S3 the reader
  makes range requests through `ZipFile::RemoteIO`, so there's no local copy at all.
- **One shape, many models.** 00c5f7fea "Break import and export objects into record sets" and
  122a228ed "Use convention to create boilerplate record sets": the generic `RecordSet` works
  for any table with `account_id`. Subclasses override only `records`, `export_record`,
  `files`, `import_batch` or `check_record`. That is the template method again, the same
  structure as `Notifier` ([[components/notifications]]).
- **Ids survive the trip.** Records are inserted with their original ids, and `check` raises
  `ConflictError` if an id already exists. *(Inference: this only works because every table
  uses globally unique UUIDv7 keys. With integer keys every foreign key would need
  remapping.)* Blob keys are the exception. 71b99c1e1 "Fix path traversal vulnerability in
  ActiveStorage blob key import" generates fresh keys, because a crafted
  `"../../config/deploy.yml"` key could read local files through the Disk service.
- **Treat the archive as hostile.** Anyone can sign up and upload an import
  (`Account::ImportsController#create` creates the account). The protections are layered:
  - polymorphic `*_type` values are checked against the manifest's own model list before
    `constantize` (8fb57ace0, b4fd22644);
  - GIDs in rich text resolve only to records in the importing account (b742963f7);
  - `belongs_to` ids must not already exist, and user references must point at users in the
    export;
  - zip-bomb budgets. 744fedbfe "Cap what an account import reads out of a zip entry",
    c9824cf7e "Budget what an import reads against the size of the archive it came from"
    (*"A real export measures 0.76 bytes out per byte of archive"*), and dec47a32f "End an
    import batch once its entries add up to 16MB".
  The long comments in `zip_file/reader.rb` give the arithmetic. Comments are kept for this
  kind of non-obvious *why*.
- **Check, then process.** 27c73ff42 "Rename validate to check": *"Validate is an ActiveModel
  method, overriding it could have unintended side-effects"*. A failed check sets
  `failure_reason` (`conflict`, `invalid_export`, `insufficient_storage_space`), the user gets
  an email, and `cleanup` later destroys the half-made account. a7c9040b9 "Fail account imports
  cleanly on duplicate unique keys (#3068)" adds declared `unique_keys` to the pre-flight and
  also rescues `RecordNotUnique` during processing (*"Belt to the pre-flight's suspenders"*).
- **Resumable by design.** f50d6d093 "Implement cursors for imports". The cursor is
  `[model_name, last_file]`, and `Manifest#each_record_set(start:)` skips forward.
  `resume_job` re-raises terminal errors so a bad archive isn't retried forever.
- **Both storage backends are first-class.** `ZipFile` branches once, at the edge
  (`s3_service?`). 0ba7b9f24 "Fix BC-10008678752: tame self-hosted import disk demands" read
  disk zips in place through `path_for` instead of copying them to a tempfile, and added a `df`
  preflight. The commit cites *"ENOSPC mid-import crashes the shared puma/Solid Queue
  container"*.
- **Don't export the exports.** ad1b10368 "Fix export size doubling from re-exporting prior
  export blobs (#2707)": export and import zips are blobs on the account too, so they're
  excluded through `INTERNAL_RECORD_TYPES = %w[Export Account::Import]`. The STI base name is
  `Export` because `polymorphic_name` stores the base class.
- **Rich text needs translation, not copying.** SGIDs are signed with the instance's secret, so
  the export writes plain GIDs and the import re-signs them. Links get relativized on the way
  out and re-slugged on the way in (2f9d4533c, 4eadce8ff).
- **Already-compressed media is stored, not deflated.** f7e2b4e0b "Don't compress attachments in
  export": *"Since they are typically images and videos, which are already compressed."*
- **Exports are ephemeral and rate-limited.** From e16cc21b0 "Add "data export" feature"
  (PR #1768): *"Exports expire after 24 hours. And are limited to 10 per day."* That becomes
  `scope :current`, `CURRENT_EXPORT_LIMIT = 10` → `head :too_many_requests`, and
  `Export.cleanup` in `config/recurring.yml`.
- **After import, rebuild derived data rather than trusting it.** `process` finishes with
  `reconcile_cards_count`, `create_missing_user_settings`, granting the importer access to
  all-access boards, and `reconcile_account_storage` ([[components/storage]]).

*Reusable shape:* status-enum export record + `_later` job + attachment + mailer + recurring
cleanup; manifest of record sets; streamed zip via ZipKit; continuable check/process import;
bounded reads. *Fizzy-specific:* the model list, the human-readable `User::DataExport`
(per-card JSON plus files), join codes, entropy upsert, and the signup-as-import flow.

## Testing

- `test/models/account/import_test.rb` runs a full round trip with no mocks. It builds a real
  `Account::Export` from the `37s` fixtures, copies the zip, `destroy!`s the source account,
  imports into a new account, and compares `account_digest` before and after. Other tests cover
  each `failure_reason`, the storage preflight (stubbing `available_storage_space`), and cards
  count reconciliation.
- `test/jobs/account/data_import_job_test.rb` runs the same round trip through
  `perform_now` to exercise the continuable steps.
- `test/models/zip_file_test.rb` builds hostile archives in memory and asserts the exact error:
  entries over the cap, understated sizes, truncated deflate streams, and budget overruns that
  surface through a wrapping consumer.
- `test/models/account/data_transfer/` has one test per specialized record set (blob, file,
  rich text) plus `record_set_test.rb` for unique keys and polymorphic allowlisting.
- Also `test/models/account/export_test.rb`, `test/models/user/data_export_test.rb`,
  `test/controllers/accounts/exports_controller_test.rb`, `test/mailers/export_mailer_test.rb`.

## Reuse recipe

1. Add an `exports` table (STI `type`, `status`, `completed_at`, owner ids) with
   `has_one_attached :file`. `build_later` → job → `build` → mailer. Add a recurring `cleanup`
   and a per-user "current" limit in the controller.
2. Write `ZipFile.create_for(attachment)` on ZipKit's `Streamer`. Stream into S3
   `upload_stream` when the service is S3, otherwise into a tempfile. Track `byte_size` and the
   MD5 checksum while writing so the blob can be finalized.
3. Write a `Manifest` that lists record sets parent-first, and a generic `RecordSet`
   (`data/<table>/<id>.json`, `insert_all!` batches). Subclass only where a model needs it:
   identity merge, regenerated blob keys, rich text re-signing.
4. Stream blob bytes as `storage/<key>` with `compress: false`, using
   `blob.download { |chunk| }` out and `blob.upload(stream)` in.
5. Import = `check` (ids free, refs internal, types allowlisted, unique keys free) then
   `process`. Put both in an `ActiveJob::Continuable` job with a `[model, last_file]` cursor and
   a terminal-error list that is discarded instead of resumed.
6. Bound everything read from the archive: per-entry size, total expansion against archive
   size, and batch bytes.
7. Exclude the export/import attachments from the export itself.
8. After import, reconcile counters and caches instead of importing them as truth.
9. Test one full round trip against fixtures, plus one hostile-archive test per limit.

## Related

[[components/storage]] · [[components/accounts-tenancy]] · [[patterns/jobs-later-now]] ·
[[components/notifications]] · [[testing/fixtures]]
