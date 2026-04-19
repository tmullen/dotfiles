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

## Uninstall

```sh
stow -D nvim
```

## Packages

- `bash` — Bash aliases layered on top of Omarchy defaults.
- `git` — Git config and global ignore.
- `nvim` — Neovim keymaps layered on top of LazyVim.
