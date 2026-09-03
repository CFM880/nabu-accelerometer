#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Run this on a Linux host connected to nabu's USB-C port.
set -eu

output=${1:-nabu-usb-console-$(date +%Y%m%d-%H%M%S).log}

find_console()
{
	for tty in /dev/ttyACM*; do
		[ -c "$tty" ] || continue
		properties=$(udevadm info --query=property --name="$tty" 2>/dev/null || true)
		case $properties in *ID_VENDOR_ID=0525*) ;; *) continue ;; esac
		case $properties in *ID_MODEL_ID=a4a7*) ;; *) continue ;; esac
		echo "$tty"
		return 0
	done
	return 1
}

echo "waiting for nabu USB console (0525:a4a7); logging to $output" >&2
echo "keep this running, then boot the nabu accelerometer test entry" >&2

while :; do
	device=$(find_console || true)
	if [ -z "$device" ]; then
		sleep 1
		continue
	fi

	echo "$(date --iso-8601=seconds) connected: $device" | tee -a "$output" >&2
	stty -F "$device" raw -echo -hupcl 115200 2>/dev/null || true
	# cat exits when the gadget disconnects.  Loop so a reboot reconnects to
	# the same log instead of losing the beginning of the next attempt.
	stdbuf -o0 cat "$device" 2>/dev/null | stdbuf -o0 tee -a "$output" || true
	echo "$(date --iso-8601=seconds) disconnected: $device" | tee -a "$output" >&2
	sleep 1
done
