#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

binary=/usr/local/libexec/nabu-tablet-mode
unit=/etc/systemd/system/nabu-tablet-mode.service
doc=/usr/local/share/doc/nabu-accelerometer/DEVELOPMENT.md

[ "$#" -eq 0 ] || {
	echo "usage: sudo $0" >&2
	exit 2
}
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

if [ -e "$binary" ]; then
	strings "$binary" | grep -Fq 'Nabu Tablet Mode Switch' || {
		echo "refusing to remove unexpected binary: $binary" >&2
		exit 1
	}
fi
if [ -e "$unit" ]; then
	grep -Fqx 'ExecStart=/usr/local/libexec/nabu-tablet-mode' "$unit" || {
		echo "refusing to remove unexpected unit: $unit" >&2
		exit 1
	}
fi

systemctl disable --now nabu-tablet-mode.service 2>/dev/null || true
[ ! -e "$unit" ] || rm -- "$unit"
[ ! -e "$binary" ] || rm -- "$binary"
[ ! -e "$doc" ] || rm -- "$doc"
rmdir --ignore-fail-on-non-empty /usr/local/share/doc/nabu-accelerometer
systemctl daemon-reload

echo "removed the Nabu tablet-mode helper"
echo "Mutter will return to hardware-derived touch mode"
