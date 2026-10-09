#!/bin/sh
# Universal runtime dependencies for both macOS 13 desktop architectures.
# Homebrew supplies build tools only; its runtime bottles can require newer OSes.
set -eu
umask 022
cd "$(dirname "$0")/../.."
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'Run this setup on macOS.' >&2; exit 1; }
brew install cmake shaderc
for tool in cmake curl shasum tar python3 xcrun; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'Missing build tool: %s\n' "$tool" >&2; exit 1; }
done
runtime=$(pwd)/build/toolchains/macos
mkdir -p "$runtime/licenses"
stage=$(mktemp -d "$runtime/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
fetch() {
    curl --fail --location --retry 3 "$1" --output "$2"
    printf '%s  %s\n' "$3" "$2" | shasum -a 256 -c -
}
# The FreeType project publishes this source archive and checksum:
# https://sourceforge.net/projects/freetype/files/freetype2/2.13.3/
fetch https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz \
    "$stage/freetype.tar.xz" 0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289
tar -xf "$stage/freetype.tar.xz" -C "$stage"
export MACOSX_DEPLOYMENT_TARGET=13.0
cmake -S "$stage/freetype-2.13.3" -B "$stage/freetype-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$runtime/freetype" \
    '-DCMAKE_OSX_ARCHITECTURES=x86_64;arm64' -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=ON \
    -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
cmake --build "$stage/freetype-build" --parallel "$(sysctl -n hw.ncpu)"
cmake --install "$stage/freetype-build"
cp "$stage/freetype-2.13.3/docs/FTL.TXT" "$runtime/licenses/FreeType-FTL.txt"
cp "$stage/freetype-2.13.3/docs/GPLv2.TXT" "$runtime/licenses/FreeType-GPLv2.txt"
# Official universal release, both slices verified to target macOS 12.0.
# Digest is published in the release's GitHub API asset metadata:
# https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2
fetch https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar \
    "$stage/MoltenVK-macos.tar" f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e
tar -xf "$stage/MoltenVK-macos.tar" -C "$stage"
mkdir -p "$runtime/moltenvk"
cp "$stage/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$runtime/moltenvk/"
cp "$stage/MoltenVK/LICENSE" "$runtime/licenses/MoltenVK.txt"
for library in "$runtime/freetype/lib/libfreetype.dylib" "$runtime/moltenvk/libMoltenVK.dylib"; do
    xcrun lipo -verify_arch x86_64 arm64 "$library"
done
# App packaging also checks every bundled library's minimum deployment target
# and non-system imports, then thins the universal libraries for each installer.
python3 - "$runtime" "${GITHUB_ENV:-}" <<'PY'
import pathlib, shlex, sys
runtime = pathlib.Path(sys.argv[1])
environment = {
    'FREETYPE_LIBRARY': str(runtime / 'freetype/lib/libfreetype.dylib'),
    'MOLTENVK_LIBRARY': str(runtime / 'moltenvk/libMoltenVK.dylib'),
    'THIRD_PARTY_LICENSE_DIR': str(runtime / 'licenses'),
}
(runtime / 'env.sh').write_text(''.join(f'export {key}={shlex.quote(value)}\n' for key, value in environment.items()))
if sys.argv[2]:
    with open(sys.argv[2], 'a') as output:
        for key, value in environment.items():
            output.write(f'{key}={value}\n')
PY
printf 'Universal macOS 13 runtime libraries ready; local builds: . build/toolchains/macos/env.sh\n'
