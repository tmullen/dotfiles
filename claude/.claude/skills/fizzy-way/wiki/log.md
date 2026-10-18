# Change log

- 2026-10-18 — Pilot built at snapshot `27d0d2e6b`: index, components/notifications, patterns/model-concerns, voice/dhh-refactors, sources.
- 2026-10-18 — Verified: all cited SHAs resolve, quoted commit subjects match git, all source paths exist at snapshot. External quotes verified by fetch (see voice/sources.md).
- 2026-10-18 — Template settled: pages are distilled (rule → test → example → evidence SHAs), no inline historical diffs; raw material moved to wiki/evidence/. voice/sources.md → sources.md.
- 2026-10-18 — Full build (workflow, 10 agents): 26 pages added across components, patterns, testing, voice/team, and decisions. Evidence added: team commits and themes, PR comments and review themes. Verifier: all SHAs resolve, quoted subjects match, 6 fixes applied (e.g. a reworded PR quote replaced verbatim, uncited whys marked inference, stale ssrf_protection.rb path noted in sources.md). The critic's uncovered list is under "Planned" in index.md.
- Known vestigial code at the snapshot (pages don't recommend it): User#mentionable_handles, Watch.not_watching, Filter#cacheable?, Event::Promptable, duplicate `resource :reading` under cards.
- 2026-10-18 — Review mode: review.md, scripts/check.rb (11 checks, calibrated: fixture fires all, Fizzy baseline 4), scripts/test/check_test.rb, overlays/factory.md ported from dhh-review (public/private heuristic removed).
- 2026-10-18 — Ran on factory/rails: fixed class-method, heredoc, wrapped-route and model-size gaps; added overlays/<repo>.yml accepted lists (factory: protocol + SPA endpoints). Factory: 124 findings.
- 2026-10-18 — Ledger: scripts/ledger.rb + overlays/factory.ledger.yml (116 open). Stable finding ids (check + path + subject, repeats numbered); dropped the member-block route finding (redundant, unstable). Ranking: weight × (1 + 90-day churn) × size.
- 2026-10-18 — Added components/cards-boards-columns (core domain; reuse recipe for slimming a big core model). Verified SHAs, subjects, fixtures.
- 2026-10-18 — refresh.rb: per-page staleness from snapshot + sources, --mark/--bump-clean/--evidence/--verify. First cycle: 27d0d2e6b → 55bb38335 (Pele replaces Mermaid; decisions #11 gained the example).
