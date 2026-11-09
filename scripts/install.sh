#!/bin/zsh
# Builds the release Monart.app (scripts/build-release.sh) and installs it in /Applications,
# so Monart opens from Launchpad, Spotlight or the Dock like any other app — no Xcode needed.
# The disk image for sharing ends up in build/ as well.
set -euo pipefail
cd "$(dirname "$0")/.."

if pgrep -xq Monart; then
  echo "Monart is running — quit it first (check for unsaved drawings)." >&2
  exit 1
fi
dmg=$(scripts/build-release.sh | tail -1)
rm -rf /Applications/Monart.app
ditto build/DerivedData/Build/Products/Release/Monart.app /Applications/Monart.app
# Let Finder, Spotlight and "Open With" pick up the app and its .canvas document type.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Monart.app
echo "Installed /Applications/Monart.app"
echo "Disk image to share: $dmg"
