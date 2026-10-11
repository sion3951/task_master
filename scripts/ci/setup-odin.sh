#!/bin/sh
# CI compilers: immutable, checksum-verified releases per build platform.
set -eu
release=dev-2026-10
case "$(uname -s):$(uname -m)" in
    Linux:x86_64)
        platform=linux-amd64
        checksum=c3c8b095621fd0c75f7f73e3a0829f1b4d45324225f20ba11ed8dc4da310a8ab ;;
    Linux:aarch64|Linux:arm64)
        platform=linux-arm64
        checksum=99c43e9670a285901d6cfee5f56197b74c7d6f7c537b35ecba0c1b44ac2e4df8 ;;
    Darwin:arm64)
        # September avoids October's Objective-C code-generation regression:
        # https://github.com/odin-lang/Odin/issues/7793
        release=dev-2026-09
        platform=macos-arm64
        checksum=3e6cbc1f247d8d14fe02c3151272d0a5b8d6d77acb7219f5b62914e4d95d97f7 ;;
    Darwin:x86_64)
        release=dev-2026-09
        platform=macos-amd64
        checksum=c1f6d6320218ec7e511093a87bdd599b72a8417a9d2a00de2c9691103562165b ;;
    *) printf '%s\n' 'This CI compiler setup supports Linux and macOS x64/ARM64.' >&2; exit 1 ;;
esac
destination=build/toolchains/odin
mkdir -p "$destination"
archive=$destination/compiler.tar.gz
curl --fail --location --retry 3 \
    "https://github.com/odin-lang/Odin/releases/download/$release/odin-$platform-$release.tar.gz" \
    --output "$archive"
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$archive" | cut -d ' ' -f 1)
else
    actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
fi
[ "$actual" = "$checksum" ] || { printf '%s\n' 'Odin compiler checksum mismatch.' >&2; exit 1; }
tar -xzf "$archive" --strip-components=1 -C "$destination"
rm "$archive"
"$destination/odin" version
if [ "$(uname -s)" = Linux ]; then
    # The official compiler archive ships stb sources, not the native static
    # libraries imported by screenshot/image support in the desktop.
    sh "$destination/vendor/stb/src/build_stb.sh" unix
fi
if [ -n "${GITHUB_PATH:-}" ]; then
    (cd "$destination" && pwd) >> "$GITHUB_PATH"
fi
