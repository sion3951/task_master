#!/bin/sh
# Build or combine the collector payloads embedded in desktop release builds.
set -eu

usage() {
    cat <<'USAGE'
Usage: sh scripts/build-collectors.sh [--arch native|amd64|arm64|all] [--all]
                                    [--linux-dir DIR] [--windows-dir DIR] [--mac-dir DIR]

Default: build this Linux or macOS machine's native collector, keeping other payloads.
--arch all builds both native OS architectures; --all requires all six payloads.
Prebuilt directories accept task_master-collector-linux-{amd64,arm64} and
 task_master-collector-darwin-{amd64,arm64} and
 task_master-collector-windows-{amd64,arm64}[.exe]. Windows directories can also
 provide task_master-collector.exe. Windows ARM64 uses x64 emulation on Win11
 when only the Windows x64 collector is provided.

Environment:
 ODIN                       Odin compiler executable (default: odin)
 CC_AMD64 / CC_ARM64         Linux cross C compiler executable; no shell flags
 LINUX_AMD64_SYSROOT         AMD64 target libc/sysroot for clang cross-linking
 LINUX_ARM64_SYSROOT         ARM64 target libc/sysroot for clang cross-linking
 CLANG                      Cross clang executable (default: clang)
 WINDOWS_SDK_ROOT           Odin-compatible Windows SDK + MSVC CRT tree;
                            enables Windows cross-build with lld-link

Examples:
 sh scripts/build-collectors.sh
 CC_ARM64=aarch64-linux-gnu-gcc sh scripts/build-collectors.sh --arch arm64
 LINUX_ARM64_SYSROOT=/path/to/sysroot sh scripts/build-collectors.sh --arch arm64
 sh scripts/build-collectors.sh --all --linux-dir artifacts --windows-dir artifacts --mac-dir artifacts
USAGE
}

fail() { printf '%s\n' "$*" >&2; exit 1; }
arch=native
strict=false
linux_dir=
windows_dir=
mac_dir=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --all) strict=true; arch=all; shift ;;
        --arch) [ "$#" -ge 2 ] || fail '--arch needs a value'; arch=$2; shift 2 ;;
        --linux-dir) [ "$#" -ge 2 ] || fail '--linux-dir needs a directory'; linux_dir=$2; shift 2 ;;
        --mac-dir) [ "$#" -ge 2 ] || fail '--mac-dir needs a directory'; mac_dir=$2; shift 2 ;;
        --windows-dir) [ "$#" -ge 2 ] || fail '--windows-dir needs a directory'; windows_dir=$2; shift 2 ;;
        *) fail "Unknown argument: $1 (use --help)" ;;
    esac
done
[ -f telemetry.odin ] && [ -f collector/main.odin ] || fail 'Run this script from the repository root.'
host_os=$(uname -s)
case "$host_os" in Linux|Darwin) ;; *) fail 'This script builds Linux/macOS payloads. On Windows use scripts/build-windows.ps1.' ;; esac
command -v file >/dev/null 2>&1 || fail 'Install the file utility to verify imported collector architectures.'
case "$(uname -m)" in
    x86_64) native=amd64 ;;
    aarch64|arm64) native=arm64 ;;
    riscv64) native=riscv64 ;;
    *) fail 'Unsupported native collector architecture.' ;;
esac
if $strict; then arch=all; fi
case "$arch" in
    native) architectures=$native ;;
    amd64|arm64|riscv64) architectures=$arch ;;
    all) architectures='amd64 arm64' ;;
    *) fail "Unsupported architecture: $arch" ;;
esac
[ -z "$linux_dir" ] || [ -d "$linux_dir" ] || fail "No Linux artifact directory: $linux_dir"
[ -z "$windows_dir" ] || [ -d "$windows_dir" ] || fail "No Windows artifact directory: $windows_dir"
[ -z "$mac_dir" ] || [ -d "$mac_dir" ] || fail "No macOS artifact directory: $mac_dir"

mkdir -p build
if [ -n "$windows_dir" ] && [ -s "$windows_dir/task_master-windows-sensors.zip" ]; then
    cp "$windows_dir/task_master-windows-sensors.zip" build/task_master-windows-sensors.zip
