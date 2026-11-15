#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Install the fixed-curve auto-brightness daemon and its user unit, and enable
# it for the graphical session of every user (systemd only follows symlinks in
# the *.wants directories, a plain file there is ignored).
set -eu

binary=${1:?usage: install-autobrightness.sh <nabu-autobrightness> <unit> [root]}
unit=${2:?missing unit}
root=${3:-}

install -d -m0755 "$root/usr/local/libexec" "$root/etc/systemd/user/graphical-session.target.wants"
install -m0755 "$binary" "$root/usr/local/libexec/nabu-autobrightness"
install -m0644 "$unit" "$root/etc/systemd/user/nabu-autobrightness.service"
ln -sf /etc/systemd/user/nabu-autobrightness.service \
	"$root/etc/systemd/user/graphical-session.target.wants/nabu-autobrightness.service"

# polkit: the daemon runs as the session user and has to claim the sensor,
# which iio-sensor-proxy only allows for an active session by default.
install -d -m0755 "$root/etc/polkit-1/rules.d"
install -m0644 "$(dirname -- "$0")/../config/50-nabu-autobrightness.rules" \
	"$root/etc/polkit-1/rules.d/50-nabu-autobrightness.rules"
