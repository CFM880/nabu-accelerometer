#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# nabu-main install hook for the SLPI/SSC userspace stack.
#
# The kernel modules are installed by nabu-main from the manifest.  This hook
# delegates the userspace half (UKI promotion, SLPI filesystem, hexagonrpcd,
# libssc, iio-sensor-proxy and the tablet-mode helper) to the module's existing
# installer, which already implements the transaction and rollback logic.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
artifact_dir=${NABU_ARTIFACTS:-$project_dir/artifacts}

exec "$project_dir/scripts/install.sh" "$artifact_dir"
