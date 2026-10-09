#!/bin/sh
# Install the extracted runtime so the installed app needs neither FUSE nor
# the downloaded AppImage. The desktop always runs as the ordinary user.
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Administrator authorization is required.' >&2; exit 1; }
[ "$#" -eq 2 ] || { echo 'Expected AppDir and installation action.' >&2; exit 2; }
appdir=$1
action=$2
destination=/opt/task_master
launcher=/usr/local/bin/task_master
desktop=/usr/local/share/applications/task_master.desktop
icon=/usr/local/share/icons/hicolor/scalable/apps/task_master.svg
for path in /opt "$destination" "$launcher" "$desktop" "$icon" /usr/local/libexec/task_master; do
    [ ! -L "$path" ] || { echo "Refusing a symlink at $path" >&2; exit 1; }
done
case "$action" in
    --remove)
        rm -f "$launcher" "$desktop" "$icon" /usr/local/libexec/task_master/collector
        rm -rf "$destination"
        echo 'task_master removed; user preferences and history retained.'
        exit 0 ;;
    ''|--install) ;;
    *) echo 'Unknown installation action.' >&2; exit 2 ;;
esac
for file in AppRun usr/bin/task_master usr/libexec/task_master/collector usr/share/task_master/install-system.sh; do
    [ -f "$appdir/$file" ] || { echo "Incomplete package: missing $file" >&2; exit 1; }
done
command -v setcap >/dev/null 2>&1 || { echo 'Install libcap2-bin (Debian/Ubuntu) or libcap (other distributions) and retry.' >&2; exit 1; }
install -d -o root -g root -m 755 /opt
stage=$(mktemp -d /opt/.task_master-install-XXXXXX)
trap 'rm -rf "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
cp -a "$appdir/." "$stage/runtime"
chown -hR root:root "$stage/runtime"
chmod -R go-w "$stage/runtime"
sh "$stage/runtime/usr/share/task_master/install-system.sh" "$stage/runtime/usr/libexec/task_master/collector"
if [ -e "$destination" ]; then mv "$destination" "$stage/previous"; fi
mv "$stage/runtime" "$destination"
install -d -o root -g root -m 755 /usr/local/bin /usr/local/share/applications /usr/local/share/icons/hicolor/scalable/apps
cat > "$stage/launcher" <<'LAUNCHER'
#!/bin/sh
exec /opt/task_master/AppRun --run "$@"
LAUNCHER
install -o root -g root -m 755 "$stage/launcher" "$launcher"
sed 's|^Exec=.*|Exec=/usr/local/bin/task_master|; s|^TryExec=.*|TryExec=/usr/local/bin/task_master|' \
    "$destination/usr/share/applications/task_master.desktop" > "$stage/task_master.desktop"
install -o root -g root -m 644 "$stage/task_master.desktop" "$desktop"
install -o root -g root -m 644 "$destination/usr/share/icons/hicolor/scalable/apps/task_master.svg" "$icon"
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database /usr/local/share/applications || true; fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -f -t /usr/local/share/icons/hicolor || true; fi
echo 'Installed task_master in /opt/task_master, applications-menu entry and power-access collector.'
