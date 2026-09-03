#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

version=3.9
expected_archive=iio-sensor-proxy-$version.tar.gz
expected_sha256=af5edd307dcfa52dc3a242d13b7cc756e90a71640caf332efbad960e21649ae4
binary=/usr/local/libexec/iio-sensor-proxy-ssc
dropin_dir=/etc/systemd/system/iio-sensor-proxy.service.d
dropin=$dropin_dir/nabu-ssc.conf
rule=/etc/udev/rules.d/90-nabu-ssc-accelerometer.rules
legacy_identity_rule_sha256=dcc04b9147f0f162b208334c5c4658b70b4e26384fa968a0632cd7468a387761

usage()
{
	echo "usage: sudo $0 /path/to/$expected_archive" >&2
	exit 2
}

[ "$#" -eq 1 ] || usage
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dropin_source=$script_dir/../config/nabu-ssc-iio-sensor-proxy.conf
rule_source=$script_dir/../config/90-nabu-ssc-accelerometer.rules
archive=$(realpath -- "$1")

for source in "$dropin_source" "$rule_source"; do
	[ -f "$source" ] || {
		echo "missing packaged configuration: $source" >&2
		exit 1
	}
done
[ -s "$archive" ] || {
	echo "missing source archive: $archive" >&2
	exit 1
}
[ "$(basename -- "$archive")" = "$expected_archive" ] || {
	echo "unexpected archive name: $(basename -- "$archive")" >&2
	exit 1
}
actual_sha256=$(sha256sum "$archive" | cut -d ' ' -f 1)
[ "$actual_sha256" = "$expected_sha256" ] || {
	echo "iio-sensor-proxy source archive SHA256 mismatch" >&2
	echo "expected: $expected_sha256" >&2
	echo "actual:   $actual_sha256" >&2
	exit 1
}

[ -x /usr/local/bin/ssccli ] || {
	echo "libssc is not installed; run install-libssc.sh first" >&2
	exit 1
}
[ "$(/usr/local/bin/ssccli --version)" = "libssc version 0.4.4" ] || {
	echo "unexpected installed libssc version" >&2
	exit 1
}
systemctl is-active --quiet hexagonrpcd.service || {
	echo "hexagonrpcd.service is not active" >&2
	exit 1
}

if [ -e "$dropin" ] && ! cmp -s "$dropin" "$dropin_source"; then
	echo "refusing to replace unexpected systemd drop-in: $dropin" >&2
	exit 1
fi
if [ -e "$rule" ] && ! cmp -s "$rule" "$rule_source"; then
	installed_rule_sha256=$(sha256sum "$rule" | cut -d ' ' -f 1)
	[ "$installed_rule_sha256" = "$legacy_identity_rule_sha256" ] || {
		echo "refusing to replace unexpected udev rule: $rule" >&2
		exit 1
	}
fi
if [ -e "$binary" ]; then
	strings "$binary" | grep -Fq 'SSC accelerometer sensor' || {
		echo "refusing to replace unexpected binary: $binary" >&2
		exit 1
	}
fi

apt-get install --no-install-recommends -y \
	build-essential \
	meson \
	ninja-build \
	pkgconf \
	libglib2.0-dev \
	libgudev-1.0-dev \
	libpolkit-gobject-1-dev

build_root=$(mktemp -d /tmp/nabu-iio-sensor-proxy-build.XXXXXX)
cleanup()
{
	rm -rf -- "$build_root"
}
trap cleanup EXIT HUP INT TERM

source_dir=$build_root/source
build_dir=$build_root/build
install -d -m 0755 "$source_dir"
tar -xzf "$archive" --strip-components=1 -C "$source_dir"

meson setup "$build_dir" "$source_dir" \
	--prefix=/usr/local \
	--buildtype=release \
	-Dssc-support=enabled \
	-Dtests=false \
	-Dgtk-tests=false \
	-Dgtk_doc=false \
	-Dudevrulesdir="$build_root/not-installed/udev" \
	-Dsystemdsystemunitdir="$build_root/not-installed/systemd"
meson compile -C "$build_dir"

built_binary=$build_dir/src/iio-sensor-proxy
[ -x "$built_binary" ] || {
	echo "missing built iio-sensor-proxy binary" >&2
	exit 1
}
ldd "$built_binary" | grep -Fq 'libssc.so.2' || {
	echo "built binary does not link to libssc" >&2
	exit 1
}
strings "$built_binary" | grep -Fq 'SSC accelerometer sensor' || {
	echo "built binary does not contain the SSC accelerometer backend" >&2
	exit 1
}

install -d -o root -g root -m 0755 "$(dirname -- "$binary")"
install -o root -g root -m 0755 "$built_binary" "$binary"
install -d -o root -g root -m 0755 "$dropin_dir" /etc/udev/rules.d
install -o root -g root -m 0644 "$dropin_source" "$dropin"
install -o root -g root -m 0644 "$rule_source" "$rule"

systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger --action=add --subsystem-match=misc --sysname-match='fastrpc-sdsp*'
udevadm settle
systemctl restart iio-sensor-proxy.service

systemctl is-active --quiet iio-sensor-proxy.service
udevadm info --query=property --path=/sys/class/misc/fastrpc-sdsp | \
	grep -Fqx 'IIO_SENSOR_PROXY_TYPE=ssc-accel'

echo "installed iio-sensor-proxy $version with Qualcomm SSC support: $binary"
echo "source SHA256: $actual_sha256"
echo "installed Nabu udev opt-in: $rule"
echo "installed reversible systemd override: $dropin"
echo "the distribution iio-sensor-proxy binary was preserved"
echo "next: run test-iio-sensor-proxy-ssc.sh as the normal user"
