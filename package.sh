#!/bin/bash
# Build Ratebridge.app — a real bundle, not a bare binary.
#
# This is not cosmetic. Accessibility and Automation grants are keyed to code
# signature and bundle identity; macOS will not reliably hold a grant for a bare
# CLI binary launched by launchd. Bundling is what makes the UI reader work
# unattended. (Verified the hard way: the daemon's reader returned nil under
# launchd while working fine from a shell.)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Ratebridge"
VERSION="0.9.0"
DEST="${1:-/Applications}"
APP="$DEST/$APP_NAME.app"

./build.sh >/dev/null

mkdir -p "$DEST"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bin/ratebridge "$APP/Contents/MacOS/ratebridge"

# Icon. Regenerate only if missing so a rebuild does not churn the bundle
# needlessly — every content change gives the app a new ad-hoc CDHash, which
# invalidates its Accessibility grant.
if [ ! -f icon/Ratebridge.icns ]; then
    swiftc -O icon/makeicon.swift -o icon/makeicon
    (cd icon && ./makeicon Ratebridge.iconset >/dev/null \
        && iconutil -c icns Ratebridge.iconset -o Ratebridge.icns)
fi
cp icon/Ratebridge.icns "$APP/Contents/Resources/Ratebridge.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>com.bns.ratebridge</string>
	<key>CFBundleExecutable</key><string>ratebridge</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key><string>14.2</string>
	<key>CFBundleIconFile</key><string>Ratebridge</string>
	<key>LSUIElement</key><true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Ratebridge reads the sample rate your music player displays for the current track, so it can match your DAC to it.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Sign with a stable identity if one exists, ad-hoc otherwise.
#
# This is the difference between "grant Accessibility once" and "grant it again
# after every build". An ad-hoc signature has no identity, so the app's
# designated requirement is a bare `cdhash H"..."` — a new hash every build, and
# TCC refuses to rebind an existing entry to it. Signed with a real identity the
# requirement becomes `identifier "com.bns.ratebridge" and anchor apple generic
# and certificate leaf[subject.CN] = "..."`, which is byte-identical across
# builds, so the grant survives. Verified 2026-08-28 by signing two differing
# copies and diffing `codesign -d -r-`.
#
# Any codesigning identity works. If the cert expires or is removed, this falls
# back to ad-hoc and the old re-grant behaviour returns — hence the warning.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*\)"$/\1/p' | head -1)"

if [ -n "$SIGN_ID" ]; then
    codesign --force --deep --sign "$SIGN_ID" "$APP"
    echo "signed: $SIGN_ID"
else
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    echo "WARNING: no codesigning identity found; signed ad-hoc."
    echo "         The Accessibility grant will need redoing after every build."
fi

echo "built: $APP"
