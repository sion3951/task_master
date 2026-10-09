#!/bin/sh
# Administrative authorization is confined to installation/removal.
set -eu
fail() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: sudo sh scripts/install-macos.sh [--app PATH] [--remove]
Install task_master.app in /Applications, its native SSH collector in
 /usr/local/libexec/task_master/collector, and the read-only sensor LaunchDaemon.
From a packaged build directory: sudo sh install-macos.sh
--remove stops services and removes installed executables; user preferences remain.
USAGE
}
remove=false
source_app=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --remove) remove=true; shift ;;
        --app) [ "$#" -ge 2 ] || fail '--app needs a bundle path'; source_app=$2; shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[ "$(uname -s)" = Darwin ] || fail 'This installer requires macOS 13 or newer.'
[ "$(id -u)" -eq 0 ] || fail 'Run this installer with sudo; the desktop itself stays unprivileged.'
os_major=$(sw_vers -productVersion | cut -d. -f1)
[ "$os_major" -ge 13 ] || fail 'task_master requires macOS 13 or newer.'
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
label=dev.task_master.sensors
agent_label=dev.task_master.persistence
daemon_plist=/Library/LaunchDaemons/$label.plist
sensor_directory='/Library/Application Support/task_master'
target_app=/Applications/task_master.app
collector_directory=/usr/local/libexec/task_master
case "$(uname -m)" in arm64) architecture=arm64; apple_arch=arm64 ;; x86_64) architecture=amd64; apple_arch=x86_64 ;; *) fail 'Unsupported Mac architecture.' ;; esac

# launchctl bootout removes the job before all its processes necessarily exit.
# Wait for the old shell, whose TERM handler kills and waits for powermetrics.
# Do not replace resources if graceful cleanup failed.
stop_job() {
    stop_target=$1
    diagnostic=$(mktemp)
    if launchctl print "$stop_target" > "$diagnostic" 2>&1; then
        old_pid=$(awk '$1 == "pid" && $2 == "=" { print $3; exit }' "$diagnostic")
        if ! launchctl bootout "$stop_target" > "$diagnostic" 2>&1; then
            cat "$diagnostic" >&2; rm -f "$diagnostic"; fail "Could not stop $stop_target. Installed resources were retained."
        fi
        if [ -n "$old_pid" ]; then
            elapsed=0
            while kill -0 "$old_pid" 2>/dev/null; do
                [ "$elapsed" -lt 35 ] || { rm -f "$diagnostic"; fail "Service $stop_target did not stop cleanly; installed resources were retained."; }
                sleep 1; elapsed=$((elapsed + 1))
            done
        fi
    elif ! grep -q 'Could not find service' "$diagnostic"; then
        # A logged-out user has no GUI domain and therefore no running agent.
        absent_domain=false
        case "$stop_target" in gui/*) if grep -q 'Could not find domain' "$diagnostic"; then absent_domain=true; fi ;; esac
        if ! $absent_domain; then
            cat "$diagnostic" >&2; rm -f "$diagnostic"; fail "Could not inspect $stop_target."
        fi
    fi
    rm -f "$diagnostic"
}

if $remove; then
    stop_job "system/$label"
    # Remove only the invoking account's user collector; never change another
    # account's saved machines/preferences or assume root's HOME is theirs.
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        user_uid=$(id -u "$SUDO_USER")
        user_home=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
        if [ -f "$user_home/Library/LaunchAgents/$agent_label.plist" ]; then
            stop_job "gui/$user_uid/$agent_label"
            rm -f "$user_home/Library/LaunchAgents/$agent_label.plist"
        fi
        [ -z "$user_home" ] || rm -rf "$user_home/Library/Application Support/task_master/persistence"
    fi
    rm -f "$daemon_plist"
    rm -rf "$sensor_directory" /var/run/task_master "$target_app" "$collector_directory"
    printf 'task_master removed; user preferences and history caches retained.\n'
    exit 0
fi

if [ -z "$source_app" ]; then
    if [ -d "$script_directory/task_master.app" ]; then source_app=$script_directory/task_master.app
    else source_app=$script_directory/../build/macos-$architecture/task_master.app; fi
fi
[ -f "$source_app/Contents/MacOS/task_master" ] && [ -f "$source_app/Contents/MacOS/task_master-collector" ] || fail "Incomplete app bundle: $source_app"
# file ships with macOS; lipo requires developer tools that an end user's Mac
# need not have. Accept a thin matching Mach-O or a universal binary containing it.
for binary in task_master task_master-collector; do
    binary_description=$(/usr/bin/file -b "$source_app/Contents/MacOS/$binary")
    case "$binary_description" in
        *Mach-O*" $apple_arch"*) ;;
        *) fail "The packaged $binary does not support this Mac's $apple_arch architecture." ;;
    esac
done
codesign --verify --strict "$source_app"
sensor_source=$script_directory/task_master-sensors.sh
[ -f "$sensor_source" ] || sensor_source=$script_directory/../sensors/macos/task_master-sensors.sh
[ -f "$sensor_source" ] || fail "Missing packaged sensor helper: $sensor_source"
sh -n "$sensor_source"
for dedicated_path in "$sensor_directory" "$collector_directory" "$daemon_plist" /var/run/task_master; do
    [ ! -L "$dedicated_path" ] || fail "Refusing a symlink at an installed helper path: $dedicated_path"
done

# Finish reversible staging before stopping any installed service.
staging=$(mktemp -d /Applications/.task_master-install.XXXXXX)
trap 'rm -rf "$staging"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$source_app" "$staging/task_master.app"
cp "$sensor_source" "$staging/task_master-sensors.sh"
cat > "$staging/$label.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.task_master.sensors</string>
<key>ProgramArguments</key><array><string>/bin/sh</string><string>/Library/Application Support/task_master/task_master-sensors.sh</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>ThrottleInterval</key><integer>5</integer>
<key>ExitTimeOut</key><integer>30</integer>
<key>Umask</key><integer>18</integer>
</dict></plist>
PLIST
plutil -lint "$staging/$label.plist"
stop_job "system/$label"
install -d -o root -g wheel -m 755 "$sensor_directory" "$collector_directory"
install -o root -g wheel -m 644 "$staging/task_master-sensors.sh" "$sensor_directory/task_master-sensors.sh"
install -o root -g wheel -m 644 "$0" "$sensor_directory/install-macos.sh"
install -o root -g wheel -m 644 "$staging/$label.plist" "$daemon_plist"
install -o root -g wheel -m 755 "$source_app/Contents/MacOS/task_master-collector" "$collector_directory/collector.new"
mv -f "$collector_directory/collector.new" "$collector_directory/collector"
if [ -e "$target_app" ]; then mv "$target_app" "$staging/Previous.app"; fi
mv "$staging/task_master.app" "$target_app"
chown -R root:wheel "$target_app" "$sensor_directory" "$collector_directory"
launchctl enable "system/$label"
if ! launchctl bootstrap system "$daemon_plist"; then
    fail 'task_master was installed, but its sensor LaunchDaemon could not start. Run this installer again to retry.'
fi
printf 'task_master installed in /Applications; native collector and sensor service ready.\n'
printf 'Open task_master as your normal user. Enable Persistence in the app to collect after closing its window.\n'
