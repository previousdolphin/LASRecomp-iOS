#!/bin/bash
# Builds VAProbe.ipa (needs Xcode with the iOS SDK). Unsigned unless IDENTITY is set: sideloading tools
# (AltStore, SideStore, Sideloadly) sign it with your Apple ID and apply vaprobe.entitlements as far as your account allows.
#   tools/ios/vaprobe/build.sh                      -> build/ios/VAProbe.ipa
#   IDENTITY="Apple Development: ..." PROFILE=x.mobileprovision tools/ios/vaprobe/build.sh   (signed)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${OUT:-$here/../../../build/ios}"
app="$out/Payload/VAProbe.app"
rm -rf "$out/Payload" && mkdir -p "$app"
xcrun -sdk iphoneos clang -target arm64-apple-ios16.0 -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
    -framework UIKit -framework Foundation -framework Metal -framework MetalFX \
    -o "$app/VAProbe" "$here/main.m"
cp "$here/Info.plist" "$app/Info.plist"
plutil -convert binary1 "$app/Info.plist"
if [ -n "${IDENTITY:-}" ]; then
    [ -n "${PROFILE:-}" ] && cp "$PROFILE" "$app/embedded.mobileprovision"
    codesign -f -s "$IDENTITY" --entitlements "$here/vaprobe.entitlements" "$app"
fi
(cd "$out" && rm -f VAProbe.ipa && zip -qr VAProbe.ipa Payload)
echo "$out/VAProbe.ipa"
