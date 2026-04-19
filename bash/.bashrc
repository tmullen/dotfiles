# If not running interactively, don't do anything (leave this at the top of this file)
[[ $- != *i* ]] && return

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
