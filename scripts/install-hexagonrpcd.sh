#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

dropin_dir=/etc/systemd/system/hexagonrpcd.service.d
dropin=$dropin_dir/nabu-slpi.conf
legacy_dropin_sha256=8c6f65e9d79092716ee0ac917a6162710632f01ddd23d1442c76208256792625
hexagonfs_dir=/lib/firmware/hexagonfs
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dropin_source=$script_dir/../config/nabu-slpi-hexagonrpcd.conf

[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

[ -c /dev/fastrpc-sdsp ] || {
	echo "missing SLPI FastRPC device: /dev/fastrpc-sdsp" >&2
	exit 1
}

[ -f "$dropin_source" ] || {
	echo "missing packaged systemd override: $dropin_source" >&2
	exit 1
}

for path in \
	"$hexagonfs_dir/sensors/config" \
	"$hexagonfs_dir/sensors/registry" \
	"$hexagonfs_dir/sensors/sns_reg.conf" \
	"$hexagonfs_dir/socinfo"; do
	[ -e "$path" ] || {
		echo "missing Nabu HexagonFS input: $path" >&2
		exit 1
	}
done

if [ -e "$dropin" ] && ! cmp -s "$dropin" "$dropin_source"; then
	installed_dropin_sha256=$(sha256sum "$dropin" | cut -d ' ' -f 1)
	[ "$installed_dropin_sha256" = "$legacy_dropin_sha256" ] || {
		echo "refusing to replace unexpected systemd drop-in: $dropin" >&2
		exit 1
	}
fi

# Ubuntu's wrapper defaults unknown SoCs to ADSP.  Nabu's sensor process is
# the static sensors PD on SLPI, exposed by the upstream kernel as sdsp.
apt-get install --no-install-recommends -y hexagonrpcd

install -d -o root -g root -m 0755 "$dropin_dir"

install -o root -g root -m 0644 "$dropin_source" "$dropin"

udevadm trigger --subsystem-match=misc --sysname-match='fastrpc-*'
udevadm settle

runuser -u fastrpc -- test -r /dev/fastrpc-sdsp
runuser -u fastrpc -- test -w /dev/fastrpc-sdsp

systemctl daemon-reload
systemctl enable --now hexagonrpcd.service

echo "installed hexagonrpcd with Nabu SLPI sensors-PD configuration"
echo "FastRPC device: /dev/fastrpc-sdsp"
echo "HexagonFS root: $hexagonfs_dir"
echo "SLPI sensors-PD settle delay: 15 seconds"
echo "the current SLPI recovery cycle will retry initialization automatically"
