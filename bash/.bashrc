# If not running interactively, don't do anything (leave this at the top of this file)
[[ $- != *i* ]] && return

# mise shims — must stay ahead of omarchy's `mise activate` below, which keeps
# shims in PATH behind the tool paths it manages. activate only re-resolves on
# prompt display, so anything inheriting this env (Claude Code, cron, editors)
# would otherwise be pinned to whatever mise resolved at launch cwd; shims
# resolve per-directory at exec time.
eval "$(mise activate bash --shims)"

# All the default Omarchy aliases and functions
# (don't mess with these directly, just overwrite them here!)
source ~/.local/share/omarchy/default/bash/rc

# Add your own exports, aliases, and functions here.

# Ruby
alias be='bundle exec'

# Git
alias gbr='git branch'
alias gco='git co'
alias gdf='git diff'
alias gl='git l'
alias gp='git push'
alias gpf='git push --force-with-lease'
alias gst='git stash'
alias gsp='git stash pop'

# git-smart (https://rubygems.org/gems/git-smart)
alias gup='git smart-pull'

# bun global bin (gbrain, etc.)
export PATH="$HOME/.cache/.bun/bin:$PATH"

# Claude — work account (Loan Labs Teams) via isolated config dir.
# Personal account stays on omarchy's default `c`/`cx` (~/.claude).
# `bin/` shims xdg-open so OAuth re-logins open the "Work" Chromium profile
# (signed into claude.ai as the work account), keeping it off the personal one.
# mise shims lead: claude inherits this PATH and never fires activate's prompt
# hook, so activate's install-dirs are frozen at launch cwd and would shadow the
# shims for any other directory — launching from ~ would hand a factory session
# the wrong ruby/node. Ahead of them, shims resolve per-directory at exec time.
alias cw='PATH="$HOME/.claude-work/bin:$HOME/.local/share/mise/shims:$PATH" CLAUDE_CONFIG_DIR=~/.claude-work claude'
alias cwx='printf "\033[2J\033[3J\033[H" && PATH="$HOME/.claude-work/bin:$HOME/.local/share/mise/shims:$PATH" CLAUDE_CONFIG_DIR=~/.claude-work claude --permission-mode bypassPermissions'

# aws-vault: pass backend (GPG-encrypted store) + curses pinentry for Hyprland
export AWS_VAULT_BACKEND=pass
export GPG_TTY=$(tty)
