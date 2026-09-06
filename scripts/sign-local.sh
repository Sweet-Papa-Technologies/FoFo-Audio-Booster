#!/bin/bash
# Ad-hoc signing is only for local previews. Distribution uses Xcode export.
set -euo pipefail
app="${1:?Pass a development .app bundle}"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
if [[ -d "$sparkle" ]]; then
    for nested in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle/Versions/B/XPCServices/Downloader.xpc" "$sparkle/Versions/B/XPCServices/Installer.xpc"; do
        if [[ -e "$nested" ]]; then codesign --force --sign - "$nested"; fi
    done
    codesign --force --sign - "$sparkle"
fi
widget="$app/Contents/PlugIns/FoFoBoosterWidget.appex"
if [[ -d "$widget" ]]; then codesign --force --sign - "$widget"; fi
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
