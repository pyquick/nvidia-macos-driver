#!/bin/bash
# sign_package.sh <pkgroot>: sign every Mach-O file and every kext/bundle in a staged driver package with
# CODESIGN_IDENTITY (default "-", the ad-hoc identity). Runs after finish_package.sh; refreshs the SHA256SUMS lines of the
# files its signatures changed, then verifies the tree. The kexts are signed too: a release that ships them should carry
# the project's own signature, not an ad-hoc one. Loading them still depends on the machine's AMFI setup.
set -euo pipefail
ROOT=${1:?usage: sign_package.sh <pkgroot>}
[ -d "$ROOT" ] || { echo "sign_package: $ROOT is not a directory" >&2; exit 2; }
ID=${CODESIGN_IDENTITY:--}
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

is_macho() {
  local magic
  magic=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$magic" in cffaedfe|cefaedfe|cafebabe|bebafeca|feedfacf) return 0;; esac
  return 1
}

sign_file() {
  local f=$1 ent="$TMP/entitlements.plist"
  is_macho "$f" || return 0
  rm -f "$ent"
  codesign -d --entitlements :- "$f" >"$ent" 2>/dev/null || true
  if [ -s "$ent" ]; then
    codesign --force --timestamp=none --sign "$ID" --entitlements "$ent" "$f" >/dev/null
  else
    codesign --force --timestamp=none --sign "$ID" "$f" >/dev/null
  fi
}

refresh_sum() {
  local rel=$1
  [ -f "$ROOT/SHA256SUMS" ] || return 0
  grep -qE "^[0-9a-f]{64}  (\./)?$rel$" "$ROOT/SHA256SUMS" || return 0
  bash "$HERE/sums_refresh.sh" "$ROOT" "$rel"
}

echo "sign_package: signing $ROOT with identity $ID"
# Inner Mach-O files first, including the main executable of each kext and bundle. find -depth visits a directory after
# its children, so the bundle seals below run over already-signed contents.
while IFS= read -r -d '' f; do
  sign_file "$f"
  refresh_sum "${f#"$ROOT/"}"
done < <(find "$ROOT" -depth -type f -print0)

while IFS= read -r -d '' b; do
  rel=${b#"$ROOT/"}
  codesign --force --timestamp=none --sign "$ID" "$b" >/dev/null
  codesign --verify --deep --strict "$b" >/dev/null
  # sealing a bundle rewrites CodeResources and may rewrite the main executable's signature
  while IFS= read -r -d '' f; do refresh_sum "${f#"$ROOT/"}"; done < <(find "$b" -type f -print0)
  refresh_sum "$rel/Contents/_CodeSignature/CodeResources"
done < <(find "$ROOT" -depth -type d \( -name '*.kext' -o -name '*.bundle' \) -print0)

# Verify every Mach-O file outside the already-checked bundles.
while IFS= read -r -d '' f; do
  is_macho "$f" || continue
  codesign -v "$f" >/dev/null 2>&1 || { echo "sign_package: $f is not signed" >&2; exit 1; }
done < <(find "$ROOT" -type f -print0)

if [ "${SIGN_PACKAGE_CHECK:-1}" = 1 ] && [ -x "$HERE/check_package.sh" ]; then
  bash "$HERE/check_package.sh" "$ROOT"
fi
echo "sign_package: $ROOT is signed and verified"
