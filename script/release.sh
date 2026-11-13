#!/bin/bash
# Releases the version in Sources/Core/Version.swift: build, sign, notarize, tag, GitHub release.
# Needs SIGN_IDENTITY (a "Developer ID Application: …" name) and NOTARY_PROFILE (a notarytool
# keychain profile), from the environment or a git-ignored .release.env.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .release.env ]] && source .release.env
: "${SIGN_IDENTITY:?set SIGN_IDENTITY}" "${NOTARY_PROFILE:?set NOTARY_PROFILE}"

version=$(sed -nE 's/.*version = "([^"]+)".*/\1/p' Sources/Core/Version.swift)
tag="v$version"
zip="dist/Sluice-$tag-macos.zip"

[[ -z $(git status --porcelain) ]] || { echo "uncommitted changes"; exit 1; }
[[ $(git symbolic-ref --short HEAD) == main ]] || { echo "release from main"; exit 1; }
git fetch -q --tags origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main differs from origin/main"; exit 1; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "$tag exists; bump Version.swift"; exit 1; }

script/bundle.sh
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" dist/Sluice.app/Contents/MacOS/sluice
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" dist/Sluice.app
ditto -c -k --keepParent dist/Sluice.app "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/Sluice.app
rm "$zip"
ditto -c -k --keepParent dist/Sluice.app "$zip"
spctl --assess --type execute dist/Sluice.app

git tag "$tag"
git push -q origin "$tag"
gh release create "$tag" "$zip" --title "Sluice $tag" --generate-notes "$@"
