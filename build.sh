#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$ROOT/build/MenuShelf.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
swiftc -O -framework AppKit -framework ApplicationServices \
  "$ROOT/MenuShelf.swift" "$ROOT/MenuBarIconService.swift" \
  -o "$APP/Contents/MacOS/MenuShelf"

# Build the multi-resolution .icns from Resources/AppIcon.png (1024x1024).
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
            512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  size=${spec%%:*}
  name=${spec#*:}
  sips -z "$size" "$size" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
# Ad-hoc signing produces a new signature on every build; macOS may then ask
# for Accessibility permission to be granted again.
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
