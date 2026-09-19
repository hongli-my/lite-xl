#!/bin/sh
# Regenerate the Nerd Font subset used by the treeview.
#
# `data/fonts/JetBrainsMonoNerdFontMono-Regular.ttf` is a subset of the full
# JetBrains Mono Nerd Font (~2.4 MB): the editor only uses a few dozen file type
# icons from it, plus it needs ASCII/Latin-1 and the box/geometric ranges the
# renderer falls back to for missing codepoints.
#
# Usage:
#   scripts/subset-icons-font.sh [FULL_FONT]
#
# FULL_FONT defaults to the font in the tree and must be the *full* Nerd Font.
# The subset already committed in the repository is only ~99 KB, so the script
# refuses to run on it; restore the full font first with:
#   git show HEAD:data/fonts/JetBrainsMonoNerdFontMono-Regular.ttf > /tmp/full.ttf
#   scripts/subset-icons-font.sh /tmp/full.ttf
#
# The list of codepoints is taken from data/plugins/treeview.lua, so re-run this
# script after adding new file type icons there.
set -e

cd "$(dirname "$0")/.." || exit 1

TREEVIEW=data/plugins/treeview.lua
TARGET=data/fonts/JetBrainsMonoNerdFontMono-Regular.ttf
SRC=${1:-$TARGET}

if [ ! -f "$SRC" ]; then
  echo "error: font not found: $SRC" >&2
  exit 1
fi

src_size=$(wc -c < "$SRC" | tr -d ' ')
if [ "$src_size" -lt 500000 ]; then
  echo "error: $SRC does not look like the full Nerd Font (${src_size} bytes)." >&2
  echo "       See the comments at the top of this script to restore it." >&2
  exit 1
fi

icons=$(grep -o '\\u{[0-9a-fA-F]*}' "$TREEVIEW" \
  | sed 's/\\u{/U+/; s/}$//' \
  | sort -u \
  | tr '\n' ',')
if [ -z "$icons" ]; then
  echo "error: no icon codepoints found in $TREEVIEW" >&2
  exit 1
fi

# ASCII, Latin-1, box drawing, geometric shapes (renderer fallback glyph), icons
unicodes="U+0020-007E,U+00A0-00FF,U+2500-257F,U+25A0-25FF,${icons%,}"

echo "subsetting $(basename "$SRC") -> $TARGET"
echo "unicodes: $unicodes"

PYFTSUBSET=
if command -v pyftsubset >/dev/null 2>&1; then
  PYFTSUBSET="pyftsubset"
elif python3 -c 'import fontTools' >/dev/null 2>&1; then
  PYFTSUBSET="python3 -m fontTools.subset"
elif command -v uv >/dev/null 2>&1; then
  PYFTSUBSET="uv run --quiet --with fonttools pyftsubset"
else
  echo "error: fonttools is required (pip install fonttools, or install uv)" >&2
  exit 1
fi

# shellcheck disable=SC2086
$PYFTSUBSET "$SRC" --unicodes="$unicodes" --output-file="$TARGET"

echo "done: $TARGET is now $(wc -c < "$TARGET" | tr -d ' ') bytes"
echo "note: the file is binary; check the treeview still draws its icons."
