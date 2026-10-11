#!/bin/sh
# Spawned by the desktop before shutdown. Only package installation is elevated;
# this helper and the relaunched desktop retain the original user's identity.
set -eu
umask 077
[ "$#" -eq 9 ] || exit 2
platform=$1 kind=$2 package=$3 stage=$4 parent=$5 executable=$6 portable=$7 expected_hash=$8 expected_size=$9
result=$(dirname "$stage")/install-result.txt
log=$stage/install.log
last_log=$(dirname "$stage")/last-install.log
install_lock=$(dirname "$stage")/install-lock
lock_owned=0
status=error
message='The update installer did not finish.'
exited=0
backup=
replacement=

finish() {
    code=$?
    trap - EXIT HUP INT TERM
    # Report before relaunch: startup consumes the result, while the log remains
    # available for diagnostics if the package manager or authorization failed.
    tail -c 262144 "$log" > "$last_log" 2>/dev/null || true
    printf '%s\n%s\nInstallation log: %s\n' "$status" "$message" "$last_log" > "$result.tmp"
    mv -f "$result.tmp" "$result"
    [ -z "$replacement" ] || rm -f "$replacement"
    if [ "$exited" -eq 1 ]; then
        unset APPDIR APPIMAGE OWD ARGV0 LD_LIBRARY_PATH LIBDECOR_PLUGIN_DIR XLOCALEDIR XKB_CONFIG_ROOT FONTCONFIG_PATH FONTCONFIG_FILE
        case "$platform:$kind" in
            darwin:macos) /usr/bin/open -a /Applications/task_master.app >/dev/null 2>&1 || true ;;
            linux:appimage)
                if [ -n "$portable" ]; then APPIMAGE_EXTRACT_AND_RUN=1 "$portable" --run >/dev/null 2>&1 &
                else /usr/local/bin/task_master >/dev/null 2>&1 & fi ;;
            *) "$executable" >/dev/null 2>&1 & ;;
        esac
    fi
    # A bounded final log and result are enough for diagnosis. Remove staged
    # packages on either outcome so failed downloads do not accumulate.
    [ -z "$backup" ] || rm -f "$backup"
    rm -rf "$stage"
    if [ "$lock_owned" -eq 1 ] && [ "$(cat "$install_lock/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$install_lock"; fi
    exit "$code"
}
trap finish EXIT
trap 'message="Update installation interrupted."; exit 130' INT
trap 'message="Update installation interrupted."; exit 143' HUP TERM
fail() { message=$*; printf '%s\n' "$message" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || fail 'Update helper must run as the normal desktop user.'
case "$parent" in ''|*[!0-9]*) fail 'Invalid updater parent process.' ;; esac
case "$expected_hash" in ''|*[!0-9a-fA-F]*) fail 'Invalid signed package checksum.' ;; esac
[ "${#expected_hash}" -eq 64 ] || fail 'Invalid signed package checksum.'
case "$expected_size" in ''|*[!0-9]*) fail 'Invalid signed package size.' ;; esac

# Bound shutdown waiting rather than kill a desktop with unsaved state. Mark
# shutdown before acquiring the install lock, so a conflict relaunches the app.
remaining=120
while kill -0 "$parent" 2>/dev/null; do
    [ "$remaining" -gt 0 ] || fail 'task_master did not close; the previous installation was retained.'
    sleep 1
    remaining=$((remaining-1))
done
exited=1

