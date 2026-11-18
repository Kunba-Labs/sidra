#!/usr/bin/env bash
# A demo build for a physical iPad, for App Review's screen recording: always in demo mode (made-up
# machine "devbox", GitLab and Theasa from fixtures, no network to real machines). It installs as a
# separate app, nl.sadiq.sidra.demo, so the real Sidra and its data stay as they are.
# It builds a snapshot of HEAD (uncommitted edits are left out) and adds it to the install page that
# build/ota/site serves (see sidra-full/tools/publish-ipad.sh) under /demo/.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_ID=H9PLG58DB9
ISSUER=d5f5385b-5e34-4d70-925d-0debd3a3e090
KEY=~/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8
BUNDLE=nl.sadiq.sidra.demo
ROOT=$PWD/build/ota-demo
SHA=$(git rev-parse --short HEAD)
SRC=$ROOT/src-$SHA
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale

mkdir -p "$SRC"
git archive HEAD | tar -x -C "$SRC"
(cd "$SRC" && xcodegen generate >/dev/null)

echo "building demo $SHA (log: $ROOT/build.log)"
xcodebuild build -project "$SRC/Sidra.xcodeproj" -scheme Sidra -configuration Debug \
  -destination generic/platform=iOS -derivedDataPath "$ROOT/dd" \
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
  PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE SIDRA_DEMO=YES ENABLE_USER_SCRIPT_SANDBOXING=NO \
  > "$ROOT/build.log" 2>&1 || { grep -E "error:|\*\* BUILD" "$ROOT/build.log" | head -20; exit 1; }

APP=$ROOT/dd/Build/Products/Debug-iphoneos/Sidra.app
[[ -d "$APP/Demo" ]] || { echo "the fixtures are missing from the app"; exit 1; }
SITE=$PWD/build/ota/site
[[ -f "$SITE/index.html" ]] || { echo "no install page: run sidra-full/tools/publish-ipad.sh first"; exit 1; }
HOST=$("$TS" status --json | python3 -c "import json,sys; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null || echo alexei.tailbca3e8.ts.net)
BASE=https://$HOST:8443

rm -rf "$SITE/demo" "$ROOT/payload" && mkdir -p "$SITE/demo" "$ROOT/payload/Payload"
cp -cR "$APP" "$ROOT/payload/Payload/"
(cd "$ROOT/payload" && zip -qry -1 "$SITE/demo/Sidra.ipa" Payload)
rm -rf "$ROOT/payload"
cat > "$SITE/demo/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>$BASE/demo/Sidra.ipa?$SHA</string></dict><dict><key>kind</key><string>display-image</string><key>url</key><string>$BASE/icon.png</string></dict><dict><key>kind</key><string>full-size-image</string><key>url</key><string>$BASE/icon-1024.png</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>$BUNDLE</string><key>bundle-version</key><string>1.0.0</string><key>kind</key><string>software</string><key>title</key><string>Sidra demo</string></dict>
</dict></array></dict></plist>
PLIST
sed -i '' '/demo\/manifest/d' "$SITE/index.html"   # the link from a previous demo build, on its own line
echo "<p style=\"position:fixed;bottom:24px;width:100%\"><a style=\"color:#5ad6a0\" href=\"itms-services://?action=download-manifest&url=$BASE/demo/manifest.plist\">Install the demo build ($SHA)</a></p>" >> "$SITE/index.html"
echo "$BASE/ (demo link under the Install button)"
