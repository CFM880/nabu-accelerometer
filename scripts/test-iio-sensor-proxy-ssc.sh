#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

seconds=${1:-20}
script_path=$(realpath -- "$0")
case $seconds in
	*[!0-9]*|'')
		echo "usage: $0 [positive-seconds]" >&2
		exit 2
		;;
esac
[ "$seconds" -gt 0 ] || {
	echo "timeout must be positive" >&2
	exit 2
}

systemctl is-active --quiet hexagonrpcd.service
systemctl is-active --quiet iio-sensor-proxy.service

has_accelerometer=$(busctl get-property \
	net.hadess.SensorProxy \
	/net/hadess/SensorProxy \
	net.hadess.SensorProxy \
	HasAccelerometer | awk '{print $2}')
[ "$has_accelerometer" = true ] || {
	echo "desktop sensor API does not expose an accelerometer" >&2
	exit 1
}
echo "desktop sensor API reports HasAccelerometer=true"

log=$(mktemp /tmp/nabu-monitor-sensor.XXXXXX)
cleanup()
{
	rm -f -- "$log"
}
trap cleanup EXIT HUP INT TERM

echo "monitoring the desktop sensor API for $seconds seconds"
echo "rotate the tablet through at least one quarter turn"
set +e
timeout "$seconds" monitor-sensor >"$log" 2>&1
status=$?
set -e
cat "$log"

if grep -Fq 'Not Authorized: Sensor claim not allowed' "$log"; then
	echo "accelerometer discovery passed, but this inactive/SSH session cannot claim it"
	if [ "${NABU_SENSOR_USER_UNIT:-0}" != 1 ] && command -v systemd-run >/dev/null; then
		echo "retrying through the user manager associated with the active graphical login"
		exec systemd-run --user --wait --pipe --collect \
			--unit="nabu-ssc-orientation-test-$$" \
			--setenv=NABU_SENSOR_USER_UNIT=1 \
			"$script_path" "$seconds"
	fi
	echo "log in locally, then rerun this test to verify orientation changes"
	exit 0
fi

case $status in
	0|124) ;;
	*)
		echo "monitor-sensor failed with status $status" >&2
		exit "$status"
		;;
esac
grep -Eq 'Has accelerometer|Accelerometer orientation changed' "$log" || {
	echo "desktop sensor API did not expose the SSC accelerometer" >&2
	exit 1
}

echo "desktop sensor API exposed the SSC accelerometer"
