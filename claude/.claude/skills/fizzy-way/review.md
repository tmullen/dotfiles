# Review mode

A correctness review asks *does it work*. This one asks *would 37signals merge it*, and
it measures "good" by the wiki, which comes from Fizzy, not from abstract metrics.
Surface everything they'd change, from the biggest issue to the smallest, sorted by
how much authority backs each point.

## How you got here

- **Typed as a review request** (`/fizzy-way review …`, "DHH review this", "would
  37signals merge this"): run the whole protocol.
- **A passing question mid-task** ("does this read well?"): run the checker on the
  files, answer in a few lines from the relevant wiki page, and offer the full pass.
  Don't answer one question with five sections.

## 1. The project's directives first

Read the project's `CLAUDE.md`/`AGENTS.md`/`STYLE.md`, its RuboCop config, and the
docs they point to (see "The project comes first" in `SKILL.md`). Then sort every
candidate finding into one of three buckets:

- **Their rule already says it.** Cite their rule. That makes it compliance rather
  than taste, which is easier to act on.
- **They decided otherwise.** Say nothing; a softened note still counts as noise.
- **No rule and no linter covers it.** Spend your attention here.

A divergence the project settled, such as an SPA, a different API style or a house
naming scheme, is a decision, not a finding. Drop those candidates silently. The
checker can't read prose, so this filtering is your job.

Never report anything RuboCop can fix. Run `bin/rubocop` if it exists.

## 2. Run the checker

```bash
ruby scripts/check.rb <repo-root> [--paths <changed files>]
ruby scripts/check.rb <repo-root> --since main        # what this branch added or fixed
ruby scripts/check.rb <repo-root> --next 10           # ranked: the theme worth taking on next
ruby scripts/check.rb --shape <file>...               # neutral readout
```

Each check prints the question to ask and the wiki page that shows the alternative.
**Findings are candidates.** Read each one against its page and the project's
directives before reporting it. The checker is stateless and reads the code as it is.
`--since` compares against a git ref in a temporary worktree. `--next` ranks by
weight × (1 + commits in the last 90 days) × size, because files people keep touching
are where a fix pays off. Endpoints fixed by external specs (SAML, OIDC `.well-known`,
OAuth, PWA) are exempt in every app.

| Check | Asks | Page |
|---|---|---|
| service-layer | a role-named class or service directory where a model trait or namespaced PORO belongs | patterns/model-concerns |
| custom-action, custom-route | a verb on a controller where a noun resource belongs | patterns/state-as-resource |
| route-restriction | `only:`/`except:` lists with no story behind them | voice/dhh-refactors |
| unorganized-model | a big Active Record model with no traits folder | patterns/model-concerns |
| anemic-method | a short, argument-free chain wrapped in a name with one caller | voice/dhh-refactors |
| anemic-concern | a concern with no behavior (constants only) | patterns/model-concerns |
| anemic-partial | a one-line partial rendered from one place | voice/dhh-refactors |
| fat-job | `perform` that does work instead of calling `thing.verb` | patterns/jobs-later-now |
| silent-persistence | `save`/`update`/`create` in a controller with the result ignored | voice/dhh-refactors |
| state-columns | `x_at` + `x_by_id` (or boolean + timestamp): state that wants its own record | patterns/state-as-resource |

**Calibration.** Each check is tuned so that Fizzy itself comes out almost clean.
`scripts/test/check_test.rb` asserts the remaining baseline, and each leftover hit is
a judgment call worth knowing about:

- **`resources :passkeys, except: %i[ show new ]`** restricts actions, and the
  restriction has a story behind it.
- **`Mentions#mentionable_users → board.users`** is a hook that a model can override.
  An extension point is a fair reason to keep a one-line method.
- **`cards/triage/_columns`** is a one-line lazy turbo frame. Inlining it would be
  defensible, and so is keeping it as a named slot.

**What the checker deliberately leaves out, and why:**
- **Method length and public/private ratios.** Fizzy's ideal traits are all public
  (`Card::Closeable`: 6 public, 0 private). A long `case` on an event action is
  accepted style there (`Notification::EventPayload#body`, 40 lines).
- **Comment share.** Fizzy's comment-heavy files record invariants and the
  non-obvious *why*, which is exactly what comments are for. Read comments by hand
  and ask: why, or what?
- **Concern size.** A one-association trait is fine (`Card::Multistep` is a lone
  `has_many`). The name is what makes it a trait.

If you add a check, add a fixture case for it and keep Fizzy at its baseline
(`ruby scripts/test/check_test.rb`). A heuristic that flags Fizzy's own code is
wrong, not Fizzy.

## 3. Review against the wiki

Most consequential first. Never open on whitespace.

1. **Organization.** Does the code live where Rails already has a place? See
   `patterns/model-concerns`, `patterns/events-as-spine`, `patterns/jobs-later-now`.
2. **Resources.** Are actions CRUD on nouns? See `patterns/state-as-resource`,
   `patterns/controller-scoping`.
3. **Naming.** Does the domain speak, and do verb pairs match? See `patterns/naming`,
   and theme 2 of `voice/dhh-refactors`.
4. **Abstraction.** Does each name earn its place? Is there a missing object? See
   theme 1 of `voice/dhh-refactors` and theme 1 of `voice/team` (param salad becomes
   an object).
5. **Trust.** Is the code re-checking what Rails or the schema already guarantees?
   Are there nil-guards on certain data, or non-bang persistence calls? See theme 3
   of `voice/dhh-refactors`.
6. **Component fit.** If the code builds something Fizzy already has (notifications,
   access, mentions…), compare it with that component page's *Shape* and *Reuse
   recipe*.
7. **Readability.** Can it be read top to bottom, with the most important methods
   first and helpers in order of use?

## 4. Write-up

```
## Verdict
One line: would they merge this as it reads today?

## Against your own rules
Compliance: cite their rule, anchor at file:line, show the rewrite.

## What they'd change
Most consequential first. Each finding: file:line, the rewrite as code, and the
Fizzy precedent (wiki page, or commit SHA/PR) that backs it. Small items one line each.

## Nice
What's genuinely good. Skip the section rather than invent praise.
```

- **Show the rewrite.** "Extract this" is not a review; the extracted code is.
- **Back every taste call with a precedent** from the wiki. If none exists, say it is
  your own judgment.
- **No scores, and never propose a new framework, gem, or layer.** The answer is less
  code, in the places Rails already provides.
- **Report everything real, and invent nothing.** If the code is good, say so in
  three lines and stop.

## Targets

By default, review the working tree plus **the whole of every file it touches**,
because shape, ordering and naming can't be judged from a diff hunk.

- **A PR number or URL:** run `gh pr diff` for that PR and read the full files.
- **Paths:** review those files whole.
- **A range** (e.g. `main..HEAD`): review that range.
- **`--fix`:** apply the findings after reporting them, then run the repo's test or
  validation command. Anything with more than one defensible resolution stays a
  finding, with its options listed.
