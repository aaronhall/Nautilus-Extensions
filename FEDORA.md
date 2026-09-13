# Fedora notes (this fork)

This is a fork of [ToFpon/Nautilus-Extensions](https://github.com/ToFpon/Nautilus-Extensions),
kept installable without Ubuntu's PPA/apt. Upstream files are left untouched so
`git pull upstream` stays clean; fork-specific additions are:

| File | What |
|---|---|
| `install.sh` | symlink installer (no apt), respects `disabled/` |
| `extensions.yaml` | default extension set (edit to include/exclude) |
| `FEDORA.md` | this file |
| `create-link-in-clipboard.py` | own extension (candidate for upstream PR) |
| `dim-incomplete-downloads.py` | own extension (candidate for upstream PR) |

## Install on Fedora

```bash
# loader (required) + common optional deps
sudo dnf install nautilus-python python3-gobject gtk4 libadwaita \
    ghostscript ffmpeg python3-pypdf python3-cairo p7zip poppler-utils \
    ffmpegthumbnailer
# unrar lives in RPM Fusion if you need rar support

git clone git@github.com:aaronhall/Nautilus-Extensions.git
cd Nautilus-Extensions
./install.sh --check-deps   # optional: report what's missing
./install.sh                # link all extensions, restart Nautilus
```

`install.sh` symlinks each `*.py` here into
`~/.local/share/nautilus-python/extensions/`, so this repo stays the canonical
copy — edit a file, run `nautilus -q`, done. Useful flags:

```bash
./install.sh --list                 # status without changing anything
./install.sh --only preview-panel,cut-dim   # just these, ignore yaml
./install.sh --exclude dual-panel,column-browser  # also skip these
./install.sh --all                  # everything, ignore yaml
./install.sh --uninstall             # remove only links pointing into this repo
```

The default set lives in `extensions.yaml` — comment out (or add) entries
there and re-run `./install.sh` to apply. Currently excluded by default:
`deb-installer` (Debian/Ubuntu-only) and `hidden-dim-all` (upstream says to
pick only one of the hidden-dim variants; `-icon` is kept). Re-running also
removes links that are no longer selected (`--only` never removes; `--no-prune`
opts out). A custom file (e.g. per-machine) works via
`./install.sh --config PATH`.

Extensions disabled via Extensions Manager (parked in `disabled/`) are never
re-linked. `nautilus -q` closes open Files windows; use `--no-restart` to skip.

## Own extensions (proposed upstream contributions)

| Extension | Description |
|---|---|
| `create-link-in-clipboard.py` | Right-click → "Create Link in Clipboard": absolute `Link to <name>` symlinks staged in `/tmp/nautilus-links-*/`, placed on the clipboard as COPY so paste copies the link (repeatable). Prunes staging dirs older than 7 days. |
| `dim-incomplete-downloads.py` | Dims `*.!qB` qBittorrent partials to 0.35 opacity via a 750 ms view walk. Technique adapted from upstream's hidden-dim extensions. |

Both carry `SPDX-License-Identifier: GPL-3.0-or-later` to match upstream's LICENSE.

## Staying in sync with upstream

Remotes: `origin` = this fork, `upstream` = ToFpon's repo.

```bash
git fetch upstream
git checkout main && git merge upstream/main   # or: git rebase upstream/main
git push origin main
```

To propose a change upstream, push a topic branch to `origin` and open the PR
against ToFpon's repo:

```bash
git checkout -b my-fix
# ... edit upstream files ...
git push -u origin my-fix
gh pr create --repo ToFpon/Nautilus-Extensions --base main --head aaronhall:my-fix
```

Rule of thumb: keep upstream files pristine on `main` except via merges from
`upstream/main`; do fork-specific work in new files or topic branches.
