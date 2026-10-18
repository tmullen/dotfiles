---
name: fizzy-way
description: How 37signals builds a Rails SaaS app, distilled from Fizzy (DHH's reference app) into a wiki of components, patterns, testing practice, decisions, and the team's own refactors. Use when asking "has Fizzy built X / how did they build it", "what would 37signals or DHH do here", when designing a common SaaS component (notifications, comments, mentions, access, events, search, exports, auth), when deciding where code belongs or what to name it, or for a DHH/37signals-style review of how code is organized and named ("would they merge this", taste pass, "is this vanilla Rails").
---

# The Fizzy way

The wiki is in `wiki/`, and `wiki/index.md` is its map. The primary source is the
Fizzy checkout at `~/Work/Vendor/fizzy`, pinned at the snapshot SHA in `wiki/index.md`.
Every page lists its `sources:` so you can open the real code.

## Modes

**Lookup** ("has Fizzy built X?", "how do they do Y?")
1. Read `wiki/index.md` and pick a page by its `use_when` triggers.
2. Answer from the page's *Answer* and *Shape* sections.
3. If the question goes deeper than the page, open the files in `sources:`. If the
   wiki has no page, grep `~/Work/Vendor/fizzy/app` for the concept and say the
   answer came from code, not the wiki.

**Build** ("add notifications to my app the Fizzy way")
1. Read the component page and the patterns it links to.
2. Follow its *Reuse recipe*, mapping Fizzy's nouns onto the target app's domain.
   Port the shape and the reasoning, not the product details. Card stacking, for
   example, is Fizzy's own product choice.
3. Match the target repo's house rules where they conflict, and say so.

**Review** ("what would DHH/37signals change?", "would they merge this?", a taste pass)
Follow `review.md`. In short: read the house rules (and `overlays/<repo>.md` if one
exists), run `scripts/check.rb`, judge each candidate against its wiki page, and write
up findings anchored at `file:line` with the rewrite and the Fizzy precedent.

## Rules

- **Separate what's cited from what's inferred.** A "why" stated in a commit, PR,
  blog post or podcast gets cited. Anything else is labeled as inference. Never put
  words in DHH's or the team's mouths.
- **Check the code over the wiki.** If the code at the snapshot disagrees with a
  page, trust the code and add an entry to `wiki/log.md`.
- **Pages are distilled; `wiki/evidence/` is raw.** Read pages. Grep evidence or `git show <sha>` in the Fizzy checkout only when a page falls short. Never read evidence wholesale.
