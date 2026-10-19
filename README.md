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

### Extra Claude accounts (`~/.claude-work`, `~/.claude-personal`)

Aliases in `bash` run Claude Code against a separate config dir per account:

| Alias | Config dir | Login |
|---|---|---|
| `cw` / `cwx` | `~/.claude-work` | ted@loanlabs.ai, Loan Labs (Team) |
| `cl` / `clx` | `~/.claude-personal` | ted@loanlabs.ai, personal org (Max) |

Both share CLAUDE.md, statusline, skills, and commands with `~/.claude`. They
aren't stow packages — bootstrap their symlinks after `stow claude`:

```sh
./bootstrap-claude-dirs.sh
```

Idempotent. Runtime state there (history, sessions, credentials) is machine-local
and untracked.

`settings.json` is a real, untracked, mode-600 file in each dir: its SessionStart
hook names the dir it lives in, and `~/.claude-personal`'s pins the login to the
personal org. Seed a new machine from `~/.claude-work`'s copy:

```sh
d=~/.claude-personal
mkdir -p $d/hooks && cp ~/.claude-work/hooks/herdr-agent-state.sh $d/hooks/
jq --arg hook "bash '$d/hooks/herdr-agent-state.sh' session" '
  .hooks.SessionStart[0].hooks[0].command = $hook
  | .forceLoginMethod = "claudeai"
  | .forceLoginOrgUUID = "7baba97c-e76e-4624-b95b-2e2f3f736171"
' ~/.claude-work/settings.json > $d/settings.json
chmod 600 $d/settings.json
cl auth login --email ted@loanlabs.ai
cl auth status --text   # Organization: ted@loanlabs.ai's Organization
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
