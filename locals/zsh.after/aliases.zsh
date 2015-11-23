alias gup='git smart-pull'
alias gbr='git branch'
alias gpf='git push --force-with-lease'
alias s='git status -sb $argv; return 0'

alias be="bundle exec"

alias mss="mysql.server start"
alias pg="pg_ctl -D /usr/local/var/postgres -l /usr/local/var/postgres/server.log"

alias heroku:psql='_heroku_psql() { psql `/usr/local/bin/heroku config:get DATABASE_URL -a $1`};_heroku_psql'

