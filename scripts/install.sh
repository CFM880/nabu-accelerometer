#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
libexec_dir=$project_dir/libexec
artifact_dir=${1:-$project_dir/artifacts}

[ "$#" -le 1 ] || {
	echo "usage: sudo bash $0 [/path/to/artifacts]" >&2
	exit 2
}
artifact_dir=$(CDPATH= cd -- "$artifact_dir" && pwd)

for artifact in \
	nabu-accelerometer-production.efi \
	fastrpc.ko \
	qcom_pd_mapper.ko; do
	[ -s "$artifact_dir/$artifact" ] || {
		echo "missing final artifact: $artifact_dir/$artifact" >&2
		exit 1
	}
done

"$libexec_dir/install-production-uki.sh" \
	"$artifact_dir/nabu-accelerometer-production.efi" \
	"$artifact_dir/fastrpc.ko" \
	"$artifact_dir/qcom_pd_mapper.ko"
"$libexec_dir/install-slpi-filesystem.sh"
"$libexec_dir/install-hexagonrpcd.sh"

libssc_archive=$artifact_dir/libssc-v0.4.4.tar.gz
if [ -s "$libssc_archive" ]; then
	"$libexec_dir/install-libssc.sh" "$libssc_archive"
else
	[ -x /usr/local/bin/ssccli ] &&
		[ "$(/usr/local/bin/ssccli --version)" = "libssc version 0.4.4" ] || {
		echo "missing $libssc_archive and libssc 0.4.4 is not installed" >&2
		exit 1
	}
	echo "using installed libssc 0.4.4"
fi

iio_archive=$artifact_dir/iio-sensor-proxy-3.9.tar.gz
if [ -s "$iio_archive" ]; then
	"$libexec_dir/install-iio-sensor-proxy-ssc.sh" "$iio_archive"
else
	[ -x /usr/local/libexec/iio-sensor-proxy-ssc ] &&
		strings /usr/local/libexec/iio-sensor-proxy-ssc | \
		grep -Fq 'SSC accelerometer sensor' || {
		echo "missing $iio_archive and the SSC sensor proxy is not installed" >&2
		exit 1
	}
	echo "using installed SSC iio-sensor-proxy"
fi

tablet_binary=$artifact_dir/nabu-tablet-mode
if [ -s "$tablet_binary" ]; then
	"$libexec_dir/install-tablet-mode.sh" "$tablet_binary"
else
	[ -x /usr/local/libexec/nabu-tablet-mode ] || {
		echo "missing $tablet_binary and the tablet-mode helper is not installed" >&2
		exit 1
	}
	echo "using installed tablet-mode helper"
fi

echo "installed the final Nabu accelerometer stack"
echo "reboot is required for the UKI and kernel modules"
