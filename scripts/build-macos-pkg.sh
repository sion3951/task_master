#!/bin/sh
# Build a native Installer package from an already-built signed app bundle.
set -eu
umask 022
fail() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: sh scripts/build-macos-pkg.sh --arch amd64|arm64 [--app PATH]
                                   [--version VERSION] [--output-dir DIR]
Defaults: VERSION file, build/macos-<arch>/task_master.app, build/packages.
INSTALLER_SIGN_IDENTITY optionally signs with a Developer ID Installer certificate.
SIGN_IDENTITY in build-macos.sh signs the app itself. Public distribution also
requires notarization using the publisher's Apple credentials.
USAGE
}
cd "$(dirname "$0")/.."
architecture=
source_app=
version=
output_dir=build/packages
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --arch|--app|--version|--output-dir)
            [ "$#" -ge 2 ] || fail "$1 needs a value"
            case "$1" in
                --arch) architecture=$2 ;;
                --app) source_app=$2 ;;
                --version) version=$2 ;;
                --output-dir) output_dir=$2 ;;
            esac
            shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
case "$architecture" in amd64) apple_arch=x86_64 ;; arm64) apple_arch=arm64 ;; *) fail 'Specify --arch amd64 or arm64.' ;; esac
[ "$(uname -s)" = Darwin ] || fail 'macOS Installer packages must be built on a Mac.'
for tool in python3 pkgbuild productbuild ditto lipo codesign; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done
[ -n "$source_app" ] || source_app=build/macos-$architecture/task_master.app
[ -n "$version" ] || version=$(cat VERSION)
numeric_version=$(python3 - "$version" <<'PY'
import re, sys
match = re.fullmatch(r'(\d+(?:\.\d+){0,3})(?:[-+~][0-9A-Za-z.+~\-]+)?', sys.argv[1])
if not match:
    raise SystemExit('Version must have one to four numeric components, optionally followed by release metadata.')
print(match[1])
PY
)
for binary in task_master task_master-collector; do
    [ -x "$source_app/Contents/MacOS/$binary" ] || fail "Incomplete app bundle: $source_app"
    lipo -verify_arch "$apple_arch" "$source_app/Contents/MacOS/$binary"
done
codesign --verify --strict "$source_app"
mkdir -p build "$output_dir"
stage=$(mktemp -d build/macos-pkg-stage.XXXXXX)
trap 'rm -rf "$stage"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$stage/root/Applications" "$stage/scripts"
ditto "$source_app" "$stage/root/Applications/task_master.app"
cp scripts/install-macos.sh sensors/macos/task_master-sensors.sh "$stage/scripts/"
cp packaging/macos/preinstall packaging/macos/postinstall "$stage/scripts/"
printf '%s\n' "$apple_arch" > "$stage/scripts/architecture"
chmod 755 "$stage/scripts/preinstall" "$stage/scripts/postinstall"
# Do not relocate to an arbitrary older .app found elsewhere on disk. The
# postinstall helper and desktop always use /Applications/task_master.app.
pkgbuild --analyze --root "$stage/root" "$stage/components.plist"
python3 - "$stage/components.plist" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
components = plistlib.loads(path.read_bytes())
for component in components:
    component['BundleIsRelocatable'] = False
    component['BundleHasStrictIdentifier'] = True
    component['BundleOverwriteAction'] = 'upgrade'
path.write_bytes(plistlib.dumps(components))
PY
pkgbuild --root "$stage/root" --component-plist "$stage/components.plist" \
    --scripts "$stage/scripts" --identifier dev.task-master.desktop \
    --version "$numeric_version" --install-location / "$stage/task_master.pkg"
python3 - "$stage/Distribution.xml" "$apple_arch" "$numeric_version" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
output, architecture, version = sys.argv[1:]
distribution = ET.Element('installer-gui-script', {'minSpecVersion': '2'})
ET.SubElement(distribution, 'title').text = 'task_master'
ET.SubElement(distribution, 'options', {
    'customize': 'never', 'require-scripts': 'true',
    'rootVolumeOnly': 'true', 'hostArchitectures': architecture,
})
ET.SubElement(distribution, 'domains', {
    'enable_localSystem': 'true', 'enable_currentUserHome': 'false', 'enable_anywhere': 'false',
})
volume = ET.SubElement(distribution, 'volume-check')
allowed = ET.SubElement(volume, 'allowed-os-versions')
ET.SubElement(allowed, 'os-version', {'min': '13.0'})
outline = ET.SubElement(distribution, 'choices-outline')
ET.SubElement(outline, 'line', {'choice': 'task_master'})
choice = ET.SubElement(distribution, 'choice', {'id': 'task_master', 'visible': 'false', 'title': 'task_master'})
ET.SubElement(choice, 'pkg-ref', {'id': 'dev.task-master.desktop'})
ET.SubElement(distribution, 'pkg-ref', {
    'id': 'dev.task-master.desktop', 'version': version, 'onConclusion': 'none',
}).text = 'task_master.pkg'
ET.ElementTree(distribution).write(output, encoding='utf-8', xml_declaration=True)
PY
destination=$output_dir/task_master-$version-$architecture.pkg
set -- productbuild --distribution "$stage/Distribution.xml" --package-path "$stage"
[ -z "${INSTALLER_SIGN_IDENTITY:-}" ] || set -- "$@" --sign "$INSTALLER_SIGN_IDENTITY"
"$@" "$destination"
printf 'macOS installer ready: %s\n' "$destination"
