#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror -I Sources/AudioDSP/include Sources/AudioDSP/PluginBridge.cpp Tests/Bridge/main.cpp -framework AudioToolbox -framework CoreAudio -o .build/tests/bridge-tests
.build/tests/bridge-tests
