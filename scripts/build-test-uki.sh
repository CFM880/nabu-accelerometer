#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

if [ "$#" -ne 3 ]; then
	echo "usage: $0 /path/to/linux /path/to/output /path/to/nabu-accelerometer-test.efi" >&2
	exit 2
fi

kernel_tree=$(CDPATH= cd -- "$1" && pwd)
output_dir=$(CDPATH= cd -- "$2" && pwd)
destination=$3
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
dts_dir=$kernel_tree/arch/arm64/boot/dts/qcom
enable_iris=${ENABLE_IRIS:-0}

case $enable_iris in
	0)
		cmdline=$project_dir/config/slpi-boot-only.cmdline
		profile='Iris-blocked'
		;;
	1)
		cmdline=$project_dir/config/slpi-boot-only-iris-enabled.cmdline
		profile='Iris-enabled'
		;;
	*)
		echo "ENABLE_IRIS must be 0 or 1" >&2
		exit 2
		;;
esac

dtb=sm8150-xiaomi-nabu-accelerometer-slpi-boot-only.dtb
if [ -f "$dts_dir/sm8150-xiaomi-nabu-camera.dtsi" ]; then
	dtb=sm8150-xiaomi-nabu-camera-accelerometer-slpi-boot-only.dtb
fi
if [ -f "$dts_dir/sm8150-xiaomi-nabu-iris.dtsi" ]; then
	dtb=sm8150-xiaomi-nabu-iris-accelerometer-slpi-boot-only.dtb
fi
if [ -f "$dts_dir/sm8150-xiaomi-nabu-camera.dtsi" ] &&
   [ -f "$dts_dir/sm8150-xiaomi-nabu-iris.dtsi" ]; then
	dtb=sm8150-xiaomi-nabu-iris-camera-accelerometer-slpi-boot-only.dtb
fi

image=$output_dir/arch/arm64/boot/Image
devicetree=$output_dir/arch/arm64/boot/dts/qcom/$dtb
kernel_release=$(make -s -C "$kernel_tree" O="$output_dir" kernelrelease)
temporary=$destination.new
uki_stub=${UKI_STUB:-}
ukify=${UKIFY:-/usr/bin/ukify}
ukify_python=${UKIFY_PYTHON:-/usr/bin/python3}

test -s "$image"
test -s "$devicetree"
test -s "$ukify"
test -x "$ukify_python"
rm -f -- "$temporary"
set -- build \
	--linux "$image" \
	--devicetree "$devicetree" \
	--cmdline "@$cmdline" \
	--os-release @/etc/os-release \
	--uname "$kernel_release" \
	--sbat "@$project_dir/config/uki.sbat" \
	--efi-arch aa64
if [ -n "$uki_stub" ]; then
	[ -s "$uki_stub" ] || {
		echo "missing UKI_STUB: $uki_stub" >&2
		exit 1
	}
	set -- "$@" --stub "$uki_stub"
fi
set -- "$@" --output "$temporary"
"$ukify_python" "$ukify" "$@"
mv -f -- "$temporary" "$destination"

echo "built fixed SLPI boot-only diagnostic UKI ($profile): $destination"
sha256sum "$destination"
