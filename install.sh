#!/usr/bin/env bash
# Build MiAgent Desktop + the MiAgent CLI, install the shared assets (prompts,
# tools, skills, fonts, the dotenv example, and the theme example) into
# the MiAgent configuration directory, and link the launchers into a user bin
# directory.
#
# The installer is deliberately conservative about an existing configuration:
# prompts, tools, skills, and .env.example are only written when missing
# (or with --force), and an existing .env is never overwritten. The uninstaller
# removes only the launcher symlinks and leaves the configuration directory
# intact.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

FORCE=0
SKIP_BUILD=0
NO_DESKTOP=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Build MiAgent Desktop and the MiAgent CLI, install the bundled prompts, tools,
skills, fonts, dotenv example, and theme example into the MiAgent configuration
directory, put the binaries under <config>/bin and <config>/tools, then link
'miagent' and 'miagent-desktop' into a user bin directory.

Options:
  --force       overwrite existing prompts, tools, skills, and
                .env.example (an existing .env is never overwritten)
  --skip-build  use the binaries already in build/ instead of running make
  --no-desktop  do not create or link a .desktop entry
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
  ZIG                        Zig 0.16.x compiler to build the native deps
                             (default: zig on PATH)

Examples:
  ./install.sh
  make install
  MIAGENT_CONFIG_DIR=/tmp/miagent-test ./install.sh --skip-build
EOF
}

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force)      FORCE=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        --no-desktop) NO_DESKTOP=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[ -n "${HOME:-}" ] || die "HOME is not set"

# Resolve a path without requiring it to exist. Install paths are made absolute
# so symlink targets and desktop entries keep working from any directory.
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
[ -n "$BIN_DIR" ] || die "could not determine the launcher directory"

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

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

log "Checking build dependencies"

ZIG_BIN="${ZIG:-zig}"
missing=()
for cmd in odin make cc g++ ar install ln readlink sed curl tar sha256sum "$ZIG_BIN"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
    printf 'missing required command(s): %s\n' "${missing[*]}" >&2
    die "install them with your package manager, then re-run this script"
fi

if ! odin version >/dev/null 2>&1; then
    die "'odin' is installed but not runnable (check your Odin installation)"
fi

zig_version="$("$ZIG_BIN" version 2>/dev/null || true)"
case "$zig_version" in
    0.16|0.16.*) ;;
    *)
        die "the pinned libghostty-vt source requires Zig 0.16.x; found '${zig_version:-unknown}' (set ZIG=/path/to/zig-0.16 to choose another compiler)"
        ;;
esac

if command -v pkg-config >/dev/null 2>&1; then
    lib_missing=()
    pkg-config --exists glfw3   || lib_missing+=("GLFW 3")
    if ! pkg-config --exists libcurl && ! pkg-config --exists curl; then
        lib_missing+=("libcurl")
    fi
    pkg-config --exists zlib    || lib_missing+=("zlib")
    if ! pkg-config --exists gl && ! pkg-config --exists opengl; then
        lib_missing+=("OpenGL")
    fi
    if [ "${#lib_missing[@]}" -gt 0 ]; then
        printf 'missing development libraries: %s\n' "${lib_missing[*]}" >&2
        printf 'install the development packages for GLFW 3, OpenGL, libcurl, and zlib\n' >&2
        printf '(package names vary by distribution; on Debian/Ubuntu see\n' >&2
        printf 'libglfw3-dev, libgl1-mesa-dev, libcurl4-openssl-dev, zlib1g-dev)\n' >&2
        die "build dependencies are incomplete"
    fi
    if ! pkg-config --exists gio-2.0; then
        warn "GIO/GLib not found; the folder picker will fall back to manual path entry"
    fi
else
    warn "pkg-config not found; skipping checks for GLFW, libcurl, zlib, and OpenGL"
fi

# Runtime tools used by the bundled bash TGI tool. They are not needed to build
# the app, so these are warnings rather than hard failures.
for cmd in bwrap jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "$cmd not found; the bundled bash tool will not run until it is installed"
    fi
done

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

if [ "$SKIP_BUILD" -eq 0 ]; then
    log "Compiling MiAgent (the first build may download native dependencies)"
    ( cd "$ROOT" && make all )
else
    log "Skipping build (--skip-build)"
fi

for bin in miagent miagent-desktop miagent-mcp miagent-mcp-host; do
    [ -x "$ROOT/build/$bin" ] || die "missing build output: $ROOT/build/$bin (run without --skip-build)"
done

# ---------------------------------------------------------------------------
# Configuration files
# ---------------------------------------------------------------------------

