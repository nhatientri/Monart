#!/bin/zsh
# Builds the release Canvas.app (scripts/build-release.sh) and installs it in /Applications,
# so Canvas opens from Launchpad, Spotlight or the Dock like any other app — no Xcode needed.
# The disk image for sharing ends up in build/ as well.
set -euo pipefail
cd "$(dirname "$0")/.."

if pgrep -xq Canvas; then
  echo "Canvas is running — quit it first (check for unsaved drawings)." >&2
  exit 1
fi
dmg=$(scripts/build-release.sh | tail -1)
rm -rf /Applications/Canvas.app
ditto build/DerivedData/Build/Products/Release/Canvas.app /Applications/Canvas.app
# Let Finder, Spotlight and "Open With" pick up the app and its .canvas document type.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Canvas.app
echo "Installed /Applications/Canvas.app"
echo "Disk image to share: $dmg"
