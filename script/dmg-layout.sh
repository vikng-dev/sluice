#!/bin/bash
# Arranges the disk image's window, once, by Finder's own hand, and keeps what Finder wrote down
# (Assets/dmg/DS_Store), which script/dmg.sh puts into every image after. Run it again only when
# the window's design changes: script/dmg-layout.sh [Sluice.app] [a file for a picture of the window].
# It needs a desktop, and leave to drive Finder. The volume's name and the names in it are what the
# layout is kept by, so they stay as they are.
set -euo pipefail
cd "$(dirname "$0")/.."
app=${1:-dist/Sluice.app} shot=${2:-}
[[ -d /Volumes/Sluice ]] && { echo "a volume named Sluice is mounted; eject it first"; exit 1; }
sips -s format png Assets/dmg/background.svg --out /tmp/sluice-dmg-1x.png >/dev/null
sips -s format png -z 800 1280 Assets/dmg/background.svg --out /tmp/sluice-dmg-2x.png >/dev/null
tiffutil -cathidpicheck /tmp/sluice-dmg-1x.png /tmp/sluice-dmg-2x.png -out Assets/dmg/background.tiff 2>/dev/null

work=$(mktemp -d)
trap 'hdiutil detach -quiet /Volumes/Sluice 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/stage/.background"
ditto "$app" "$work/stage/Sluice.app"
ln -s /Applications "$work/stage/Applications"
cp Assets/dmg/background.tiff "$work/stage/.background/background.tiff"
hdiutil create -quiet -volname Sluice -srcfolder "$work/stage" -fs HFS+ -format UDRW "$work/rw.dmg"
hdiutil attach -quiet "$work/rw.dmg"
osascript <<'SCRIPT'
tell application "Finder"
  tell disk "Sluice"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Sluice.app" of container window to {180, 190}
    set position of item "Applications" of container window to {460, 190}
    close
    open
    update without registering applications
    delay 2
  end tell
  activate
end tell
SCRIPT
sync; sleep 2
if [[ -n $shot ]]; then
  read -r x1 y1 x2 y2 < <(osascript -e 'tell application "Finder" to get bounds of window "Sluice"' | tr -d ',')
  screencapture -x -R"$x1,$y1,$((x2 - x1)),$((y2 - y1))" "$shot"
fi
osascript -e 'tell application "Finder" to close window "Sluice"' >/dev/null 2>&1 || true
sync; sleep 1
cp /Volumes/Sluice/.DS_Store Assets/dmg/DS_Store
echo "kept Assets/dmg/DS_Store"
