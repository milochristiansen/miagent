#!/usr/bin/env bash
# Fetch and build the native dependencies (libghostty-vt + cimgui).
#
# The build uses the system Zig compiler (from PATH, or $ZIG) instead of
# downloading a private toolchain. The Ghostty source is pinned to the first
# upstream commit whose libghostty-vt builds with Zig 0.16.x; cimgui and Dear
# ImGui remain pinned commits. Results land in third_party/ and are consumed by
# the Makefile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/.deps"
THIRD="$ROOT/third_party"

# Ghostty 1.3.2-dev at the upstream "Update to Zig 0.16.0" merge (#12726).
# This is the first commit whose libghostty-vt builds with Zig 0.16.x and
# carries the C API this tree uses. The commit is kept in one place so the
# Makefile can detect a native build made from a different pin.
GHOSTTY_COMMIT="$(cat "$ROOT/scripts/ghostty-commit")"
GHOSTTY_URL="https://codeload.github.com/ghostty-org/ghostty/tar.gz/$GHOSTTY_COMMIT"
GHOSTTY_SHA256=2660d08665d85ecdba204f344265965bb569ac4ed0a3dff82d3e6bc1bfb8bedb
GHOSTTY_MARKER="$DEPS/ghostty/.miagent-source"

# cimgui master from 2026-10-18 and the imgui commit it points at.
CIMGUI_COMMIT=c4461a7eadbd17b6a6a8124a8abbf499aba6318d
IMGUI_COMMIT=6d32174508fb8c518e7a832cc1d571fadd5cba76

# Bump this whenever the compile-time Dear ImGui options below change, so the
# Makefile knows an existing libcimgui.a must be rebuilt.
CIMGUI_CONFIG="wchar32-v1"

ZIG="${ZIG:-zig}"
CXX="${CXX:-g++}"
AR="${AR:-ar}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need curl
need tar
need sha256sum
need "$ZIG"
need "$CXX"
need "$AR"

ZIG_VERSION="$("$ZIG" version)"
case "$ZIG_VERSION" in
  0.16|0.16.*) ;;
  *)
    echo "error: the pinned libghostty-vt source requires Zig 0.16.x; found $ZIG_VERSION" >&2
    echo "       install Zig 0.16.x, or set ZIG=/path/to/zig-0.16" >&2
    exit 1
    ;;
esac

mkdir -p "$DEPS" "$THIRD"

echo "==> Zig $ZIG_VERSION ($ZIG)"

# The build no longer downloads its own Zig; remove the old private toolchain
# from a previous checkout so it cannot be picked up by accident.
if [ -e "$DEPS/zig" ] || [ -e "$DEPS/zig.tar.xz" ]; then
  echo "==> Removing obsolete local Zig download"
  rm -rf "$DEPS/zig" "$DEPS/zig.tar.xz"
fi

echo "==> Ghostty $GHOSTTY_COMMIT source"
if [ ! -d "$DEPS/ghostty" ] || [ "$(cat "$GHOSTTY_MARKER" 2>/dev/null || true)" != "$GHOSTTY_COMMIT" ]; then
  rm -rf "$DEPS/ghostty"
  curl -fL "$GHOSTTY_URL" -o "$DEPS/ghostty.tar.gz"
  echo "$GHOSTTY_SHA256  $DEPS/ghostty.tar.gz" | sha256sum -c -
  tar -C "$DEPS" -xzf "$DEPS/ghostty.tar.gz"
  mv "$DEPS/ghostty-$GHOSTTY_COMMIT" "$DEPS/ghostty"
  printf '%s\n' "$GHOSTTY_COMMIT" > "$GHOSTTY_MARKER"
  rm -f "$DEPS/ghostty.tar.gz"
else
  echo "    already present"
fi

echo "==> libghostty-vt (static)"
export ZIG_GLOBAL_CACHE_DIR="$DEPS/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="$DEPS/zig-local-cache"
(cd "$DEPS/ghostty" && "$ZIG" build -Demit-lib-vt -Doptimize=ReleaseFast)

