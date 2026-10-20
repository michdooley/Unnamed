#!/bin/zsh
# Builds Unnamed.app for download: a universal (Apple silicon + Intel)
# Release build, ad-hoc signed, packaged as a DMG and a ZIP in build/release.
#
# Ad-hoc signing needs no Apple Developer account. Without one the app can't
# be notarized, so the first time someone opens it, macOS asks them to allow
# it in System Settings › Privacy & Security (see the README's install steps).
# Ad-hoc signing also keeps the builder's name and Apple ID out of the app.
#
# Usage: Scripts/make-release.sh
# An Unsplash key is left out unless UNSPLASH_ACCESS_KEY is set in the
# environment (a personal key in Signing.local.xcconfig is never shipped).
set -euo pipefail
cd "${0:A:h}/.."

DERIVED=build/ReleaseDerivedData
OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild -project Unnamed.xcodeproj -scheme Unnamed -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  UNSPLASH_ACCESS_KEY="${UNSPLASH_ACCESS_KEY:-}" \
  build | grep -E "^\*\* BUILD|error:" || true

APP="$DERIVED/Build/Products/Release/Unnamed.app"
[[ -d "$APP" ]] || { echo "The build failed."; exit 1; }
codesign --verify --deep --strict "$APP"
# No debugging entitlement in what people download.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "The app is signed for debugging (get-task-allow); not packaging it."
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "Unnamed $VERSION: $(lipo -archs "$APP/Contents/MacOS/Unnamed")"

# A disk image to drag the app from into Applications.
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Unnamed.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Unnamed $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Unnamed-$VERSION.dmg"
rm -rf "$STAGE"

# And a plain ZIP.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Unnamed-$VERSION.zip"

(cd "$OUT" && shasum -a 256 Unnamed-* > SHA256SUMS.txt)
ls -lh "$OUT"
