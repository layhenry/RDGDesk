#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
prefix="$PWD/.build/vendor/freerdp-prefix"
pkgconfig_alias_root="$(mktemp -d /private/tmp/rdc-freerdp-pkgconfig.XXXXXX)"
ln -s "$prefix" "$pkgconfig_alias_root/prefix"
trap 'rm -f "$pkgconfig_alias_root/prefix"; rmdir "$pkgconfig_alias_root"' EXIT
export PKG_CONFIG_PATH="$pkgconfig_alias_root/prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export DYLD_LIBRARY_PATH="$prefix/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
swift_build_arguments=()
if [[ "${RDC_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
  swift_build_arguments+=(--disable-sandbox)
fi
swift build "${swift_build_arguments[@]}"
