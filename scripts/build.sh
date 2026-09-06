#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache"
configuration="${CONFIGURATION:-Release}"
if [[ "${1:-}" == "--standalone" ]]; then
    swift build --disable-sandbox -c release
    app="$PWD/build/FoFoBooster.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp .build/release/FoFoBooster "$app/Contents/MacOS/"
    cp Config/Info.plist "$app/Contents/Info.plist"
    cp Sources/FoFoBooster/Resources/AppIcon.icns "$app/Contents/Resources/"
    ditto .build/release/FoFoBooster_FoFoBooster.bundle "$app/Contents/Resources/FoFoBooster_FoFoBooster.bundle"
    if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
        codesign --force --options runtime --timestamp --entitlements Config/App.entitlements --sign "$SIGNING_IDENTITY" "$app"
    else
        codesign --force --sign - "$app"
    fi
    echo "Built $app (standalone developer build; widget and updater require the Xcode build)"
else
    python3 scripts/generate-project.py
    signing=(CODE_SIGNING_ALLOWED=NO)
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then signing=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"); fi
    xcodebuild -project FoFoBooster.xcodeproj -scheme FoFoBooster -configuration "$configuration" -derivedDataPath .build/xcode -clonedSourcePackagesDirPath .build/packages "${signing[@]}" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
    mkdir -p build
    ditto ".build/xcode/Build/Products/$configuration/FoFoBooster.app" build/FoFoBooster.app
    if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then python3 scripts/sign-app.py build/FoFoBooster.app; fi
    echo "Built $PWD/build/FoFoBooster.app"
fi
