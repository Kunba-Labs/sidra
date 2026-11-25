#!/usr/bin/env bash
# Development-signed builds of HEAD as install links on one page, on this Mac's Tailscale name (port 8443).
# iPhone and iPad share one build; Apple Vision Pro has its own. Publishing one keeps the other on the page.
# Only devices registered on the team can install. A Vision Pro registers when it is paired with Xcode once
# (Vision Pro: Settings > General > Remote Devices; Mac: Xcode > Window > Devices). Tailscale must be on
# while a device downloads.
#
#   tools/publish-ota.sh             build for iPhone and iPad, then publish
#   tools/publish-ota.sh vision      build for Vision Pro, then publish
#   tools/publish-ota.sh --no-build  rebuild the page from the last builds
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_ID=${ASC_KEY_ID:-H9PLG58DB9}
ISSUER=${ASC_ISSUER_ID:-d5f5385b-5e34-4d70-925d-0debd3a3e090}
KEY=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}
ROOT=${SIDRA_OTA_ROOT:-$PWD/build/ota}
SITE=$ROOT/site
LOCAL_PORT=18771
HTTPS_PORT=8443
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale

PLAT=ios; BUILD=1
for a in "$@"; do case $a in vision) PLAT=vision ;; ios) PLAT=ios ;; --no-build) BUILD=0 ;; esac; done

dd_of() { [[ $1 == vision ]] && echo "$ROOT/dd-vision" || echo "$ROOT/dd"; }
app_of() { [[ $1 == vision ]] && echo "$(dd_of vision)/Build/Products/Release-xros/Sidra.app" || echo "$(dd_of ios)/Build/Products/Release-iphoneos/Sidra.app"; }

HOST=$("$TS" status --json | python3 -c "import json,sys; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))")
BASE=https://$HOST:$HTTPS_PORT
mkdir -p "$SITE"

# A profile without the headset builds fine and then fails on it: no paired Vision Pro, no Vision Pro build.
if (( BUILD )) && [[ $PLAT == vision ]] && ! xcrun devicectl list devices 2>/dev/null | grep -q "Apple Vision Pro.*physical"; then
  echo "no Vision Pro paired with this Mac: pair it with Xcode first (Vision Pro: Settings > General > Remote Devices)"; exit 1
fi

if (( BUILD )); then
  dest='generic/platform=iOS'; [[ $PLAT == vision ]] && dest='generic/platform=visionOS'
  xcodegen generate >/dev/null
  echo "building $(git rev-parse --short HEAD) for ${PLAT}…"
  xcodebuild build -project Sidra.xcodeproj -scheme Sidra -configuration Release -destination "$dest" \
    -derivedDataPath "$(dd_of $PLAT)" -skipPackagePluginValidation -skipMacroValidation \
    -allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
    > "$ROOT/build-$PLAT.log" 2>&1 || { grep -E "error:" "$ROOT/build-$PLAT.log" | sort -u | head -20; echo "build failed, log: $ROOT/build-$PLAT.log"; exit 1; }

  # Package: the page's folder for this platform gets its .ipa, manifest and the commit it was built from.
  APP=$(app_of $PLAT); OUT=$SITE/$PLAT; COMMIT=$(git rev-parse --short HEAD)
  rm -rf "$OUT" "$ROOT/payload"; mkdir -p "$OUT" "$ROOT/payload/Payload"
  cp -cR "$APP" "$ROOT/payload/Payload/"
  (cd "$ROOT/payload" && zip -qry -1 "$OUT/Sidra.ipa" Payload)
  rm -rf "$ROOT/payload"
  echo "$COMMIT" > "$OUT/commit"; date '+%-d %b %H:%M' > "$OUT/date"
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")
  cat > "$OUT/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>$BASE/$PLAT/Sidra.ipa?$COMMIT</string></dict><dict><key>kind</key><string>display-image</string><key>url</key><string>$BASE/icon.png</string></dict><dict><key>kind</key><string>full-size-image</string><key>url</key><string>$BASE/icon-1024.png</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>nl.sadiq.sidra</string><key>bundle-version</key><string>$VERSION</string><key>kind</key><string>software</string><key>title</key><string>Sidra</string></dict>
</dict></array></dict></plist>
PLIST
fi

# The page: one card per build that exists.
cp design/icon/icon-180.png "$SITE/icon.png"
cp design/icon/icon-1024.png "$SITE/icon-1024.png"
card() {   # <folder> <title> <devices>
  [[ -f "$SITE/$1/Sidra.ipa" ]] || return 0
  local size; size=$(du -m "$SITE/$1/Sidra.ipa" | cut -f1)
  cat <<CARD
<section style="background:#12151a;border:1px solid rgba(255,255,255,.065);border-radius:14px;padding:20px 22px;margin:12px 0;text-align:left;display:flex;align-items:center;gap:16px">
<div style="flex:1"><h2 style="font-size:19px;margin:0 0 4px">$2</h2><p style="color:#828b98;margin:0;font-size:14px">$3. Build $(cat "$SITE/$1/commit"), $(cat "$SITE/$1/date"), $size MB</p></div>
<a style="background:#5ad6a0;color:#0c0e12;padding:12px 22px;border-radius:10px;font-weight:700;text-decoration:none" href="itms-services://?action=download-manifest&url=$BASE/$1/manifest.plist">Install</a></section>
CARD
}
{
  cat <<HEAD
<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Install Sidra</title><link rel=apple-touch-icon href=icon.png><link rel=icon href=icon.png>
<body style="background:#0c0e12;color:#d9dde3;font:17px -apple-system,sans-serif;margin:0;display:grid;place-items:center;min-height:100vh">
<main style="width:min(560px,92vw);text-align:center"><img src="icon.png" width=96 height=96 alt="" style="border-radius:22px;display:block;margin:0 auto 12px"><h1 style="font-size:28px;margin:0 0 6px">Sidra</h1><p style="color:#828b98;margin:0 0 8px">Private builds. Install the one for this device.</p>
HEAD
  card ios "iPhone and iPad" "One build for both"
  card vision "Apple Vision Pro" "visionOS"
  cat <<FOOT
<p style="color:#828b98;font-size:14px">Keep Tailscale on until the install finishes. Delete a TestFlight copy of Sidra first.</p></main>
FOOT
} > "$SITE/index.html"

# The iPad-only layout kept its build at the root; those links are gone now.
rm -f "$SITE/Sidra.ipa" "$SITE/manifest.plist"

pkill -f "http.server $LOCAL_PORT" 2>/dev/null || true
nohup python3 -m http.server "$LOCAL_PORT" --bind 127.0.0.1 --directory "$SITE" >"$ROOT/site.log" 2>&1 </dev/null &
disown
"$TS" serve --bg --https="$HTTPS_PORT" "http://127.0.0.1:$LOCAL_PORT" >/dev/null
echo "$BASE/"
