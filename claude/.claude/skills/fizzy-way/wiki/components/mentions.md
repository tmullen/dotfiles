---
title: Mentions
use_when: [mentions, "@mention", tag a person in a comment, scan rich text for users, mentionee, notify mentioned users, mention picker, autocomplete users in editor, Action Text attachment for users]
sources:
  - app/models/concerns/mentions.rb, app/models/card/mentions.rb, app/models/comment/mentions.rb
  - app/models/mention.rb, app/models/user/mentionable.rb, app/models/user/attachable.rb
  - app/jobs/mention/create_job.rb
  - app/models/notifier/mention_notifier.rb, app/models/notification/mention_payload.rb
  - app/controllers/prompts/users_controller.rb, app/controllers/prompts/boards/users_controller.rb
  - app/views/prompts/boards/users/_user.html.erb, app/views/users/_attachable.html.erb
  - app/helpers/rich_text_helper.rb
  - config/routes.rb (namespace :prompts, resolve "Mention")
  - test/models/concerns/mentions_test.rb, test/models/user/mentionable_test.rb, test/models/notifier/mention_notifier_test.rb
  - commits aa3acfeaa, d5f035933, 5c9874474, 56a85c261, cdadc0373, e44608036, 53eba9bd0, edcc9e327, 60b3c9c77, b68693623, 29d07e732
snapshot: 27d0d2e6b
---

# Mentions

## Answer

A mention is an **Action Text attachment**: the editor embeds the user's
`attachable_sgid`, so finding mentionees means reading the rich text's attachments.
There's no regex over the text. A shared `Mentions` concern goes on any model that
has rich text (`Card`, `Comment`). After commit it enqueues `Mention::CreateJob`,
which intersects the attached users with the users who may be mentioned there and
writes one `Mention` row (`source`, `mentioner`, `mentionee`) per person. `Mention` is
itself `Notifiable`, so the notification pipeline takes it from there. Its own
callback also makes the mentionee watch the card.

## Shape

```
app/models/
  concerns/mentions.rb      # shared trait: has_many :mentions/:mentionees, after_save_commit → job, scan_mentionees
  card/mentions.rb          # include ::Mentions; mentionable? = published?; should_check_mentions? = was_just_published?
  comment/mentions.rb       # include ::Mentions; mentionable? = card.published?
  mention.rb                # include Notifiable; polymorphic source; mentioner/mentionee; after_create_commit watch
  user/mentionable.rb       # has_many :mentions; mentioned_by(mentioner, at:); attachable partial + content_type
  notifier/mention_notifier.rb        # recipients: [mentionee] unless self_mention?
  notification/mention_payload.rb     # push title "X mentioned you", high_priority?
app/jobs/mention/create_job.rb        # perform(record, mentioner:) → record.create_mentions(mentioner:)
app/controllers/prompts/
  users_controller.rb                 # all active account users (global editors)
  boards/users_controller.rb          # users with access to the board; stale? etag
app/views/prompts/boards/users/_user.html.erb   # <lexxy-prompt-item sgid=...>
app/views/users/_attachable.html.erb            # how a mention renders inside content
app/helpers/rich_text_helper.rb                 # mentions_prompt(board): <lexxy-prompt trigger="@">
```

Routes:

```ruby
namespace :prompts do
  resources :cards
  resources :users
  resources :boards do
    scope module: :boards do
      resources :users
    end
  end
end

resolve "Mention" do |mention, options|
  polymorphic_url(mention.source, options)
end
```

The picker is a plain `index` that returns HTML fragments. Its URL is
`prompts_board_users_path(board)`, nested under the board so that it only offers
people with access to that board.

## Key code

The shared concern does most of the work. It uses reflection to find the record's
rich text fields, and template methods for the per-model rules:

