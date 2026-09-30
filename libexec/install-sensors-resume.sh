#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Install the Nabu sensor resume hook: a oneshot unit that starts the SLPI
# sensor userspace again if suspend took it down.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
unit_source=$project_dir/config/nabu-sensors-resume.service
script_source=$script_dir/nabu-sensors-resume
unit_target=/etc/systemd/system/nabu-sensors-resume.service
script_target=/usr/local/libexec/nabu-sensors-resume

[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}
[ -f "$unit_source" ] || {
	echo "missing packaged unit: $unit_source" >&2
	exit 1
}
[ -f "$script_source" ] || {
	echo "missing resume helper: $script_source" >&2
	exit 1
}

install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 "$script_source" "$script_target"
install -o root -g root -m 0644 "$unit_source" "$unit_target"

systemctl daemon-reload
systemctl enable nabu-sensors-resume.service

echo "installed Nabu sensor resume hook: $unit_target"
