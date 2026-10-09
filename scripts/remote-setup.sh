#!/bin/sh
# Local terminal launcher. task_master replaces only the quoted template values.
set -eu
stage=@STAGE@
host=@HOST@
port=@PORT@
install_requested=@INSTALL@
windows_probe=@WINDOWS_PROBE@
windows_install=@WINDOWS_INSTALL@
windows_cleanup=@WINDOWS_CLEANUP@
remote_stage=
remote_windows=false
ssh_batch() {
    if [ "$port" -gt 0 ]; then
        command ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -p "$port" "$@"
    else
        command ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$@"
    fi
}
scp_batch() {
    if [ "$port" -gt 0 ]; then
        command scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -P "$port" "$@"
    else
        command scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$@"
    fi
}
cleanup() {
    result=$?
    trap - EXIT
    if [ -n "$remote_stage" ]; then
        if $remote_windows; then ssh_batch -- "$host" "$windows_cleanup" </dev/null || :
        else ssh_batch -- "$host" "rm -rf '$remote_stage'" </dev/null || :
        fi
    fi
    if [ "$result" -eq 0 ]; then echo 'Installer finished. task_master will reconnect and verify telemetry.'
    else echo "Setup failed (exit $result). Read the error above, fix it, then retry."
    fi
    # Remove payloads immediately, and keep only the tiny result for the app.
    find "$stage" -type f -delete
    printf '%s\n' "$result" > "$stage/result"
    echo 'Press Enter to close this terminal.'
    read -r answer || :
    rm -rf "$stage"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
if [ "$install_requested" = false ]; then
    echo "Opening passwordless SSH to $host. Exit the shell to return to task_master."
    ssh_batch -t -- "$host"
    exit
fi
echo "Installing task_master collector and hardware sensor access on $host."
echo 'SSH must already work without a password. Any prompt below is for administrator installation.'
platform=$(ssh_batch -- "$host" 'uname -s; uname -m' 2>/dev/null) || platform=
case "$platform" in
    Linux*) system=linux ;;
    Darwin*) system=darwin ;;
    *)
        platform=$(ssh_batch -- "$host" "$windows_probe")
        case "$platform" in task_master-windows-*) system=windows; remote_windows=true ;; *) echo 'Unsupported remote operating system.' >&2; exit 1 ;; esac
        ;;
esac
architecture=$(printf '%s\n' "$platform" | tail -n 1 | tr -d '\r')
case "$architecture" in
    x86_64|amd64|task_master-windows-AMD64|task_master-windows-X64) architecture=amd64 ;;
    aarch64|arm64|task_master-windows-ARM64) architecture=arm64 ;;
    riscv64) architecture=riscv64 ;;
    *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;;
esac
payload=$stage/collector-$system-$architecture
[ -s "$payload" ] || { echo "This build has no $system $architecture collector. Use a complete release build." >&2; exit 1; }
scp_host=$host
case "$host" in
    *:*)
        case "$host" in
            *\[*) ;;
            *@*) scp_host="${host%@*}@[${host##*@}]" ;;
            *) scp_host="[$host]" ;;
        esac
        ;;
esac
if $remote_windows; then
    remote_stage=$(ssh_batch -- "$host" @WINDOWS_STAGE@)
    remote_stage=$(printf '%s' "$remote_stage" | tr -d '\r')
    scp_batch "$payload" "$scp_host:$remote_stage/collector"
    scp_batch "$stage/install-remote-windows.ps1" "$stage/install-sensors.ps1" "$scp_host:$remote_stage/"
    if [ -s "$stage/sensors.zip" ]; then scp_batch "$stage/sensors.zip" "$scp_host:$remote_stage/"; fi
    ssh_batch -t -- "$host" "$windows_install"
else
    remote_stage=$(ssh_batch -- "$host" 'umask 077; mktemp -d /tmp/task_master-install-XXXXXXXX')
    case "$remote_stage" in /tmp/task_master-install-????????) ;; *) remote_stage=; echo 'Unexpected remote staging path.' >&2; exit 1 ;; esac
    suffix=${remote_stage#/tmp/task_master-install-}
    case "$suffix" in *[!a-zA-Z0-9]*) remote_stage=; echo 'Unexpected remote staging path.' >&2; exit 1 ;; esac
    scp_batch "$payload" "$scp_host:$remote_stage/collector"
    scp_batch "$stage/install-remote-unix.sh" "$stage/install-system.sh" "$stage/task_master-sensors.sh" "$stage/sensors.plist" "$scp_host:$remote_stage/"
    ssh_batch -t -- "$host" "if [ \"\$(id -u)\" -eq 0 ]; then sh '$remote_stage/install-remote-unix.sh'; else sudo sh '$remote_stage/install-remote-unix.sh'; fi"
fi
