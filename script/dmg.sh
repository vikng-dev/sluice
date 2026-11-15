#!/bin/bash
# Makes the disk image a person downloads from the site: the app beside a way into Applications,
# in a window laid out as Assets/dmg has it, under the app's own icon, signed, notarized and stapled.
# script/dmg.sh <Sluice.app, itself signed and stapled> <out.dmg>. Needs SIGN_IDENTITY and
# NOTARY_PROFILE, as script/release.sh does. The window's layout is made by script/dmg-layout.sh.
set -euo pipefail
app=$1 out=$2 root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$root/.release.env" ]] && source "$root/.release.env"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY}" "${NOTARY_PROFILE:?set NOTARY_PROFILE}"

work=$(mktemp -d)
trap 'hdiutil detach -quiet "$work/mnt" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/stage/.background" "$work/mnt"
ditto "$app" "$work/stage/Sluice.app"
ln -s /Applications "$work/stage/Applications"
cp "$root/Assets/dmg/background.tiff" "$work/stage/.background/background.tiff"
cp "$root/Assets/dmg/DS_Store" "$work/stage/.DS_Store"
cp "$root/Assets/AppIcon.icns" "$work/stage/.VolumeIcon.icns"
hdiutil create -quiet -volname Sluice -srcfolder "$work/stage" -fs HFS+ -format UDRW "$work/rw.dmg"
# a volume shows its own icon only when its root says it has one
hdiutil attach -quiet -nobrowse -mountpoint "$work/mnt" "$work/rw.dmg"
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$work/mnt"
hdiutil detach -quiet "$work/mnt"
rm -f "$out"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -o "$out"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$out"
xcrun notarytool submit "$out" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$out"
spctl --assess --type open --context context:primary-signature "$out"
