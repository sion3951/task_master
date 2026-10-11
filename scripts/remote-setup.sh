#!/bin/sh
# Local terminal launcher. task_master replaces only the quoted template values.
set -eu
stage=@STAGE@
host=@HOST@
port=@PORT@
install_requested=@INSTALL@
protocol=@PROTOCOL@
helper=@HELPER@
step=Starting
progress() {
    step=$1
    printf '%s\n' "$step" > "$stage/progress"
    printf '\n%s\n' "$step"
}
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
    if [ "$result" -eq 0 ] && [ "$install_requested" = true ]; then echo 'Installation complete. Step 6/6: task_master must reconnect and verify fresh telemetry.'
    elif [ "$result" -eq 0 ]; then echo 'SSH session finished.'
    else echo "Setup failed during $step (exit $result). Read the error above, fix it, then retry Setup / fix."
    fi
    # Remove payloads immediately, and keep only the tiny result for the app.
    find "$stage" -type f ! -name progress -delete
    printf '%s\n' "$result" > "$stage/result.pending"
    mv "$stage/result.pending" "$stage/result"
    echo 'Press Enter to close this terminal.'
    read -r answer || :
    # Give the GUI time to acknowledge the result even when Enter is pressed
    # immediately. If it has closed, still clean staging before this exits.
    attempts=0
    while [ ! -f "$stage/acknowledged" ] && [ "$attempts" -lt 3 ]; do
        sleep 1; attempts=$((attempts+1))
    done
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
echo "Guided setup for $host. This installs a durable collector and hardware sensor access."
echo 'Ordinary reconnections reuse the installed collector without administrator prompts.'
progress 'Step 1/6: SSH connection and host trust'
# A terminal may confirm a new host key and authenticate interactively. Never
# bypass changed-host-key checks or alter the configured SSH alias/jump host.
if ! ssh_batch -- "$host" exit; then
    echo 'Check the SSH error above. For a new host, verify its displayed fingerprint before accepting it.'
    echo 'The following connection can ask for host trust or your account password.'
    if [ "$port" -gt 0 ]; then
        command ssh -o BatchMode=no -o StrictHostKeyChecking=ask -o ConnectTimeout=8 -p "$port" -- "$host" exit
    else
        command ssh -o BatchMode=no -o StrictHostKeyChecking=ask -o ConnectTimeout=8 -- "$host" exit
    fi
fi
progress 'Step 2/6: Passwordless authentication for automatic reconnection'
if ! ssh_batch -- "$host" exit; then
    echo 'SSH works interactively, but unattended authentication still needs a key or agent.' >&2
    echo 'Add this PC to your SSH configuration and load its key into your SSH agent.' >&2
    if command -v ssh-copy-id >/dev/null 2>&1; then
        echo "You can provision an existing public key with ssh-copy-id (include -p $port when a custom port is used), then retry Setup / fix." >&2
    fi
    exit 1
fi
progress 'Step 3/6: Operating system and architecture'
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
echo "Detected $system $architecture; collector uses protocol $protocol."
if [ ! -s "$payload" ] || { $remote_windows && [ ! -s "$stage/sensors.zip" ]; }; then
    progress 'Step 3/6: Prepare verified remote helpers (download or cache)'
    "$helper" --prepare-remote-helpers "$system" "$architecture" "$stage"
fi
[ -s "$payload" ] || { echo "Could not prepare the $system $architecture collector." >&2; exit 1; }
progress 'Step 4/6: Transfer and collector compatibility'
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
    scp_batch "$payload" "$scp_host:$remote_stage/collector.exe"
    scp_batch "$stage/install-remote-windows.ps1" "$stage/install-sensors.ps1" "$scp_host:$remote_stage/"
    if [ -s "$stage/sensors.zip" ]; then scp_batch "$stage/sensors.zip" "$scp_host:$remote_stage/"; fi
    ssh_batch -- "$host" @WINDOWS_VALIDATE@
    progress 'Step 5/6: Durable collector and sensor permissions (administrator access)'
    ssh_batch -t -- "$host" "$windows_install"
else
    remote_stage=$(ssh_batch -- "$host" 'umask 077; mktemp -d /tmp/task_master-install-XXXXXXXX')
    case "$remote_stage" in /tmp/task_master-install-????????) ;; *) remote_stage=; echo 'Unexpected remote staging path.' >&2; exit 1 ;; esac
    suffix=${remote_stage#/tmp/task_master-install-}
    case "$suffix" in *[!a-zA-Z0-9]*) remote_stage=; echo 'Unexpected remote staging path.' >&2; exit 1 ;; esac
    scp_batch "$payload" "$scp_host:$remote_stage/collector"
    scp_batch "$stage/install-remote-unix.sh" "$stage/install-system.sh" "$stage/task_master-sensors.sh" "$stage/sensors.plist" "$scp_host:$remote_stage/"
    ssh_batch -- "$host" "chmod 700 '$remote_stage/collector'; actual=\$( '$remote_stage/collector' --protocol-version ); [ \"\$actual\" = '$protocol' ] || { echo 'Collector protocol mismatch. Use a complete matching release build.' >&2; exit 1; }"
    progress 'Step 5/6: Durable collector and sensor permissions (administrator access)'
    ssh_batch -t -- "$host" "if [ \"\$(id -u)\" -eq 0 ]; then sh '$remote_stage/install-remote-unix.sh' '$protocol'; else sudo sh '$remote_stage/install-remote-unix.sh' '$protocol'; fi"
fi
progress 'Step 6/6: Reconnect and verify fresh telemetry in task_master'
