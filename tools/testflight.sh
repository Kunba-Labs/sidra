#!/usr/bin/env bash
# Archive, export and upload Sidra to TestFlight. 
#
#   tools/testflight.sh            bump build number, archive, export, upload
#   tools/testflight.sh --no-bump  reuse the current CURRENT_PROJECT_VERSION
#   tools/testflight.sh --vision   the Apple Vision Pro build (same target, visionOS); combine with --no-bump
#                                  to ship the build number the iOS upload just used. Testers: internal group "Me".
#
# Signing is automatic with the App Store Connect API key (no Apple ID in Xcode on this Mac).
set -euo pipefail
cd "$(dirname "$0")/.."

# Your App Store Connect API key: ASC_KEY_ID, ASC_ISSUER_ID, and the .p8 in ~/.appstoreconnect/private_keys/.
KEY_ID=${ASC_KEY_ID:?set ASC_KEY_ID}
ISSUER=${ASC_ISSUER_ID:?set ASC_ISSUER_ID}
KEY=${ASC_KEY_PATH:-~/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}
TEAM=${DEVELOPMENT_TEAM:-KF53B4S5HD}
OUT=build/testflight
mkdir -p "$OUT"

PLATFORM=iOS; ALTOOL=ios
for a in "$@"; do [[ $a == --vision ]] && { PLATFORM=visionOS; ALTOOL=visionos; OUT=build/testflight-vision; mkdir -p "$OUT"; }; done

if [[ " $* " != *" --no-bump "* ]]; then
  # The app's line is the first; the USB driver target keeps its own.
  line=$(grep -nE '^\s*CURRENT_PROJECT_VERSION:' project.yml | head -1 | cut -d: -f1)
  current=$(sed -n "${line}p" project.yml | awk '{print $2}')
  next=$((current + 1))
  sed -i "" "${line}s/^\([[:space:]]*CURRENT_PROJECT_VERSION:\) .*/\1 $next/" project.yml
  echo "build number $current -> $next"
fi
xcodegen generate >/dev/null

cat > "$OUT/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF

AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")

echo "archiving…"
xcodebuild archive -project Sidra.xcodeproj -scheme Sidra -configuration Release \
  -destination "generic/platform=$PLATFORM" -archivePath "$OUT/Sidra.xcarchive" \
  -skipPackagePluginValidation -skipMacroValidation "${AUTH[@]}" \
  2>&1 | grep -E 'error:|warning: .*(Sidra/|Packages/Sidra)|ARCHIVE (SUCCEEDED|FAILED)' | sort -u

echo "exporting…"
xcodebuild -exportArchive -archivePath "$OUT/Sidra.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT/export" "${AUTH[@]}" 2>&1 | grep -E 'error:|EXPORT (SUCCEEDED|FAILED)|Exported' | sort -u

IPA=$(ls "$OUT"/export/*.ipa | head -1)
echo "uploading ${IPA}…"
xcrun altool --upload-app -f "$IPA" -t $ALTOOL --apple-id "${ASC_APP_ID:-6832359499}" --apiKey "$KEY_ID" --apiIssuer "$ISSUER" 2>&1 | grep -E 'UPLOAD|error|Error|successfully' | head -5
echo "done. Build appears in App Store Connect after processing (5 to 15 minutes)."
