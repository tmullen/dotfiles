# If not running interactively, don't do anything (leave this at the top of this file)
[[ $- != *i* ]] && return

# All the default Omarchy aliases and functions
# (don't mess with these directly, just overwrite them here!)
# /etc/omarchy.conf is written by omarchy-dev-link. When absent, force the
# package default instead of preserving a stale inherited dev-link value before
# we decide which rc file to source.
if [[ -f /etc/omarchy.conf ]]; then
  source /etc/omarchy.conf
  export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
else
  export OMARCHY_PATH=/usr/share/omarchy
fi
source "$OMARCHY_PATH/default/bash/rc"

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

alias cw='CLAUDE_CONFIG_DIR=~/.claude-work claude'
alias cwx='printf "\033[2J\033[3J\033[H" && cw --permission-mode bypassPermissions'
alias cl='CLAUDE_CONFIG_DIR=~/.claude-personal claude'
alias clx='printf "\033[2J\033[3J\033[H" && cl --permission-mode bypassPermissions'

# aws-vault: pass backend (GPG-encrypted store) + curses pinentry for Hyprland
export AWS_VAULT_BACKEND=pass
export GPG_TTY=$(tty)

# Shim lead: `mise activate` resolves at prompt display, so anything inheriting
# this env without one (Claude sessions, editors, cron) is frozen at launch cwd.
PATH="$HOME/.local/share/mise/shims:$PATH"
