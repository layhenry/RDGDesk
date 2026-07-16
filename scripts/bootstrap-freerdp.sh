#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD/.build/vendor"
source_dir="$root/src/FreeRDP"
build_dir="$root/build/freerdp"
prefix="$root/freerdp-prefix"
ref="3.26.0"

for tool in git cmake ninja pkg-config; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool"; exit 1; }
done

if [[ ! -d "$source_dir/.git" ]]; then
  git clone --depth 1 --branch "$ref" https://github.com/FreeRDP/FreeRDP.git "$source_dir"
fi

test "$(git -C "$source_dir" describe --tags --exact-match)" = "$ref"
if ! git -C "$source_dir" diff --quiet --ignore-submodules -- ||
   ! git -C "$source_dir" diff --cached --quiet --ignore-submodules --; then
  echo "FreeRDP source checkout has tracked modifications: $source_dir" >&2
  exit 1
fi
openssl_root="$(/opt/homebrew/bin/brew --prefix openssl@3)"

cmake -S "$source_dir" -B "$build_dir" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DOPENSSL_ROOT_DIR="$openssl_root" \
  -DWITH_CLIENT=ON -DWITH_SERVER=OFF \
  -DWITH_SDL_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF \
  -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_CUPS=OFF \
  -DWITH_PCSC=OFF -DWITH_USB_REDIRECTION=OFF -DCHANNEL_URBDRC=OFF \
  -DWITH_MANPAGES=OFF -DWITH_SAMPLE=OFF -DWITH_TESTS=OFF
cmake --build "$build_dir"
cmake --install "$build_dir"
PKG_CONFIG_PATH="$prefix/lib/pkgconfig" pkg-config --atleast-version=3.26.0 freerdp3
