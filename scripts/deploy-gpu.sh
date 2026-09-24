#!/bin/bash
# Build + deploy the GPU-enabled Lite XL app to ~/Desktop.
# Usage: bash scripts/deploy-gpu.sh
set -e

cd "$(dirname "$0")/.."
BUILD=build-static
APP="$BUILD/Lite XL.app"

echo "=== Building ==="
ninja -C "$BUILD"

echo "=== Updating app bundle binary ==="
cp -f "$BUILD/src/lite-xl" "$APP/Contents/MacOS/lite-xl"

echo "=== Bundling dylibs + signing ==="
bash scripts/macos-bundle-dylibs.sh "$APP" "$BUILD"

echo "=== Syncing data files into bundle ==="
# Copy data/ (core, plugins, fonts, colors) into the bundle's Resources.
# The meson install step does this for a fresh build, but we update the
# binary in-place with ninja, so the data may be stale.
rsync -a --delete data/ "$APP/Contents/Resources/"

echo "=== Deploying to ~/Desktop ==="
rm -rf ~/Desktop/"Lite XL.app"
cp -R "$APP" ~/Desktop/

echo "=== Done: ~/Desktop/Lite XL.app ==="
