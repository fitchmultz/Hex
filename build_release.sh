#!/bin/bash
set -e

# Ensure the embedded Canary runtime archive exists before building.
if [[ ! -f "build/canary-env/python-env.bin" ]]; then
  echo "[build_release] Canary runtime archive missing – building"
  ./scripts/package_canary_env.sh
fi

# Build Release
xcodebuild -project Hex.xcodeproj -scheme Hex -configuration Release -derivedDataPath build clean build | cat

# Replicate the Resources folder manually since it's excluded from the Xcode copy phase.
APP_RESOURCES_DIR="build/Build/Products/Release/Hex.app/Contents/Resources"
rsync -a --delete "Hex/Resources/" "$APP_RESOURCES_DIR/"

# Stage Canary runtime archive into the built app bundle.
CANARY_ARCHIVE="build/canary-env/python-env.bin"
CANARY_FREEZE="runtime/canary/python-env-freeze.txt"
CANARY_WORKER="runtime/canary/hex_canary_worker.py"
APP_CANARY_DIR="build/Build/Products/Release/Hex.app/Contents/Resources/Canary"

if [[ ! -f "$CANARY_ARCHIVE" ]]; then
  echo "[build_release] Canary archive not found at $CANARY_ARCHIVE" >&2
  exit 1
fi

mkdir -p "$APP_CANARY_DIR"
cp "$CANARY_ARCHIVE" "$APP_CANARY_DIR/python-env.bin"
cp "$CANARY_FREEZE" "$APP_CANARY_DIR/python-env-freeze.txt"
cp "$CANARY_WORKER" "$APP_CANARY_DIR/hex_canary_worker.py"

# Replace the app
osascript -e 'tell application "Hex" to quit' || true
rm -rf "/Applications/Hex.app"
ditto "build/Build/Products/Release/Hex.app" "/Applications/Hex.app"

# Remove quarantine
xattr -dr com.apple.quarantine "/Applications/Hex.app" || true

# Create ad‑hoc entitlements with disable-library-validation (lets the app load its embedded Sparkle)
cp "Hex/Hex.entitlements" /tmp/adhoc-hex.entitlements
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' /tmp/adhoc-hex.entitlements 2>/dev/null || true

# Re-sign all nested code ad‑hoc (frameworks, XPCs/apps), then the host with entitlements
find "/Applications/Hex.app/Contents/Frameworks" -maxdepth 3 \
  \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" \) \
  -exec codesign --force --options runtime -s - "{}" \;

codesign --force --deep --options runtime --entitlements /tmp/adhoc-hex.entitlements -s - "/Applications/Hex.app"

# Sanity check (TeamIdentifier should be empty for both app and Sparkle)
codesign -dv --verbose=4 "/Applications/Hex.app" | sed -n 's/^\\(Identifier\\|TeamIdentifier\\|Signature\\).*/\\0/p'
codesign -dv --verbose=4 "/Applications/Hex.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" | sed -n 's/^\\(Identifier\\|TeamIdentifier\\|Signature\\).*/\\0/p'

# Launch
open -a "/Applications/Hex.app"
