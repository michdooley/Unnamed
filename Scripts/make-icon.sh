#!/bin/zsh
# Rebuilds the app icon from the CD shader, at every size the asset catalog needs.
#   Scripts/make-icon.sh [lightX lightY rotation]
set -euo pipefail
cd "$(dirname "$0")/.."
icons=Unnamed/Assets.xcassets/AppIcon.appiconset
work=$(mktemp -d)
xcrun -sdk macosx metal -c Unnamed/Components/CDShader.metal -o "$work/cd.air"
xcrun -sdk macosx metallib "$work/cd.air" -o "$work/cd.metallib"
swift Scripts/make-icon.swift "$work/cd.metallib" "$icons/icon-1024.png" "$@"
for size in 16 32 64 128 256 512; do
  sips -z $size $size "$icons/icon-1024.png" --out "$icons/icon-$size.png" >/dev/null
done
rm -rf "$work"
echo "Updated $icons"
