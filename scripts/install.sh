#!/bin/zsh
# Builds an optimized (Release) Canvas.app and installs it in /Applications, so Canvas
# opens from Launchpad, Spotlight or the Dock like any other app — no Xcode needed.
#
#   scripts/install.sh            # build + install
#   scripts/install.sh --dmg      # also make build/Canvas.dmg to copy to another Mac
#
# The app is ad-hoc signed (no Apple Developer account), which is fine on this Mac. Another
# Mac will refuse it at first: right-click the app ▸ Open, or System Settings ▸ Privacy &
# Security ▸ Open Anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild build -project Canvas.xcodeproj -scheme Canvas -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData -quiet
app=build/DerivedData/Build/Products/Release/Canvas.app

if pgrep -xq Canvas; then
  echo "Canvas is running — quit it first (your drawings are autosaved, but check for unsaved ones)." >&2
  exit 1
fi
rm -rf /Applications/Canvas.app
ditto "$app" /Applications/Canvas.app
# Let Finder, Spotlight and "Open With" pick up the app and its .canvas document type.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Canvas.app
echo "Installed /Applications/Canvas.app"

if [[ "${1:-}" == "--dmg" ]]; then
  rm -f build/Canvas.dmg
  hdiutil create -volname Canvas -srcfolder /Applications/Canvas.app -ov -format UDZO build/Canvas.dmg >/dev/null
  echo "Made build/Canvas.dmg"
fi
