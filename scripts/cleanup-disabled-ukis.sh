#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

esp_device=/dev/disk/by-partlabel/esp
esp_mount=/boot/efi
uki_dir=$esp_mount/EFI/ubuntu
mounted_here=false

if [ "$#" -ne 0 ]; then
	echo "usage: sudo $0" >&2
	exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root" >&2
	exit 1
fi

if [ ! -b "$esp_device" ]; then
	echo "missing ESP device: $esp_device" >&2
	exit 1
fi

cleanup()
{
	if [ "$mounted_here" = true ]; then
		sync
		umount "$esp_mount"
	fi
}
trap cleanup EXIT HUP INT TERM

if findmnt -rn -M "$esp_mount" >/dev/null 2>&1; then
	mounted_source=$(findmnt -rn -o SOURCE -M "$esp_mount")
	if [ "$(readlink -f -- "$mounted_source")" != "$(readlink -f -- "$esp_device")" ]; then
		echo "$esp_mount is mounted from unexpected device: $mounted_source" >&2
		exit 1
	fi
else
	if [ ! -d "$esp_mount" ]; then
		install -d -m 0755 -- "$esp_mount"
	fi
	mount -t vfat "$esp_device" "$esp_mount"
	mounted_here=true
fi

if [ ! -d "$uki_dir" ]; then
	echo "missing expected UKI directory: $uki_dir" >&2
	exit 1
fi

found=false
for disabled in "$uki_dir"/*.disabled; do
	if [ ! -f "$disabled" ]; then
		continue
	fi
	found=true
	size=$(stat -c %s -- "$disabled")
	echo "removing: $disabled ($size bytes)"
	rm -f -- "$disabled"
done

if [ "$found" = false ]; then
	echo "no disabled UKIs found in $uki_dir"
else
	sync "$uki_dir"
	df -h "$esp_mount"
	echo "removed all top-level *.disabled files from $uki_dir"
fi