```ruby
module Mentions
  extend ActiveSupport::Concern

  included do
    has_many :mentions, as: :source, dependent: :destroy
    has_many :mentionees, through: :mentions
    after_save_commit :create_mentions_later, if: :should_create_mentions?
  end

  def create_mentions(mentioner: Current.user)
    scan_mentionees.each do |mentionee|
      mentionee.mentioned_by mentioner, at: self
    end
  end

  def scan_mentionees
    mentionees_from_attachments & mentionable_users
  end

  private
    def mentionees_from_attachments
      rich_text_associations.flat_map { send(it.name)&.body&.attachments&.collect { it.attachable } }.compact
    end

    def mentionable_users
      board.users
    end

    def rich_text_associations
      self.class.reflect_on_all_associations(:has_one).filter { it.klass == ActionText::RichText }
    end

    def should_create_mentions?
      mentionable? && (mentionable_content_changed? || should_check_mentions?)
    end

    def mentionable_content_changed?
      rich_text_associations.any? { send(it.name)&.body_previously_changed? }
    end

    def create_mentions_later
      Mention::CreateJob.perform_later(self, mentioner: Current.user)
    end

    # Template method
    def mentionable? = true
    def should_check_mentions? = false
end
```

*(The last two methods are condensed to endless defs. The source uses full `def`/`end`.)*

Per-model specializations only override the hooks:

```ruby
module Card::Mentions
  extend ActiveSupport::Concern

  included do
    include ::Mentions

    def mentionable?
      published?
    end

    def should_check_mentions?
      was_just_published?
    end
  end
end
```

The verb lives on the person, and it's idempotent:

```ruby
module User::Mentionable
  def mentioned_by(mentioner, at:)
    mentions.find_or_create_by! source: at, mentioner: mentioner
  end
end

class Mention < ApplicationRecord
  include Notifiable

  belongs_to :account, default: -> { source.account }
  belongs_to :source, polymorphic: true
  belongs_to :mentioner, class_name: "User"
  belongs_to :mentionee, class_name: "User", inverse_of: :mentions

  after_create_commit :watch_source_by_mentionee

  delegate :card, to: :source

  def self_mention? = mentioner == mentionee
  def notifiable_target = source
  ...
end
```

To make a `User` embeddable in Action Text, `User::Mentionable` sets
`to_attachable_partial_path` → `"users/attachable"`,
`to_editor_content_attachment_partial_path` (same), and
`content_type` → `"application/vnd.actiontext.mention"`.

## Why

- **Scan structure, not text.** Plain-text `@handle` matching came first
  (aa3acfeaa "Add plain text mentions", with `User#mentionable_handles` matching initials
  and first names). Rich-text attachments were added next to it in 5c9874474 "Support
  rich text mentions". Jorge then deleted the regex path in 56a85c261 "Remove plain
  text mentions" (PR #1551). The commit body says: *"They can cause duplicates"*.
  `mentionable_handles` still exists and is tested, but nothing calls it. Leftover
  (inference).
- **One concern, found by reflection.** d5f035933 "Extract mentionable content using
  reflection to remove duplicated logic and the need for additional concerns" replaced
  per-model `mentionable_content` methods with `reflect_on_all_associations(:has_one)`
  filtered to `ActionText::RichText`. Any model with `has_rich_text` gets mentions by
  including one module.
- **Only fire when the rich text actually changed.** cdadc0373 "Don't trigger unless
  the mentionable content changes": *"This is also needed to prevent incorrect
  triggering on cascade touches!"* `belongs_to ... touch: true` chains re-save
  parents, so you have to check `body_previously_changed?`.
- **Drafts are silent until they're published.** 17f9df8df "Don't create mentions from
  drafts until those are published" added the `mentionable?` hook. b68693623 and
  29d07e732 ("Fix: not detecting mentions when publishing saved drafts") added
  `should_check_mentions?` → `was_just_published?`, because publishing doesn't change
  the body, so the dirty check alone misses it.
- **Idempotent writes.** e44608036 "Don't create duplicated mentions": *"E.g: when
  editing a comment or description with a mention"*. `create!` became
  `find_or_create_by!`. Re-saving a body re-scans all its mentionees, and only new ones
  produce rows. So editing a comment to add `@kevin` notifies Kevin without re-notifying
  anyone already mentioned.
