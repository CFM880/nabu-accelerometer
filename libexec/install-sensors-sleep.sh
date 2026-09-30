#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Install the Nabu sensor sleep hooks: a pair of oneshot units that quiesce
# the FastRPC sensor server before suspend and recover the sensor stack after
# resume.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
script_source=$script_dir/nabu-sensors-sleep
script_target=/usr/local/libexec/nabu-sensors-sleep
unit_dir=/etc/systemd/system

[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}
[ -f "$script_source" ] || {
	echo "missing sleep helper: $script_source" >&2
	exit 1
}

install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 "$script_source" "$script_target"

for unit in nabu-sensors-suspend nabu-sensors-resume; do
	source=$project_dir/config/$unit.service
	[ -f "$source" ] || {
		echo "missing packaged unit: $source" >&2
		exit 1
	}
	install -o root -g root -m 0644 "$source" "$unit_dir/$unit.service"
done

systemctl daemon-reload
systemctl enable nabu-sensors-suspend.service nabu-sensors-resume.service

echo "installed Nabu sensor sleep hooks"
