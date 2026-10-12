#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# nabu-main install hook for nabu-accelerometer.
#
# Kernel modules (fastrpc.ko, qcom_pd_mapper.ko) and the product UKI are
# installed by nabu-main.  This hook installs the module's userspace stack from
# the artifacts produced by the build hook (libssc, iio-sensor-proxy and the
# tablet-mode helper) plus the SLPI/hexagonrpcd runtime setup.  Nothing is
# compiled and no network access is needed here.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
libexec_dir=$project_dir/libexec
artifact_dir=${NABU_ARTIFACTS:-$project_dir/artifacts}

require_artifact()
{
	[ -s "$artifact_dir/$1" ] || {
		echo "missing build artifact: $artifact_dir/$1; run 'make build' first" >&2
		exit 1
	}
	printf '%s\n' "$artifact_dir/$1"
}

"$libexec_dir/install-slpi-filesystem.sh"
"$libexec_dir/install-hexagonrpcd.sh"

"$libexec_dir/install-libssc.sh" \
	"$(require_artifact ssccli)" \
	"$(require_artifact libssc.so.2)"

"$libexec_dir/install-iio-sensor-proxy-ssc.sh" \
	"$(require_artifact iio-sensor-proxy-ssc)" \
	"$(require_artifact net.hadess.SensorProxy.conf)"

"$libexec_dir/install-tablet-mode.sh" "$(require_artifact nabu-tablet-mode)"

"$libexec_dir/install-sensors-sleep.sh"

echo "installed the Nabu userspace sensor stack"