fi
stage=$(mktemp -d build/collector-cross.XXXXXX)
trap 'rm -rf "$stage"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$stage/source"
cp telemetry*.odin remote_protocol.odin collector/*.odin "$stage/source/"
odin=${ODIN:-odin}

verify_linux() {
    description=$(file -b "$1")
    case "$2:$description" in
        amd64:*ELF*executable*x86-64*|arm64:*ELF*executable*ARM*aarch64*|riscv64:*ELF*executable*RISC-V*) ;;
        *) fail "Collector does not match Linux $2: $1 ($description)" ;;
    esac
}
verify_windows() {
    description=$(file -b "$1")
    case "$description" in
        *PE32+*executable*x86-64*) ;;
        *PE32+*executable*Aarch64*|*PE32+*executable*ARM64*)
            [ "$2" = arm64 ] || fail "Expected Windows x64 collector: $1" ;;
        *) fail "Not a Windows executable collector: $1 ($description)" ;;
    esac
}

build_linux() {
    target_arch=$1
    destination=build/task_master-collector-linux-$target_arch
    candidate=
    if [ -n "$linux_dir" ] && [ -f "$linux_dir/task_master-collector-linux-$target_arch" ]; then
        candidate=$linux_dir/task_master-collector-linux-$target_arch
    fi
    if [ -n "$candidate" ]; then
        verify_linux "$candidate" "$target_arch"
        cp "$candidate" "$stage/linux-$target_arch"
    elif [ "$host_os" = Linux ] && [ "$target_arch" = "$native" ]; then
        command -v "$odin" >/dev/null 2>&1 || fail "Odin compiler not found: $odin"
        "$odin" build "$stage/source" "-target:linux_$target_arch" "-out:$stage/linux-$target_arch" \
            -o:speed -vet -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536
    else
        case "$target_arch" in
            arm64) compiler=${CC_ARM64:-}; sysroot=${LINUX_ARM64_SYSROOT:-}; triple=aarch64-linux-gnu ;;
            amd64) compiler=${CC_AMD64:-}; sysroot=${LINUX_AMD64_SYSROOT:-}; triple=x86_64-linux-gnu ;;
            *) fail "Build Linux $target_arch natively or provide its prebuilt payload." ;;
        esac
        # A distro cross GCC carries its own target libc paths. Otherwise clang
        # needs an explicit target sysroot; never feed ARM objects to host ld.
        if [ -z "$compiler" ] && command -v "$triple-gcc" >/dev/null 2>&1; then compiler=$triple-gcc; fi
        if [ -z "$compiler" ] && [ -z "$sysroot" ]; then
            # An existing validated payload can be retained in a combined build.
            if [ -f "$destination" ]; then
                verify_linux "$destination" "$target_arch"
                printf 'Keeping %s; no cross toolchain was supplied.\n' "$destination"
                return
            fi
            fail "Linux $target_arch needs CC_$(printf '%s' "$target_arch" | tr '[:lower:]' '[:upper:]')=$triple-gcc, a LINUX_$(printf '%s' "$target_arch" | tr '[:lower:]' '[:upper:]')_SYSROOT, or --linux-dir with its prebuilt collector."
        fi
        command -v "$odin" >/dev/null 2>&1 || fail "Odin compiler not found: $odin"
        [ -z "$sysroot" ] || [ -d "$sysroot" ] || fail "No target sysroot: $sysroot"
        "$odin" build "$stage/source" "-target:linux_$target_arch" -build-mode:obj -use-single-module \
            "-out:$stage/linux-$target_arch.o" -o:speed -vet -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536
        if [ -n "$compiler" ]; then
            command -v "$compiler" >/dev/null 2>&1 || fail "Cross compiler not found: $compiler"
            set -- "$compiler"
            if [ -n "$sysroot" ]; then set -- "$@" "--sysroot=$sysroot"; fi
        else
            compiler=${CLANG:-clang}
            command -v "$compiler" >/dev/null 2>&1 || fail "Cross clang not found: $compiler"
            command -v ld.lld >/dev/null 2>&1 || fail 'Clang cross-linking needs ld.lld.'
            set -- "$compiler" "--target=$triple" "--sysroot=$sysroot" -fuse-ld=lld
        fi
        "$@" "$stage/linux-$target_arch.o" -o "$stage/linux-$target_arch" -pie \
            -Wl,-z,now -Wl,-z,relro '-Wl,-rpath,$ORIGIN' -pthread -ldl -lm -lc
    fi
    verify_linux "$stage/linux-$target_arch" "$target_arch"
    chmod 755 "$stage/linux-$target_arch"
    mv "$stage/linux-$target_arch" "$destination"
    printf 'Ready: %s\n' "$destination"
}

if [ "$host_os" = Linux ] || [ -n "$linux_dir" ] || $strict; then
    for target_arch in $architectures; do build_linux "$target_arch"; done
fi

verify_darwin() {
    description=$(file -b "$1")
    case "$2:$description" in
        amd64:*Mach-O*executable*x86_64*|arm64:*Mach-O*executable*arm64*) ;;
        *) fail "Collector does not match macOS $2: $1 ($description)" ;;
    esac
}
build_darwin() {
    target_arch=$1
    destination=build/task_master-collector-darwin-$target_arch
    candidate=
    if [ -n "$mac_dir" ] && [ -f "$mac_dir/task_master-collector-darwin-$target_arch" ]; then
        candidate=$mac_dir/task_master-collector-darwin-$target_arch
    fi
    if [ -n "$candidate" ]; then
        verify_darwin "$candidate" "$target_arch"
        cp "$candidate" "$stage/darwin-$target_arch"
    elif [ "$host_os" = Darwin ]; then
        command -v "$odin" >/dev/null 2>&1 || fail "Odin compiler not found: $odin"
        "$odin" build "$stage/source" "-target:darwin_$target_arch" -minimum-os-version:13.0 "-out:$stage/darwin-$target_arch" \
            -o:speed -vet -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536
    elif [ -f "$destination" ]; then
        verify_darwin "$destination" "$target_arch"
        printf 'Keeping %s; import macOS payloads with --mac-dir.\n' "$destination"
        return
    elif $strict || [ -n "$mac_dir" ]; then
        fail "macOS $target_arch requires --mac-dir containing a collector built on macOS."
    else
        return 0
    fi
    verify_darwin "$stage/darwin-$target_arch" "$target_arch"
    chmod 755 "$stage/darwin-$target_arch"
    mv "$stage/darwin-$target_arch" "$destination"
    printf 'Ready: %s\n' "$destination"
}
if [ "$host_os" = Darwin ] && ! $strict && [ -z "$mac_dir" ]; then
    for target_arch in $architectures; do build_darwin "$target_arch"; done
else
    for target_arch in amd64 arm64; do build_darwin "$target_arch"; done
fi

windows_amd64=build/task_master-collector-windows-amd64
windows_arm64=build/task_master-collector-windows-arm64
if [ -n "$windows_dir" ]; then
    candidate=
    for filename in task_master-collector-windows-amd64 task_master-collector-windows-amd64.exe task_master-collector.exe; do
        if [ -f "$windows_dir/$filename" ]; then candidate=$windows_dir/$filename; break; fi
    done
    [ -n "$candidate" ] || fail "No Windows x64 collector found in $windows_dir"
    verify_windows "$candidate" amd64
    cp "$candidate" "$stage/windows-amd64"
    mv "$stage/windows-amd64" "$windows_amd64"
    candidate=
    for filename in task_master-collector-windows-arm64 task_master-collector-windows-arm64.exe; do
        if [ -f "$windows_dir/$filename" ]; then candidate=$windows_dir/$filename; break; fi
    done
    if [ -n "$candidate" ]; then
        verify_windows "$candidate" arm64
        cp "$candidate" "$stage/windows-arm64"
        mv "$stage/windows-arm64" "$windows_arm64"
    else
        cp "$windows_amd64" "$windows_arm64"
        printf 'Windows ARM64 payload uses Windows 11 x64 emulation.\n'
    fi
elif [ -n "${WINDOWS_SDK_ROOT:-}" ]; then
    [ -d "$WINDOWS_SDK_ROOT" ] || fail "No Windows SDK tree: $WINDOWS_SDK_ROOT"
    command -v lld-link >/dev/null 2>&1 || fail 'Windows cross-linking needs lld-link.'
    command -v "$odin" >/dev/null 2>&1 || fail "Odin compiler not found: $odin"
    "$odin" build "$stage/source" -target:windows_amd64 "-windows-sdk-root:$WINDOWS_SDK_ROOT" \
        -linker:lld "-out:$stage/windows-amd64.exe" -o:speed -vet \
        -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536
    verify_windows "$stage/windows-amd64.exe" amd64
    mv "$stage/windows-amd64.exe" "$windows_amd64"
    cp "$windows_amd64" "$windows_arm64"
    printf 'Windows ARM64 payload uses Windows 11 x64 emulation.\n'
elif [ -f "$windows_amd64" ]; then
    verify_windows "$windows_amd64" amd64
    if [ ! -f "$windows_arm64" ]; then cp "$windows_amd64" "$windows_arm64"; fi
    verify_windows "$windows_arm64" arm64
    printf 'Keeping existing Windows collector payloads.\n'
elif $strict; then
    fail 'The complete bundle needs --windows-dir with a Windows release collector or WINDOWS_SDK_ROOT plus lld-link.'
fi

missing=
if $strict && [ ! -s build/task_master-windows-sensors.zip ]; then
    fail 'A complete release needs task_master-windows-sensors.zip from the Windows build for remote sensor installation.'
fi
for payload in build/task_master-collector-linux-amd64 build/task_master-collector-linux-arm64 \
               "$windows_amd64" "$windows_arm64" build/task_master-collector-darwin-amd64 build/task_master-collector-darwin-arm64; do
    if [ ! -s "$payload" ]; then missing="$missing $payload"; fi
done
if [ -n "$missing" ]; then
    printf 'Native payload ready; a complete release still needs:%s\n' "$missing"
    printf 'Build them natively or rerun --all with the documented cross toolchains/prebuilt directories.\n'
    if $strict; then fail 'The complete collector bundle is incomplete.'; fi
else
    printf 'All six collector payloads are ready.\n'
fi
