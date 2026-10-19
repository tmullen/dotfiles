---
title: What DHH refactors
use_when: [what would DHH change, is this too abstract, should I extract this, naming review, taste pass, 37signals-style review, is this anemic, refactor toward simplicity]
sources: 548 DHH commits on Fizzy (index: evidence/dhh-commits.txt); sources.md
snapshot: 55bb38335
---

# What DHH refactors

Most of his commits **remove** something that doesn't pull its weight. The commit
subject is the reason, stated in a few words. Values he states himself: *"Aesthetically
pleasing code is a value unto itself"* ([Rails Doctrine](https://rubyonrails.org/doctrine#beautiful-code))
and *"Make it work. But then you should refactor it to make it nice."*
([On Writing Software Well #7](https://www.youtube.com/watch?v=Yd3j3ZEx6DU))

Each theme below gives the rule, the test he applies, and one example. "Evidence"
lists Fizzy commit SHAs. Open them only when the rule is not enough.

## 1. Anemic code gets inlined

**Rule:** a method, partial, helper, scope or concern that only renames a single
expression gets deleted, and the expression goes back to the call site. This is his
most distinctive theme: "anemic" appears in 19 commit subjects.
**Test:** does the name say something the expression doesn't? If yes, extract it to
name a concept or to keep one level of abstraction. If no, inline it.
**Example:** `private def user_cards = Current.user.accessible_cards` was deleted in
favor of the expression ("Explained less and extracted nothing of value"). A concern
holding only two constants was dissolved into the one trait that used them.
**Evidence:** 9e0b9c08c, a1543f266, 9913853cc, 22abf0ba4

## 2. Speak the domain, consistently

**Rule:** names come from the domain, not the UI or the implementation. Verb pairs
match (`open`/`close`, not `active`/`close`). Drop qualifiers that context already
supplies (`Entropy`, not `Entropy::Configuration`). Bold names are welcome: *"don't
be aseptic; double down on boldness"* ([Domain driven boldness](https://dev.37signals.com/domain-driven-boldness/)).
Fizzy examples are `gild`, `Goldness`, `NotNow`, `Entropy` and `Closure`.
**Test:** say it aloud next to its pair and its namespace. A widget name
(`closure_toggle`) gives way to the concept (`closure`).
**Evidence:** 7a46fd094, b788ef163, and subjects such as "Match domain language", "Suffix qualifier is unnecessary"

## 3. Trust the framework and the data

**Rule:**
- Prefer what Rails already provides:
  - model-to-route lookup (`form_with model: card` with no `url:`)
  - `_path` over `_url`
  - full `resources`, with `only:` reserved for when *"there's a specific story to tell"*
  - built-ins such as `authenticate_or_request_with_http_token`
- Rely on database constraints plus `create!`/`update!` instead of duplicate presence validations.
- Use bang methods so failures raise.
- Don't nil-guard what the domain guarantees ("Be confident").

**Test:** is this code re-stating something Rails or the schema already enforces?
**Evidence:** 333634a5c, 72d0008df, d6c88736b, 3ec930834, a7d17b38a

## 4. Performance comes from HTTP and from loading less

**Rule:** reach for `fresh_when`/etags, lazy-loaded frames and fewer requests before
anything clever. Load a collection once in the controller, pass it to `fresh_when`,
and reuse it in the view (`@users.many?`, not a second `count`). Remove slow counts
and broadcasts that aren't needed.
**Evidence:** 6570f5fc0, and 21 subjects mentioning etag or caching

## 5. Keep transactions short

**Rule:** don't wrap a batch of independent writes in one transaction, and don't
bloat the main one. He balances this against leaving data broken: "Don't want to
balloon txn, but also don't want to end up with a state with broken data". It's a
judgment call, not a ban.
**Evidence:** 7124835e6

## 6. Split overloaded controllers into resources

**Rule:** when a controller starts carrying unrelated actions, the extra one becomes
its own resource. `UsersController#join` became `Users::JoinsController#new/create`.
In the other direction, one controller should handle all of a concept (one readings
controller for every notification reading), and a single record doesn't need an
`index`.
**Evidence:** 43069b1ea; also see [[patterns/state-as-resource]]

## 7. Plain beats clever

**Rule:** write code that reads top to bottom. Most important methods go first,
helpers follow in order of use, and scopes are lined up in the order of the flow. A
temporary variable is better than a chained trick: `redirect_to
@collection.cards.create!` was judged "Too clever".
**Evidence:** b36b2f04a, and subjects such as "We don't need to be fancy here", "More natural conditional"

## 8. One way per job

**Rule:** once a pattern exists, everything uses it.
- Turbo stream *templates* in all but the simplest cases.
- Re-render the card (`render_card_replacement`) rather than redirect.
- Partials live next to the templates that include them, and don't reference ivars.
- Plain HTML when there is no logic.

**Evidence:** subjects "Prefer templates for turbo streams in all but the very simplest cases", "Follow render_card_replacement pattern", "Dont reference ivars in partial"

## Not worth capturing

Whitespace, quoting and indentation commits ("Style", "Spacing"). RuboCop omakase
already covers them.
