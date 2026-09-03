#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

ssccli=/usr/local/bin/ssccli
seconds=${1:-20}

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

[ -x "$ssccli" ] || {
	echo "missing $ssccli; run install-libssc.sh first" >&2
	exit 1
}
systemctl is-active --quiet hexagonrpcd.service || {
	echo "hexagonrpcd.service is not active" >&2
	exit 1
}

echo "libssc: $($ssccli --version)"
echo "testing SSC accelerometer for $seconds seconds"
echo "move or rotate the tablet while samples are being printed"

# Sensor discovery itself can retry for up to 100 seconds. Give it a bounded
# grace period beyond the requested sample window so a missing SSC service does
# not leave a diagnostic command running indefinitely.
timeout "$((seconds + 110))s" \
	"$ssccli" --debug --sensor accelerometer --timeout "$seconds"
