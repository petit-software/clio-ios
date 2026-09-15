#!/bin/sh
# Archive Clio in Release, export an .ipa for App Store Connect, and
# upload it when an API key is in the environment. See docs/plan.md.
#
#   scripts/testflight.sh            # archive + export to .build/testflight/Clio.ipa
#   ASC_KEY_ID=… ASC_ISSUER_ID=… scripts/testflight.sh   # …and upload
set -eu
cd "$(dirname "$0")/.."
out=.build/testflight
archive="$out/Clio.xcarchive"
rm -rf "$out" && mkdir -p "$out"

xcodegen generate >/dev/null
xcodebuild -project Clio.xcodeproj -scheme Clio -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -allowProvisioningUpdates archive | grep -E 'error:|warning: .*[Ss]ign|ARCHIVE' || true
[ -d "$archive" ] || { echo "no archive"; exit 1; }

xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$out" \
  -allowProvisioningUpdates | grep -E 'error:|EXPORT' || true
ipa=$(ls "$out"/*.ipa 2>/dev/null | head -1)
[ -n "$ipa" ] || { echo "no .ipa"; exit 1; }
echo "exported $ipa"

if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  xcrun altool --upload-app --type ios --file "$ipa" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
else
  echo "no ASC_KEY_ID/ASC_ISSUER_ID: upload $ipa with Transporter or the Organizer"
fi
