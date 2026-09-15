#!/bin/bash
# Builds Ghost.app (universal, ad-hoc signed) and wraps it in a DMG under dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=Ghost
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
DIST=dist
BUNDLE=$DIST/$APP.app

echo "▸ Compiling"
if swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error|Build complete"; then
  BIN=$(find .build -path "*/Products/Release/$APP" -type f | head -1)
fi
if [ -z "${BIN:-}" ] || [ ! -f "$BIN" ]; then
  echo "  universal build unavailable, building native"
  swift build -c release 2>&1 | grep -E "error|Build complete"
  BIN=.build/release/$APP
fi
echo "  $(file -b "$BIN" | head -c 80)"

echo "▸ Assembling bundle"
rm -rf "$DIST"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
echo -n 'APPL????' > "$BUNDLE/Contents/PkgInfo"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Rendering icon"
  TMP=$(mktemp -d)
  swift scripts/make-icon.swift "$TMP/icon.png"
  mkdir -p "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Accessibility grant across rebuilds (TCC keys on it).
# "Ghost Dev" is a self-signed cert in the login keychain; ad-hoc is the fallback.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Ghost Dev"'; then
  echo "▸ Signing (Ghost Dev)"
  codesign --force --deep --sign "Ghost Dev" "$BUNDLE"
else
  echo "▸ Signing (ad-hoc — Accessibility will need re-granting after each build)"
  codesign --force --deep --sign - "$BUNDLE"
fi

echo "▸ Packaging DMG"
STAGE=$DIST/dmg
mkdir -p "$STAGE"
cp -R "$BUNDLE" "$STAGE/"
cp Resources/ReadMeFirst.txt "$STAGE/Read Me First.txt"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DIST/$APP-$VERSION.dmg"
rm -rf "$STAGE"

echo "✓ $DIST/$APP-$VERSION.dmg"
