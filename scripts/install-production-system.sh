#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")

if [ "$#" -eq 0 ] && [ -d "$project_dir/artifacts" ]; then
	set -- \
		"$project_dir/artifacts/nabu-accelerometer-production.efi" \
		"$project_dir/artifacts/fastrpc.ko" \
		"$project_dir/artifacts/qcom_pd_mapper.ko"
elif [ "$#" -ne 3 ]; then
	echo "usage: sudo $0 [/path/to/nabu-accelerometer-production.efi /path/to/fastrpc.ko /path/to/qcom_pd_mapper.ko]" >&2
	exit 2
fi

"$script_dir/install-production-uki.sh" "$@"
"$script_dir/install-hexagonrpcd.sh"

echo "installed the Nabu production UKI, kernel modules, and event-driven hexagonrpcd configuration"
echo "reboot is required before the PDR-gated FastRPC path takes effect"
