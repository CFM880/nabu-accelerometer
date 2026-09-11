#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

dropin_dir=/etc/systemd/system/hexagonrpcd.service.d
dropin=$dropin_dir/nabu-slpi.conf
legacy_dropin_sha256=8c6f65e9d79092716ee0ac917a6162710632f01ddd23d1442c76208256792625
delayed_dropin_sha256=29571e705fdf67d8e6b810b272162648ba509f4af4f71a54f4cceeb4a28c5d56
sensors_pd_dropin_sha256=256e0af7d26434dd84830a4fcc7929536a91ebf4e799103a856951453b78ad19
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
	case $installed_dropin_sha256 in
		"$legacy_dropin_sha256"|"$delayed_dropin_sha256"|"$sensors_pd_dropin_sha256") ;;
		*)
			echo "refusing to replace unexpected systemd drop-in: $dropin" >&2
			exit 1
			;;
	esac
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
echo "SLPI root-PD readiness: kernel PDR event (15-second failure timeout)"
echo "the current SLPI recovery cycle will retry initialization automatically"
