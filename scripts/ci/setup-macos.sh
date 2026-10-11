#!/bin/sh
# macOS graphics use Apple's system frameworks and embedded Metal source.
set -eu
cd "$(dirname "$0")/../.."
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'Run this setup on macOS.' >&2; exit 1; }
for tool in "${ODIN:-odin}" python3 xcrun; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'Missing build tool: %s\n' "$tool" >&2; exit 1; }
done
for tool in clang lipo otool codesign pkgbuild productbuild; do
    xcrun --find "$tool" >/dev/null
done
xcrun --sdk macosx --show-sdk-path >/dev/null
printf '%s\n' 'Apple SDK ready for native Metal/AppKit builds targeting macOS 13.'
