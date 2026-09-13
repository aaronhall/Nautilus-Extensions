#!/usr/bin/env bash
#
# install.sh — symlink-based installer for these Nautilus extensions.
#
# No apt/PPA required. Symlinks each *.py in this repo into
#   ~/.local/share/nautilus-python/extensions/
# so the repo stays the canonical copy (edit here, `nautilus -q`, done).
#
# Respects the Extensions Manager convention: anything parked in the
#   disabled/  subdirectory is left alone and never re-linked.
#
# By default the set of extensions comes from extensions.yaml in this repo
# (edit it to exclude extensions you don't want). Re-running applies the
# file: newly excluded extensions get their links removed.
#
# Usage:
#   ./install.sh                  link extensions per extensions.yaml (default)
#   ./install.sh --only a,b       link only these, ignore extensions.yaml
#   ./install.sh --exclude a,b    also skip these (adds to the yaml excludes)
#   ./install.sh --all            link every *.py, ignore extensions.yaml
#   ./install.sh --config PATH    use a different yaml (e.g. per-machine lists)
#   ./install.sh --no-config      ignore extensions.yaml (same set as --all)
#   ./install.sh --no-prune       don't remove links that are no longer selected
#   ./install.sh --list           show link status, change nothing
#   ./install.sh --uninstall      remove links pointing into this repo
#   ./install.sh --check-deps     check loader + optional deps, change nothing
#   ./install.sh --no-restart     don't run `nautilus -q` at the end
#   ./install.sh --force          replace conflicting regular files (backs up)
#
# Options can be combined, e.g. ./install.sh --only preview-panel --no-restart
#
set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.local/share/nautilus-python/extensions"
DISABLED_DIR="${TARGET_DIR}/disabled"

ONLY="" EXCLUDE="" CONFIG="" LIST_ONLY=0 UNINSTALL=0 CHECK_DEPS=0 NO_RESTART=0 FORCE=0 ALL=0 NO_CONFIG=0 NO_PRUNE=0

usage() { sed -n '2,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)      ONLY="${2:?--only needs a value}"; shift 2 ;;
        --exclude)   EXCLUDE="${2:?--exclude needs a value}"; shift 2 ;;
        --all)       ALL=1; shift ;;
        --config)    CONFIG="${2:?--config needs a file}"; shift 2 ;;
        --no-config) NO_CONFIG=1; shift ;;
        --list)      LIST_ONLY=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --check-deps) CHECK_DEPS=1; shift ;;
        --no-restart) NO_RESTART=1; shift ;;
        --force)     FORCE=1; shift ;;
        --no-prune)  NO_PRUNE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# --- dependency check (informational; works on rpm- and dpkg-based distros) ---
check_deps() {
    local missing=0
    echo "== loader (required) =="
    if have rpm; then
        if rpm -q nautilus-python >/dev/null 2>&1; then
            echo "  ok: $(rpm -q nautilus-python)"
        else
            echo "  MISSING: nautilus-python  (sudo dnf install nautilus-python)"
            missing=1
        fi
    elif have dpkg; then
        if dpkg -s python3-nautilus >/dev/null 2>&1; then
            echo "  ok: python3-nautilus"
        else
            echo "  MISSING: python3-nautilus  (sudo apt install python3-nautilus)"
            missing=1
        fi
    else
        echo "  ?: no rpm/dpkg found — make sure the nautilus-python loader is installed"
    fi
    echo "== optional (only needed by some extensions) =="
    # "fedora-pkg|debian-pkg|used-by"
    local rows=(
        "ghostscript|ghostscript|compress-pdf, merge-pdf, watermark-pdf"
        "ffmpeg|ffmpeg|video-to-audio, duration-column (ffprobe), preview-panel"
        "python3-pypdf|python3-pypdf|compress-pdf, merge-pdf, watermark-pdf"
        "python3-cairo|python3-cairo|annotate-image"
        "p7zip|p7zip-full|archive-browser, extract-here (7z support)"
        "unrar|unrar|archive-browser, extract-here (rar support; RPM Fusion on Fedora)"
        "poppler-utils|poppler-utils|pdf helpers"
        "ffmpegthumbnailer|ffmpegthumbnailer|preview-panel video thumbnails"
        "ripgrep|ripgrep|search-content (falls back to grep)"
    )
    local row fedorapk debpk usedby state
    for row in "${rows[@]}"; do
        IFS='|' read -r fedorapk debpk usedby <<<"$row"
        if have rpm; then
            rpm -q "$fedorapk" >/dev/null 2>&1 && state="ok" || state="missing"
        elif have dpkg; then
            dpkg -s "$debpk" >/dev/null 2>&1 && state="ok" || state="missing"
        else
            have "${fedorapk%%-*}" && state="ok?" || state="?"
        fi
        printf "  %-18s %-7s (%s)\n" "$fedorapk" "$state" "$usedby"
    done
    return "$missing"
}

