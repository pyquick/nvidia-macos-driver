#!/bin/bash
set -euo pipefail

source_dir=$(cd "$(dirname "$0")" && pwd)
output=${1:?Usage: bash tools/ReleaseChecker/build.sh NEW_OUTPUT_DIRECTORY}
mkdir "$output"
output=$(cd "$output" && pwd)

app="$output/GeekAudio Driver Update.app"
binary="$app/Contents/MacOS/GeekAudioReleaseChecker"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
cp "$source_dir/Installer.sh" "$app/Contents/Resources/Installer.sh"
for localization in "$source_dir"/Resources/*.lproj; do
    plutil -lint "$localization"/*.strings
    cp -R "$localization" "$app/Contents/Resources/"
done

icon_work=$(mktemp -d "${TMPDIR:-/tmp}/geekaudio-icon.XXXXXX")
trap 'rm -r "$icon_work"' EXIT
iconset="$icon_work/AppIcon.iconset"
mkdir "$iconset"
sips -s format png "$source_dir/AppIcon.svg" --out "$icon_work/icon.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -Z "$size" "$icon_work/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -Z "$((size * 2))" "$icon_work/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

helper_hash=$(shasum -a 256 "$app/Contents/Resources/Installer.sh" | cut -d' ' -f1)
public_key=$(<"$source_dir/driver-public-key.txt")
[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]
cat > "$icon_work/InstallerPins.swift" <<EOF
enum InstallerPins {
    static let publicKey = "$public_key"
    static let helperSHA256 = "$helper_hash"
}
EOF
for arch in x86_64 arm64; do
    xcrun swiftc -swift-version 6 -O -target "$arch-apple-macosx15.0" \
        "$source_dir/ReleaseCheckerApp.swift" "$source_dir/ReleaseFeed.swift" "$source_dir/InstallPlan.swift" \
        "$source_dir/DriverInstaller.swift" "$icon_work/InstallerPins.swift" \
        -o "$output/$arch"
done
xcrun lipo -create "$output/x86_64" "$output/arm64" -output "$binary"
xcrun lipo "$binary" -verify_arch x86_64 arm64
unlink "$output/x86_64"
unlink "$output/arm64"

codesign --force --sign "${RELEASE_CHECKER_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict --deep "$app"
zip="$output/GeekAudio-ReleaseChecker-macOS.zip"
ditto -c -k --keepParent "$app" "$zip"
(cd "$output" && shasum -a 256 "$(basename "$zip")" > SHA256SUMS.txt)
printf 'Built %s\n' "$app"
