#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# nabu-main install hook for nabu-accelerometer.
#
# Kernel modules (fastrpc.ko, qcom_pd_mapper.ko) and the product UKI are
# installed by nabu-main; this hook only ensures the userspace SLPI/SSC
# stack: the SLPI readonly mapping, hexagonrpcd, libssc, iio-sensor-proxy and
# the tablet-mode helper.  Every step is idempotent and detects an already
# installed component, so it is safe to re-run.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
libexec_dir=$project_dir/libexec
artifact_dir=${NABU_ARTIFACTS:-$project_dir/artifacts}

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
	"$libexec_dir/install-iio-sensor-proxy-ssc.sh"
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

echo "installed the Nabu userspace sensor stack"
