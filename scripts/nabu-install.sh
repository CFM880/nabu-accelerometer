#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# nabu-main install hook for nabu-accelerometer.
#
# Kernel modules (fastrpc.ko, qcom_pd_mapper.ko) and the product UKI are
# installed by nabu-main; this hook only ensures the userspace SLPI/SSC
# stack: the SLPI readonly mapping, hexagonrpcd, libssc, iio-sensor-proxy and
# the tablet-mode helper.  Every step is idempotent: already-correct
# components are reused, and only missing ones are (re)built from the pinned
# source archives vendored under third_party/ (or an explicit artifact
# override).
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
libexec_dir=$project_dir/libexec
artifact_dir=${NABU_ARTIFACTS:-$project_dir/artifacts}
third_party_dir=$project_dir/third_party

# Locate a pinned source archive: an explicit artifact override first, then the
# archive vendored in third_party/.
find_archive()
{
	name=$1
	for dir in "$artifact_dir" "$third_party_dir"; do
		if [ -s "$dir/$name" ]; then
			printf '%s\n' "$dir/$name"
			return 0
		fi
	done
	return 1
}

"$libexec_dir/install-slpi-filesystem.sh"
"$libexec_dir/install-hexagonrpcd.sh"

libssc_bin=/usr/local/bin/ssccli
if [ -x "$libssc_bin" ] &&
	[ "$("$libssc_bin" --version)" = "libssc version 0.4.4" ]; then
	echo "using installed libssc 0.4.4"
elif libssc_archive=$(find_archive libssc-v0.4.4.tar.gz); then
	"$libexec_dir/install-libssc.sh" "$libssc_archive"
else
	echo "libssc 0.4.4 is not installed and no libssc-v0.4.4.tar.gz archive was found" >&2
	exit 1
fi

iio_binary=/usr/local/libexec/iio-sensor-proxy-ssc
if [ -x "$iio_binary" ] &&
	strings "$iio_binary" | grep -Fq 'Nabu SSC light filter v2 enabled'; then
	# Already patched: only refresh the systemd override and udev rule.
	"$libexec_dir/install-iio-sensor-proxy-ssc.sh"
elif iio_archive=$(find_archive iio-sensor-proxy-3.9.tar.gz); then
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
