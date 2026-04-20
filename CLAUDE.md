# Dotfiles repo — working notes

This repo holds personal [Omarchy](https://omarchy.org) customizations, managed with [GNU Stow](https://www.gnu.org/software/stow/). Read this before editing anything here or under `$HOME` that a package targets (e.g. `~/.config/`, `~/.claude/`, top-level dotfiles).

## Layout

Each top-level directory is a **stow package**. Inside it, the file tree mirrors where the files belong under `$HOME`:

```
<package>/<path-under-home>/<file>
```

Example:

```
nvim/.config/nvim/lua/config/keymaps.lua  →  ~/.config/nvim/lua/config/keymaps.lua
```

`.stowrc` pins `--target=$HOME`, so `stow <package>` from the repo root targets the correct location.

## Editing existing configs

Files already tracked here are **symlinked** into their target location under `$HOME`. Editing the target transparently modifies the real file in this repo — that is fine, and expected. After editing, commit from this repo.

Before editing any file under `$HOME` that might be tracked, check whether it is a symlink pointing here:

```sh
readlink -f <target-path>
```

If it resolves into `~/Work/Personal/dotfiles/`, the source of truth is this repo.

## Adding a new file to an existing package

1. Create the file at the correct path inside the package, e.g. `nvim/.config/nvim/lua/plugins/foo.lua`.
2. Re-run `stow <package>` from the repo root. Stow adds missing file-level symlinks without disturbing existing ones.
3. Commit.

Do **not** create the file directly at the target location and then try to move it — that creates an orphan outside the repo.

## Adopting a file that already exists under `$HOME` but not in this repo

Applies to anything a package targets — `~/.config/<pkg>/…`, `~/.claude/…`, top-level dotfiles like `~/.bashrc`, etc. The workflow is the same regardless of where under `$HOME` the file lives.

The existing file is the source of truth — **never replace, overwrite, or clobber it.** Move it into the repo so stow takes over:

1. Confirm the file is a real file, not already a symlink into this repo:
   ```sh
   readlink -f <target-path>
   ```
2. `mkdir -p <pkg>/<target-path-relative-to-$HOME>/` (parent dirs) to mirror the target path inside the package.
3. **Move** (do not copy) the file into the package:
   ```sh
   mv <target-path> <pkg>/<target-path-relative-to-$HOME>
   ```
   Moving (not copying) guarantees there is no lingering real file at the target to collide with the symlink stow is about to create.
4. Run `stow <pkg>` from the repo root. Stow creates the symlink at the target → the file you just moved.
5. Verify with `readlink -f` that the symlink resolves into this repo.
6. Now make your edits in the repo file. Commit.

## Adding a new package

1. `mkdir -p <newpkg>/<target-path>` mirroring where it belongs under `$HOME`.
2. Move or write files into that tree.
3. `stow <newpkg>` from the repo root.
4. Add an entry to `README.md` under "Packages".

## Ignored paths

`.gitignore` excludes Claude Code session state (`.remember/`, `.claude/settings.local.json`) and editor/OS junk. Do not commit machine-local Claude settings.

## Conflicts

If `stow <pkg>` reports a conflict, it means a real file already exists at the target. Investigate — it is usually a pre-existing config (e.g., a LazyVim starter file). Resolve by merging it into the package or removing the target; never force-overwrite silently.
