#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-main install helper: install the prebuilt libssc (ssccli + libssc.so.2)
# produced by the build hook.  Compilation happens at build time; this script
# only places files and refreshes the linker cache.  It does not need the SLPI
# FastRPC node, so it works before SLPI has probed.
set -eu

version=0.4.4
ssccli_target=/usr/local/bin/ssccli
libssc_target=/usr/local/lib/libssc.so.2

[ "$#" -eq 2 ] || {
	echo "usage: $0 <ssccli> <libssc.so.2>" >&2
	exit 2
}
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

if [ -c /dev/fastrpc-sdsp ] && systemctl is-active --quiet hexagonrpcd.service; then
	slpi_up=true
else
	slpi_up=false
fi

ssccli_source=$(realpath -- "$1")
libssc_source=$(realpath -- "$2")

[ -s "$ssccli_source" ] || {
	echo "missing prebuilt ssccli: $ssccli_source" >&2
	exit 1
}
[ -s "$libssc_source" ] || {
	echo "missing prebuilt libssc.so.2: $libssc_source" >&2
	exit 1
}

install -d -o root -g root -m 0755 "$(dirname -- "$ssccli_target")" "$(dirname -- "$libssc_target")"
install -o root -g root -m 0755 "$ssccli_source" "$ssccli_target"
install -o root -g root -m 0644 "$libssc_source" "$libssc_target"
ldconfig

[ "$("$ssccli_target" --version)" = "libssc version $version" ] || {
	echo "installed ssccli version check failed" >&2
	exit 1
}

echo "installed prebuilt libssc $version: $ssccli_target"
[ "$slpi_up" = true ] && echo "SLPI and hexagonrpcd were left running"
echo "libssc installation complete"
