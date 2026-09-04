#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

mode=${1:-kernel}
case $mode in
	kernel|all) ;;
	*)
		echo "usage: sudo bash $0 [kernel|all]" >&2
		exit 2
		;;
esac
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
libexec_dir=$(dirname -- "$script_dir")/libexec

if [ "$mode" = all ]; then
	"$libexec_dir/remove-tablet-mode.sh"
	"$libexec_dir/remove-iio-sensor-proxy-ssc.sh"
	"$libexec_dir/remove-hexagonrpcd-nabu-config.sh"
	"$libexec_dir/remove-slpi-filesystem.sh"
fi

"$libexec_dir/restore-production-uki.sh"
echo "restore mode '$mode' completed; reboot is required"
