#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_root/dist/Keyboard Studio.app"
binary_path="$project_root/.build/release/KeyboardStudio"

swift build --package-path "$project_root" -c release --product KeyboardStudio

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_path" "$app_dir/Contents/MacOS/KeyboardStudio"
cp "$project_root/Assets/KeyboardStudio.icns" "$app_dir/Contents/Resources/KeyboardStudio.icns"

plutil -create xml1 "$app_dir/Contents/Info.plist"
plutil -insert CFBundleDisplayName -string "Keyboard Studio" "$app_dir/Contents/Info.plist"
plutil -insert CFBundleExecutable -string "KeyboardStudio" "$app_dir/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string "com.lucas.keyboardstudio" "$app_dir/Contents/Info.plist"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$app_dir/Contents/Info.plist"
plutil -insert CFBundleIconFile -string "KeyboardStudio" "$app_dir/Contents/Info.plist"
plutil -insert CFBundleName -string "Keyboard Studio" "$app_dir/Contents/Info.plist"
plutil -insert CFBundlePackageType -string "APPL" "$app_dir/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "0.5.0" "$app_dir/Contents/Info.plist"
plutil -insert CFBundleVersion -string "9" "$app_dir/Contents/Info.plist"
plutil -insert CFBundleURLTypes -json '[{"CFBundleURLName":"com.lucas.keyboardstudio.actions","CFBundleURLSchemes":["keyboardstudio"]}]' "$app_dir/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string "14.0" "$app_dir/Contents/Info.plist"
plutil -insert NSHumanReadableCopyright -string "Built for local SayoDevice customization" "$app_dir/Contents/Info.plist"

# Keep the local app's designated requirement stable across rebuilds. A plain
# ad-hoc signature defaults to a CDHash requirement, which changes with every
# binary and makes macOS treat an existing Input Monitoring grant as stale.
codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "com.lucas.keyboardstudio"' \
    "$app_dir"
echo "$app_dir"
