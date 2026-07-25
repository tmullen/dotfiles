#!/usr/bin/env bash
# Recreate ~/.claude-work shared-config symlinks.
#
# Work Claude runs against a separate config dir via the `cw` / `cwx` aliases
# (see bash/.bashrc): CLAUDE_CONFIG_DIR=~/.claude-work. It SHARES its settings,
# CLAUDE.md, statusline, and skills with personal Claude by symlinking to the
# same source in the `claude` stow package.
#
# Runtime state (projects/, history.jsonl, sessions/, .credentials.json, cache/)
# is intentionally machine-local and NOT tracked — Claude recreates it on first run.
#
# Idempotent: safe to re-run. Run from anywhere.
set -euo pipefail

src="$HOME/Work/Personal/dotfiles/claude/.claude"
dst="$HOME/.claude-work"

mkdir -p "$dst"
for item in settings.json CLAUDE.md statusline.sh skills; do
  ln -sfn "$src/$item" "$dst/$item"
  echo "linked  ~/.claude-work/$item -> ${src/#$HOME/~}/$item"
done
