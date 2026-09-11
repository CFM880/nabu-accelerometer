#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

kernel_release=6.14.11-nabu-iris-camera1+
expected_uki=nabu-accelerometer-production.efi
expected_production_sha256=ffc4686dad32b76c1c17320d574f823dee14da7278fb176ef11bfe984afc46c1
previous_production_sha256=ee992b7a34d7d0440b0dd33d6ff88827c608d87ee5fd84fd885df974ab463146
older_production_sha256=2a013298756a1c4e7363baa88e592f55dcecb8260cacb0d6990b3aea2745d96d
legacy_production_sha256=bfe54a5f336b82e9424a8cb567f32251e554bfaaea4cba90d7416d4fdbdaab12
default_uki=6.14.11-nabu-iris-camera1+-build1.efi
original_default_sha256=873994f0af8d42f9cc65752b4381e77b2e153cd6bb8455d08bafcd8b05082491
alternate_original_backup_sha256=19b2b48ca4bbe6d21064083d0ea8b2a3ec28edc02ee3d5c73c0cc90c3de04a07
expected_fastrpc_module=fastrpc.ko
expected_pdm_module=qcom_pd_mapper.ko
esp_device=/dev/disk/by-partlabel/esp
esp_mount=/boot/efi
backup_dir=/var/lib/nabu-accelerometer
backup_uki=$backup_dir/$default_uki.pre-accelerometer
fastrpc_module_target=/lib/modules/$kernel_release/kernel/drivers/misc/$expected_fastrpc_module
pdm_module_target=/lib/modules/$kernel_release/kernel/drivers/soc/qcom/$expected_pdm_module
mounted_here=false

usage()
{
	echo "usage: sudo $0 /path/to/$expected_uki /path/to/$expected_fastrpc_module /path/to/$expected_pdm_module" >&2
	exit 2
}

[ "$#" -eq 3 ] || usage
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

source_uki=$(realpath -- "$1")
source_fastrpc_module=$(realpath -- "$2")
source_pdm_module=$(realpath -- "$3")
for source in "$source_uki" "$source_fastrpc_module" "$source_pdm_module"; do
	[ -s "$source" ] || {
		echo "missing production artifact: $source" >&2
		exit 1
	}
done
[ "$(basename -- "$source_uki")" = "$expected_uki" ] || usage
[ "$(basename -- "$source_fastrpc_module")" = "$expected_fastrpc_module" ] || usage
[ "$(basename -- "$source_pdm_module")" = "$expected_pdm_module" ] || usage
source_uki_sha256=$(sha256sum "$source_uki" | cut -d ' ' -f 1)
[ "$source_uki_sha256" = "$expected_production_sha256" ] || {
	echo "production UKI SHA256 mismatch" >&2
	echo "expected: $expected_production_sha256" >&2
	echo "actual:   $source_uki_sha256" >&2
	exit 1
}

strings "$source_uki" | grep -Fq 'SLPI boot-only diagnostic' || {
	echo "production UKI does not contain the validated SLPI DTB" >&2
	exit 1
}
strings "$source_uki" | grep -Fq \
	'root=PARTLABEL=linux rw fw_devlink=permissive modprobe.blacklist=venus_core,qcom_iris module_blacklist=venus_core,qcom_iris' || {
	echo "production UKI does not contain the expected command line" >&2
	exit 1
}
if strings "$source_uki" | grep -Fq 'console=ttyGS0'; then
	echo "production UKI unexpectedly contains the USB diagnostic console" >&2
	exit 1
fi
if strings "$source_uki" | grep -Fq 'qcom,nabu-sm8150-scc'; then
	echo "production UKI contains a blocked AP-side SCC node" >&2
	exit 1
fi

[ "$(modinfo -F name "$source_fastrpc_module")" = fastrpc ] || exit 1
[ "$(modinfo -F name "$source_pdm_module")" = qcom_pd_mapper ] || exit 1
for source_module in "$source_fastrpc_module" "$source_pdm_module"; do
	module_vermagic=$(modinfo -F vermagic "$source_module")
	case $module_vermagic in
		"$kernel_release "*) ;;
		*)
			echo "module release mismatch: $module_vermagic" >&2
			exit 1
			;;
	esac
