#!/bin/sh
# Build Intel/Apple-silicon bundles containing only their native collector.
set -eu
fail() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: sh scripts/build-macos.sh [--arch native|amd64|arm64|all] [--collector-only]
                               [--development] [--version VERSION]
Default: build both architectures; each bundle embeds only its own collector.
--collector-only builds the requested native macOS collector payloads only.
--development is accepted for compatibility; all builds use local payloads only.
Environment: ODIN, SIGN_IDENTITY (default ad-hoc).
 Graphics use the system AppKit, Metal, CoreText and CoreGraphics frameworks.
 No third-party graphics libraries or shader compiler are required.
 INSTALLER_SIGN_IDENTITY signs the .pkg with a Developer ID Installer certificate.
 Full builds also create build/packages/task_master-<version>-<arch>.pkg installers.
USAGE
}
architectures='amd64 arm64'
collector_only=false
version=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --collector-only) collector_only=true; shift ;;
        --development) shift ;;
        --arch)
            [ "$#" -ge 2 ] || fail '--arch needs a value'
            case "$2" in
                native) case "$(uname -m)" in arm64) architectures=arm64 ;; x86_64) architectures=amd64 ;; *) fail 'Unsupported Mac architecture.' ;; esac ;;
                amd64|arm64) architectures=$2 ;;
                all) architectures='amd64 arm64' ;;
                *) fail "Unsupported architecture: $2" ;;
            esac
            shift 2 ;;
        # Accepted for existing build callers; foreign payloads are never imported.
        --linux-dir|--windows-dir|--mac-dir) [ "$#" -ge 2 ] || fail "$1 needs a directory"; shift 2 ;;
        --version) [ "$#" -ge 2 ] || fail '--version needs a value'; version=$2; shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail 'Build and sign macOS packages on a Mac with Xcode Command Line Tools.'
[ -f telemetry.odin ] && [ -f shaders/ui.metal ] || fail 'Run this script from the repository root.'
odin=${ODIN:-odin}
# Prefer the compiler provisioned by the documented, checksum-verified setup.
if [ -z "${ODIN:-}" ] && [ -x build/toolchains/odin/odin ]; then odin=build/toolchains/odin/odin; fi
export ODIN="$odin"
for tool in "$odin" python3 xcrun; do command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"; done
for tool in clang lipo otool codesign; do xcrun --find "$tool" >/dev/null || fail "Xcode tool not found: $tool"; done
xcrun --sdk macosx --show-sdk-path >/dev/null
export MACOSX_DEPLOYMENT_TARGET=13.0
[ -n "$version" ] || version=${PACKAGE_VERSION:-$(cat VERSION)}
mkdir -p build
stage=$(mktemp -d build/macos-stage.XXXXXX)
trap 'rm -rf "$stage"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$stage/collector-src"
cp telemetry*.odin remote_protocol.odin collector/*.odin "$stage/collector-src/"
for target_arch in $architectures; do
    destination=build/task_master-collector-darwin-$target_arch
    "$odin" build "$stage/collector-src" "-target:darwin_$target_arch" -minimum-os-version:13.0 \
        "-out:$stage/collector-$target_arch" -o:speed -vet -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536 "-define:TASK_MASTER_VERSION=$version"
    xcrun codesign --force --sign "${SIGN_IDENTITY:--}" "$stage/collector-$target_arch"
    chmod 755 "$stage/collector-$target_arch"
    mv "$stage/collector-$target_arch" "$destination"
    printf 'Ready: %s\n' "$destination"
done
$collector_only && exit 0
numeric_version=$(python3 - "$version" <<'PY'
import re, sys
match = re.fullmatch(r'(\d+(?:\.\d+){0,3})(?:[-+~][0-9A-Za-z.+~\-]+)?', sys.argv[1])
if not match:
    raise SystemExit('Version must have one to four numeric components, optionally followed by release metadata.')
print(match[1])
PY
)
for target_arch in $architectures; do
    case "$target_arch" in
        amd64) apple_arch=x86_64 ;;
        arm64) apple_arch=arm64 ;;
    esac
    output=build/macos-$target_arch
    bundle=$stage/$target_arch/task_master.app
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/licenses"
    set -- "$odin" build . "-target:darwin_$target_arch" -minimum-os-version:13.0 \
        "-out:$bundle/Contents/MacOS/task_master" -o:speed -no-bounds-check -vet \
        -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536 \
        "-define:TASK_MASTER_VERSION=$version"
    define=$(printf 'TASK_MASTER_COLLECTOR_DARWIN_%s' "$target_arch" | tr '[:lower:]' '[:upper:]')
    set -- "$@" "-define:$define=build/task_master-collector-darwin-$target_arch"
    "$@"
    cp "build/task_master-collector-darwin-$target_arch" "$bundle/Contents/MacOS/task_master-collector"
    "$odin" build updater_helper "-target:darwin_$target_arch" -minimum-os-version:13.0 \
        "-out:$bundle/Contents/MacOS/task_master-update-helper" -o:speed -vet \
        -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536 "-define:TASK_MASTER_VERSION=$version"
    install -m 644 scripts/update-install-unix.sh "$bundle/Contents/Resources/update-install.sh"
    # Native Apple frameworks are supplied by macOS. Reject accidental external
    # dependencies and deployment targets newer than the macOS 13 baseline.
    python3 scripts/validate-macos-bundle.py "$bundle" "$apple_arch"
    cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.task-master.desktop</string>
<key>CFBundleName</key><string>task_master</string>
<key>CFBundleExecutable</key><string>task_master</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    python3 - "$bundle/Contents/Info.plist" "$numeric_version" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info['CFBundleShortVersionString'] = sys.argv[2]
info['CFBundleVersion'] = sys.argv[2]
path.write_bytes(plistlib.dumps(info))
PY
    cp assets/FONT-LICENSE.txt "$bundle/Contents/Resources/licenses/"
    xcrun codesign --force --sign "${SIGN_IDENTITY:--}" "$bundle/Contents/MacOS/task_master-collector"
    xcrun codesign --force --sign "${SIGN_IDENTITY:--}" "$bundle/Contents/MacOS/task_master-update-helper"
    xcrun codesign --force --sign "${SIGN_IDENTITY:--}" "$bundle"
    xcrun codesign --verify --strict "$bundle"
    mkdir -p "$output"
    rm -rf "$output/task_master.app"
    mv "$bundle" "$output/task_master.app"
    cp scripts/install-macos.sh README.md "$output/"
    cp sensors/macos/task_master-sensors.sh "$output/"
    printf 'macOS %s package ready: %s/task_master.app\n' "$target_arch" "$output"
    sh scripts/build-macos-pkg.sh --arch "$target_arch" --app "$output/task_master.app" --version "$version"
done