if [[ "$CHECK_DEPS" -eq 1 ]]; then
    check_deps
    exit $?
fi

# --- candidate list ---
norm() { # "a.py,b" -> "a b" (strip .py, split commas, trim)
    tr ',' ' ' <<<"$1" | sed -e 's/\.py\b//g' -e 's/  */ /g' -e 's/^ //;s/ $//'
}

mapfile -t ALL_SRCS < <(cd "$REPO_DIR" && ls -1 *.py 2>/dev/null || true)
if [[ "${#ALL_SRCS[@]}" -eq 0 ]]; then
    echo "No *.py extensions found in $REPO_DIR" >&2; exit 1
fi

# --- yaml config (bash-only parser for our simple `key:` + `  - item` shape) ---
parse_yaml_list() { # $1=file $2=key -> bare names, one per line
    tr -d "\"'" < "$1" | awk -v key="$2" '
        /^[^ \t#][^:]*:/ {
            line = $0; sub(/:.*$/, "", line);
            gsub(/^[ \t]+|[ \t]+$/, "", line);
            in_target = (line == key); next
        }
        in_target && /^[ \t]*-/ {
            line = $0; sub(/^[ \t]*-[ \t]*/, "", line); sub(/[ \t]*#.*$/, "", line);
            gsub(/^[ \t]+|[ \t]+$/, "", line);
            sub(/\.py$/, "", line);
            if (line != "") print line
        }
    '
}

contains() { # $1=needle $2...=haystack (.py suffix tolerated on both sides)
    local needle="${1%.py}" x
    shift
    for x in "$@"; do [[ "${x%.py}" == "$needle" ]] && return 0; done
    return 1
}

CONFIG_FILE="${CONFIG:-$REPO_DIR/extensions.yaml}"
SELECTED=()
if [[ -n "$ONLY" ]]; then
    for want in $(norm "$ONLY"); do
        if [[ -f "$REPO_DIR/$want.py" ]]; then
            SELECTED+=("$want.py")
        else
            echo "warning: no such extension: $want (skipped)" >&2
        fi
    done
elif [[ "$ALL" -eq 1 || "$NO_CONFIG" -eq 1 ]]; then
    SELECTED=("${ALL_SRCS[@]}")
elif [[ -f "$CONFIG_FILE" ]]; then
    echo "using config: $CONFIG_FILE"
    mapfile -t WANTED < <(parse_yaml_list "$CONFIG_FILE" install)
    mapfile -t CFG_EXCL < <(parse_yaml_list "$CONFIG_FILE" exclude)
    if [[ "${#WANTED[@]}" -eq 0 ]]; then
        echo "warning: no 'install:' entries in $CONFIG_FILE — selecting all *.py" >&2
        SELECTED=("${ALL_SRCS[@]}")
    else
        for want in "${WANTED[@]}"; do
            if [[ -f "$REPO_DIR/$want.py" ]]; then
                SELECTED+=("$want.py")
            else
                echo "warning: config lists unknown extension: $want (skipped)" >&2
            fi
        done
    fi
    if [[ "${#CFG_EXCL[@]}" -gt 0 ]]; then
        EXCLUDE="${EXCLUDE:+$EXCLUDE,}$(IFS=,; echo "${CFG_EXCL[*]}")"
    fi
else
    echo "warning: no config at $CONFIG_FILE — selecting all *.py" >&2
    SELECTED=("${ALL_SRCS[@]}")
fi
if [[ -n "$EXCLUDE" ]]; then
    EXCL=" $(norm "$EXCLUDE") "
    FILTERED=()
    for f in "${SELECTED[@]}"; do
        [[ "$EXCL" == *" ${f%.py} "* ]] || FILTERED+=("$f")
    done
    SELECTED=("${FILTERED[@]}")
fi

disabled_names() { # names (with .py) parked in disabled/
    [[ -d "$DISABLED_DIR" ]] || return 0
    local f
    for f in "$DISABLED_DIR"/*.py; do
        [[ -e "$f" ]] || continue
        basename -- "$f"
    done
}

# --- --list: report, change nothing ---
if [[ "$LIST_ONLY" -eq 1 ]]; then
    DIS="$(disabled_names)"
    printf "%-32s %s\n" "EXTENSION" "STATUS"
    for src in "${ALL_SRCS[@]}"; do
        link="$TARGET_DIR/$src"
        if ! contains "$src" "${SELECTED[@]}"; then
            st="excluded (not selected)"
        elif grep -qx "$src" <<<"$DIS" 2>/dev/null; then
            st="disabled (in disabled/, left alone)"
        elif [[ -L "$link" && "$(readlink -f "$link")" == "$REPO_DIR/$src" ]]; then
            st="linked -> this repo"
        elif [[ -L "$link" ]]; then
            st="linked elsewhere: $(readlink "$link")"
        elif [[ -e "$link" ]]; then
            st="regular file (conflict; use --force to replace)"
        else
            st="not installed"
        fi
        printf "%-32s %s\n" "$src" "$st"
    done
    exit 0
fi

# --- --uninstall: remove only links pointing into this repo ---
if [[ "$UNINSTALL" -eq 1 ]]; then
    removed=0
    shopt -s nullglob
    for link in "$TARGET_DIR"/*.py; do
        if [[ -L "$link" && "$(readlink -f "$link")" == "$REPO_DIR/"* ]]; then
            rm -- "$link" && echo "removed: $(basename "$link")" && removed=$((removed+1))
        fi
    done
    rm -rf -- "$TARGET_DIR/__pycache__" 2>/dev/null || true
    echo "$removed link(s) removed."
    [[ "$NO_RESTART" -eq 1 ]] || { echo "Restarting Nautilus..."; nautilus -q 2>/dev/null || true; }
    exit 0
fi

# --- install ---
mkdir -p -- "$TARGET_DIR"
check_deps || echo "(continuing anyway — install the loader above if extensions don't load)"
echo

DIS="$(disabled_names)"
linked=0 repointed=0 skipped=0
for src in "${SELECTED[@]}"; do
    if grep -qx "$src" <<<"$DIS" 2>/dev/null; then
        echo "skip (disabled): $src"
        skipped=$((skipped+1)); continue
    fi
    link="$TARGET_DIR/$src"
    if [[ -L "$link" && "$(readlink -f "$link")" == "$REPO_DIR/$src" ]]; then
        echo "ok (already linked): $src"
    elif [[ -L "$link" ]]; then
        ln -sfn -- "$REPO_DIR/$src" "$link" && echo "repointed: $src -> $REPO_DIR"
        repointed=$((repointed+1))
    elif [[ -e "$link" ]]; then
        if [[ "$FORCE" -eq 1 ]]; then
            bak="${link}.bak-$(date +%Y%m%d%H%M%S)"
            mv -- "$link" "$bak" && ln -s -- "$REPO_DIR/$src" "$link" \
                && echo "replaced (backup: $bak): $src"
            repointed=$((repointed+1))
        else
            echo "conflict (regular file, skipped; --force to replace): $src"
            skipped=$((skipped+1))
        fi
    else
        ln -s -- "$REPO_DIR/$src" "$link" && echo "linked: $src"
        linked=$((linked+1))
    fi
done

# prune stale links into this repo whose source is gone (e.g. renamed upstream)
pruned=0
shopt -s nullglob
for link in "$TARGET_DIR"/*.py; do
    if [[ -L "$link" && ! -e "$link" && "$(readlink -f "$link" 2>/dev/null)" == "$REPO_DIR/"* ]]; then
        rm -- "$link" && echo "pruned stale: $(basename "$link")" && pruned=$((pruned+1))
    fi
done
rm -rf -- "$TARGET_DIR/__pycache__" 2>/dev/null || true

# remove links that point here but are no longer selected (config-driven runs;
# --only never prunes, --no-prune opts out)
if [[ "$NO_PRUNE" -eq 0 && -z "$ONLY" ]]; then
    for link in "$TARGET_DIR"/*.py; do
        base="$(basename -- "$link")"
        if [[ -L "$link" && "$(readlink -f "$link" 2>/dev/null)" == "$REPO_DIR/"* ]] \
            && ! contains "$base" "${SELECTED[@]}"; then
            rm -- "$link" && echo "removed (not selected): $base" && pruned=$((pruned+1))
        fi
    done
fi

echo
echo "linked=$linked repointed=$repointed skipped=$skipped pruned=$pruned"
if [[ "$NO_RESTART" -eq 1 ]]; then
    echo "Skipping Nautilus restart (--no-restart). Run 'nautilus -q' to load changes."
else
    echo "Restarting Nautilus (closes open Files windows)..."
    nautilus -q 2>/dev/null || true
fi
