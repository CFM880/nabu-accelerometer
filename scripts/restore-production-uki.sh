#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

default_uki=6.14.11-nabu-iris-camera1+-build1.efi
original_default_sha256=873994f0af8d42f9cc65752b4381e77b2e153cd6bb8455d08bafcd8b05082491
alternate_original_backup_sha256=19b2b48ca4bbe6d21064083d0ea8b2a3ec28edc02ee3d5c73c0cc90c3de04a07
esp_device=/dev/disk/by-partlabel/esp
esp_mount=/boot/efi
backup_uki=/var/lib/nabu-accelerometer/$default_uki.pre-accelerometer
mounted_here=false

[ "$#" -eq 0 ] || {
	echo "usage: sudo $0" >&2
	exit 2
}
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}
[ -s "$backup_uki" ] || {
	echo "missing original UKI backup: $backup_uki" >&2
	exit 1
}
backup_sha256=$(sha256sum "$backup_uki" | cut -d ' ' -f 1)
case $backup_sha256 in
	"$original_default_sha256"|"$alternate_original_backup_sha256") ;;
	*)
		echo "original UKI backup failed verification" >&2
		exit 1
		;;
esac

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
	[ "$(readlink -f -- "$mounted_source")" = "$(readlink -f -- "$esp_device")" ] || exit 1
else
	install -d -m 0755 -- "$esp_mount"
	mount -t vfat "$esp_device" "$esp_mount"
	mounted_here=true
fi

destination_uki=$esp_mount/EFI/ubuntu/$default_uki
[ -s "$destination_uki" ] || {
	echo "missing default UKI path: $destination_uki" >&2
	exit 1
}
current_sha256=$(sha256sum "$destination_uki" | cut -d ' ' -f 1)
case $current_sha256 in
	"$original_default_sha256"|"$alternate_original_backup_sha256")
		echo "the original default UKI is already installed"
		exit 0
		;;
esac
strings "$destination_uki" | grep -Fq 'SLPI boot-only diagnostic' || {
	echo "refusing to replace an unknown current default UKI" >&2
	exit 1
}

temporary_uki=$destination_uki.restore-new
rm -f -- "$temporary_uki"
install -m 0644 -- "$backup_uki" "$temporary_uki"
sync "$temporary_uki"
[ "$(sha256sum "$temporary_uki" | cut -d ' ' -f 1)" = "$backup_sha256" ] || exit 1
mv -f -- "$temporary_uki" "$destination_uki"
sync "$destination_uki"

echo "restored the original default UKI: $destination_uki"
echo "backup retained at: $backup_uki"
echo "reboot is required"
