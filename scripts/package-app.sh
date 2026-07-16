#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

create_dmg=0
if [[ "${1:-}" == "--dmg" ]]; then
  create_dmg=1
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--dmg]" >&2
  exit 2
fi

prefix="$PWD/.build/vendor/freerdp-prefix"
if [[ ! -f "$prefix/lib/libfreerdp3.3.dylib" ]]; then
  echo "FreeRDP is missing; run ./scripts/bootstrap-freerdp.sh first." >&2
  exit 1
fi

pkgconfig_alias_root="$(mktemp -d /private/tmp/rdc-freerdp-pkgconfig.XXXXXX)"
ln -s "$prefix" "$pkgconfig_alias_root/prefix"
cleanup() {
  rm -f "$pkgconfig_alias_root/prefix"
  rmdir "$pkgconfig_alias_root"
}
trap cleanup EXIT

export PKG_CONFIG_PATH="$pkgconfig_alias_root/prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export DYLD_LIBRARY_PATH="$prefix/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/rdc-clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-/private/tmp/rdc-swiftpm-cache}"
swift_arguments=(build -c release)
if [[ "${RDC_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
  swift_arguments+=(--disable-sandbox)
fi
swift "${swift_arguments[@]}"

app="$PWD/dist/Rdc.app"
frameworks="$app/Contents/Frameworks"
macos="$app/Contents/MacOS"
rm -rf "$app"
mkdir -p "$frameworks" "$macos"
cp packaging/Info.plist "$app/Contents/Info.plist"
cp .build/release/Rdc "$macos/Rdc"

copy_dependency() {
  local dependency="$1"
  local source=""
  case "$dependency" in
    @rpath/*)
      source="$prefix/lib/${dependency#@rpath/}"
      ;;
    /opt/homebrew/*|/usr/local/*)
      source="$dependency"
      ;;
    *)
      return
      ;;
  esac
  if [[ -L "$source" ]]; then
    source="$(cd "$(dirname "$source")" && pwd)/$(readlink "$source")"
  fi
  [[ -f "$source" ]] || return
  local destination="$frameworks/$(basename "$dependency")"
  if [[ ! -f "$destination" ]]; then
    cp "$source" "$destination"
  fi
}

scan_dependencies() {
  local binary="$1"
  otool -L "$binary" | tail -n +2 | awk '{ print $1 }'
}

while IFS= read -r dependency; do
  copy_dependency "$dependency"
done < <(scan_dependencies "$macos/Rdc")

changed=1
while [[ $changed -eq 1 ]]; do
  changed=0
  while IFS= read -r library; do
    while IFS= read -r dependency; do
      before="$(find "$frameworks" -type f | wc -l | tr -d ' ')"
      copy_dependency "$dependency"
      after="$(find "$frameworks" -type f | wc -l | tr -d ' ')"
      if [[ "$after" -gt "$before" ]]; then changed=1; fi
    done < <(scan_dependencies "$library")
  done < <(find "$frameworks" -type f -name '*.dylib' -print)
done

install_name_tool -add_rpath @executable_path/../Frameworks "$macos/Rdc" 2>/dev/null || true
while IFS= read -r binary; do
  if [[ "$binary" == *.dylib ]]; then
    install_name_tool -id "@rpath/$(basename "$binary")" "$binary"
  fi
  while IFS= read -r dependency; do
    case "$dependency" in
      /opt/homebrew/*|/usr/local/*)
        install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$binary"
        ;;
    esac
  done < <(scan_dependencies "$binary")
done < <(find "$macos" "$frameworks" -type f -print)

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

if [[ $create_dmg -eq 1 ]]; then
  rm -f "$PWD/dist/Rdc.dmg"
  hdiutil create -volname Rdc -srcfolder "$app" -ov -format UDZO "$PWD/dist/Rdc.dmg"
fi

echo "$app"
if [[ $create_dmg -eq 1 ]]; then echo "$PWD/dist/Rdc.dmg"; fi
