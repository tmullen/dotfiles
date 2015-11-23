# use bin files if available
PATH="./bin:$PATH"

# add Qt fix to path
# PATH=~/Applications/Qt5.5.1/5.5/clang_64/bin:$PATH
PATH="$(brew --prefix qt@5.5)/bin:$PATH"

