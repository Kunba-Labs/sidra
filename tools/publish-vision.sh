#!/usr/bin/env bash
# A development-signed Apple Vision Pro build of HEAD, published as an install link on this Mac's Tailscale
# name (port 8444; the iPad's page keeps 8443). Only a headset registered on the team can install it:
# pair it once with Xcode (Vision Pro: Settings > General > Remote Devices; Mac: Xcode > Window > Devices),
# which registers it. Tailscale must be on while the headset downloads.
#
#   tools/publish-vision.sh            build, then publish
#   tools/publish-vision.sh --no-build publish the last build again
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_ID=${ASC_KEY_ID:-H9PLG58DB9}
ISSUER=${ASC_ISSUER_ID:-d5f5385b-5e34-4d70-925d-0debd3a3e090}
KEY=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}
ROOT=$PWD/build/ota-vision
APP=$ROOT/dd/Build/Products/Release-xros/Sidra.app
SITE=$ROOT/site
LOCAL_PORT=18772
HTTPS_PORT=8444
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale

if [[ "${1:-}" != "--no-build" ]]; then
  xcodegen generate >/dev/null
  echo "building $(git rev-parse --short HEAD) for Vision Pro…"
  xcodebuild build -project Sidra.xcodeproj -scheme Sidra -configuration Release -destination 'generic/platform=visionOS' \
    -derivedDataPath "$ROOT/dd" -skipPackagePluginValidation -skipMacroValidation \
    -allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
    > "$ROOT.log" 2>&1 || { grep -E "error:" "$ROOT.log" | sort -u | head -20; echo "build failed, log: $ROOT.log"; exit 1; }
  git rev-parse --short HEAD > "$ROOT/built-commit"
fi
[[ -d "$APP" ]] || { echo "no build yet: run without --no-build"; exit 1; }

HOST=$("$TS" status --json | python3 -c "import json,sys; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))")
BASE=https://$HOST:$HTTPS_PORT
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")
COMMIT=$(cat "$ROOT/built-commit" 2>/dev/null || echo unknown)

rm -rf "$SITE" "$ROOT/payload"
mkdir -p "$SITE" "$ROOT/payload/Payload"
cp -cR "$APP" "$ROOT/payload/Payload/"
(cd "$ROOT/payload" && zip -qry -1 "$SITE/Sidra.ipa" Payload)
rm -rf "$ROOT/payload"
cp design/icon/icon-180.png "$SITE/icon.png"
cp design/icon/icon-1024.png "$SITE/icon-1024.png"

cat > "$SITE/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>$BASE/Sidra.ipa?$COMMIT</string></dict><dict><key>kind</key><string>display-image</string><key>url</key><string>$BASE/icon.png</string></dict><dict><key>kind</key><string>full-size-image</string><key>url</key><string>$BASE/icon-1024.png</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>nl.sadiq.sidra</string><key>bundle-version</key><string>$VERSION</string><key>kind</key><string>software</string><key>title</key><string>Sidra</string></dict>
</dict></array></dict></plist>
PLIST

SIZE=$(du -m "$SITE/Sidra.ipa" | cut -f1)
cat > "$SITE/index.html" <<HTML
<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Install Sidra for Vision Pro</title><link rel=icon href=icon.png>
<body style="background:#0c0e12;color:#d9dde3;font:17px -apple-system,sans-serif;margin:0;display:grid;place-items:center;min-height:100vh;text-align:center">
<main><img src="icon.png" width=120 height=120 alt="" style="border-radius:60px;display:block;margin:0 auto 16px"><h1 style="font-size:28px;margin-top:0">Sidra for Vision Pro</h1><p style="color:#828b98">Private build $COMMIT, $SIZE MB</p>
<p><a style="display:inline-block;background:#5ad6a0;color:#0c0e12;padding:14px 28px;border-radius:12px;font-weight:700;text-decoration:none" href="itms-services://?action=download-manifest&url=$BASE/manifest.plist">Install</a></p>
<p style="color:#828b98;font-size:14px">Keep Tailscale on until the install finishes. A TestFlight copy of Sidra must be deleted first.</p></main>
HTML

pkill -f "http.server $LOCAL_PORT" 2>/dev/null || true
nohup python3 -m http.server "$LOCAL_PORT" --bind 127.0.0.1 --directory "$SITE" >"$ROOT/site.log" 2>&1 </dev/null &
disown
"$TS" serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$LOCAL_PORT" >/dev/null
echo "$BASE/"
