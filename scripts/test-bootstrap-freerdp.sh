#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD/.build/vendor"
source_dir="$root/src/FreeRDP"
prefix="$root/freerdp-prefix"

test_pkgconfig_from_other_cwd() {
  local includedir libdir
  includedir="$(cd /private/tmp && PKG_CONFIG_PATH="$prefix/lib/pkgconfig" pkg-config --variable=includedir freerdp3)"
  libdir="$(cd /private/tmp && PKG_CONFIG_PATH="$prefix/lib/pkgconfig" pkg-config --variable=libdir freerdp3)"
  includedir="${includedir//\\ / }"
  libdir="${libdir//\\ / }"

  (cd /private/tmp && test -f "$includedir/freerdp/version.h") || {
    echo "pkg-config includedir does not resolve from /private/tmp: $includedir"
    return 1
  }
  (cd /private/tmp && test -f "$libdir/libfreerdp3.dylib") || {
    echo "pkg-config libdir does not resolve from /private/tmp: $libdir"
    return 1
  }
}

test_dirty_source_is_rejected() {
  local tracked_file backup output rc
  tracked_file="$source_dir/README.md"
  backup="$(mktemp)"

  test -z "$(git -C "$source_dir" status --porcelain --untracked-files=no)" || {
    echo "vendor checkout must be clean before dirty-source regression"
    return 1
  }

  cp "$tracked_file" "$backup"
  cleanup_dirty_source_test() {
    trap - RETURN INT TERM
    cp "$backup" "$tracked_file"
    rm -f "$backup"
  }
  trap cleanup_dirty_source_test RETURN
  trap 'cleanup_dirty_source_test; exit 130' INT
  trap 'cleanup_dirty_source_test; exit 143' TERM
  printf '\n' >> "$tracked_file"

  set +e
  output="$(./scripts/bootstrap-freerdp.sh 2>&1)"
  rc=$?
  set -e

  test "$rc" -ne 0 || {
    echo "bootstrap accepted a dirty tracked FreeRDP checkout"
    return 1
  }
  [[ "$output" == *"tracked modifications"* ]] || {
    echo "bootstrap did not explain dirty tracked FreeRDP checkout"
    return 1
  }
}

case "${1:-all}" in
  pkgconfig)
    test_pkgconfig_from_other_cwd
    ;;
  dirty)
    test_dirty_source_is_rejected
    ;;
  all)
    test_pkgconfig_from_other_cwd
    test_dirty_source_is_rejected
    ;;
  *)
    echo "usage: $0 [pkgconfig|dirty|all]" >&2
    exit 2
    ;;
esac
