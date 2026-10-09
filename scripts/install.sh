#!/bin/sh
set -eu

case ${1:-local} in
    local)
        installer=$(realpath scripts/install-system.sh)
        collector=$(realpath build/task_master-collector)
        desktop=$(realpath build/task_master)
        if [ "$(id -u)" -eq 0 ]; then
            sh "$installer" "$collector" "$desktop"
        elif [ -t 0 ] || sudo -n true 2>/dev/null; then
            sudo sh "$installer" "$collector" "$desktop"
        else
            pkexec /usr/bin/sh "$installer" "$collector" "$desktop"
        fi
        if [ "$(id -u)" -ne 0 ]; then /usr/local/bin/task_master --stats; fi
        ;;
    remote)
        host=${2:-}
        case "$host" in
            ''|-*|*[!a-zA-Z0-9_.@:%\[\]-]*)
                echo 'Set HOST to an SSH alias or user@host (ports belong in SSH config).' >&2
                exit 2
                ;;
        esac
        stage=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$host" \
            "set -eu; [ \"\$(uname -s)\" = Linux ]; [ \"\$(uname -m)\" = '$(uname -m)' ]; mktemp -d /tmp/task_master-install-XXXXXXXX")
        case "$stage" in
            /tmp/task_master-install-????????) ;;
            *) echo 'Unable to stage the collector on this host.' >&2; exit 1 ;;
        esac
        stage_suffix=${stage#/tmp/task_master-install-}
        case "$stage_suffix" in
            *[!a-zA-Z0-9]*) echo 'Unexpected remote staging path.' >&2; exit 1 ;;
        esac
        cleanup() { ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$host" "rm -rf '$stage'" </dev/null; }
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' HUP TERM
        scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes build/task_master-collector scripts/install-system.sh "$host:$stage/"
        ssh -t -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$host" \
            "sudo sh '$stage/install-system.sh' '$stage/task_master-collector'"
        ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$host" \
            '/usr/local/libexec/task_master/collector --stats'
        ;;
    *) echo 'Usage: sh scripts/install.sh [local | remote HOST]' >&2; exit 2 ;;
esac
