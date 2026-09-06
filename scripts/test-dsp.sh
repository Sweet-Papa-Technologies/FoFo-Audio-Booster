#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror -I Sources/AudioDSP/include Sources/AudioDSP/AudioDSP.cpp Sources/AudioDSP/PluginBridge.cpp Tests/DSP/main.cpp -framework AudioToolbox -framework CoreAudio -o .build/tests/dsp-tests
.build/tests/dsp-tests
