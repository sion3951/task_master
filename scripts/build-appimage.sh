#!/bin/sh
set -eu
usage() { echo 'Usage: sh scripts/build-appimage.sh [--version VERSION] [--build-dir DIR] [--output-dir DIR]'; }
cd "$(dirname "$0")/.."
version=
build_dir=build
output_dir=build/packages
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version|--build-dir|--output-dir)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            case "$1" in --version) version=$2 ;; --build-dir) build_dir=$2 ;; --output-dir) output_dir=$2 ;; esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[ -n "$version" ] || version=$(cat VERSION)
case "$version" in [0-9]*) ;; *) echo 'Version must start with a digit.' >&2; exit 2 ;; esac
case "$version" in *[!0-9A-Za-z.+~\-]*) echo 'Invalid version.' >&2; exit 2 ;; esac
[ "$(uname -s)" = Linux ] || { echo 'Build AppImages on Linux.' >&2; exit 1; }
case "$(uname -m)" in x86_64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;; *) echo 'AppImage builds support x64 and ARM64.' >&2; exit 1 ;; esac
for tool in python3 patchelf; do command -v "$tool" >/dev/null 2>&1 || { echo "Missing $tool" >&2; exit 1; }; done
[ -x "$build_dir/task_master" ] && [ -x "$build_dir/task_master-collector" ] || { echo 'Build the native desktop and collector first.' >&2; exit 1; }
mkdir -p "$build_dir" "$output_dir"
work=$(mktemp -d "$build_dir/.appimage-stage-XXXXXX")
work=$(CDPATH= cd -- "$work" && pwd)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
appdir=$work/task_master.AppDir
mkdir -p "$appdir/usr/bin" "$appdir/usr/libexec/task_master" "$appdir/usr/lib/task_master" \
    "$appdir/usr/share/applications" "$appdir/usr/share/icons/hicolor/scalable/apps" \
    "$appdir/usr/share/doc/task_master" "$appdir/usr/share/task_master"
python3 scripts/bundle-linux-libraries.py "$build_dir/task_master" "$appdir/usr/bin/task_master" "$appdir/usr/lib/task_master"
python3 scripts/bundle-libdecor.py "$appdir/usr/lib/task_master"
python3 scripts/bundle-linux-data.py "$appdir"
python3 scripts/collect-linux-licenses.py "$appdir/usr/lib/task_master" "$appdir/usr/share/doc/task_master/licenses"
install -m 755 "$build_dir/task_master-collector" "$appdir/usr/libexec/task_master/collector"
patchelf --remove-rpath "$appdir/usr/libexec/task_master/collector"
install -m 755 packaging/linux/AppRun "$appdir/AppRun"
install -m 644 assets/linux/task_master.desktop "$appdir/usr/share/applications/task_master.desktop"
install -m 644 assets/linux/task_master.svg "$appdir/usr/share/icons/hicolor/scalable/apps/task_master.svg"
install -m 644 scripts/install-system.sh "$appdir/usr/share/task_master/install-system.sh"
install -m 644 scripts/install-appimage.sh scripts/install-appimage-system.sh "$appdir/usr/share/task_master/"
install -m 644 README.md "$appdir/usr/share/doc/task_master/README.md"
ln -s usr/share/applications/task_master.desktop "$appdir/task_master.desktop"
ln -s usr/share/icons/hicolor/scalable/apps/task_master.svg "$appdir/task_master.svg"
ln -s task_master.svg "$appdir/.DirIcon"
tools=build/toolchains/appimage
if [ -z "${APPIMAGETOOL:-}" ] || [ -z "${APPIMAGE_RUNTIME:-}" ]; then python3 scripts/fetch-appimage-tools.py "$tools"; fi
appimagetool=${APPIMAGETOOL:-$tools/appimagetool-$arch.AppImage}
runtime=${APPIMAGE_RUNTIME:-$tools/runtime-$arch}
[ -x "$appimagetool" ] && [ -f "$runtime" ] || { echo 'Missing AppImage tool/runtime.' >&2; exit 1; }
appimagetool=$(realpath "$appimagetool")
runtime=$(realpath "$runtime")
output=$output_dir/task_master-$version-$arch.AppImage
(
    # Building from an AppImage-hosted editor must not inherit that editor's
    # extraction paths or original working directory into the packaging tool.
    unset OWD APPIMAGE APPDIR ARGV0
    ARCH=$arch APPIMAGE_EXTRACT_AND_RUN=1 "$appimagetool" --runtime-file "$runtime" "$appdir" "$work/package.AppImage"
)
chmod 755 "$work/package.AppImage"
mv "$work/package.AppImage" "$output"
echo "Built $output"
