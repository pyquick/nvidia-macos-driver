#!/usr/bin/env python3
"""Apply the GeekAudio 2.9 overlay to the exact official driver archive."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


BASE_SHA256 = 'b624bf07c78cea03043e096383d5c8b01e4fb2c804a6ba377a4e66a2566422ef'
VULKAN_LINKS = {
    Path('Library/GPUBundles/nvmtl/libvulkan.dylib'): 'libvulkan.1.dylib',
    Path('Library/GPUBundles/nvmtl/libvulkan.1.dylib'): 'libvulkan.1.4.362.dylib',
}
PLUGIN = Path('Library/GPUBundles/NVMTLDriver.bundle')
NVRM = Path('Library/Extensions/NVRM.kext')
FRAMEBUFFER = Path('Library/Extensions/NVRMFB.kext')
PAYLOAD = {
    FRAMEBUFFER / 'Contents/MacOS/NVRMFB',
    FRAMEBUFFER / 'Contents/Info.plist',
    FRAMEBUFFER / 'Contents/_CodeSignature/CodeResources',
    PLUGIN / 'Contents/MacOS/NVMTLDriver',
    PLUGIN / 'Contents/MacOS/libnvencvt.dylib',
    PLUGIN / 'Contents/MacOS/libnvencvt-loader.dylib',
    Path('extras/firefox-nvdec.sh'),
    Path('licenses/mickys-nvenc-LICENSE.txt'),
}


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def files(root, allowed_links=None):
    names = set()
    for path in root.rglob('*'):
        if path.is_symlink():
            expected = (allowed_links or {}).get(path.relative_to(root))
            if expected is None or str(path.readlink()) != expected or not path.is_file():
                raise ValueError(f'Unexpected symlink: {path}')
            continue
        if path.is_file():
            names.add(path.relative_to(root))
        elif not path.is_dir():
            raise ValueError(f'Unexpected file type: {path}')
    return names


def assemble(archive, output):
    overlay = Path(__file__).resolve().parent
    identity = json.loads((overlay / 'RELEASE-IDENTITY.json').read_text())
    payload = overlay / 'payload'
    if digest(archive) != BASE_SHA256:
        raise ValueError('Download the official v2.9 archive and verify its SHA-256.')
    if output.exists() or output.is_symlink():
        raise ValueError('Choose a new output path.')
    if files(payload) != PAYLOAD or identity['payload_sha256'] != {
        name.as_posix(): digest(payload / name) for name in PAYLOAD
    }:
        raise ValueError('Overlay payload or digest mismatch.')
    with tempfile.TemporaryDirectory(prefix='.geekaudio-assemble-', dir=output.parent) as staging:
        run('/usr/bin/tar', '-xzf', str(archive), '-C', staging)
        root = Path(staging) / 'pkgroot'
        files(root, VULKAN_LINKS)
        run('/usr/bin/shasum', '-a', '256', '--strict', '-c', '--quiet', 'SHA256SUMS', cwd=root)
        for name in sorted(PAYLOAD):
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(payload / name, root / name)
        # The base CFBundleVersion stays compatible with the other kexts. The checker reads the overlay tag separately.
        nvrm_plist = root / NVRM / 'Contents/Info.plist'
        nvrm_info = plistlib.loads(nvrm_plist.read_bytes())
        nvrm_info['GeekAudioReleaseTag'] = identity['release']
        nvrm_plist.write_bytes(plistlib.dumps(nvrm_info, sort_keys=False))
        run('/usr/bin/xattr', '-cr', str(root))
        for name in ('libnvencvt.dylib', 'libnvencvt-loader.dylib'):
            run('/usr/bin/codesign', '--force', '--sign', '-', str(root / PLUGIN / 'Contents/MacOS' / name))
        for path in (NVRM, PLUGIN):
            run('/usr/bin/codesign', '--force', '--sign', '-', str(root / path))
        for path in (NVRM, FRAMEBUFFER, PLUGIN):
            run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(root / path))
        original = root / 'BASELINE-IDENTITY.json'
        shutil.copyfile(original, root / 'UPSTREAM-BASELINE-IDENTITY.json')
        identity['assembled_sha256'] = {str(name): digest(root / name) for name in sorted(PAYLOAD)}
        original.write_text(json.dumps(identity, ensure_ascii=False, indent=2) + '\n')
        checksums = root / 'SHA256SUMS'
        checksums.write_text(''.join(
            f'{digest(root / name)}  {name.as_posix()}\n'
            for name in sorted(files(root, VULKAN_LINKS)) if name != Path('SHA256SUMS')
        ))
        run('/usr/bin/shasum', '-a', '256', '--strict', '-c', '--quiet', 'SHA256SUMS', cwd=root)
        run('/bin/bash', str(root / 'sums_complete.sh'), str(root))
        root.rename(output)
    print(f'Assembled and verified {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('official_archive', type=Path)
    parser.add_argument('output_directory', type=Path)
    args = parser.parse_args()
    try:
        assemble(args.official_archive.resolve(strict=True), args.output_directory.absolute())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Assembly stopped: {error}\n')
