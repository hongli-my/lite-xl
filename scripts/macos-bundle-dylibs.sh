#!/bin/bash
# Makes a macOS .app self contained: every non-system dynamic library the
# executable depends on is copied into Contents/Frameworks and the references
# are rewritten to @executable_path/../Frameworks/...
#
# Only needed for libraries that meson builds as subprojects and links
# dynamically - currently libpng, which FreeType requires to decode the PNG
# compressed bitmaps of colour emoji fonts (Apple Color Emoji).
#
# Usage: scripts/macos-bundle-dylibs.sh <path to .app> [<meson build dir>]
set -e

APP="$1"
BUILD_DIR="$2"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "usage: $0 <path to .app> [<meson build dir>]" >&2
  exit 1
fi

BIN="$APP/Contents/MacOS/lite-xl"
FRAMEWORKS="$APP/Contents/Frameworks"
if [ ! -f "$BIN" ]; then
  echo "error: $BIN not found" >&2
  exit 1
fi
mkdir -p "$FRAMEWORKS"

# Locates the file behind an install name.  @rpath entries are looked up in the
# build tree, which is where the subproject libraries are produced.
resolve_library() {
  name="$1"
  case "$name" in
    @rpath/*) name="${name#@rpath/}" ;;
    @*) return 1 ;;
  esac
  path=""
  if [ -n "$BUILD_DIR" ]; then
    path=$(find "$BUILD_DIR/subprojects" -name "$name" -type f 2>/dev/null | head -n 1)
  fi
  if [ -z "$path" ] && [ -f "$name" ]; then
    path="$name"
  fi
  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
}

copied=0
for lib in $(otool -L "$BIN" | tail -n +2 | awk '{print $1}'); do
  case "$lib" in
    /usr/lib/*|/System/*|@executable_path/*) continue ;;
  esac
  src=$(resolve_library "$lib") || {
    echo "warning: could not locate $lib, it will be needed at runtime" >&2
    continue
  }
  name=$(basename "$src")
  echo "bundling $name"
  cp -f "$src" "$FRAMEWORKS/$name"
  chmod u+w "$FRAMEWORKS/$name"
  install_name_tool -id "@executable_path/../Frameworks/$name" "$FRAMEWORKS/$name"
  install_name_tool -change "$lib" "@executable_path/../Frameworks/$name" "$BIN"
  copied=$((copied + 1))
done

if [ "$copied" = 0 ]; then
  echo "nothing to bundle: only system libraries are linked"
  rmdir "$FRAMEWORKS" 2>/dev/null || true
  exit 0
fi

# install_name_tool invalidates the signature, so sign again.  The signature is
# ad-hoc: these are local builds without a Developer ID.
codesign --force --sign - "$FRAMEWORKS"/*.dylib 2>/dev/null || true
codesign --force --sign - "$BIN"
codesign --force --sign - "$APP"
echo "bundled: $(ls -1 "$FRAMEWORKS" | tr '\n' ' ')"
