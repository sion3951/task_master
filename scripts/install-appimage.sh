#!/bin/sh
# User-facing AppImage installation; only the system installer is elevated.
set -eu
appdir=$1
shift
action=${1:-}
case "$action" in ''|--install|--remove) ;; *) echo 'Unknown installation option.' >&2; exit 2 ;; esac
[ "$#" -le 1 ] || { echo 'Installation takes no additional arguments.' >&2; exit 2; }
installer=$appdir/usr/share/task_master/install-appimage-system.sh

in_terminal() {
    for terminal in gnome-terminal konsole xfce4-terminal xterm; do
        if command -v "$terminal" >/dev/null 2>&1; then
            case "$terminal" in
                gnome-terminal) exec "$terminal" --wait -- sh "$0" "$appdir" "${action:---install}" ;;
                konsole) exec "$terminal" --nofork -e sh "$0" "$appdir" "${action:---install}" ;;
                xfce4-terminal) exec "$terminal" --disable-server -x sh "$0" "$appdir" "${action:---install}" ;;
                *) exec "$terminal" -e sh "$0" "$appdir" "${action:---install}" ;;
            esac
        fi
    done
    report --error 'Open this AppImage in a terminal with --install, or install zenity/kdialog and polkit for graphical installation.'
    exit 1
}

report() {
    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        zenity "$1" --title=task_master --text="$2" || true
    elif command -v kdialog >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        case "$1" in --error) kdialog --error "$2" --title task_master ;; *) kdialog --msgbox "$2" --title task_master ;; esac
    else printf '%s\n' "$2"; fi
}

if [ -z "$action" ]; then
    message='Install task_master, its applications-menu entry and its power-access collector? Administrator authorization is required.'
    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        zenity --question --title='Install task_master' --text="$message" --ok-label=Install --cancel-label=Cancel || exit 0
    elif command -v kdialog >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        kdialog --yesno "$message" --title 'Install task_master' || exit 0
    elif [ ! -t 0 ]; then
        # Desktops without a dialog utility still get an interactive installer.
        in_terminal
    fi
fi

if [ "$(id -u)" -ne 0 ] && [ ! -t 0 ] && ! command -v pkexec >/dev/null 2>&1; then in_terminal; fi
log=$(mktemp)
trap 'rm -f "$log"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

if [ "$(id -u)" -eq 0 ]; then
    sh "$installer" "$appdir" "$action" >"$log" 2>&1 && status=0 || status=$?
elif command -v pkexec >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    pkexec /bin/sh "$installer" "$appdir" "$action" >"$log" 2>&1 && status=0 || status=$?
elif command -v sudo >/dev/null 2>&1; then
    sudo sh "$installer" "$appdir" "$action" >"$log" 2>&1 && status=0 || status=$?
else
    report --error 'Install sudo/polkit or run this installation command as root.'
    exit 1
fi
if [ "$status" -ne 0 ]; then
    report --error "task_master installation failed:
$(cat "$log")"
    exit "$status"
fi
cat "$log"
if [ "$action" = --remove ]; then report --info 'task_master removed. User preferences and histories were retained.'
else
    report --info 'task_master installed. Open it from the applications menu. Enable Persistence in the app if wanted.'
    if [ -z "$action" ] && [ "$(id -u)" -ne 0 ]; then
        rm -f "$log"
        exec /usr/local/bin/task_master
    fi
fi
