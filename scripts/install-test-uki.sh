#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

kernel_release=6.14.11-nabu-iris-camera1+
expected_uki=nabu-accelerometer-test.efi
expected_ssc_module=nabu-sm8150-ssc.ko
expected_spi_module=spi-geni-qcom.ko
expected_fastrpc_module=fastrpc.ko
expected_iris_module=qcom-iris.ko
esp_device=/dev/disk/by-partlabel/esp
esp_mount=/boot/efi
ssc_module_target=/lib/modules/$kernel_release/extra/$expected_ssc_module
spi_module_target=/lib/modules/$kernel_release/kernel/drivers/spi/$expected_spi_module
fastrpc_module_target=/lib/modules/$kernel_release/kernel/drivers/misc/$expected_fastrpc_module
iris_module_target=/lib/modules/$kernel_release/kernel/drivers/media/platform/qcom/iris/$expected_iris_module
mounted_here=false

usage()
{
	echo "usage: sudo $0 /path/to/$expected_uki /path/to/$expected_ssc_module /path/to/$expected_spi_module /path/to/$expected_fastrpc_module [/path/to/$expected_iris_module]" >&2
	exit 2
}

case $# in
	4 | 5) ;;
	*) usage ;;
esac
argument_count=$#
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

source_uki=$(realpath -- "$1")
source_ssc_module=$(realpath -- "$2")
source_spi_module=$(realpath -- "$3")
source_fastrpc_module=$(realpath -- "$4")
source_iris_module=
if [ "$argument_count" -eq 5 ]; then
	source_iris_module=$(realpath -- "$5")
fi
[ -s "$source_uki" ] || {
	echo "missing test UKI: $source_uki" >&2
	exit 1
}
[ -s "$source_ssc_module" ] || {
	echo "missing private SSC module: $source_ssc_module" >&2
	exit 1
}
[ -s "$source_spi_module" ] || {
	echo "missing upstream SPI module: $source_spi_module" >&2
	exit 1
}
[ -s "$source_fastrpc_module" ] || {
	echo "missing FastRPC module: $source_fastrpc_module" >&2
	exit 1
}
if [ -n "$source_iris_module" ]; then
	[ -s "$source_iris_module" ] || {
		echo "missing Iris module: $source_iris_module" >&2
		exit 1
	}
fi
[ "$(basename -- "$source_uki")" = "$expected_uki" ] || {
	echo "unexpected UKI name: $(basename -- "$source_uki")" >&2
	exit 1
}
[ "$(basename -- "$source_ssc_module")" = "$expected_ssc_module" ] || {
	echo "unexpected SSC module name: $(basename -- "$source_ssc_module")" >&2
	exit 1
}
[ "$(basename -- "$source_spi_module")" = "$expected_spi_module" ] || {
	echo "unexpected SPI module name: $(basename -- "$source_spi_module")" >&2
	exit 1
}
[ "$(basename -- "$source_fastrpc_module")" = "$expected_fastrpc_module" ] || {
	echo "unexpected FastRPC module name: $(basename -- "$source_fastrpc_module")" >&2
	exit 1
}
if [ -n "$source_iris_module" ] &&
   [ "$(basename -- "$source_iris_module")" != "$expected_iris_module" ]; then
	echo "unexpected Iris module name: $(basename -- "$source_iris_module")" >&2
	exit 1
fi
strings "$source_uki" | grep -Fq 'g_serial.use_acm' || {
	echo "test UKI does not contain the built-in USB serial gadget" >&2
	exit 1
}
strings "$source_uki" | grep -Fq \
	'console=ttyGS0 console=tty0 loglevel=8 ignore_loglevel no_console_suspend' || {
	echo "test UKI does not contain the USB console command line" >&2
	exit 1
}
if strings "$source_uki" | grep -Fq \
	'module_blacklist=venus_core,qcom_iris'; then
	profile=iris-blocked
	[ "$argument_count" -eq 4 ] || {
		echo "safe Iris-blocked UKI must not be installed with an Iris module argument" >&2
		exit 1
	}
