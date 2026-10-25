#!/bin/zsh
# Builds Diorama.app (app + dioramad + diorama CLI) into dist/.
#
# Environment:
#   BUNDLE_ID       bundle identifier (default io.github.diorama.Diorama)
#   SIGN_IDENTITY   codesign identity, e.g. "Developer ID Application: Name (TEAMID)".
#                   Default "-" (ad-hoc; fine for local use, not for distribution).
#   CONFIGURATION   release (default) or debug
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-io.github.diorama.Diorama}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION="$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' Sources/DioramaCore/Models.swift)"
DIST="dist"
APP="$DIST/Diorama.app"

echo "▸ Building Diorama $VERSION ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product dioramad
swift build -c "$CONFIGURATION" --product diorama
swift build -c "$CONFIGURATION" --product DioramaApp
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
# The CLI lives in Helpers/: on a case-insensitive volume MacOS/diorama would overwrite MacOS/Diorama.
cp "$BIN/DioramaApp" "$APP/Contents/MacOS/Diorama"
cp "$BIN/dioramad" "$APP/Contents/Helpers/dioramad"
cp "$BIN/diorama" "$APP/Contents/Helpers/diorama"

echo "▸ Rendering icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$DIST/icon-1024.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$DIST/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$DIST/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Diorama</string>
  <key>CFBundleDisplayName</key><string>Diorama</string>
  <key>CFBundleExecutable</key><string>Diorama</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Diorama contributors. Apache License 2.0.</string>
</dict>
</plist>
PLIST

echo "▸ Signing ($SIGN_IDENTITY)"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp=none)
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp); fi
for b in dioramad diorama; do codesign "${SIGN_ARGS[@]}" -i "$BUNDLE_ID.$b" "$APP/Contents/Helpers/$b"; done
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
# Guard against the case-collision regression: the main executable must be the app.
file "$APP/Contents/MacOS/Diorama" | grep -q "Mach-O" && ! cmp -s "$APP/Contents/MacOS/Diorama" "$APP/Contents/Helpers/diorama"

echo "▸ Packaging"
( cd "$DIST" && rm -f "Diorama-$VERSION.zip" && ditto -c -k --keepParent Diorama.app "Diorama-$VERSION.zip" )
# File name only, so `shasum -c` works in the folder the user downloads to.
( cd "$DIST" && shasum -a 256 "Diorama-$VERSION.zip" | tee "Diorama-$VERSION.zip.sha256" )
echo "✓ $APP"
