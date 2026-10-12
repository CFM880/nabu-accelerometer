#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-main install helper: install the prebuilt SSC iio-sensor-proxy binary and
# its generated D-Bus policy, then wire up the systemd/udev integration.  The
# compile (with the Nabu patches) happens in the build hook; this script only
# places files and configures the running system.
set -eu

version=3.9
binary=/usr/local/libexec/iio-sensor-proxy-ssc
dropin_dir=/etc/systemd/system/iio-sensor-proxy.service.d
dropin=$dropin_dir/nabu-ssc.conf
rule=/etc/udev/rules.d/90-nabu-ssc-accelerometer.rules
dbusconf=/usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf
legacy_identity_rule_sha256=dcc04b9147f0f162b208334c5c4658b70b4e26384fa968a0632cd7468a387761
legacy_accelerometer_only_rule_sha256=95b011f5634b7ced33e03b90144d5f7f273dd29cad3dcacbb09b83c588ab91f3
legacy_motion_rule_sha256=0862d933b1a9b89d624864638b96024030bba561ba4af76dc8858b78084479e0

[ "$#" -eq 2 ] || {
	echo "usage: $0 <iio-sensor-proxy-ssc> <net.hadess.SensorProxy.conf>" >&2
	exit 2
}
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dropin_source=$script_dir/../config/nabu-ssc-iio-sensor-proxy.conf
rule_source=$script_dir/../config/90-nabu-ssc-accelerometer.rules

binary_source=$(realpath -- "$1")
dbusconf_source=$(realpath -- "$2")

for source in "$binary_source" "$dbusconf_source" "$dropin_source" "$rule_source"; do
	[ -s "$source" ] || {
		echo "missing input: $source" >&2
		exit 1
	}
done

# Validate the prebuilt binary before touching the system.
strings "$binary_source" | grep -Fq 'Nabu SSC light filter v2 enabled' || {
	echo "prebuilt binary lacks the Nabu light filter: $binary_source" >&2
	exit 1
}
for backend in accelerometer light compass gyroscope magnetometer; do
	strings "$binary_source" | grep -Fq "SSC $backend sensor" || {
		echo "prebuilt binary lacks the SSC $backend backend" >&2
		exit 1
	}
done
for iface in Gyroscope Magnetometer; do
	grep -Fq "send_interface=\"net.hadess.SensorProxy.$iface\"" "$dbusconf_source" || {
		echo "generated D-Bus policy lacks the $iface interface: $dbusconf_source" >&2
		exit 1
	}
done

[ -x /usr/local/bin/ssccli ] || {
	echo "libssc is not installed; install it before iio-sensor-proxy" >&2
	exit 1
}
[ "$(/usr/local/bin/ssccli --version)" = "libssc version 0.4.4" ] || {
	echo "unexpected installed libssc version" >&2
	exit 1
}

if [ -e "$dropin" ] && ! cmp -s "$dropin" "$dropin_source"; then
	echo "refusing to replace unexpected systemd drop-in: $dropin" >&2
	exit 1
fi
if [ -e "$rule" ] && ! cmp -s "$rule" "$rule_source"; then
	installed_rule_sha256=$(sha256sum "$rule" | cut -d' ' -f1)
	case $installed_rule_sha256 in
	"$legacy_identity_rule_sha256"|"$legacy_accelerometer_only_rule_sha256"|"$legacy_motion_rule_sha256")
		;;
	*)
		echo "refusing to replace unexpected udev rule: $rule" >&2
		exit 1
		;;
	esac
fi
if [ -e "$binary" ]; then
	for backend in accelerometer light compass gyroscope magnetometer; do
		strings "$binary" | grep -Fq "SSC $backend sensor" || {
			echo "refusing to replace unexpected binary: $binary" >&2
			exit 1
		}
	done
fi

install -d -o root -g root -m 0755 "$(dirname -- "$binary")"
install -o root -g root -m 0755 "$binary_source" "$binary"

install -d -o root -g root -m 0755 "$(dirname -- "$dbusconf")"
install -o root -g root -m 0644 "$dbusconf_source" "$dbusconf"
systemctl reload dbus 2>/dev/null || systemctl restart dbus

install -d -o root -g root -m 0755 "$dropin_dir" /etc/udev/rules.d
install -o root -g root -m 0644 "$dropin_source" "$dropin"
install -o root -g root -m 0644 "$rule_source" "$rule"

systemctl daemon-reload
udevadm control --reload-rules

if [ -c /dev/fastrpc-sdsp ]; then
	udevadm trigger --action=add --subsystem-match=misc --sysname-match='fastrpc-sdsp*'
	udevadm settle
	systemctl restart iio-sensor-proxy.service
	systemctl is-active --quiet iio-sensor-proxy.service
	udevadm info --query=property --path=/sys/class/misc/fastrpc-sdsp | \
		grep -Fqx 'IIO_SENSOR_PROXY_TYPE=ssc-accel ssc-light ssc-compass ssc-gyro ssc-magnetometer'
else
	echo "iio-sensor-proxy installed; restart deferred until /dev/fastrpc-sdsp appears" >&2
fi

echo "installed prebuilt iio-sensor-proxy $version with Qualcomm SSC support: $binary"
echo "installed D-Bus policy: $dbusconf"
echo "installed reversible systemd override: $dropin"
echo "the distribution iio-sensor-proxy binary was preserved"
echo "SSC iio-sensor-proxy installation complete"
