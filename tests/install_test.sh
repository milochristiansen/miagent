#!/bin/sh
# Exercise install.sh/uninstall.sh entirely inside a temporary tree. The real
# ~/.config/miagent and ~/.local/bin are never touched.
set -eu

cd "$(dirname "$0")/.."

if [ ! -x build/miagent ] || [ ! -x build/miagent-desktop ] \
   || [ ! -x build/miagent-mcp ] || [ ! -x build/miagent-mcp-host ]; then
    echo "install_test: build the binaries first (make all)" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

CONFIG="$TMP/config"
BIN="$TMP/bin"
APPS="$TMP/applications"
ICONS="$TMP/icons"

export MIAGENT_CONFIG_DIR="$CONFIG"
export MIAGENT_BIN_DIR="$BIN"
export MIAGENT_APPLICATIONS_DIR="$APPS"
export MIAGENT_ICONS_DIR="$ICONS"

fail() {
    echo "install_test: $*" >&2
    exit 1
}

# Seed user data that the installer must not clobber.
mkdir -p "$CONFIG/prompts"
printf 'OPENAI_API_KEY=keep-me\n' > "$CONFIG/.env"
printf 'CUSTOM SYSTEM\n' > "$CONFIG/prompts/SYSTEM.md"

echo "== install"
./install.sh --skip-build >"$TMP/install.log" 2>&1 || {
    cat "$TMP/install.log" >&2
    fail "install.sh failed"
}

[ "$(cat "$CONFIG/.env")" = "OPENAI_API_KEY=keep-me" ] || fail "installer overwrote .env"
[ "$(cat "$CONFIG/prompts/SYSTEM.md")" = "CUSTOM SYSTEM" ] || fail "installer overwrote an existing prompt"
[ -f "$CONFIG/prompts/COMPACT-INITIAL.md" ] || fail "missing installed prompt"
[ -f "$CONFIG/skills/tgi-tools/SKILL.md" ] || fail "missing installed TGI skill"
[ -f "$CONFIG/skills/tgi-tools/references/TGI.md" ] || fail "missing TGI skill reference"
grep -q '^name: tgi-tools$' "$CONFIG/skills/tgi-tools/SKILL.md" || fail "TGI skill has no name"
TGI_SCHEMA=$(cd "$TMP" && MIAGENT_CONFIG_DIR="$CONFIG" TGI_METHOD=SCHEMA \
    TGI_TOOL=activate_skill "$CONFIG/tools/activate_skill")
printf '%s' "$TGI_SCHEMA" | grep -q 'tgi-tools' || fail "installed TGI skill was not discovered"
[ -f "$CONFIG/theme.json.example" ] || fail "missing installed theme example"
[ -f "$CONFIG/fonts/NotoEmoji-Regular.ttf" ] || fail "missing bundled emoji font"
[ -x "$CONFIG/tools/bash" ] || fail "bash tool is not executable"
[ -x "$CONFIG/tools/deepseek-search" ] || fail "deepseek-search tool is not executable"
[ -x "$CONFIG/tools/activate_skill" ] || fail "activate_skill tool is not executable"
[ -d "$CONFIG/skills" ] || fail "skills directory missing"
[ -x "$CONFIG/tools/miagent-mcp" ] || fail "MCP bridge missing from tools"
[ -x "$CONFIG/bin/miagent" ] || fail "CLI missing from config bin"
[ -x "$CONFIG/bin/miagent-desktop" ] || fail "desktop binary missing from config bin"
[ -x "$CONFIG/bin/miagent-mcp-host" ] || fail "MCP host missing from config bin"
[ -L "$BIN/miagent" ] || fail "miagent launcher symlink missing"
[ -L "$BIN/miagent-desktop" ] || fail "miagent-desktop launcher symlink missing"
[ "$(readlink "$BIN/miagent")" = "$CONFIG/bin/miagent" ] || fail "miagent symlink target is wrong"
[ -f "$CONFIG/miagent-desktop.desktop" ] || fail "desktop entry missing from config"
[ -L "$APPS/miagent-desktop.desktop" ] || fail "desktop entry symlink missing"
grep -q '^Icon=miagent$' "$CONFIG/miagent-desktop.desktop" || fail "desktop entry does not use the MiAgent icon"
[ -f "$ICONS/hicolor/scalable/apps/miagent.svg" ] || fail "scalable icon missing"
[ -f "$ICONS/hicolor/48x48/apps/miagent.png" ] || fail "48x48 icon missing"
[ -f "$ICONS/hicolor/512x512/apps/miagent.png" ] || fail "512x512 icon missing"

echo "== re-run is idempotent"
./install.sh --skip-build >"$TMP/install2.log" 2>&1 || {
    cat "$TMP/install2.log" >&2
    fail "second install.sh failed"
}
[ "$(cat "$CONFIG/prompts/SYSTEM.md")" = "CUSTOM SYSTEM" ] || fail "re-run overwrote an existing prompt"
[ "$(cat "$CONFIG/.env")" = "OPENAI_API_KEY=keep-me" ] || fail "re-run overwrote .env"
[ -f "$CONFIG/skills/tgi-tools/SKILL.md" ] || fail "re-run removed the TGI skill"

echo "== --force updates assets but not .env"
printf '\nLOCAL EDIT\n' >> "$CONFIG/skills/tgi-tools/SKILL.md"
./install.sh --skip-build --force >"$TMP/install3.log" 2>&1 || {
    cat "$TMP/install3.log" >&2
    fail "install.sh --force failed"
}
[ "$(cat "$CONFIG/.env")" = "OPENAI_API_KEY=keep-me" ] || fail "--force overwrote .env"
[ "$(cat "$CONFIG/prompts/SYSTEM.md")" != "CUSTOM SYSTEM" ] || fail "--force did not update a prompt"
! grep -q 'LOCAL EDIT' "$CONFIG/skills/tgi-tools/SKILL.md" || fail "--force did not update the TGI skill"

echo "== uninstall removes symlinks and icons"
printf 'KEEP\n' > "$CONFIG/keep.txt"
./uninstall.sh >"$TMP/uninstall.log" 2>&1 || {
    cat "$TMP/uninstall.log" >&2
    fail "uninstall.sh failed"
}
[ ! -e "$BIN/miagent" ] || fail "uninstall left the miagent symlink"
[ ! -e "$BIN/miagent-desktop" ] || fail "uninstall left the miagent-desktop symlink"
[ ! -e "$APPS/miagent-desktop.desktop" ] || fail "uninstall left the desktop-entry symlink"
[ -f "$CONFIG/keep.txt" ] || fail "uninstall removed a config file"
[ -f "$CONFIG/.env" ] || fail "uninstall removed .env"
[ -x "$CONFIG/bin/miagent" ] || fail "uninstall removed the installed CLI"
[ -f "$CONFIG/miagent-desktop.desktop" ] || fail "uninstall removed the desktop entry file"
[ ! -e "$ICONS/hicolor/scalable/apps/miagent.svg" ] || fail "uninstall left the scalable icon"
[ ! -e "$ICONS/hicolor/48x48/apps/miagent.png" ] || fail "uninstall left a rendered icon"

echo "install_test: OK"
