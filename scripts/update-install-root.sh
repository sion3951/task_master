#!/bin/sh
# Embedded in update-helper; never read or executed from the download cache.
set -eu
umask 077
kind=$1 package=$2 work=$3
[ "$(id -u)" -eq 0 ] || exit 1
backup_update_helpers() {
    update_directory=$1
    for name in update-helper update-install.sh; do
        [ ! -f "$update_directory/$name" ] || cp -p "$update_directory/$name" "$work/previous-$name"
    done
}
restore_update_helpers() {
    update_directory=$1
    install -d -o root -g "$2" -m 755 "$update_directory"
    for name in update-helper update-install.sh; do
        if [ -f "$work/previous-$name" ]; then
            # Preserve the protected file's permissions and replace atomically;
            # the currently executing helper may still hold its old inode.
            mv -f "$work/previous-$name" "$update_directory/$name"
        else
            rm -f "$update_directory/$name"
        fi
    done
}
case "$kind" in
    deb) export DEBIAN_FRONTEND=noninteractive; /usr/bin/apt-get install -y "$package" ;;
    macos)
        /usr/bin/ditto /Applications/task_master.app "$work/Previous.app"
        backup_update_helpers /Library/PrivilegedHelperTools/task_master
        if /usr/sbin/installer -pkg "$package" -target /; then :
        else
            # Restore the prior desktop bundle after a failed package install.
            # System Installer receipts/dependencies remain package-manager state.
            rm -rf /Applications/task_master.app
            /usr/bin/ditto "$work/Previous.app" /Applications/task_master.app
            restore_update_helpers /Library/PrivilegedHelperTools/task_master wheel
            exit 1
        fi ;;
    appimage)
        chmod 700 "$package"
        # Extraction works without FUSE and must not inherit a parent AppImage.
        unset APPDIR APPIMAGE OWD ARGV0 APPIMAGE_EXTRACT_AND_RUN
        cd "$work"
        "$package" --appimage-extract >/dev/null
        # Preserve the installed runtime for a failed system-installer attempt.
        [ ! -d /opt/task_master ] || cp -a /opt/task_master "$work/previous-runtime"
        [ ! -f /usr/local/libexec/task_master/collector ] || cp -p /usr/local/libexec/task_master/collector "$work/previous-collector"
        backup_update_helpers /usr/local/libexec/task_master
        if sh "$work/squashfs-root/usr/share/task_master/install-appimage-system.sh" "$work/squashfs-root" --install; then :
        else
            if [ -d "$work/previous-runtime" ]; then rm -rf /opt/task_master; mv "$work/previous-runtime" /opt/task_master; fi
            if [ -f "$work/previous-collector" ]; then cp -p "$work/previous-collector" /usr/local/libexec/task_master/collector; command -v setcap >/dev/null 2>&1 && setcap cap_perfmon=ep /usr/local/libexec/task_master/collector || true; fi
            restore_update_helpers /usr/local/libexec/task_master root
            exit 1
        fi ;;
esac
