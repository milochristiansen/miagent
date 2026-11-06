#!/usr/bin/env bash
# Remove the MiAgent launcher symlinks, the desktop-entry symlink, and the
# icons installed into the user's hicolor icon theme. The configuration
# directory (<config>/bin, tools, prompts, skills, docs, .env, gui.json, ...) is
# deliberately left untouched; the final message tells the user how to delete it
# manually.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Remove the 'miagent' and 'miagent-desktop' launcher symlinks, the desktop entry
symlink, and the icon files installed into the user's hicolor icon theme.
Nothing inside the MiAgent configuration directory is removed.

Options:
  -h, --help    show this help

Environment:
  MIAGENT_CONFIG_DIR         installation directory
                             (default: \$XDG_CONFIG_HOME/miagent, or ~/.config/miagent)
  MIAGENT_BIN_DIR            launcher directory
                             (default: \$XDG_BIN_HOME, or ~/.local/bin)
  MIAGENT_APPLICATIONS_DIR   desktop-entry directory
                             (default: \$XDG_DATA_HOME/applications, or ~/.local/share/applications)
  MIAGENT_ICONS_DIR          icon-theme directory
                             (default: \$XDG_DATA_HOME/icons, or ~/.local/share/icons)

Examples:
  ./uninstall.sh
  make uninstall
  MIAGENT_CONFIG_DIR=/tmp/miagent-test MIAGENT_BIN_DIR=/tmp/bin ./uninstall.sh
EOF
}

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *)         die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[ -n "${HOME:-}" ] || die "HOME is not set"

abs_path() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *)  printf '%s/%s' "$PWD" "$1" ;;
    esac
}

strip_trailing_slashes() {
    local p=$1
    while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
    printf '%s' "$p"
}

if [ -n "${MIAGENT_CONFIG_DIR:-}" ]; then
    CONFIG_DIR=$(abs_path "$MIAGENT_CONFIG_DIR")
else
    config_home=${XDG_CONFIG_HOME:-}
    case "$config_home" in
        /*) ;;
        *)  config_home="$HOME/.config" ;;
    esac
    CONFIG_DIR="$config_home/miagent"
fi
CONFIG_DIR=$(strip_trailing_slashes "$CONFIG_DIR")
case "$CONFIG_DIR" in
    ""|"/"|"$HOME") die "refusing to use unsafe configuration directory: '$CONFIG_DIR'" ;;
esac

if [ -n "${MIAGENT_BIN_DIR:-}" ]; then
    BIN_DIR=$(abs_path "$MIAGENT_BIN_DIR")
elif [ -n "${XDG_BIN_HOME:-}" ]; then
    BIN_DIR=$(abs_path "$XDG_BIN_HOME")
else
    BIN_DIR="$HOME/.local/bin"
fi
BIN_DIR=$(strip_trailing_slashes "$BIN_DIR")

if [ -n "${MIAGENT_APPLICATIONS_DIR:-}" ]; then
    APP_DIR=$(abs_path "$MIAGENT_APPLICATIONS_DIR")
else
    data_home=${XDG_DATA_HOME:-}
    case "$data_home" in
        /*) ;;
        *)  data_home="$HOME/.local/share" ;;
    esac
    APP_DIR="$data_home/applications"
fi
APP_DIR=$(strip_trailing_slashes "$APP_DIR")

if [ -n "${MIAGENT_ICONS_DIR:-}" ]; then
    ICON_DIR=$(abs_path "$MIAGENT_ICONS_DIR")
else
    data_home=${XDG_DATA_HOME:-}
    case "$data_home" in
        /*) ;;
        *)  data_home="$HOME/.local/share" ;;
    esac
    ICON_DIR="$data_home/icons"
fi
ICON_DIR=$(strip_trailing_slashes "$ICON_DIR")

removed=0
icons_removed=0

# Remove a symlink only when it points into the expected part of the
# configuration directory. Regular files are never touched.
remove_launcher_link() {
    local link=$1 prefix=$2 target
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
        log "not present: $link"
        return 0
    fi
    if [ ! -L "$link" ]; then
        warn "not removing $link: it is not a symlink"
        return 0
    fi
    target=$(readlink "$link")
    case "$target" in
        "$prefix"/*)
            rm -f "$link"
            log "removed $link -> $target"
            removed=$((removed + 1))
            ;;
        *)
            warn "not removing $link: it points to $target, not $prefix"
            ;;
    esac
}

log "Removing MiAgent launcher symlinks"
remove_launcher_link "$BIN_DIR/miagent"          "$CONFIG_DIR/bin"
remove_launcher_link "$BIN_DIR/miagent-desktop"  "$CONFIG_DIR/bin"
remove_launcher_link "$APP_DIR/miagent-desktop.desktop" "$CONFIG_DIR"

log "Removing MiAgent icons from $ICON_DIR/hicolor"
remove_icon_file() {
    local file=$1
    if [ -f "$file" ]; then
        rm -f "$file"
        log "removed $file"
        icons_removed=$((icons_removed + 1))
    fi
}
remove_icon_file "$ICON_DIR/hicolor/scalable/apps/miagent.svg"
for size in 16 24 32 48 64 128 256 512; do
    remove_icon_file "$ICON_DIR/hicolor/${size}x${size}/apps/miagent.png"
done

if command -v update-desktop-database >/dev/null 2>&1 && [ -d "$APP_DIR" ]; then
    update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1 && [ -d "$ICON_DIR/hicolor" ]; then
    gtk-update-icon-cache -f -t "$ICON_DIR/hicolor" >/dev/null 2>&1 || true
fi

cat <<EOF

Launcher symlinks removed: $removed
Icon files removed: $icons_removed

The MiAgent configuration directory was NOT touched:

  $CONFIG_DIR

To fully uninstall MiAgent, delete that directory manually:

  rm -rf $(printf '%q' "$CONFIG_DIR")

That directory contains your .env, prompts, tools, skills, docs, and gui.json (including
your known projects). Back it up first if you want to keep any of those settings.

You may also remove runtime/cache state if desired:
  \${XDG_RUNTIME_DIR:-~/.cache}/miagent
  \${XDG_CACHE_HOME:-~/.cache}/miagent
and per-project .miagent/ session directories.

EOF
