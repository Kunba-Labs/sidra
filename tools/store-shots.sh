#!/bin/zsh
# App Store screenshots from the demo mode: iPad 13" (landscape) and iPhone 6.9" (portrait).
# Usage: tools/store-shots.sh [ipad-sim-id] [iphone-sim-id]   → build/shots/{ipad,iphone}/*.png
set -eu
cd "$(dirname "$0")/.."
IPAD=${1:-$(xcrun simctl list devices available | grep -m1 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}')}
PHONE=${2:-$(xcrun simctl list devices available | grep -m1 'iPhone 17 Pro Max' | grep -oE '[0-9A-F-]{36}')}
dd=(); [ -n "${DD:-}" ] && dd=(-derivedDataPath "$DD")   # DD: reuse a derived data folder
for pair in "ipad:$IPAD" "iphone:$PHONE"; do
  kind=${pair%%:*}; id=${pair#*:}
  rm -rf build/shots/$kind; mkdir -p build/shots/$kind
  xcrun simctl boot $id 2>/dev/null || true
  xcrun simctl status_bar $id override --time 9:41 --batteryLevel 100 --batteryState charged --wifiBars 3 --cellularBars 4
  TEST_RUNNER_SIDRA_SHOT_DIR=$PWD/build/shots/$kind xcodebuild test -project Sidra.xcodeproj -scheme Sidra -destination "id=$id" "${dd[@]}" \
    -skipPackagePluginValidation -skipMacroValidation -only-testing:SidraUITests/StoreScreenshotsUITests -quiet
  # XCUIScreen captures the iPad in its portrait frame: turn it to the landscape it was shot in.
  if [ $kind = ipad ]; then for f in build/shots/ipad/*.png; do sips -r 270 "$f" >/dev/null; python3 tools/dev/strippng.py "$f" >/dev/null; done; fi
done
ls build/shots/*/
