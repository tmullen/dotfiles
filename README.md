# dotfiles

Personal customizations for [Omarchy](https://omarchy.org), managed with [GNU Stow](https://www.gnu.org/software/stow/).

## Layout

Each top-level directory is a stow package mirroring its target path under `$HOME`:

```
nvim/.config/nvim/lua/config/keymaps.lua  →  ~/.config/nvim/lua/config/keymaps.lua
```

## Install

```sh
git clone git@github.com:<user>/dotfiles.git ~/Work/Personal/dotfiles
cd ~/Work/Personal/dotfiles
stow nvim
```

`.stowrc` sets `--target=$HOME`, so `stow <package>` works from the repo root.

### Work Claude (`~/.claude-work`)

The `cw` / `cwx` aliases (in `bash`) run Claude Code against a separate config
dir, `~/.claude-work`, that shares its CLAUDE.md/statusline/skills with personal
Claude. It's not a stow package — bootstrap its symlinks after `stow claude`:

```sh
./bootstrap-claude-work.sh
```

Idempotent. Runtime state there (history, sessions, credentials) is machine-local
and untracked.

`settings.json` is **not** linked. Work Claude authenticates against AWS Bedrock
(us-west-2) and `/setup-bedrock` writes the bearer token into that file's `env`
block, so it has to stay real, untracked, and mode 600. `claude/.claude/settings.json`
in this repo is the seed copy for a new machine:

```sh
cp claude/.claude/settings.json ~/.claude-work/settings.json
chmod 600 ~/.claude-work/settings.json
cw   # then run /setup-bedrock
```

## Uninstall

```sh
stow -D nvim
```

## Packages

- `alacritty` — Alacritty config (font size bump).
- `bash` — Bash aliases layered on top of Omarchy defaults.
- `claude` — Claude Code user settings and status line script.
- `ghostty` — Ghostty config (font size bump).
- `git` — Git config and global ignore.
- `hypr` — Hyprland keybindings (Gmail/Calendar/Claude webapps) and input tweaks.
- `lazygit` — Lazygit config.
- `nvim` — Neovim keymaps layered on top of LazyVim.
