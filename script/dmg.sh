#!/bin/bash
# Makes the disk image a person downloads from the site: the app beside a way into Applications,
# signed, notarized and stapled. script/dmg.sh <Sluice.app, itself signed and stapled> <out.dmg>.
# Needs SIGN_IDENTITY and NOTARY_PROFILE, as script/release.sh does.
set -euo pipefail
app=$1 out=$2
[[ -f "$(dirname "$0")/../.release.env" ]] && source "$(dirname "$0")/../.release.env"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY}" "${NOTARY_PROFILE:?set NOTARY_PROFILE}"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Sluice.app"
ln -s /Applications "$stage/Applications"
rm -f "$out"
hdiutil create -quiet -volname Sluice -srcfolder "$stage" -fs HFS+ -format UDZO "$out"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$out"
xcrun notarytool submit "$out" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$out"
spctl --assess --type open --context context:primary-signature "$out"
