#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C COPYFILE_DISABLE=1
unset PERL5OPT PERL5LIB
umask 077

mode=$1 archive=$2 archive_sha=$3 tag=$4
if [ "$mode" = install ]; then
    [ "$(id -u)" = 0 ]
    work=$(mktemp -d /private/var/tmp/geekaudio-install.XXXXXX)
    trap 'rm -r "$work"' EXIT
else
    [ "$mode" = prepare ]
    work=$5
    mkdir -m 700 "$work"
fi

echo '== Verify complete driver archive'
[ -f "$archive" ] && [ ! -L "$archive" ]
cp -P "$archive" "$work/driver.tar.gz"
[ ! -L "$work/driver.tar.gz" ]
(cd "$work" && printf '%s  driver.tar.gz\n' "$archive_sha" | shasum -a 256 --strict --quiet -c -)

echo '== Extract and verify installer'
tar -xzf "$work/driver.tar.gz" -C "$work"
root="$work/pkgroot"
cd "$root"
[ -x ./install.sh ]
[ "$(plutil -extract release raw -o - BASELINE-IDENTITY.json)" = "$tag" ]
[ "$(plutil -extract GeekAudioReleaseTag raw -o - Library/Extensions/NVRM.kext/Contents/Info.plist)" = "$tag" ]
shasum -a 256 --strict --quiet -c SHA256SUMS
/bin/bash ./sums_complete.sh "$root"
for bundle in Library/GPUBundles/NVMTLDriver.bundle Library/Extensions/{NVRM,NVRMFB}.kext; do
    codesign --verify --deep --strict "$bundle"
done

if [ "$mode" = install ]; then
    /bin/bash ./install.sh
else
    echo 'CHECK PASS (prepared package only)'
fi
