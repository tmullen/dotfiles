#!/usr/bin/env bash
# Recreate the shared-config symlinks in each extra Claude config dir.
#
# Extra Claude accounts run against their own config dir via aliases in
# bash/.bashrc (`cw` → ~/.claude-work, `cl` → ~/.claude-personal). Each SHARES
# its CLAUDE.md, statusline, skills, and commands with ~/.claude by symlinking to
# the same source in the `claude` stow package. A dir that keeps a real
# directory of its own in place of a link (~/.claude-work/commands) is left as is.
#
# settings.json is not linked: each dir's copy carries its own hook path, and
# ~/.claude-personal's pins its login to the personal org. See README.md for
# seeding it on a new machine.
#
# Runtime state (projects/, history.jsonl, sessions/, .credentials.json, cache/)
# is machine-local and untracked — Claude recreates it on first run.
#
# Idempotent: safe to re-run. Run from anywhere.
set -euo pipefail

src="$HOME/Work/Personal/dotfiles/claude/.claude"

for dst in "$HOME/.claude-work" "$HOME/.claude-personal"; do
  mkdir -p "$dst"
  for item in CLAUDE.md statusline.sh skills commands; do
    if [[ -d "$dst/$item" && ! -L "$dst/$item" ]]; then
      echo "kept    ${dst/#$HOME/\~}/$item (a real directory, not linked)"
      continue
    fi
    ln -sfn "$src/$item" "$dst/$item"
    echo "linked  ${dst/#$HOME/\~}/$item -> ${src/#$HOME/\~}/$item"
  done
done
