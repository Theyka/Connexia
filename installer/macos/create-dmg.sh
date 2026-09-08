#!/usr/bin/env bash
#
# Packages the macOS release build into a distributable .dmg.
#
# Usage:
#   flutter build macos --release
#   installer/macos/create-dmg.sh [output.dmg]   (default: connexia-macos-arm64.dmg)
#
# The image holds connexia.app next to an /Applications symlink, so users
# mount it and drag the app onto the symlink to install. The app is only
# ad-hoc signed: it runs fine locally, but until a Developer ID certificate
# and notarization are set up, other machines show Gatekeeper's
# "unidentified developer" warning on first launch (see README).

set -euo pipefail

app_path="build/macos/Build/Products/Release/connexia.app"
output="${1:-connexia-macos-arm64.dmg}"

if [ ! -d "$app_path" ]; then
  echo "error: $app_path not found — run 'flutter build macos --release' first" >&2
  exit 1
fi

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

cp -R "$app_path" "$staging/connexia.app"
ln -s /Applications "$staging/Applications"

rm -f "$output"
hdiutil create \
  -volname "Connexia" \
  -srcfolder "$staging" \
  -format UDZO \
  -ov \
  "$output" >/dev/null

echo "Built $output"