for src in prompts tools skills assets/fonts .env.example theme.json.example; do
    [ -e "$ROOT/$src" ] || die "missing installer asset: $ROOT/$src"
done

log "Creating configuration directory $CONFIG_DIR"
mkdir -p "$CONFIG_DIR/bin" "$CONFIG_DIR/tools" "$CONFIG_DIR/prompts" "$CONFIG_DIR/fonts" "$CONFIG_DIR/skills"

created=0
updated=0
kept=0

copy_file() {
    local src=$1 dest=$2 mode=$3
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        if [ "$FORCE" -eq 1 ]; then
            install -m "$mode" "$src" "$dest"
            updated=$((updated + 1))
        else
            kept=$((kept + 1))
        fi
    else
        install -m "$mode" "$src" "$dest"
        created=$((created + 1))
    fi
}

copy_tree() {
    local src_dir=$1 dest_dir=$2 mode=$3
    local src name dest
    [ -d "$src_dir" ] || return 0
    mkdir -p "$dest_dir"
    for src in "$src_dir"/*; do
        [ -e "$src" ] || continue
        [ -f "$src" ] || continue
        name=$(basename "$src")
        dest="$dest_dir/$name"
        copy_file "$src" "$dest" "$mode"
    done
}

copy_skill_tree() {
    local src_root=$1 dest_root=$2
    local src rel dest
    [ -d "$src_root" ] || return 0
    while IFS= read -r src; do
        [ -f "$src" ] || continue
        rel=${src#"$src_root"/}
        dest="$dest_root/$rel"
        mkdir -p "$(dirname "$dest")"
        copy_file "$src" "$dest" 0644
    done < <(find "$src_root" \( -type f -o -type l \) -print | LC_ALL=C sort)
}

copy_tree "$ROOT/prompts" "$CONFIG_DIR/prompts" 0644
copy_tree "$ROOT/tools"   "$CONFIG_DIR/tools"   0755
copy_skill_tree "$ROOT/skills" "$CONFIG_DIR/skills"
copy_tree "$ROOT/assets/fonts" "$CONFIG_DIR/fonts" 0644
copy_file "$ROOT/.env.example" "$CONFIG_DIR/.env.example" 0644
copy_file "$ROOT/theme.json.example" "$CONFIG_DIR/theme.json.example" 0644

# An existing .env is critical user configuration: never overwrite it, even
# with --force. Only create one from the example when none exists.
env_created=0
if [ ! -e "$CONFIG_DIR/.env" ] && [ ! -L "$CONFIG_DIR/.env" ]; then
    install -m 0600 "$ROOT/.env.example" "$CONFIG_DIR/.env"
    env_created=1
else
    kept=$((kept + 1))
fi

install_binary() {
    local src=$1 dest=$2 tmp
    [ -x "$src" ] || die "missing executable: $src"
    tmp="$dest.tmp.$$"
    install -m 0755 "$src" "$tmp"
    mv -f "$tmp" "$dest"
}

log "Installing binaries into $CONFIG_DIR/bin"
install_binary "$ROOT/build/miagent"         "$CONFIG_DIR/bin/miagent"
install_binary "$ROOT/build/miagent-desktop" "$CONFIG_DIR/bin/miagent-desktop"
install_binary "$ROOT/build/miagent-mcp"     "$CONFIG_DIR/bin/miagent-mcp"
install_binary "$ROOT/build/miagent-mcp-host" "$CONFIG_DIR/bin/miagent-mcp-host"

# The bridge is also a TGI tool, so discovery finds it in <config>/tools even
# when the CLI is not started from the build directory.
log "Installing the MCP bridge as a TGI tool"
install_binary "$ROOT/build/miagent-mcp" "$CONFIG_DIR/tools/miagent-mcp"

# ---------------------------------------------------------------------------
# Launchers
# ---------------------------------------------------------------------------

link_launcher() {
    local target=$1 link=$2
    mkdir -p "$(dirname "$link")"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        if [ "$FORCE" -eq 1 ]; then
            warn "replacing existing non-symlink $link"
            rm -f "$link"
        else
            warn "not replacing existing non-symlink $link (use --force to replace it)"
            return 0
        fi
    fi
    ln -sfn "$target" "$link"
    log "linked $link -> $target"
}

log "Linking launchers into $BIN_DIR"
link_launcher "$CONFIG_DIR/bin/miagent"         "$BIN_DIR/miagent"
link_launcher "$CONFIG_DIR/bin/miagent-desktop" "$BIN_DIR/miagent-desktop"

# ---------------------------------------------------------------------------
# Desktop entry
# ---------------------------------------------------------------------------

desktop_linked=0
if [ "$NO_DESKTOP" -eq 0 ]; then
    # Install the icon into the freedesktop hicolor theme so the desktop entry
    # can refer to it by name. The scalable SVG is accompanied by pre-rendered
    # PNGs for panels and docks that cannot load SVG directly.
    log "Installing application icon into $ICON_DIR/hicolor"
    # The tree holds the source SVG under scalable/apps and pre-rendered PNGs
    # under <size>x<size>/apps for panels and docks without SVG support.
    [ -d "$ROOT/assets/icons/hicolor" ] || die "missing installer asset: $ROOT/assets/icons/hicolor"
    for src in "$ROOT/assets/icons/hicolor"/*/apps/miagent.*; do
        [ -f "$src" ] || continue
        rel=${src#"$ROOT/assets/icons/hicolor/"}
        dest="$ICON_DIR/hicolor/$rel"
        mkdir -p "$(dirname "$dest")"
        install -m 0644 "$src" "$dest"
    done
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        # User hicolor directories usually have no index.theme of their own;
        # the cache is optional, so ignore failures.
        gtk-update-icon-cache -f -t "$ICON_DIR/hicolor" >/dev/null 2>&1 || true
    fi

    log "Creating desktop entry"
    desktop_file="$CONFIG_DIR/miagent-desktop.desktop"
    exec_path="$CONFIG_DIR/bin/miagent-desktop"
    # Desktop Entry Exec quoting: backslash-escape the characters special
    # inside a quoted argument and double a literal percent (field code).
    exec_esc=$(printf '%s' "$exec_path" | sed 's/%/%%/g; s/[\\"`$]/\\&/g')
    env_arg_esc=$(printf '%s' "MIAGENT_CONFIG_DIR=$CONFIG_DIR" | sed 's/%/%%/g; s/[\\"`$]/\\&/g')

    cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=MiAgent Desktop
GenericName=AI Agent
Comment=Desktop shell for the MiAgent agent harness
Exec=/usr/bin/env "$env_arg_esc" "$exec_esc"
TryExec=$exec_path
Icon=miagent
Terminal=false
Categories=Development;Utility;
Keywords=AI;agent;assistant;desktop;
StartupNotify=true
EOF
    chmod 0644 "$desktop_file"

    mkdir -p "$APP_DIR"
    link_launcher "$desktop_file" "$APP_DIR/miagent-desktop.desktop"
    if [ -L "$APP_DIR/miagent-desktop.desktop" ]; then
        desktop_linked=1
    fi

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH; add it to run 'miagent' and 'miagent-desktop' by name" ;;
esac

printf '\n'
log "MiAgent installed"
printf '  configuration : %s\n' "$CONFIG_DIR"
printf '  CLI           : %s\n' "$BIN_DIR/miagent"
printf '  desktop app   : %s\n' "$BIN_DIR/miagent-desktop"
printf '  binaries      : %s\n' "$CONFIG_DIR/bin"
printf '  tools/prompts : %s/tools, %s/prompts\n' "$CONFIG_DIR" "$CONFIG_DIR"
printf '  skills        : %s/skills\n' "$CONFIG_DIR"
if [ "$desktop_linked" -eq 1 ]; then
    printf '  desktop entry : %s\n' "$APP_DIR/miagent-desktop.desktop"
    printf '  icon          : %s/hicolor/*/apps/miagent.*\n' "$ICON_DIR"
fi
if [ "$created" -gt 0 ] || [ "$updated" -gt 0 ] || [ "$kept" -gt 0 ]; then
    printf '  config files  : %d created, %d updated, %d left untouched\n' "$created" "$updated" "$kept"
fi

if [ "$env_created" -eq 1 ]; then
    printf '\nCreated %s/.env from the bundled .env.example.\n' "$CONFIG_DIR"
else
    printf '\nExisting %s/.env left untouched.\n' "$CONFIG_DIR"
fi

cat <<EOF

Next step: edit

  $CONFIG_DIR/.env

and set at least OPENAI_API_KEY, OPENAI_BASE_URL, and OPENAI_MODEL (plus any
optional settings) to configure the agent. Then try:

  miagent "summarize this repository"
  miagent-desktop

EOF

if [ "$kept" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
    printf 'Existing configuration files were left untouched; use --force to overwrite\n'
    printf 'prompts, tools, skills, and .env.example (an existing .env is never replaced).\n\n'
fi