done
strings "$source_fastrpc_module" | grep -Fq \
	'enabling SM8150 SDSP high-IOVA workaround' || {
	echo "FastRPC module lacks the validated SM8150 SDSP workaround" >&2
	exit 1
}
strings "$source_fastrpc_module" | grep -Fq \
	'tracking protection domain %s for %s' || {
	echo "FastRPC module lacks SLPI attach-PD PDR gating" >&2
	exit 1
}
[ -b "$esp_device" ] || {
	echo "missing ESP device: $esp_device" >&2
	exit 1
}

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
	[ "$(readlink -f -- "$mounted_source")" = "$(readlink -f -- "$esp_device")" ] || {
		echo "$esp_mount is mounted from unexpected device: $mounted_source" >&2
		exit 1
	}
else
	install -d -m 0755 -- "$esp_mount"
	mount -t vfat "$esp_device" "$esp_mount"
	mounted_here=true
fi

destination_dir=$esp_mount/EFI/ubuntu
destination_uki=$destination_dir/$default_uki
temporary_uki=$destination_uki.new
[ -d "$destination_dir" ] || {
	echo "missing expected UKI directory: $destination_dir" >&2
	exit 1
}
[ -s "$destination_uki" ] || {
	echo "missing expected default UKI: $destination_uki" >&2
	find "$destination_dir" -maxdepth 1 -type f -name '*.efi' -print >&2
	exit 1
}

installed_uki_sha256=$(sha256sum "$destination_uki" | cut -d ' ' -f 1)

install -d -o root -g root -m 0700 "$backup_dir"
if [ -e "$backup_uki" ]; then
	backup_sha256=$(sha256sum "$backup_uki" | cut -d ' ' -f 1)
	case $backup_sha256 in
		"$original_default_sha256"|"$alternate_original_backup_sha256") ;;
		*)
			echo "refusing unexpected default UKI backup: $backup_uki" >&2
			exit 1
			;;
	esac
elif [ "$installed_uki_sha256" = "$original_default_sha256" ]; then
	install -o root -g root -m 0600 "$destination_uki" "$backup_uki.new"
	sync "$backup_uki.new"
	backup_sha256=$(sha256sum "$backup_uki.new" | cut -d ' ' -f 1)
	[ "$backup_sha256" = "$original_default_sha256" ] || exit 1
	mv -f -- "$backup_uki.new" "$backup_uki"
	sync "$backup_uki"
else
	echo "default UKI does not match the known pre-accelerometer image" >&2
	echo "expected: $original_default_sha256" >&2
	echo "actual:   $installed_uki_sha256" >&2
	exit 1
fi

if [ "$installed_uki_sha256" != "$source_uki_sha256" ]; then
	case $installed_uki_sha256 in
		"$original_default_sha256"|"$previous_production_sha256"|"$older_production_sha256"|"$legacy_production_sha256"|"$expected_production_sha256") ;;
		*)
			echo "refusing to overwrite an unknown default UKI" >&2
			exit 1
			;;
	esac
	rm -f -- "$temporary_uki"
	install -m 0644 -- "$source_uki" "$temporary_uki"
	sync "$temporary_uki"
	[ "$(sha256sum "$temporary_uki" | cut -d ' ' -f 1)" = "$source_uki_sha256" ] || exit 1
	mv -f -- "$temporary_uki" "$destination_uki"
	sync "$destination_uki"
	installed_uki_sha256=$source_uki_sha256
fi

install -d -m 0755 -- "$(dirname -- "$fastrpc_module_target")"
install -m 0644 -- "$source_fastrpc_module" "$fastrpc_module_target"
install -m 0644 -- "$source_pdm_module" "$pdm_module_target"
depmod "$kernel_release"
sync "$fastrpc_module_target" "$pdm_module_target"

echo "promoted the validated SLPI accelerometer UKI to the existing default path"
echo "default UKI: $destination_uki"
echo "production SHA256: $installed_uki_sha256"
echo "recoverable original backup: $backup_uki"
echo "reboot is required"
