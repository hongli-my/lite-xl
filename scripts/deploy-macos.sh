#!/bin/bash
# macOS only: refresh the app bundle and deploy it to the copy of Lite XL you
# actually launch (default: ~/Desktop/LiteXL.app).
#
# Why not just scripts/build.sh: a Lua-only change (plugins, colors, core) needs
# no recompilation, so meson can reinstall the data tree into the bundle as is.
# Two things still have to happen or the deployed app breaks:
#
#   1. meson install --destdir "Lite XL.app"   (plain `ninja install` fails:
#      prefix is /, so it tries to write to /Contents/Resources)
#   2. scripts/macos-bundle-dylibs.sh          (the freshly installed binary
#      references @rpath/libpng16.16.dylib, which only resolves inside the build
#      tree; the script moves it to @executable_path/../Frameworks and re-signs
#      ad-hoc)
#
# Usage: scripts/deploy-macos.sh [options]

set -e

cd "$(dirname "$0")/.."

show_help() {
  echo
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Available options:"
  echo "-b --builddir DIRNAME    Meson build directory."
  echo "                         Default: 'build-static'."
  echo "-t --target PATH         App bundle to deploy to."
  echo "                         Default: '\$HOME/Desktop/LiteXL.app'."
  echo "-n --no-deploy           Only refresh the bundle inside the build dir."
  echo "-c --no-compile          Skip 'meson compile' (Lua-only changes)."
  echo "-h --help                Show this help and exit."
  echo
}

main() {
  local build_dir="build-static"
  local target="$HOME/Desktop/LiteXL.app"
  local deploy=1
  local compile=1
  local bundle_name="Lite XL.app"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--builddir)   build_dir="$2"; shift 2;;
      -t|--target)     target="$2"; shift 2;;
      -n|--no-deploy)  deploy=0; shift;;
      -c|--no-compile) compile=0; shift;;
      -h|--help)       show_help; return 0;;
      *) echo "Unknown option: $1" >&2; show_help >&2; exit 1;;
    esac
  done

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: this script only applies to macOS app bundles." >&2
    exit 1
  fi
  if [[ ! -d "$build_dir" ]]; then
    echo "Error: build directory '$build_dir' not found (run scripts/build.sh -B first)." >&2
    exit 1
  fi

  local app="$build_dir/$bundle_name"

  if [[ $compile -eq 1 ]]; then
    echo "==> meson compile ($build_dir)"
    meson compile -C "$build_dir"
  fi

  echo "==> meson install -> $app"
  meson install -C "$build_dir" --destdir "$bundle_name" \
    --skip-subprojects=freetype2,lua,pcre2,libpng,zlib --no-rebuild

  echo "==> bundling non-system dylibs + ad-hoc signature"
  scripts/macos-bundle-dylibs.sh "$app" "$build_dir"

  # A leftover @rpath reference means the app would fail to start with a dyld
  # error as soon as it is opened from outside the build tree.
  local outside
  outside="$(otool -L "$app/Contents/MacOS/lite-xl" | tail -n +2 \
    | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/|@executable_path/)' || true)"
  if [[ -n "$outside" ]]; then
    echo "Error: the bundle still links against libraries outside it:" >&2
    echo "$outside" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$app"
  echo "    bundle OK"

  if [[ $deploy -eq 0 ]]; then
    echo "==> done (--no-deploy)"
    return 0
  fi

  echo "==> deploying to $target"
  if pgrep -qf "$target/Contents/MacOS/lite-xl"; then
    echo "    note: Lite XL is running from that bundle; quit it (Cmd+Q) and reopen."
  fi
  if [[ -d "$target" ]]; then
    local backup
    backup="$(mktemp -d)/$(basename "$target").old-$(date +%Y%m%d-%H%M%S)"
    mv "$target" "$backup"
    echo "    previous bundle moved to $backup"
  fi
  mkdir -p "$(dirname "$target")"
  ditto "$app" "$target"

  echo "==> verifying"
  if ! diff -rq "$app" "$target" >/dev/null; then
    echo "Error: the deployed bundle differs from $app" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$target"
  if diff -rq data/plugins "$target/Contents/Resources/plugins" >/dev/null; then
    echo "    plugins in the deployed bundle match data/plugins"
  else
    echo "    WARNING: plugins in the deployed bundle differ from data/plugins" >&2
  fi

  echo
  echo "Done. Quit Lite XL (Cmd+Q, not just the window) and reopen $target."
}

main "$@"