# Serialize installation across desktop instances. A stale owner can only be
# reclaimed after taking the reclamation directory and rechecking its PID.
if ! mkdir "$install_lock" 2>/dev/null; then
    owner=$(cat "$install_lock/pid" 2>/dev/null || true)
    reclaim=0
    case "$owner" in
        ''|*[!0-9]*) [ -n "$(find "$install_lock" -prune -mmin +2 2>/dev/null)" ] && reclaim=1 ;;
        *) kill -0 "$owner" 2>/dev/null || reclaim=1 ;;
    esac
    if [ "$reclaim" -eq 1 ] && mkdir "$install_lock/reclaim" 2>/dev/null; then
        current_owner=$(cat "$install_lock/pid" 2>/dev/null || true)
        if [ "$current_owner" = "$owner" ] && { [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; }; then rm -rf "$install_lock"
        else rmdir "$install_lock/reclaim" 2>/dev/null || true; fi
    fi
    mkdir "$install_lock" 2>/dev/null || fail 'Another task_master update is already installing.'
fi
lock_owned=1
printf '%s\n' "$$" > "$install_lock/pid"

verify() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    actual_size=$(wc -c < "$1" | tr -d '[:space:]')
    [ "$actual_size" = "$expected_size" ] || return 1
    if [ "$platform" = darwin ]; then actual_hash=$(/usr/bin/shasum -a 256 "$1" | awk '{print $1}')
    else actual_hash=$(sha256sum "$1" | awk '{print $1}'); fi
    [ "$actual_hash" = "$expected_hash" ]
}
verify "$package" || fail 'Downloaded package changed after verification; the previous installation was retained.'

# Stop background persistence without changing its enablement or preferences.
if [ "$platform" = linux ]; then
    unit=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/task_master-persistence.service
    if [ -f "$unit" ]; then
        systemctl --user stop task_master-persistence.service || fail 'Could not stop background persistence cleanly.'
    fi
elif [ "$platform" = darwin ]; then
    agent=gui/$(id -u)/dev.task_master.persistence
    if /bin/launchctl print "$agent" > "$stage/launch-agent.txt" 2>&1; then
        service_pid=$(awk '/^[[:space:]]*pid = / {print $3; exit}' "$stage/launch-agent.txt")
        /bin/launchctl bootout "$agent" || fail 'Could not stop background persistence cleanly.'
        remaining=35
        while [ -n "$service_pid" ] && kill -0 "$service_pid" 2>/dev/null; do
            [ "$remaining" -gt 0 ] || fail 'Background persistence did not stop cleanly.'
            sleep 1; remaining=$((remaining-1))
        done
    elif [ -f "$HOME/Library/LaunchAgents/dev.task_master.persistence.plist" ] && ! grep -q 'Could not find service' "$stage/launch-agent.txt"; then
        fail 'Could not inspect background persistence.'
    fi
    rm -f "$stage/launch-agent.txt"
fi

# The elevated script first copies into a root-owned private directory and
# verifies again there. Package managers never install from a mutable download.
cat > "$stage/elevated.sh" <<'ROOTSCRIPT'
#!/bin/sh
set -eu
umask 077
platform=$1 kind=$2 source=$3 expected_hash=$4 expected_size=$5
[ "$(id -u)" -eq 0 ] || exit 1
work=$(mktemp -d /tmp/task_master-update-root-XXXXXX)
trap 'rm -rf "$work"' EXIT
case "$kind" in deb) package=$work/update.deb ;; macos) package=$work/update.pkg ;; appimage) package=$work/update.AppImage ;; *) exit 2 ;; esac
cp "$source" "$package"
[ "$(wc -c < "$package" | tr -d '[:space:]')" = "$expected_size" ] || exit 1
if [ "$platform" = darwin ]; then actual_hash=$(/usr/bin/shasum -a 256 "$package" | awk '{print $1}')
else actual_hash=$(sha256sum "$package" | awk '{print $1}'); fi
[ "$actual_hash" = "$expected_hash" ] || { echo 'Package checksum changed before installation.' >&2; exit 1; }
case "$kind" in
    deb) export DEBIAN_FRONTEND=noninteractive; apt-get install -y "$package" ;;
    macos)
        /usr/bin/ditto /Applications/task_master.app "$work/Previous.app"
        if /usr/sbin/installer -pkg "$package" -target /; then :
        else
            # Restore the prior desktop bundle after a failed package install.
            # System Installer receipts/dependencies remain package-manager state.
            rm -rf /Applications/task_master.app
            /usr/bin/ditto "$work/Previous.app" /Applications/task_master.app
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
        if sh "$work/squashfs-root/usr/share/task_master/install-appimage-system.sh" "$work/squashfs-root" --install; then :
        else
            if [ -d "$work/previous-runtime" ]; then rm -rf /opt/task_master; mv "$work/previous-runtime" /opt/task_master; fi
            if [ -f "$work/previous-collector" ]; then cp -p "$work/previous-collector" /usr/local/libexec/task_master/collector; command -v setcap >/dev/null 2>&1 && setcap cap_perfmon=ep /usr/local/libexec/task_master/collector || true; fi
            exit 1
        fi ;;
