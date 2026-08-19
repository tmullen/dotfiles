#!/usr/bin/env bash
# Recreate ~/.claude-work shared-config symlinks.
#
# Work Claude runs against a separate config dir via the `cw` / `cwx` aliases
# (see bash/.bashrc): CLAUDE_CONFIG_DIR=~/.claude-work. It SHARES its CLAUDE.md,
# statusline, and skills with personal Claude by symlinking to the same source
# in the `claude` stow package.
#
# settings.json is deliberately NOT linked: work Claude authenticates against
# AWS Bedrock, and `/setup-bedrock` writes the bearer token into the `env` block
# of $CLAUDE_CONFIG_DIR/settings.json. That file must stay a real, machine-local,
# untracked file — linking it here would both clobber the credentials and put
# them in this repo. Recreate it on a new machine with:
#
#   cp claude/.claude/settings.json ~/.claude-work/settings.json
#   chmod 600 ~/.claude-work/settings.json
#   cw   # then run /setup-bedrock
#
# Runtime state (projects/, history.jsonl, sessions/, .credentials.json, cache/)
# is intentionally machine-local and NOT tracked — Claude recreates it on first run.
#
# Idempotent: safe to re-run. Run from anywhere.
set -euo pipefail

src="$HOME/Work/Personal/dotfiles/claude/.claude"
dst="$HOME/.claude-work"

mkdir -p "$dst"
for item in CLAUDE.md statusline.sh skills; do
  ln -sfn "$src/$item" "$dst/$item"
  echo "linked  ~/.claude-work/$item -> ${src/#$HOME/~}/$item"
done
