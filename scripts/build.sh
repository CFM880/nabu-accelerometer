#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

if [ "$#" -ne 3 ]; then
	echo "usage: $0 /path/to/linux /path/to/output /path/to/artifacts" >&2
	exit 2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
libexec_dir=$project_dir/libexec

"$libexec_dir/apply-overlay.sh" "$1"

kernel_tree=$(CDPATH= cd -- "$1" && pwd)
mkdir -p "$2"
output_dir=$(CDPATH= cd -- "$2" && pwd)
mkdir -p "$3"
artifact_dir=$(CDPATH= cd -- "$3" && pwd)
dts_dir=$kernel_tree/arch/arm64/boot/dts/qcom
dtb=sm8150-xiaomi-nabu-iris-camera-accelerometer-slpi-boot-only.dtb

if [ ! -f "$dts_dir/${dtb%.dtb}.dts" ]; then
	echo "accelerometer overlay installation did not create the production DTS" >&2
	exit 1
fi

if [ ! -f "$output_dir/.config" ]; then
	echo "missing configured kernel output: $output_dir/.config" >&2
	exit 1
fi

: "${ARCH:=arm64}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${JOBS:=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
export ARCH CROSS_COMPILE

make -C "$kernel_tree" O="$output_dir" olddefconfig
make -C "$kernel_tree" O="$output_dir" -j"$JOBS" \
	Image modules_prepare drivers/misc/fastrpc.ko \
	drivers/soc/qcom/qcom_pd_mapper.ko "qcom/$dtb"

output_dtb=$output_dir/arch/arm64/boot/dts/qcom/$dtb
test -f "$output_dtb"
test -f "$output_dir/drivers/misc/fastrpc.ko"
test -f "$output_dir/drivers/soc/qcom/qcom_pd_mapper.ko"
echo "built production SLPI DTB: $output_dtb"
echo "built FastRPC module: $output_dir/drivers/misc/fastrpc.ko"
echo "built PD mapper module: $output_dir/drivers/soc/qcom/qcom_pd_mapper.ko"

"$libexec_dir/build-production-uki.sh" "$kernel_tree" "$output_dir" \
	"$artifact_dir/nabu-accelerometer-production.efi"
"$libexec_dir/build-tablet-mode.sh" "$artifact_dir/nabu-tablet-mode"
install -m 0644 "$output_dir/drivers/misc/fastrpc.ko" \
	"$artifact_dir/fastrpc.ko"
install -m 0644 "$output_dir/drivers/soc/qcom/qcom_pd_mapper.ko" \
	"$artifact_dir/qcom_pd_mapper.ko"

echo "production artifacts: $artifact_dir"
