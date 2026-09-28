#!/bin/sh
set -eu

upgrade_available="$(fw_printenv -n upgrade_available 2>/dev/null || printf '0')"
[ "$upgrade_available" = "1" ] || exit 0

deadline=$((SECONDS + 45))
while [ "$SECONDS" -lt "$deadline" ]; do
    if mountpoint -q /data &&
       [ "$(findmnt -n -o PARTLABEL /data 2>/dev/null || true)" = "hft_data" ] &&
       [ -e /dev/rpmsg0 ] &&
       systemctl is-active --quiet hftd.service &&
       pg_isready --quiet &&
       hftctl status >/dev/null 2>&1; then
        fw_setenv upgrade_available 0
        fw_setenv bootcount 0
        logger --tag hft-update "confirmed healthy update slot"
        exit 0
    fi
    sleep 1
done

logger --tag hft-update --priority user.err \
    "health confirmation timed out; leaving upgrade flag for U-Boot rollback"
exit 1
