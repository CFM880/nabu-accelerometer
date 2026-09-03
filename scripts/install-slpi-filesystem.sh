#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

firmware_dir=/lib/firmware/qcom/sm8150/xiaomi/nabu
hexagonfs_dir=/lib/firmware/hexagonfs
tqftp_rw_dir=/var/lib/tqftpserv/sensors/registry

[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

[ -f "$firmware_dir/slpi_nb.mbn" ] || {
	echo "missing nabu SLPI firmware: $firmware_dir/slpi_nb.mbn" >&2
	exit 1
}

for name in sensors socinfo; do
	source=$hexagonfs_dir/$name
	target=$firmware_dir/$name
	relative=../../../../hexagonfs/$name

	[ -d "$source" ] || {
		echo "missing Hexagon filesystem directory: $source" >&2
		exit 1
	}

	if [ -L "$target" ]; then
		[ "$(readlink -- "$target")" = "$relative" ] || {
			echo "refusing to replace unexpected symlink: $target -> $(readlink -- "$target")" >&2
			exit 1
		}
	elif [ -e "$target" ]; then
		echo "refusing to replace existing path: $target" >&2
		exit 1
	else
		ln -s -- "$relative" "$target"
	fi

	[ "$(realpath -- "$target")" = "$(realpath -- "$source")" ] || {
		echo "invalid installed mapping: $target" >&2
		exit 1
	}
	done

# tqftpserv creates only its top-level read/write directory. Create the nested
# sensor registry path before SLPI asks to create or update persistent entries.
install -d -o root -g root -m 0700 /var/lib/tqftpserv
install -d -o root -g root -m 0700 /var/lib/tqftpserv/sensors
install -d -o root -g root -m 0700 "$tqftp_rw_dir"

echo "installed SLPI readonly mapping: $firmware_dir/sensors -> ../../../../hexagonfs/sensors"
echo "installed SLPI readonly mapping: $firmware_dir/socinfo -> ../../../../hexagonfs/socinfo"
echo "prepared SLPI TQFTP read/write registry: $tqftp_rw_dir"
echo "no kernel, UKI, firmware image, or normal boot entry was modified"
echo "leave the current SLPI test boot running; the next remoteproc recovery will retry initialization"
