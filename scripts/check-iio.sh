#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

found=0

for device in /sys/bus/iio/devices/iio:device*; do
	[ -d "$device" ] || continue
	[ -r "$device/name" ] || continue
	name=$(cat "$device/name")
	case $name in
		lsm6dso_*)
			found=1
			echo "$device: $name"
			for attribute in "$device"/in_accel_*_raw \
					 "$device"/in_anglvel_*_raw \
					 "$device"/in_temp_raw; do
				[ -r "$attribute" ] || continue
				printf '  %s=%s\n' "${attribute##*/}" "$(cat "$attribute")"
			done
			;;
	esac
done

if [ "$found" -eq 0 ]; then
	echo "no LSM6DSO IIO devices found" >&2
	echo "check the active DTB, st_lsm6dsx_spi module, and kernel log" >&2
	exit 1
fi
