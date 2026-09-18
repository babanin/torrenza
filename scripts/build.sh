#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodegen generate
xcodebuild -project Torrenza.xcodeproj -scheme Torrenza -configuration "${CONFIGURATION:-Release}" -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
printf 'App: %s/build/Build/Products/%s/Torrenza.app\n' "$PWD" "${CONFIGURATION:-Release}"
