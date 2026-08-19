# Where DHH taste meets our house rules

Read this before reporting anything. A finding that fights our own style guide is worse than no finding: it burns attention, and applied it fails CI or churns the diff.

---

## 1. Already ours — cite our rule, not Fizzy's

When a finding lands here, **cite the rule number**. It stops being taste and becomes compliance, which is unarguable and easier to fix.

| The DHH point | Ours | Say |
|---|---|---|
| Vanilla Rails; no service/repository layer | **P18** | "P18 — Rails has a place for this" |
| CRUD resources; noun sub-resource over invented verb | **P13** | "P13 — `resource :closure`, not `post :close`" |
| Names descriptive alone, non-redundant in context | **P14** | "P14 — the import stutters" |
| Comments are the exception; one line, *why* only | **P16** | "P16 — default to no comment" |
| Build for the requirement in front of you | **P3** | "P3 — one caller, no second in sight" |
| One home per value | **P19** | "P19 — two sites must match" |
| Shallow jobs, `_later`/`_now`, model does the work | Thin Jobs | "`perform` is one line" |
| Thin controllers, no `begin/rescue`, `before_action` | Skinny Controllers | — |
| No `Constants` module; the framework owns the value | Framework-Owned Constants | — |
| Fix bugs at the layer that owns them | **P15** | — |

We inherit `rubocop-rails-omakase` unmodified — his own config — so Ruby formatting is already his. Never write a finding Rubocop can fix.

## 2. Ours wins — say nothing

Settled here, deliberately or empirically. Silence, not a softened note.

- **Flat `private`, not indented.** Fizzy indents; **50 of 50** of our models are flat, and omakase ships `Layout/IndentationConsistency` disabled. Our majority is the convention.
- **The React + TypeScript SPA exists.** He'd write Hotwire with no build step; that decision is made. Never propose deleting the SPA, moving to Turbo, or dropping TypeScript — same for Zod, TanStack Query, Vite. Review the frontend for naming, abstraction, organization, readability; never for its existence.
- **Jbuilder views for every response** (**P11**), even where a hash literal is shorter.
- **`workspace_id` on every tenant-owned table** (**P8**) — a tenancy invariant, not redundancy.
- **The flat body / `?expand=` / `meta.ui_hints` contract** (**P10**, `api.md` P3) — contract, not taste.
- **`Current.*`, UUIDv7 keys, `bin/ci`, fixtures over factories.** Already aligned.

## 3. Nobody is checking — earn your keep here

Omakase disables **`Metrics` entirely** — no `MethodLength`, `ClassLength`, `AbcSize`, `ParameterLists` — plus all of `Naming` and most of `Style`. Deliberate: he doesn't want a linter arguing about size. So **nothing in this repo has an opinion about shape, size, naming, or whether an abstraction earns its place.** Spend your attention on:

- Class length and the size of the public surface
- Whether a 700-line model should be concerns
- Whether an abstraction has enough callers to exist
- Naming, past the mechanical stutter test in P14
- Method ordering and invocation order
- Comment density (P16 states it; nothing enforces it)
- Parameter counts, nesting depth, conditional sprawl

`deal.rb` is the worked example: 763 lines, 54 methods, **49 public to 5 private**, 27% comments — and every method under 19 lines, so a metrics linter passes it clean. Only the shape shows it.

## Safe here, but still taste

No cop enforces these; report them as his preference, never as compliance.

- **Expanded conditionals over guard clauses.** `Style/GuardClause` and `Lint/AssignmentInCondition` are both off, so `if ids = params[...]` won't fail CI and neither will an early return. Our Skinny Controllers pattern leans the same way — it rejects `unless X; return render_error; end` in favor of a `before_action` — so the spirit is shared. One mention, no campaign.
- **Bang methods only with a non-bang counterpart.**
- **Blank-line rhythm and vertical grouping.**

## When the repo isn't factory

Only §1 and §2 are factory-specific. Elsewhere, read that repo's `CLAUDE.md` / `AGENTS.md` / `STYLE.md` / linter config and rebuild those two lists before reviewing. §3's principle — spend attention where no tool is looking — always holds.
