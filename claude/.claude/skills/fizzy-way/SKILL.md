---
name: fizzy-way
description: How 37signals builds a Rails SaaS app, distilled from Fizzy (DHH's reference app) into a wiki of components, patterns, testing practice, decisions, and the team's own refactors. Use when asking "has Fizzy built X / how did they build it", "what would 37signals or DHH do here", when designing a common SaaS component (notifications, comments, mentions, access, events, search, exports, auth), when deciding where code belongs or what to name it, or for a DHH/37signals-style review of how code is organized and named ("would they merge this", taste pass, "is this vanilla Rails").
---

# The Fizzy way

A reference for how Fizzy is built and what its team finds important. The wiki is in
`wiki/`, and `wiki/index.md` is its map. It is self-contained: answer from the pages,
not from a local copy of Fizzy. The skill keeps no state and holds no project's data.
Script paths are relative to this skill's directory.

When the real code is needed, open it on GitHub at the page's `snapshot:`, which shows
exactly the code the page was written from:

- File: `https://github.com/basecamp/fizzy/blob/<snapshot>/<path>`
- Commit: `https://github.com/basecamp/fizzy/commit/<sha>`
- PR: `https://github.com/basecamp/fizzy/pull/<number>`

## The project comes first

This skill is secondary to the project you're working in. In every mode, first read
the project's own directives: `CLAUDE.md`, `AGENTS.md`, `STYLE.md`, its linter config,
and the docs they point to. Then:

- **The project already says it:** follow the project and cite its rule, not Fizzy.
- **The project decided otherwise:** follow the project. Mention the Fizzy alternative
  only if asked, or once as an aside. Never treat it as a finding.
- **The project is silent:** apply the Fizzy way in full. This is where the skill earns
  its keep.

Fizzy's own `AGENTS.md` takes the same stance: its instructions are *"defaults with
reasons, not law"*.

## Modes

**Lookup** ("has Fizzy built X?", "how do they do Y?")
1. Read `wiki/index.md` and pick a page by its `use_when` triggers.
2. Answer from the page's *Answer* and *Shape* sections.
3. If the question goes deeper than the page, open its `sources:` on GitHub at its
   snapshot. If no page covers it, search the code on GitHub, and say the answer came
   from code, not the wiki.

**Build** ("add notifications to my app the Fizzy way")
1. Read the component page and the patterns it links to.
2. Follow its *Reuse recipe*, mapping Fizzy's nouns onto the project's domain. Port
   the shape and the reasoning, not product details. Card stacking, for example, is
   Fizzy's own product choice.
3. Where the project's directives differ, follow them and say so.

**Review** ("what would DHH/37signals change?", "would they merge this?", a taste pass)
Follow `review.md`. In short: read the project's directives, run `scripts/check.rb`,
judge each candidate against its wiki page and the directives, and write up findings
anchored at `file:line` with the rewrite and the Fizzy precedent.

## Rules

- **Separate what's cited from what's inferred.** A "why" stated in a commit, PR, blog
  post or podcast gets cited. Anything else is labeled as inference. Never put words in
  DHH's or the team's mouths.
- **The code outranks the wiki.** If code on GitHub at the snapshot disagrees with a
  page, trust the code and note it in `wiki/log.md`.
- **Pages are distilled; `wiki/evidence/` is raw.** Read pages. Grep the evidence only
  when a page falls short, and never read it wholesale.

## Keeping it current

This is maintenance of the skill itself. Every page pins the Fizzy commit it was
verified at (`snapshot:`) and lists what it was distilled from (`sources:`).
`scripts/refresh.rb` clones Fizzy into a temporary directory for each run and deletes
it afterward:

1. `ruby scripts/refresh.rb` reports stale pages (their cited files changed) with a
   GitHub compare link, changed app code no page cites, and new DHH and team commits.
2. `--diff <page>...` prints what changed in each page's cited files. Update the page
   from that diff, then run `--mark <page>...`.
3. `--bump-clean` advances every page whose cited files didn't change. `--evidence`
   appends new commits to `wiki/evidence/`. Read new DHH commits against
   `voice/dhh-refactors.md`.
4. `--verify` checks every cited SHA, quoted commit subject and path. Run it after any
   edit.

When real use shows a gap (a question no page answers, or a smell the checker misses),
add the page or the check. That's how the skill improves.