mkdir -p "$THIRD/libghostty-vt/include" "$THIRD/libghostty-vt/lib"
rm -rf "$THIRD/libghostty-vt/include/ghostty"
cp -R "$DEPS/ghostty/zig-out/include/ghostty" "$THIRD/libghostty-vt/include/"
cp "$DEPS/ghostty/zig-out/lib/libghostty-vt.a" "$THIRD/libghostty-vt/lib/"
cp "$DEPS/ghostty/LICENSE" "$THIRD/libghostty-vt/LICENSE"
printf '%s\n' "$GHOSTTY_COMMIT" > "$THIRD/libghostty-vt/.miagent-source"

echo "==> cimgui + Dear ImGui"
if [ ! -d "$DEPS/cimgui" ]; then
  curl -fL "https://codeload.github.com/cimgui/cimgui/tar.gz/$CIMGUI_COMMIT" -o "$DEPS/cimgui.tar.gz"
  tar -C "$DEPS" -xzf "$DEPS/cimgui.tar.gz"
  mv "$DEPS/cimgui-$CIMGUI_COMMIT" "$DEPS/cimgui"
  rm -f "$DEPS/cimgui.tar.gz"

  curl -fL "https://codeload.github.com/ocornut/imgui/tar.gz/$IMGUI_COMMIT" -o "$DEPS/imgui.tar.gz"
  tar -C "$DEPS" -xzf "$DEPS/imgui.tar.gz"
  # The cimgui tarball contains an empty `imgui/` placeholder (a git
  # submodule); remove it so the mv below does not nest the source one level.
  rm -rf "$DEPS/cimgui/imgui"
  mv "$DEPS/imgui-$IMGUI_COMMIT" "$DEPS/cimgui/imgui"
  rm -f "$DEPS/imgui.tar.gz"
fi

SRC="$DEPS/cimgui"
OUT="$DEPS/cimgui/build"
mkdir -p "$OUT"
# IMGUI_USE_WCHAR32 is required for emoji and other codepoints above U+FFFF.
CXXFLAGS=(-std=c++17 -O2 -fPIC -I"$SRC/imgui" -I"$SRC/imgui/backends" -DIMGUI_USE_WCHAR32)
IMPL_FLAGS=('-DIMGUI_IMPL_API=extern "C"')

rm -f "$OUT"/*.o
for f in cimgui imgui/imgui imgui/imgui_draw imgui/imgui_tables imgui/imgui_widgets imgui/imgui_demo; do
  "$CXX" "${CXXFLAGS[@]}" -c "$SRC/$f.cpp" -o "$OUT/$(basename "$f").o"
done
for f in imgui_impl_glfw imgui_impl_opengl3; do
  "$CXX" "${CXXFLAGS[@]}" "${IMPL_FLAGS[@]}" -c "$SRC/imgui/backends/$f.cpp" -o "$OUT/$f.o"
done

rm -f "$OUT/libcimgui.a"
"$AR" rcs "$OUT/libcimgui.a" "$OUT"/*.o

mkdir -p "$THIRD/cimgui/include" "$THIRD/cimgui/lib"
cp "$SRC/cimgui.h" "$SRC/cimgui_impl.h" "$THIRD/cimgui/include/"
cp "$SRC/imgui/imgui.h" "$SRC/imgui/imgui_internal.h" "$SRC/imgui/imconfig.h" \
   "$SRC/imgui/imstb_rectpack.h" "$SRC/imgui/imstb_textedit.h" "$SRC/imgui/imstb_truetype.h" \
   "$THIRD/cimgui/include/"
cp "$OUT/libcimgui.a" "$THIRD/cimgui/lib/"
printf '%s\n' "$CIMGUI_CONFIG" > "$THIRD/cimgui/.miagent-config"
cp "$SRC/LICENSE" "$THIRD/cimgui/LICENSE"
cp "$SRC/imgui/LICENSE.txt" "$THIRD/cimgui/LICENSE-imgui.txt"

echo "==> done"
echo "    libghostty-vt: $THIRD/libghostty-vt (Ghostty 1.3.2-dev, $GHOSTTY_COMMIT)"
echo "    cimgui:        $THIRD/cimgui"
