#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

seconds=${1:-0}
case $seconds in
	*[!0-9]*|'')
		echo "usage: sudo bash $0 [sample-seconds]" >&2
		exit 2
		;;
esac
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")

"$project_dir/libexec/inspect-default-uki.sh"

for service in hexagonrpcd.service iio-sensor-proxy.service nabu-tablet-mode.service; do
	systemctl is-active --quiet "$service"
	printf '%s: active, restarts=' "$service"
	systemctl show "$service" -p NRestarts --value
done

for state in /sys/class/remoteproc/remoteproc*/state; do
	[ "$(cat "$state")" = running ] || {
		echo "remoteproc is not running: $state" >&2
		exit 1
	}
done
echo "all remote processors: running"

has_accelerometer=$(busctl get-property \
	net.hadess.SensorProxy \
	/net/hadess/SensorProxy \
	net.hadess.SensorProxy \
	HasAccelerometer | awk '{print $2}')
[ "$has_accelerometer" = true ] || {
	echo "desktop sensor API has no accelerometer" >&2
	exit 1
}
orientation=$(busctl get-property \
	net.hadess.SensorProxy \
	/net/hadess/SensorProxy \
	net.hadess.SensorProxy \
	AccelerometerOrientation | cut -d ' ' -f 2-)
echo "HasAccelerometer=true, orientation=$orientation"

errors=$(journalctl -b --no-pager | grep -Eic \
	'crash detected in slpi|Unhandled context fault|USER-PD DOG|attach sensors PD timed out|watchdog' || true)
[ "$errors" -eq 0 ] || {
	echo "found $errors SLPI/FastRPC error records" >&2
	exit 1
}
echo "SLPI/FastRPC error records: 0"

if [ "$seconds" -gt 0 ]; then
	[ -x /usr/local/bin/ssccli ] || {
		echo "missing /usr/local/bin/ssccli" >&2
		exit 1
	}
	timeout "$((seconds + 110))s" \
		/usr/local/bin/ssccli --debug --sensor accelerometer --timeout "$seconds"
fi

echo "final Nabu accelerometer verification passed"
