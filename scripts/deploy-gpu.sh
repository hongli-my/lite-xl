#!/bin/bash
# Build + deploy the GPU-enabled Lite XL app to ~/Desktop/"Lite XL.app".
# Usage: bash scripts/deploy-gpu.sh
#
# Delegates to scripts/deploy-macos.sh, which installs the bundle with
# `meson install`.  This script used to rsync data/ over Contents/Resources
# with --delete, which removed everything meson installs from outside data/
# (icon.icns, licenses.md, the docs/api stubs) and replaced the configured
# core/start.lua with the raw template (VERSION = "@PROJECT_VERSION@").
set -e

cd "$(dirname "$0")/.."
BUILD=build-static

# start from a fresh bundle so files removed from data/ do not linger
rm -rf "$BUILD/Lite XL.app"

exec bash scripts/deploy-macos.sh -b "$BUILD" -t "$HOME/Desktop/Lite XL.app"
