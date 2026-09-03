#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

rule=/etc/udev/rules.d/90-nabu-ssc-accelerometer.rules
legacy_identity_rule_sha256=dcc04b9147f0f162b208334c5c4658b70b4e26384fa968a0632cd7468a387761

[ "$#" -eq 0 ] || {
	echo "usage: sudo $0" >&2
	exit 2
}
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
rule_source=$script_dir/../config/90-nabu-ssc-accelerometer.rules

[ -f "$rule_source" ] || {
	echo "missing packaged udev rule: $rule_source" >&2
	exit 1
}
model=$(tr -d '\000' </sys/firmware/devicetree/base/model 2>/dev/null || true)
case $model in
	'Xiaomi Pad 5 (nabu)'*) ;;
	*)
		echo "refusing non-Nabu machine: $model" >&2
		exit 1
		;;
esac

[ -x /usr/local/libexec/iio-sensor-proxy-ssc ] || {
	echo "SSC iio-sensor-proxy is not installed" >&2
	exit 1
}
[ -f "$rule" ] || {
	echo "SSC accelerometer udev rule is not installed: $rule" >&2
	exit 1
}

if ! cmp -s "$rule" "$rule_source"; then
	installed_rule_sha256=$(sha256sum "$rule" | cut -d ' ' -f 1)
	[ "$installed_rule_sha256" = "$legacy_identity_rule_sha256" ] || {
		echo "refusing to replace unexpected udev rule: $rule" >&2
		exit 1
	}
	install -o root -g root -m 0644 "$rule_source" "$rule"
fi

udevadm control --reload-rules
udevadm trigger --action=add --subsystem-match=misc --sysname-match='fastrpc-sdsp*'
udevadm settle
systemctl restart iio-sensor-proxy.service
systemctl is-active --quiet iio-sensor-proxy.service

udevadm info --query=property --path=/sys/class/misc/fastrpc-sdsp | \
	grep -Fqx 'ACCEL_MOUNT_MATRIX=-1,0,0;0,-1,0;0,0,1'
busctl get-property net.hadess.SensorProxy /net/hadess/SensorProxy \
	net.hadess.SensorProxy HasAccelerometer | grep -Fqx 'b true'

echo "installed Nabu 180-degree SSC accelerometer correction"
echo "mount matrix: -1,0,0;0,-1,0;0,0,1"
echo "no kernel, UKI, or boot entry was modified"
