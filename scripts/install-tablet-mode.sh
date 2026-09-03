#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

binary_target=/usr/local/libexec/nabu-tablet-mode
unit_target=/etc/systemd/system/nabu-tablet-mode.service
doc_target=/usr/local/share/doc/nabu-accelerometer/DEVELOPMENT.md

[ "$#" -eq 1 ] || {
	echo "usage: sudo $0 /path/to/nabu-tablet-mode" >&2
	exit 2
}
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
unit_source=$script_dir/../config/nabu-tablet-mode.service
doc_source=$script_dir/../DEVELOPMENT.md
binary_source=$(realpath -- "$1")

[ -s "$binary_source" ] || {
	echo "missing tablet-mode helper: $binary_source" >&2
	exit 1
}
[ -f "$unit_source" ] || {
	echo "missing packaged unit: $unit_source" >&2
	exit 1
}
[ -f "$doc_source" ] || {
	echo "missing packaged development record: $doc_source" >&2
	exit 1
}
file "$binary_source" | grep -Fq 'ELF 64-bit LSB pie executable, ARM aarch64' || {
	echo "tablet-mode helper is not an AArch64 PIE executable" >&2
	exit 1
}
strings "$binary_source" | grep -Fq 'Nabu Tablet Mode Switch' || {
	echo "unexpected tablet-mode helper" >&2
	exit 1
}

model=$(tr -d '\000' </sys/firmware/devicetree/base/model 2>/dev/null || true)
case $model in
	'Xiaomi Pad 5 (nabu)'*) ;;
	*)
		echo "refusing non-Nabu machine: $model" >&2
		exit 1
		;;
esac

[ -c /dev/uinput ] || {
	modprobe uinput
	[ -c /dev/uinput ] || {
		echo "uinput is unavailable" >&2
		exit 1
	}
}

if [ -e "$binary_target" ]; then
	strings "$binary_target" | grep -Fq 'Nabu Tablet Mode Switch' || {
		echo "refusing to replace unexpected binary: $binary_target" >&2
		exit 1
	}
fi
if [ -e "$unit_target" ] && ! cmp -s "$unit_target" "$unit_source"; then
	echo "refusing to replace unexpected unit: $unit_target" >&2
	exit 1
fi

install -d -o root -g root -m 0755 "$(dirname -- "$binary_target")"
install -d -o root -g root -m 0755 "$(dirname -- "$doc_target")"
install -o root -g root -m 0755 "$binary_source" "$binary_target"
install -o root -g root -m 0644 "$unit_source" "$unit_target"
install -o root -g root -m 0644 "$doc_source" "$doc_target"

systemctl daemon-reload
systemctl enable --now nabu-tablet-mode.service
systemctl is-active --quiet nabu-tablet-mode.service

attempt=0
while [ "$attempt" -lt 80 ]; do
	if grep -Fq 'Nabu Tablet Mode Switch' /proc/bus/input/devices; then
		break
	fi
	attempt=$((attempt + 1))
	sleep 0.1
done
grep -Fq 'Nabu Tablet Mode Switch' /proc/bus/input/devices || {
	echo "tablet-mode input device did not appear" >&2
	exit 1
}

echo "installed and enabled Nabu tablet-mode switch"
echo "binary SHA256: $(sha256sum "$binary_target" | cut -d ' ' -f 1)"
echo "the switch starts OFF, then changes to ON five seconds after the user GNOME Shell appears"
echo "this ordering lets Mutter consume its native-portrait initial orientation first"
echo "rollback: sudo ./remove-tablet-mode.sh"
