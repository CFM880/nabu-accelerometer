#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

default_uki=6.14.11-nabu-iris-camera1+-build1.efi
esp_device=/dev/disk/by-partlabel/esp
esp_mount=/boot/efi
mounted_here=false
temporary_dir=

[ "$#" -eq 0 ] || {
	echo "usage: sudo $0" >&2
	exit 2
}
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}
[ -b "$esp_device" ] || {
	echo "missing ESP device: $esp_device" >&2
	exit 1
}
for command in findmnt mount umount objcopy sha256sum stat strings tr; do
	command -v "$command" >/dev/null 2>&1 || {
		echo "missing required command: $command" >&2
		exit 1
	}
done

cleanup()
{
	if [ -n "$temporary_dir" ] && [ -d "$temporary_dir" ]; then
		rm -rf -- "$temporary_dir"
	fi
	if [ "$mounted_here" = true ]; then
		umount "$esp_mount"
	fi
}
trap cleanup EXIT HUP INT TERM

if findmnt -rn -M "$esp_mount" >/dev/null 2>&1; then
	mounted_source=$(findmnt -rn -o SOURCE -M "$esp_mount")
	[ "$(readlink -f -- "$mounted_source")" = "$(readlink -f -- "$esp_device")" ] || {
		echo "$esp_mount is mounted from unexpected device: $mounted_source" >&2
		exit 1
	}
else
	install -d -m 0755 -- "$esp_mount"
	mount -t vfat -o ro "$esp_device" "$esp_mount"
	mounted_here=true
fi

source_uki=$esp_mount/EFI/ubuntu/$default_uki
[ -s "$source_uki" ] || {
	echo "missing expected default UKI: $source_uki" >&2
	exit 1
}

temporary_dir=$(mktemp -d /tmp/nabu-default-uki.XXXXXX)
copy_uki=$temporary_dir/default-copy.efi
cmdline=$temporary_dir/cmdline
uname_section=$temporary_dir/uname
dtb=$temporary_dir/dtb
linux_image=$temporary_dir/linux

# Giving objcopy an explicit output file is important: the ESP source remains
# untouched while its sections are extracted into the temporary directory.
objcopy \
	--dump-section .cmdline="$cmdline" \
	--dump-section .uname="$uname_section" \
	--dump-section .dtb="$dtb" \
	--dump-section .linux="$linux_image" \
	"$source_uki" "$copy_uki"

echo "default UKI inspection (read-only)"
echo "path: $source_uki"
echo "size: $(stat -c %s "$source_uki")"
echo "sha256: $(sha256sum "$source_uki" | cut -d ' ' -f 1)"
echo "uname:"
tr '\000' '\n' < "$uname_section"
echo "cmdline:"
tr '\000' '\n' < "$cmdline"
for section_file in "$linux_image" "$dtb"; do
	section_name=$(basename -- "$section_file")
	echo "$section_name size: $(stat -c %s "$section_file")"
	echo "$section_name sha256: $(sha256sum "$section_file" | cut -d ' ' -f 1)"
done

marker_status()
{
	marker=$1
	label=$2
	if strings "$source_uki" | grep -Fq "$marker"; then
		echo "$label: present"
	else
		echo "$label: absent"
	fi
}

marker_status 'SLPI boot-only diagnostic' 'SLPI DTB marker'
marker_status 'console=ttyGS0' 'USB console marker'
marker_status 'qcom,nabu-sm8150-scc' 'blocked AP SCC marker'
echo "inspection complete; the ESP was not modified"
