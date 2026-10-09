#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ] || [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo 'Usage: sudo sh install-system.sh COLLECTOR [DESKTOP]' >&2
    exit 2
fi
collector_source=$1
collector_directory=/usr/local/libexec/task_master
install -d -o root -g root -m 755 "$collector_directory"
temporary=$(mktemp "$collector_directory/.collector-XXXXXX")
trap 'rm -f "$temporary"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
install -o root -g root -m 755 "$collector_source" "$temporary"
# This grant is an installation step. The helper drops it after opening only
# package-energy counters. Builds, launches and sampling never authenticate.
setcap cap_perfmon=ep "$temporary"
mv -f "$temporary" "$collector_directory/collector"
getcap "$collector_directory/collector"
if [ "$#" -eq 2 ]; then
    install -d -o root -g root -m 755 /usr/local/bin
    temporary=$(mktemp /usr/local/bin/.task_master-XXXXXX)
    install -o root -g root -m 755 "$2" "$temporary"
    mv -f "$temporary" /usr/local/bin/task_master
    echo 'Installed task_master. Launch it as your normal user.'
else
    echo 'Installed collector. task_master selects it on the next connection.'
fi
