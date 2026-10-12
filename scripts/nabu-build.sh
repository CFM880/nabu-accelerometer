#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# nabu-main build hook for nabu-accelerometer.
#
# The kernel modules and the product UKI are built by nabu-main itself.  This
# hook produces the module's userspace artifacts declared in the manifest's
# [artifacts] table: the tablet-mode helper and the SSC stack (libssc and
# iio-sensor-proxy), so that `make install` only installs prebuilt files and
# needs neither a compiler toolchain nor network access.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
module_dir=${NABU_MODULE_DIR:-$project_dir}

destination=$module_dir/out/nabu-tablet-mode
mkdir -p -- "$(dirname -- "$destination")"
"$project_dir/libexec/build-tablet-mode.sh" "$destination"

"$project_dir/libexec/build-userspace.sh"
