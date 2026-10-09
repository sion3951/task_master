#!/bin/sh
# Package already-built native binaries; run on the Debian/Ubuntu build host
# whose shared-library metadata defines the package's minimum dependencies.
set -eu
umask 022

usage() {
    echo 'Usage: scripts/build-deb.sh [--version VERSION] [--build-dir DIR] [--output-dir DIR] [--maintainer NAME]'
}
cd "$(dirname "$0")/.."
version=
build_dir=build
output_dir=build/packages
maintainer=${DEB_MAINTAINER:-task_master maintainers}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version|--build-dir|--output-dir|--maintainer)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            case "$1" in
                --version) version=$2 ;;
                --build-dir) build_dir=$2 ;;
                --output-dir) output_dir=$2 ;;
                --maintainer) maintainer=$2 ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[ -n "$version" ] || version=$(cat VERSION)
[ "$(uname -s)" = Linux ] || { echo 'Debian packages must be assembled on Linux.' >&2; exit 1; }
for tool in dpkg dpkg-deb dpkg-shlibdeps python3 patchelf; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Missing $tool. Install dpkg-dev, python3 and patchelf on the Debian/Ubuntu build host." >&2
        exit 1
    }
done
dpkg --validate-version "$version"
for binary in task_master task_master-collector; do
    [ -x "$build_dir/$binary" ] || { echo "Build $build_dir/$binary before packaging." >&2; exit 1; }
done
architecture=$(python3 - "$build_dir/task_master" "$build_dir/task_master-collector" <<'PY'
import pathlib, struct, sys
architectures = {62: 'amd64', 183: 'arm64', 243: 'riscv64'}
def architecture(filename):
    header = pathlib.Path(filename).read_bytes()[:20]
    if len(header) != 20 or header[:4] != b'\x7fELF' or header[4:6] != b'\x02\x01':
        raise SystemExit(f'{filename}: expected a native 64-bit little-endian Linux ELF')
    machine = struct.unpack_from('<H', header, 18)[0]
    if machine not in architectures:
        raise SystemExit(f'{filename}: unsupported Debian package architecture {machine}')
    return architectures[machine]
first, second = map(architecture, sys.argv[1:])
if first != second:
    raise SystemExit('Desktop and collector architectures must match')
print(first)
PY
)
[ "$architecture" = "$(dpkg --print-architecture)" ] || {
    echo "Package binaries are $architecture; use a matching Debian build host for dpkg-shlibdeps." >&2
    exit 1
}
mkdir -p "$build_dir" "$output_dir"
work=$(mktemp -d "$build_dir/.deb-stage-XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
stage=$work/debian/task-master
mkdir -p "$stage/DEBIAN" "$stage/usr/bin" "$stage/usr/libexec/task_master" \
    "$stage/usr/lib/task_master" "$stage/usr/share/applications" \
    "$stage/usr/share/icons/hicolor/scalable/apps" "$stage/usr/share/doc/task_master"
python3 scripts/bundle-linux-libraries.py "$build_dir/task_master" \
    "$stage/usr/bin/task_master" "$stage/usr/lib/task_master" --only libglfw.so.3
install -m 755 "$build_dir/task_master-collector" "$stage/usr/libexec/task_master/collector"
# A capability-bearing executable must resolve only trusted system libraries.
patchelf --remove-rpath "$stage/usr/libexec/task_master/collector"
install -m 644 assets/linux/task_master.desktop "$stage/usr/share/applications/task_master.desktop"
install -m 644 assets/linux/task_master.svg "$stage/usr/share/icons/hicolor/scalable/apps/task_master.svg"
install -m 644 README.md "$stage/usr/share/doc/task_master/README.md"
install -m 644 packaging/debian/README "$stage/usr/share/doc/task_master/packaging"
install -m 644 assets/FONT-LICENSE.txt "$stage/usr/share/doc/task_master/FONT-LICENSE.txt"
install -m 644 packaging/linux/GLFW-LICENSE.txt "$stage/usr/share/doc/task_master/GLFW-LICENSE.txt"
install -m 755 packaging/debian/postinst "$stage/DEBIAN/postinst"
install -m 755 packaging/debian/prerm "$stage/DEBIAN/prerm"
# Supply private-library metadata so shlibdeps neither requires distro GLFW
# 3.3 nor ignores missing dependencies. Scan private GLFW's own imports too.
printf 'Source: task-master\nSection: utils\nPriority: optional\nMaintainer: %s\n\nPackage: task-master\nArchitecture: any\nDescription: Native system monitor\n' "$maintainer" > "$work/debian/control"
printf 'libglfw 3 task-master\n' > "$work/debian/shlibs.local"
dependencies=$(cd "$work" && dpkg-shlibdeps -O -xtask-master \
    -ldebian/task-master/usr/lib/task_master -Sdebian/task-master \
    debian/task-master/usr/bin/task_master debian/task-master/usr/libexec/task_master/collector \
    debian/task-master/usr/lib/task_master/libglfw.so.3)
dependencies=$(printf '%s\n' "$dependencies" | sed -n 's/^shlibs:Depends=//p')
[ -n "$dependencies" ] || { echo 'dpkg-shlibdeps produced no shared-library dependencies.' >&2; exit 1; }
installed_size=$(du -sk "$stage/usr" | awk '{print $1}')
python3 - "$stage/DEBIAN/control" "$version" "$architecture" "$maintainer" "$installed_size" "$dependencies" <<'PY'
import pathlib, sys
output, version, architecture, maintainer, size, dependencies = sys.argv[1:]
# GLFW loads these backends with dlopen rather than recording DT_NEEDED, so
# shlibdeps cannot infer them from its ELF imports. Retain both display paths.
runtime = ['libvulkan1', 'openssh-client', 'libcap2-bin', 'libx11-6', 'libxi6',
           'libxrandr2', 'libxcursor1', 'libxinerama1', 'libx11-xcb1',
           'libwayland-client0', 'libwayland-cursor0', 'libwayland-egl1',
           'libxkbcommon0 (>= 0.5.0)', 'libdecor-0-0']
values = dict(VERSION=version, ARCHITECTURE=architecture, MAINTAINER=maintainer,
              INSTALLED_SIZE=size, DEPENDS=dependencies + ', ' + ', '.join(runtime))
text = pathlib.Path('packaging/debian/control.in').read_text()
for name, value in values.items():
    if '\n' in value or '\r' in value:
        raise SystemExit(f'Invalid newline in {name}')
    text = text.replace('@' + name + '@', value)
pathlib.Path(output).write_text(text)
PY
package=$output_dir/task_master_${version}_${architecture}.deb
dpkg-deb --root-owner-group --build "$stage" "$package"
echo "Built $package"
