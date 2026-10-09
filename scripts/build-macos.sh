#!/bin/sh
# Build native Intel/Apple-silicon bundles; release mode retains every remote OS.
set -eu
fail() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: sh scripts/build-macos.sh [--arch native|amd64|arm64|all] [--collector-only]
                               [--development] [--linux-dir DIR] [--windows-dir DIR]
                               [--mac-dir DIR] [--version VERSION]
Default: build both architectures and require all six SSH collector payloads.
--collector-only builds the requested native macOS collector payloads only.
--development embeds the payloads currently available instead of requiring all six.
Environment: ODIN, GLSLC, SIGN_IDENTITY (default ad-hoc), VULKAN_SDK,
 FREETYPE_AMD64 / FREETYPE_ARM64, MOLTENVK_AMD64 / MOLTENVK_ARM64:
 paths to dylibs with the respective architecture and deployment target <=13.
 FREETYPE_LIBRARY / MOLTENVK_LIBRARY provide universal or native fallback dylibs.
 INSTALLER_SIGN_IDENTITY signs the .pkg with a Developer ID Installer certificate.
 Full builds also create build/packages/task_master-<version>-<arch>.pkg installers.
USAGE
}
architectures='amd64 arm64'
collector_only=false
development=false
linux_dir=build/collectors
windows_dir=build/collectors
mac_dir=
version=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --collector-only) collector_only=true; shift ;;
        --development) development=true; shift ;;
        --arch)
            [ "$#" -ge 2 ] || fail '--arch needs a value'
            case "$2" in
                native) case "$(uname -m)" in arm64) architectures=arm64 ;; x86_64) architectures=amd64 ;; *) fail 'Unsupported Mac architecture.' ;; esac ;;
                amd64|arm64) architectures=$2 ;;
                all) architectures='amd64 arm64' ;;
                *) fail "Unsupported architecture: $2" ;;
            esac
            shift 2 ;;
        --linux-dir) [ "$#" -ge 2 ] || fail '--linux-dir needs a directory'; linux_dir=$2; shift 2 ;;
        --windows-dir) [ "$#" -ge 2 ] || fail '--windows-dir needs a directory'; windows_dir=$2; shift 2 ;;
        --mac-dir) [ "$#" -ge 2 ] || fail '--mac-dir needs a directory'; mac_dir=$2; shift 2 ;;
        --version) [ "$#" -ge 2 ] || fail '--version needs a value'; version=$2; shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail 'Build and sign macOS packages on a Mac with Xcode Command Line Tools.'
[ -f telemetry.odin ] && [ -f shaders/ui.vert ] || fail 'Run this script from the repository root.'
odin=${ODIN:-odin}
for tool in "$odin" python3 xcrun; do command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"; done
for tool in clang lipo otool install_name_tool codesign; do xcrun --find "$tool" >/dev/null || fail "Xcode tool not found: $tool"; done
export MACOSX_DEPLOYMENT_TARGET=13.0
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
        "-out:$stage/collector-$target_arch" -o:speed -vet -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536
    xcrun codesign --force --sign "${SIGN_IDENTITY:--}" "$stage/collector-$target_arch"
    chmod 755 "$stage/collector-$target_arch"
    mv "$stage/collector-$target_arch" "$destination"
    printf 'Ready: %s\n' "$destination"
done
$collector_only && exit 0
[ -n "$version" ] || version=$(cat VERSION)
numeric_version=$(python3 - "$version" <<'PY'
import re, sys
match = re.fullmatch(r'(\d+(?:\.\d+){0,3})(?:[-+~][0-9A-Za-z.+~\-]+)?', sys.argv[1])
if not match:
    raise SystemExit('Version must have one to four numeric components, optionally followed by release metadata.')
print(match[1])
PY
)
if ! $development; then
    set -- --all --linux-dir "$linux_dir" --windows-dir "$windows_dir"
    [ -z "$mac_dir" ] || set -- "$@" --mac-dir "$mac_dir"
    sh scripts/build-collectors.sh "$@"
