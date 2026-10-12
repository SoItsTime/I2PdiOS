#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$root/.cache/i2pd.ipa}"
mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"

derived="$root/.cache/ReleaseDerivedData"
stage="$root/.cache/ipa-stage"
xcodebuild -project "$root/I2PdiOS.xcodeproj" -scheme I2PDApp \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build

rm -rf "$stage"
mkdir -p "$stage/Payload"
ditto "$derived/Build/Products/Release-iphoneos/I2PDApp.app" \
  "$stage/Payload/I2PDApp.app"
rm -f "$output"
(cd "$stage" && zip -qry -X "$output" Payload)
unzip -tq "$output"
printf 'Unsigned IPA: %s\n' "$output"
