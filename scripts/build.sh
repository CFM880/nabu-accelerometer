#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
	echo "usage: $0 /path/to/linux /path/to/output [slpi-boot-only]" >&2
	exit 2
fi

profile=${3:-slpi-boot-only}
case $profile in
	slpi-boot-only)
		suffix=-$profile
		;;
	ssc-powered-empty-provider)
		suffix=-$profile
		;;
	ssc-powered-main-rcg)
		echo "$profile hard-locked on the first SCC MMIO read and is permanently blocked" >&2
		exit 2
		;;
	ssc-empty-provider)
		echo "$profile passed on hardware and is superseded by ssc-powered-empty-provider" >&2
		exit 2
		;;
	ssc-map-only)
		echo "$profile passed on hardware and is superseded by ssc-empty-provider" >&2
		exit 2
		;;
	ssc-provider)
		echo "$profile hard-locked in qcom_cc_probe() and is blocked until map-only passes" >&2
		exit 2
		;;
	ssc-controller-runtime)
		echo "$profile hard-locked and is blocked until the earlier diagnostic stages pass" >&2
		exit 2
		;;
	controller|controller-unbound|controller-runtime|polling|full)
		echo "$profile uses the retired AP QUP0 mapping and is blocked for hardware safety" >&2
		exit 2
		;;
	*)
		echo "unknown profile: $profile" >&2
		exit 2
		;;
esac

kernel_tree=$(CDPATH= cd -- "$1" && pwd)
mkdir -p "$2"
output_dir=$(CDPATH= cd -- "$2" && pwd)
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
driver_dir=$project_dir/driver
dts_dir=$kernel_tree/arch/arm64/boot/dts/qcom

if [ ! -f "$dts_dir/sm8150-xiaomi-nabu-accelerometer-slpi-boot-only.dts" ]; then
	echo "accelerometer overlay is not installed; run scripts/apply-overlay.sh first" >&2
	exit 1
fi

if [ ! -f "$output_dir/.config" ]; then
	echo "missing configured kernel output: $output_dir/.config" >&2
	exit 1
fi

dtb=sm8150-xiaomi-nabu-accelerometer$suffix.dtb
if [ -f "$dts_dir/sm8150-xiaomi-nabu-camera.dtsi" ]; then
	dtb=sm8150-xiaomi-nabu-camera-accelerometer$suffix.dtb
fi
if [ -f "$dts_dir/sm8150-xiaomi-nabu-iris.dtsi" ]; then
	dtb=sm8150-xiaomi-nabu-iris-accelerometer$suffix.dtb
fi
if [ -f "$dts_dir/sm8150-xiaomi-nabu-camera.dtsi" ] &&
   [ -f "$dts_dir/sm8150-xiaomi-nabu-iris.dtsi" ]; then
	dtb=sm8150-xiaomi-nabu-iris-camera-accelerometer$suffix.dtb
fi

: "${ARCH:=arm64}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
export ARCH CROSS_COMPILE

"$script_dir/merge-config.sh" "$kernel_tree" "$output_dir"
make -C "$kernel_tree" O="$output_dir" olddefconfig
make -C "$kernel_tree" O="$output_dir" -j"$JOBS" \
	Image modules_prepare drivers/misc/fastrpc.ko \
	drivers/soc/qcom/qcom_pd_mapper.ko \
	drivers/spi/spi-geni-qcom.ko "qcom/$dtb"

module_output=$output_dir/nabu-accelerometer-driver
mkdir -p "$module_output"
make -C "$kernel_tree" O="$output_dir" -j"$JOBS" \
	M="$driver_dir" MO="$module_output" modules

output_dtb=$output_dir/arch/arm64/boot/dts/qcom/$dtb
test -f "$output_dtb"
test -f "$module_output/nabu-sm8150-ssc.ko"
test -f "$output_dir/drivers/misc/fastrpc.ko"
test -f "$output_dir/drivers/soc/qcom/qcom_pd_mapper.ko"
test -f "$output_dir/drivers/spi/spi-geni-qcom.ko"
echo "built $profile DTB: $output_dtb"
echo "built private SSC module: $module_output/nabu-sm8150-ssc.ko"
echo "built FastRPC module: $output_dir/drivers/misc/fastrpc.ko"
echo "built PD mapper module: $output_dir/drivers/soc/qcom/qcom_pd_mapper.ko"
echo "built unmodified upstream SPI module: $output_dir/drivers/spi/spi-geni-qcom.ko"
