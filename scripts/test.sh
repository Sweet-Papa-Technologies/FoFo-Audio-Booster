#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache"
swift test --disable-sandbox
scripts/test-dsp.sh
scripts/test-bridge.sh
.build/debug/FoFoBooster --validate-effects
xcrun -sdk macosx metal -fmodules-cache-path="$PWD/.build/metal-cache" -c Sources/FoFoBooster/Resources/Visualizer.metal -o .build/Visualizer.air
python3 scripts/generate-project.py
plutil -lint Config/Info.plist Config/Widget-Info.plist Config/App.entitlements Config/Widget.entitlements FoFoBooster.xcodeproj/project.pbxproj