esac
ROOTSCRIPT
chmod 600 "$stage/elevated.sh"

elevate() {
    if [ "$platform" = darwin ]; then
        # Pass paths as AppleScript argv, with quoted form handling spaces and
        # apostrophes. Only this installer command gains administrator rights.
        /usr/bin/osascript - "$stage/elevated.sh" "$platform" "$kind" "$package" "$expected_hash" "$expected_size" <<'APPLESCRIPT'
on run arguments
    set commandText to "/bin/sh"
    repeat with argumentText in arguments
        set commandText to commandText & " " & quoted form of (argumentText as text)
    end repeat
    do shell script commandText with administrator privileges
end run
APPLESCRIPT
    elif command -v pkexec >/dev/null 2>&1; then
        pkexec /bin/sh "$stage/elevated.sh" "$platform" "$kind" "$package" "$expected_hash" "$expected_size"
    elif [ -t 0 ]; then
        sudo /bin/sh "$stage/elevated.sh" "$platform" "$kind" "$package" "$expected_hash" "$expected_size"
    elif command -v sudo >/dev/null 2>&1; then
        # Without polkit, open a terminal for sudo's password prompt. Write a
        # completion marker because desktop terminal launchers may fork/return.
        cat > "$stage/elevate-terminal.sh" <<'TERMINAL'
#!/bin/sh
stage=$1
set +e
sudo /bin/sh "$stage/elevated.sh" "$2" "$3" "$4" "$5" "$6"
code=$?
printf '%s\n' "$code" > "$stage/elevated-result.txt"
exit "$code"
TERMINAL
        terminal=
        for choice in gnome-terminal konsole xfce4-terminal x-terminal-emulator xterm; do
            if command -v "$choice" >/dev/null 2>&1; then terminal=$choice; break; fi
        done
        [ -n "$terminal" ] || { echo 'Install polkit or a desktop terminal to authorize updates.' >&2; return 1; }
        case "$terminal" in
            gnome-terminal) "$terminal" --wait -- /bin/sh "$stage/elevate-terminal.sh" "$stage" "$platform" "$kind" "$package" "$expected_hash" "$expected_size" & ;;
            konsole) "$terminal" --nofork -e /bin/sh "$stage/elevate-terminal.sh" "$stage" "$platform" "$kind" "$package" "$expected_hash" "$expected_size" & ;;
            xfce4-terminal) "$terminal" --disable-server -x /bin/sh "$stage/elevate-terminal.sh" "$stage" "$platform" "$kind" "$package" "$expected_hash" "$expected_size" & ;;
            *) "$terminal" -e /bin/sh "$stage/elevate-terminal.sh" "$stage" "$platform" "$kind" "$package" "$expected_hash" "$expected_size" & ;;
        esac
        terminal_pid=$!
        remaining=600
        while [ ! -f "$stage/elevated-result.txt" ]; do
            [ "$remaining" -gt 0 ] || { kill "$terminal_pid" 2>/dev/null || true; return 1; }
            sleep 1; remaining=$((remaining-1))
        done
        [ "$(cat "$stage/elevated-result.txt")" = 0 ]
    else echo 'Install polkit or sudo to authorize updates.' >&2; return 1; fi
}

if [ "$platform:$kind" = linux:appimage ] && [ -n "$portable" ]; then
    [ -f "$portable" ] && [ ! -L "$portable" ] || fail 'The portable AppImage was moved or removed.'
    destination=$(dirname "$portable")
    replacement=$(mktemp "$destination/.task_master-update-XXXXXX") || fail 'The AppImage directory is not writable.'
    cp "$package" "$replacement"
    chmod 755 "$replacement"
    verify "$replacement" || fail 'Staged AppImage verification failed.'
    backup=$(mktemp "$destination/.task_master-previous-XXXXXX")
    cp -p "$portable" "$backup"
    mv -f "$replacement" "$portable" || fail 'Could not replace the portable AppImage.'
    replacement=
else
    elevate || fail 'Installation failed or administrator authorization was cancelled. See the installation log.'
fi
status=success
message='task_master was updated successfully.'
