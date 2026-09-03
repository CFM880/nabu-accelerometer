#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

firmware_dir=/lib/firmware/qcom/sm8150/xiaomi/nabu

[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

for name in sensors socinfo; do
	target=$firmware_dir/$name
	expected=../../../../hexagonfs/$name

	if [ -L "$target" ] && [ "$(readlink -- "$target")" = "$expected" ]; then
		rm -- "$target"
		echo "removed diagnostic mapping: $target"
	elif [ -e "$target" ] || [ -L "$target" ]; then
		echo "refusing to remove unexpected path: $target" >&2
		exit 1
	fi
	done

# Preserve /var/lib/tqftpserv because it may contain calibration or registry
# data written by firmware. It can be inspected and removed separately.
echo "preserved /var/lib/tqftpserv and any firmware-written data"
