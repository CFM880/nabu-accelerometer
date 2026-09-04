#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

binary=/usr/local/libexec/iio-sensor-proxy-ssc
dropin=/etc/systemd/system/iio-sensor-proxy.service.d/nabu-ssc.conf
rule=/etc/udev/rules.d/90-nabu-ssc-accelerometer.rules

[ "$#" -eq 0 ] || {
	echo "usage: sudo $0" >&2
	exit 2
}
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

if [ -e "$binary" ]; then
	strings "$binary" | grep -Fq 'SSC accelerometer sensor' || {
		echo "refusing to remove unexpected binary: $binary" >&2
		exit 1
	}
	rm -- "$binary"
fi
if [ -e "$dropin" ]; then
	grep -Fqx 'ExecStart=/usr/local/libexec/iio-sensor-proxy-ssc' "$dropin" || {
		echo "refusing to remove unexpected drop-in: $dropin" >&2
		exit 1
	}
	rm -- "$dropin"
	rmdir --ignore-fail-on-non-empty "$(dirname -- "$dropin")"
fi
if [ -e "$rule" ]; then
	grep -Fq 'IIO_SENSOR_PROXY_TYPE}+="ssc-accel"' "$rule" || {
		echo "refusing to remove unexpected udev rule: $rule" >&2
		exit 1
	}
	rm -- "$rule"
fi

systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger --action=add --subsystem-match=misc --sysname-match='fastrpc-sdsp*'
udevadm settle
systemctl restart iio-sensor-proxy.service 2>/dev/null || true

echo "removed the Nabu SSC iio-sensor-proxy integration"
echo "restored the distribution iio-sensor-proxy service command"
echo "preserved libssc, hexagonrpcd, firmware, kernel, and registry data"
