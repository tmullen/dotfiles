# enable shims and autocompletion
if which rbenv > /dev/null; then eval "$(rbenv init -)"; fi

# use project specific binstubs
# export PATH="./bin:/usr/local/bin:$PATH"
export PATH="./bin:$PATH"

# use Homebrew's directories rather than ~/.rbenv
# export RBENV_ROOT=/usr/local/var/rbenv

