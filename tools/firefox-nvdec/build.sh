#!/bin/bash
set -euo pipefail

source_dir=$(cd "$(dirname "$0")" && pwd)
payload=${1:?Usage: bash tools/firefox-nvdec/build.sh OVERLAY_PAYLOAD_DIRECTORY}
codec_dir="$payload/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS"
mkdir -p "$codec_dir" "$payload/extras"
xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -O2 -Wall -Werror -dynamiclib \
    -Wl,-install_name,@rpath/libnvencvt-loader.dylib "$source_dir/nvencvt-loader.c" \
    -o "$codec_dir/libnvencvt-loader.dylib"
codesign --force --sign - "$codec_dir/libnvencvt-loader.dylib"
codesign --verify --strict "$codec_dir/libnvencvt-loader.dylib"
install -m 755 "$source_dir/firefox-nvdec.sh" "$payload/extras/firefox-nvdec.sh"
