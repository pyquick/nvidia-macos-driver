#!/bin/sh
# Optional launcher for Firefox VP9/AV1 decoding. Run after installing the driver.
loader=/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/libnvencvt-loader.dylib
if [ ! -r "$loader" ]; then
    echo "请先安装包含 Firefox 注入工具的 GeekAudio 完整驱动包。" >&2
    exit 1
fi
if /usr/bin/pgrep -x firefox >/dev/null; then
    echo "请完全退出 Firefox 后再运行此脚本。" >&2
    exit 1
fi
exec /usr/bin/open -a Firefox --env DYLD_INSERT_LIBRARIES="$loader" \
    --env NVENCVT_INJECT_ONLY=plugin-container --env NVENCVT_INJECT_DECODERS_ONLY=1 "$@"
