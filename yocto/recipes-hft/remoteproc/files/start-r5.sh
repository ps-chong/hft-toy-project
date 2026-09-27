#!/bin/sh
set -eu

remoteproc=/sys/class/remoteproc/remoteproc0
firmware=hft-r5.elf

if [ ! -d "$remoteproc" ]; then
    echo "remoteproc0 is unavailable" >&2
    exit 1
fi

case "${1:-}" in
    start)
        if [ "$(cat "$remoteproc/state")" = "running" ]; then
            exit 0
        fi
        printf '%s' "$firmware" > "$remoteproc/firmware"
        printf '%s' start > "$remoteproc/state"
        ;;
    stop)
        if [ "$(cat "$remoteproc/state")" = "running" ]; then
            printf '%s' stop > "$remoteproc/state"
        fi
        ;;
    *)
        echo "usage: $0 start|stop" >&2
        exit 2
        ;;
esac
