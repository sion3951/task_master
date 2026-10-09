#!/bin/sh
# Runs on the remote host, inside the administrator terminal opened by task_master.
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run this installer as root (normally via sudo).' >&2; exit 1; }
source_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case $(uname -s) in
    Linux)
        if ! command -v setcap >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then apt-get update; apt-get install -y libcap2-bin
            elif command -v dnf >/dev/null 2>&1; then dnf install -y libcap
            elif command -v yum >/dev/null 2>&1; then yum install -y libcap
            elif command -v pacman >/dev/null 2>&1; then pacman -S --needed --noconfirm libcap
            elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install libcap-progs
            else echo 'Install the package providing setcap, then retry Install / fix.' >&2; exit 1
            fi
        fi
        sh "$source_directory/install-system.sh" "$source_directory/collector"
        ;;
    Darwin)
        [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 ] || { echo 'macOS 13 or newer is required.' >&2; exit 1; }
        sensors='/Library/Application Support/task_master'
        collector_directory=/usr/local/libexec/task_master
        plist=/Library/LaunchDaemons/dev.task_master.sensors.plist
        for destination in "$sensors" "$collector_directory" "$plist" /var/run/task_master; do
            [ ! -L "$destination" ] || { echo "Refusing a symlink at $destination" >&2; exit 1; }
        done
        # Stop the previous shell and its powermetrics child before updating it.
        if launchctl print system/dev.task_master.sensors >"$source_directory/service.txt" 2>&1; then
            old_pid=$(awk '$1 == "pid" && $2 == "=" {print $3; exit}' "$source_directory/service.txt")
            launchctl bootout system/dev.task_master.sensors
            elapsed=0
            while [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; do
                [ "$elapsed" -lt 35 ] || { echo 'Sensor service did not stop cleanly.' >&2; exit 1; }
                sleep 1; elapsed=$((elapsed+1))
            done
        elif ! grep -q 'Could not find service' "$source_directory/service.txt"; then
            cat "$source_directory/service.txt" >&2; exit 1
        fi
        install -d -o root -g wheel -m 755 "$sensors" "$collector_directory"
        temporary=$(mktemp "$collector_directory/.collector-XXXXXX")
        trap 'rm -f "$temporary"' EXIT
        install -o root -g wheel -m 755 "$source_directory/collector" "$temporary"
        mv -f "$temporary" "$collector_directory/collector"
        install -o root -g wheel -m 644 "$source_directory/task_master-sensors.sh" "$sensors/task_master-sensors.sh"
        install -o root -g wheel -m 644 "$source_directory/sensors.plist" "$plist"
        plutil -lint "$plist"
        launchctl enable system/dev.task_master.sensors
        launchctl bootstrap system "$plist"
        echo 'Collector and macOS power/clock sensor service installed.'
        ;;
    *) echo 'Unsupported remote operating system.' >&2; exit 1 ;;
esac
# Check the executable while still privileged; sampling itself drops capabilities.
/usr/local/libexec/task_master/collector --protocol-version