- **Commit first, then do the work in a job.** 53eba9bd0 "Favor after_create_commit to
  keep transactions fast". The scan runs in `Mention::CreateJob`, and `mentioner:` is
  passed explicitly because `Current.user` doesn't exist inside the job.
- **Being mentioned subscribes you.** edcc9e327 "Add mentionees as watchers". See
  [[components/watching]].
- **Async creates a race, so the notifiers scan the text instead.** Rosa, 60b3c9c77
  "Fix duplicate push notification for mention and comment event": *"Since mentions are
  created async via Mention::CreateJob, a race condition meant the mentionee list could
  be empty when the event notification job ran first"*. The comment notifier now
  excludes `scan_mentionees` (read from the rich text) instead of `mentionees` (the
  rows). If you split work across jobs, derive exclusions from the source of truth.
- **You can only mention people who can see it.** `mentionable_users` is `board.users`,
  and the prompt endpoint is board-scoped. When access is revoked,
  `Board::Accessible#clean_inaccessible_data_for` destroys that user's mentions. (inference: no commit states the rule; it follows from the code)
- **Precedent.** DHH's [On Writing Software Well #2](https://www.youtube.com/watch?v=m1jOWu7woKM)
  uses Basecamp mentions as the example of callbacks keeping *"that which isn't
  essential to a primary flow live on the side."* Fizzy follows the same shape:
  creating a comment knows nothing about mentions.

**Reusable vs Fizzy-specific.** The reusable parts: attachment-based mentions,
the shared concern with template hooks, the `Mention` row as a `Notifiable`, and
`mentioned_by` on the user. These are Fizzy-specific: the Lexxy editor and
`<lexxy-prompt>` markup, the draft/publish rules, and "mentionees become watchers".

## Testing

- `test/models/concerns/mentions_test.rb` builds real HTML with
  `ActionText::Attachment.from_attachable(user).to_html`. It runs only the job under
  test with `perform_enqueued_jobs only: Mention::CreateJob` and counts rows with
  `assert_difference -> { Mention.count }`. The cases: drafts don't mention,
  publishing does, no repeats on update, no mentions without board access, and
  "notify new mentionees when editing a comment to add a mention".
- `test/models/user/mentionable_test.rb` checks that `mentioned_by` dedups.
- `test/models/notifier/mention_notifier_test.rb` covers self-mentions and includes
  a race test that patches `Notification.create_or_find_by` to simulate a concurrent
  job.
- `test/models/notifier/event_notifier_test.rb` has "don't create notifications on
  comment for mentionees even before mention records exist", the regression test for
  60b3c9c77.

## Reuse recipe

1. Make the user an Action Text attachable: `include ActionText::Attachable`, which Fizzy does in `User::Attachable`, along with
   `attachable_plain_text_representation` → `"@first"`. Set `to_attachable_partial_path` and `content_type`.
2. Add a picker endpoint that returns items carrying `user.attachable_sgid`. Scope it to the people who can see the record.
3. Create `Mention(source: polymorphic, mentioner, mentionee)` and include your `Notifiable` concern.
4. Write `app/models/concerns/mentions.rb` with `after_save_commit` (gated on `body_previously_changed?`) → job → `scan_mentionees` (attachments ∩ allowed users) → `mentionee.mentioned_by(mentioner, at: self)` using `find_or_create_by!`.
5. Give the concern hook methods (`mentionable?`, `should_check_mentions?`) and override them in `Model::Mentions` for drafts and visibility.
6. Pass the actor into the job explicitly. When other notifiers need to exclude mentionees, scan the body instead of querying `Mention` rows.

## Related

[[components/notifications]] · [[components/comments]] · [[components/watching]] ·
[[components/access]] · [[patterns/model-concerns]] · [[patterns/jobs-later-now]] ·
[[voice/dhh-refactors]]