elif strings "$source_uki" | grep -Fq \
	'root=PARTLABEL=linux rw fw_devlink=permissive console=ttyGS0 console=tty0 loglevel=8 ignore_loglevel no_console_suspend' &&
     ! strings "$source_uki" | grep -Eq \
	'(modprobe|module)_blacklist=.*(qcom_iris|venus_core)'; then
	profile=iris-enabled
	[ "$argument_count" -eq 5 ] || {
		echo "Iris-enabled UKI requires the matching $expected_iris_module argument" >&2
		exit 1
	}
else
	echo "test UKI has an unrecognized Iris blacklist profile" >&2
	exit 1
fi
strings "$source_uki" | grep -Fq 'SLPI boot-only diagnostic' || {
	echo "test UKI does not contain the SLPI boot-only DTB" >&2
	exit 1
}
if strings "$source_uki" | grep -Fq 'qcom,nabu-sm8150-scc'; then
	echo "test UKI still contains an AP-side SCC node" >&2
	exit 1
fi
[ "$(modinfo -F name "$source_ssc_module")" = nabu_sm8150_ssc ] || {
	echo "source is not the private nabu SSC module" >&2
	exit 1
}
[ "$(modinfo -F name "$source_spi_module")" = spi_geni_qcom ] || {
	echo "source is not the upstream spi_geni_qcom module" >&2
	exit 1
}
[ "$(modinfo -F name "$source_fastrpc_module")" = fastrpc ] || {
	echo "source is not the FastRPC module" >&2
	exit 1
}
if [ "$profile" = iris-enabled ] &&
   [ "$(modinfo -F name "$source_iris_module")" != qcom_iris ]; then
	echo "source is not the Qualcomm Iris module" >&2
	exit 1
fi
for source_module in "$source_ssc_module" "$source_spi_module" "$source_fastrpc_module"; do
	module_vermagic=$(modinfo -F vermagic "$source_module")
	case "$module_vermagic" in
		"$kernel_release "*) ;;
		*)
			echo "module release mismatch: $module_vermagic" >&2
			exit 1
			;;
	esac
done
if [ "$profile" = iris-enabled ]; then
	module_vermagic=$(modinfo -F vermagic "$source_iris_module")
	case "$module_vermagic" in
		"$kernel_release "*) ;;
		*)
			echo "Iris module release mismatch: $module_vermagic" >&2
			exit 1
			;;
	esac
fi
strings "$source_ssc_module" | grep -Fq \
	'registered powered zero-clock SCC provider; clock hardware and MMIO access intentionally skipped' || {
	echo "private module does not contain the SCC powered-empty-provider diagnostic" >&2
	exit 1
}
if strings "$source_spi_module" | grep -Fq 'nabu probe diagnostic:'; then
	echo "SPI module still contains the retired in-tree diagnostic patch" >&2
	exit 1
