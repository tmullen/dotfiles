---
name: dhh-review
description: Review code the way DHH would — naming, routing, whether to abstract, organization, readability, comments, and the physical shape of a class. Use when someone asks for a DHH or 37signals/Basecamp review, a taste or elegance pass, "what would DHH call out here", "is this vanilla Rails", or a review of how code reads rather than whether it works. Separates what our style guide already settles from his taste. Deepest on Ruby/Rails; reports, and only edits when asked.
---

# DHH review

A correctness review asks *does it work*. This asks *would he merge it*.

Surface **what he'd change** — all of it, big to small. Whether he'd raise it in a comment or fix it himself changes nothing for the reader. Sort by authority instead: our style guide settles some of it, the rest is his taste and your call. A taste review that presents preference as defect gets ignored.

## However you got here

Typed as `/dhh-review` — run the whole protocol. Fired by a passing question mid-task ("does this read well?") — read `references/conflicts.md`, glance at the shape, answer in a few lines, offer the full pass. Don't return five sections to one question.

## Know the house rules first

**Read `references/conflicts.md`**: where this taste is already our law (cite our rule), where we've decided otherwise (say nothing), where no linter looks (spend your attention). Confirm against the repo, since the map ages — `agents/function/engineering.md`, `rails/.rubocop.yml` (we inherit `rubocop-rails-omakase`, his own config, unmodified), any `CLAUDE.md` / `AGENTS.md` / `STYLE.md`.

**Never report what Rubocop can fix.** Run `bin/rubocop`.

Read `references/taste.md` when judging in earnest. On close calls prefer primary source: `~/Work/Vendor/fizzy/STYLE.md` and the Fizzy code beside it — grep for the analogous pattern and match it. If those paths are gone, say so and carry on.

## Start with the shape

```bash
ruby ~/.claude-work/skills/dhh-review/shape.rb path/to/file.rb
```

Prints every method's length in file order, the public/private split, comment share, deepest indent. Read it before the code — shape is the one dimension nothing here checks. What the outlines say:

- **Many public, few private** — nothing encapsulated. Forty tidy methods is still a grab-bag.
- **One long bar among short ones** — where the thinking stopped. Read that one first.
- **Uniform medium bars** — a spec transcribed, not modelled.
- **A long class with no concerns** — organization never attempted.
- **Deep indent** — conditional soup. Check the line it names; a wrapped string inflates it.
- **High comment share** — the names aren't carrying (P16).
- **Four or more parameters** — a missing object.

Quote the numbers. "763 lines, 49 public, 5 private" is not a matter of opinion.

## The seven lenses

Most consequential first. Never open on whitespace.

1. **Shape** — does the class's job show in its outline?
2. **Organization** — Rails has a place for this. A `Service`, `Manager`, `Interactor`, `Repository`, or `*Handler` is the loudest smell (P18); a 700-line model with no concerns is next.
3. **Naming** — does the domain speak? `card.gild`, not `CardGoldStatusApplier.new(card).apply`. Read it aloud where it lands: an import line, a stack trace, a grep result (P14).
4. **Abstraction** — one caller and no second in sight is worse than the duplication it removed (P3); three sites that must agree is a missing name (P19). Extract to name a concept, not to satisfy a rule.
5. **Routing** — CRUD on a resource, not a verb on a controller. `resource :closure` over `post :close`; the inverse comes free (P13).
6. **Readability** — readable top to bottom? Class methods, public with `initialize` first, then private below their callers in call order.
7. **Comments** — does each one survive "why couldn't the code say this?" (P16).

## The write-up

```
## Verdict
One line: would he merge this as it reads today?

## Shape
The silhouette in numbers, per file worth reporting, and what it says.

## Against our own rules
Where our style guide already settles it. Cite the rule (P13, P16, …) —
compliance, not taste. Anchor at `file:line`, show the rewrite as code.

## What he'd change
Everything else, most consequential first — a 700-line model long before a
stuttering name. Same anchoring. Include the small items, one line each;
they're the bulk of what he'd touch.

## Nice
What's genuinely good. Skip the section rather than manufacture it.
```

- **Show the rewrite.** "This should be extracted" isn't a review; the extracted version is.
- **Anchor every finding** at `file:line`.
- **No scores, no rubric tables.** A number is a way of avoiding the judgment.
- **Own the subjectivity** wherever a defensible alternative exists. Don't launder taste as fact.
- **Never propose a new framework, gem, or layer.** The answer is less code in the places Rails already provides (P2).
- **List everything real; invent nothing.** No cap, no padding. If the code is good, say so in three lines and stop.

## Targets

Default: the working tree, plus **the whole of every file it touches** — shape, ordering, and naming are invisible in a hunk.

- `/dhh-review 852` or a PR URL — that PR (`gh pr diff`), full files
- `/dhh-review rails/app/models/deal.rb` — those paths, whole
- `/dhh-review main..HEAD` — that range
- `--fix` — apply the findings after reporting them, then run `./lola validate` and report what it says. Nothing applies without this flag; anything with more than one defensible resolution stays a finding, with its options listed.
