#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool keychain profile}"
xcodegen generate
xcodebuild -project Torrenza.xcodeproj -scheme Torrenza -configuration Release -derivedDataPath build DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" CODE_SIGN_STYLE=Manual build
app_path="$PWD/build/Build/Products/Release/Torrenza.app"
mkdir -p artifacts
codesign --verify --deep --strict "$app_path"
ditto -c -k --keepParent "$app_path" artifacts/Torrenza-notarization.zip
xcrun notarytool submit artifacts/Torrenza-notarization.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
ditto -c -k --keepParent "$app_path" artifacts/Torrenza.zip
shasum -a 256 artifacts/Torrenza.zip > artifacts/Torrenza.zip.sha256