fi
strings "$source_fastrpc_module" | grep -Fq \
	'enabling SM8150 SDSP high-IOVA workaround' || {
	echo "FastRPC module does not contain the SM8150 SDSP IOVA workaround" >&2
	exit 1
}
[ -f "$spi_module_target" ] || {
	echo "missing installed SPI module: $spi_module_target" >&2
	exit 1
}
[ -f "$fastrpc_module_target" ] || {
	echo "missing installed FastRPC module: $fastrpc_module_target" >&2
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
	if [ ! -d "$esp_mount" ]; then
		install -d -m 0755 -- "$esp_mount"
	fi
	mount -t vfat "$esp_device" "$esp_mount"
	mounted_here=true
fi

destination_dir=$esp_mount/EFI/ubuntu
destination_uki=$destination_dir/$expected_uki
temporary_uki=$destination_uki.new
[ -d "$destination_dir" ] || {
	echo "missing expected ESP directory: $destination_dir" >&2
	exit 1
}
[ ! -e "$temporary_uki" ] || rm -f -- "$temporary_uki"

install -m 0644 -- "$source_uki" "$temporary_uki"
sync "$temporary_uki"

source_uki_hash=$(sha256sum "$source_uki" | cut -d ' ' -f 1)
installed_uki_hash=$(sha256sum "$temporary_uki" | cut -d ' ' -f 1)
[ "$source_uki_hash" = "$installed_uki_hash" ] || {
	echo "installed UKI hash mismatch" >&2
	exit 1
}

mv -f -- "$temporary_uki" "$destination_uki"
sync "$destination_uki"

# Install modules only after the SLPI-only DTB is safely in place. The private SCC
# module remains installed as a known-safe fallback but this DTB cannot bind it.
install -d -m 0755 -- "$(dirname -- "$ssc_module_target")"
install -m 0644 -- "$source_ssc_module" "$ssc_module_target"
install -m 0644 -- "$source_spi_module" "$spi_module_target"
install -m 0644 -- "$source_fastrpc_module" "$fastrpc_module_target"
if [ "$profile" = iris-enabled ]; then
	install -d -m 0755 -- "$(dirname -- "$iris_module_target")"
	install -m 0644 -- "$source_iris_module" "$iris_module_target"
fi
depmod "$kernel_release"

source_ssc_hash=$(sha256sum "$source_ssc_module" | cut -d ' ' -f 1)
installed_ssc_hash=$(sha256sum "$ssc_module_target" | cut -d ' ' -f 1)
[ "$source_ssc_hash" = "$installed_ssc_hash" ] || exit 1
source_spi_hash=$(sha256sum "$source_spi_module" | cut -d ' ' -f 1)
installed_spi_hash=$(sha256sum "$spi_module_target" | cut -d ' ' -f 1)
[ "$source_spi_hash" = "$installed_spi_hash" ] || exit 1
source_fastrpc_hash=$(sha256sum "$source_fastrpc_module" | cut -d ' ' -f 1)
installed_fastrpc_hash=$(sha256sum "$fastrpc_module_target" | cut -d ' ' -f 1)
[ "$source_fastrpc_hash" = "$installed_fastrpc_hash" ] || exit 1
if [ "$profile" = iris-enabled ]; then
	source_iris_hash=$(sha256sum "$source_iris_module" | cut -d ' ' -f 1)
	installed_iris_hash=$(sha256sum "$iris_module_target" | cut -d ' ' -f 1)
	[ "$source_iris_hash" = "$installed_iris_hash" ] || exit 1
	sync "$ssc_module_target" "$spi_module_target" "$fastrpc_module_target" \
		"$iris_module_target"
else
	sync "$ssc_module_target" "$spi_module_target" "$fastrpc_module_target"
fi

for old_uki in "$destination_dir"/*-accelerometer-*.efi; do
	[ -f "$old_uki" ] || continue
	[ "$(basename -- "$old_uki")" = "$expected_uki" ] && continue
	rm -f -- "$old_uki"
	echo "removed superseded accelerometer UKI: $old_uki"
done

echo "installed SLPI boot-only diagnostic UKI: $destination_uki"
echo "UKI SHA256: $installed_uki_hash"
echo "Iris profile: $profile"
echo "installed private SCC module: $ssc_module_target"
echo "SSC module SHA256: $installed_ssc_hash"
echo "restored unmodified upstream SPI module: $spi_module_target"
echo "SPI module SHA256: $installed_spi_hash"
echo "installed SM8150 SDSP IOVA FastRPC module: $fastrpc_module_target"
echo "FastRPC module SHA256: $installed_fastrpc_hash"
if [ "$profile" = iris-enabled ]; then
	echo "installed Qualcomm Iris module: $iris_module_target"
	echo "Iris module SHA256: $installed_iris_hash"
	echo "WARNING: Iris will autoload on the next boot and may hard-lock during desktop media probing"
fi
echo "USB CDC ACM console: 0525:a4a7 (host /dev/ttyACM*)"
echo "the existing default UKI was not modified"
echo "future diagnostics will replace this same test entry instead of adding versions"
echo "do not replace or unload live modules; reboot to activate this diagnostic"
