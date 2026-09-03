#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

dropin=/etc/systemd/system/hexagonrpcd.service.d/nabu-slpi.conf

[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

systemctl disable --now hexagonrpcd.service 2>/dev/null || true

if [ -f "$dropin" ] && \
	grep -Fqx 'Environment="hexagonrpcd_device=/dev/fastrpc-sdsp"' "$dropin" && \
	grep -Fqx 'Environment="hexagonrpcd_fw_dir=/lib/firmware/hexagonfs"' "$dropin"; then
	rm -- "$dropin"
	rmdir --ignore-fail-on-non-empty /etc/systemd/system/hexagonrpcd.service.d
	removed=yes
elif [ -e "$dropin" ]; then
	echo "refusing to remove unexpected systemd drop-in: $dropin" >&2
	exit 1
else
	removed=no
fi

systemctl daemon-reload

echo "stopped and disabled hexagonrpcd.service"
[ "$removed" = yes ] && echo "removed Nabu SLPI systemd override: $dropin"
echo "preserved the hexagonrpcd package and all sensor registry data"