fi
glslc=${GLSLC:-glslc}
if ! command -v "$glslc" >/dev/null 2>&1 && [ -n "${VULKAN_SDK:-}" ] && [ -x "$VULKAN_SDK/bin/glslc" ]; then glslc=$VULKAN_SDK/bin/glslc; fi
command -v "$glslc" >/dev/null 2>&1 || fail 'Install shaderc (glslc) or set GLSLC/VULKAN_SDK.'
"$glslc" shaders/ui.vert -o shaders/ui.vert.spv
"$glslc" shaders/ui.frag -o shaders/ui.frag.spv
odin_root=$("$odin" root)
for target_arch in $architectures; do
    case "$target_arch" in
        amd64) apple_arch=x86_64; free_type=${FREETYPE_AMD64:-${FREETYPE_LIBRARY:-}}; molten_vk=${MOLTENVK_AMD64:-${MOLTENVK_LIBRARY:-}}; brew_prefix=/usr/local ;;
        arm64) apple_arch=arm64; free_type=${FREETYPE_ARM64:-${FREETYPE_LIBRARY:-}}; molten_vk=${MOLTENVK_ARM64:-${MOLTENVK_LIBRARY:-}}; brew_prefix=/opt/homebrew ;;
    esac
    [ -n "$free_type" ] || free_type=$brew_prefix/opt/freetype/lib/libfreetype.dylib
    if [ -z "$molten_vk" ]; then
        for candidate in "${VULKAN_SDK:-}/lib/libMoltenVK.dylib" "${VULKAN_SDK:-}/MoltenVK/dylib/macOS/libMoltenVK.dylib" "${VULKAN_SDK:-}/../MoltenVK/dylib/macOS/libMoltenVK.dylib" "$brew_prefix/opt/molten-vk/lib/libMoltenVK.dylib"; do
            if [ -f "$candidate" ]; then molten_vk=$candidate; break; fi
        done
    fi
    [ -f "$free_type" ] || fail "Missing $target_arch FreeType dylib; set FREETYPE_$(printf '%s' "$target_arch" | tr '[:lower:]' '[:upper:]')."
    [ -n "$molten_vk" ] && [ -f "$molten_vk" ] || fail "Missing $target_arch MoltenVK dylib; set MOLTENVK_$(printf '%s' "$target_arch" | tr '[:lower:]' '[:upper:]') or VULKAN_SDK."
    xcrun lipo "$free_type" -verify_arch "$apple_arch"
    xcrun lipo "$molten_vk" -verify_arch "$apple_arch"
    xcrun lipo "$odin_root/vendor/glfw/lib/darwin/libglfw3.a" -verify_arch "$apple_arch"
    output=build/macos-$target_arch
    bundle=$stage/$target_arch/task_master.app
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks" "$bundle/Contents/Resources/licenses"
    set -- "$odin" build . "-target:darwin_$target_arch" -minimum-os-version:13.0 \
        "-out:$bundle/Contents/MacOS/task_master" -o:speed -no-bounds-check -vet \
        -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536 \
        "-collection:task_master_freetype=$(dirname "$free_type")" \
        "-define:FREETYPE_LIBRARY=task_master_freetype:$(basename "$free_type")" \
        '-extra-linker-flags:-Wl,-headerpad_max_install_names'
    for payload_os in linux windows darwin; do
        for payload_arch in amd64 arm64; do
            payload=build/task_master-collector-$payload_os-$payload_arch
            if [ -s "$payload" ]; then
                define=$(printf 'TASK_MASTER_COLLECTOR_%s_%s' "$payload_os" "$payload_arch" | tr '[:lower:]' '[:upper:]')
                set -- "$@" "-define:$define=$payload"
            elif ! $development; then fail "Missing release collector: $payload"; fi
        done
    done
    if [ -s build/task_master-windows-sensors.zip ]; then
        set -- "$@" -define:TASK_MASTER_WINDOWS_SENSORS=build/task_master-windows-sensors.zip
    elif ! $development; then fail 'Missing task_master-windows-sensors.zip for remote sensor installation.'; fi
    "$@"
    cp "build/task_master-collector-darwin-$target_arch" "$bundle/Contents/MacOS/task_master-collector"
    # Copy/thin transitive dylibs, reject dependencies requiring newer macOS,
    # and rewrite all non-system references before signing each code item.
    python3 scripts/package-macos-libraries.py "$bundle" "$apple_arch" "$free_type" "$molten_vk" "${SIGN_IDENTITY:--}"
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
    cp "$odin_root/vendor/glfw/LICENSE.txt" "$bundle/Contents/Resources/licenses/GLFW.txt"
    # Retain license notices supplied alongside the runtime distributions.
    free_license=$(dirname "$free_type")/../share/doc/freetype2
    molten_license=$(dirname "$molten_vk")/../share/molten-vk
    for license in "$free_license/FTL.TXT" "$free_license/GPLv2.TXT" "$molten_license/LICENSE" "$molten_license/LICENSE.txt"; do
        if [ -f "$license" ]; then cp "$license" "$bundle/Contents/Resources/licenses/"; fi
    done
    if [ -n "${THIRD_PARTY_LICENSE_DIR:-}" ]; then cp -R "$THIRD_PARTY_LICENSE_DIR/." "$bundle/Contents/Resources/licenses/"; fi
    xcrun codesign --force --sign "${SIGN_IDENTITY:--}" "$bundle/Contents/MacOS/task_master-collector"
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
