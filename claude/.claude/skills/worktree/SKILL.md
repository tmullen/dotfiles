---
name: worktree
description: Create or remove a git worktree using the user's ga/gd conventions and branch-naming rules (feature-/chore-/issue- prefix, no ticket numbers). Trigger on "ga"/"gd", "create/remove a worktree", or any phrasing that implies a new branch for isolated work — "spin up a branch for X", "new branch to refactor Y", "clean up this worktree", "I'm done with this one".
---

# Worktree

Create and remove git worktrees the way the user's `ga` / `gd` shell functions do: sibling directory at `../<repo>--<branch>`, `mise trust` on create, branch deleted on remove. The functions themselves don't run from the Bash tool (non-interactive shells skip the user's rc), so run the underlying git commands directly.

## Branch naming

Apply these rules without asking; the user will correct if off.

1. **Prefix:** `feature-` (new capability), `chore-` (refactor, deps, tooling, docs, tests), or `issue-` (bug fix).
2. **No ticket numbers** (`ENG-1234`, `#123`). Version numbers like `rails-7-2` are fine — they describe the *what*.
3. **Short, lowercase, hyphen-separated.** 2–5 words after the prefix.

| Task | Good | Bad |
|---|---|---|
| Refactor auth | `chore-refactor-auth` | `auth-refactor`, `chore/refactor-auth-for-testability` |
| Login broken | `issue-login-broken` | `bug-ENG-1234`, `fix-login` |
| Dark mode toggle | `feature-dark-mode` | `dark-mode-ENG-999`, `feature-add-dark-mode-toggle` |
| Bump Rails to 7.2 | `chore-bump-rails-7-2` | `rails-upgrade`, `RAILS_72` |

## Create

Announce the chosen branch name in one line first so the user can redirect. Then, from inside the main checkout:

```bash
base=$(basename "$PWD")
path="../${base}--${branch}"
git worktree add -b "$branch" "$path"
command -v mise >/dev/null && mise trust "$path"
cd "$path"
```

Tell the user the worktree path so they can `cd` there from their own shell.

## Remove

Destructive — force-removes uncommitted files and deletes the branch. Run only on an explicit request ("remove", "tear down", "clean up this worktree"), and confirm first: *"Remove `repo--chore-refactor-auth` and delete the branch?"*

From inside the worktree:

```bash
cwd=$(pwd)
worktree=$(basename "$cwd")
root=${worktree%%--*}
branch=${worktree#*--}
```

**Safety check:** if `root == worktree` (no `--` in the name), bail — this isn't a convention-created worktree, and removing it could nuke the main checkout.

Otherwise:

```bash
cd "../$root"
git worktree remove "$cwd" --force
git branch -D "$branch"
```

## Related tools

- **This skill** — default for any user-visible branch; the only path that enforces the naming convention.
- **`EnterWorktree`** — use to move the session into a worktree *after* this skill creates it; don't let it create the worktree itself (wrong naming).
- **`Agent(isolation: "worktree")`** — ephemeral subagent work with auto-cleanup. Keep using for background tasks.
- **`commit-commands:clean_gone`** — complementary: cleans up worktrees orphaned by a deleted remote, not ones the user is abandoning now.

## Proposing unprompted

If the user kicks off clearly distinct work mid-task ("also refactor billing", "fix the timezone bug while you're at it"), offer a worktree as a question: *"Want me to spin up a worktree for that?"* Skip the offer for trivial one-file fixes.

## Source

Shell implementation: `~/.local/share/omarchy/default/bash/fns/worktrees`.
