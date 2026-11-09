#!/bin/zsh
# Builds the release Canvas.app (universal: Apple Silicon + Intel) and a drag-to-install
# disk image, build/Canvas-<version>.dmg. Used by scripts/install.sh and by the GitHub
# release workflow (.github/workflows/release.yml). Prints the disk image's path last.
#
# The app is ad-hoc signed, not signed with an Apple Developer ID, so on a Mac that
# downloads it macOS asks once: System Settings ▸ Privacy & Security ▸ Open Anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' project.yml)
[[ -n "$version" ]] || { echo "MARKETING_VERSION not found in project.yml" >&2; exit 1; }

# Keep the Xcode project in step with project.yml when XcodeGen is around (CI uses the
# committed project).
if command -v xcodegen >/dev/null; then xcodegen generate >/dev/null; fi

xcodebuild build -project Canvas.xcodeproj -scheme Canvas -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData -quiet
app=build/DerivedData/Build/Products/Release/Canvas.app

# Disk image: the app next to a shortcut to /Applications, to drag it onto.
stage=build/dmg
rm -rf "$stage" && mkdir -p "$stage"
ditto "$app" "$stage/Canvas.app"
ln -s /Applications "$stage/Applications"
dmg="build/Canvas-$version.dmg"
rm -f "$dmg"
hdiutil create -volname "Canvas $version" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
echo "$dmg"
