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
legacy_accelerometer_only_rule_sha256=95b011f5634b7ced33e03b90144d5f7f273dd29cad3dcacbb09b83c588ab91f3
legacy_motion_rule_sha256=0862d933b1a9b89d624864638b96024030bba561ba4af76dc8858b78084479e0
dbusconf=/usr/share/dbus-1/system.d/net.hadess.SensorProxy.conf
dbusconf_source=

usage()
{
	echo "usage: sudo $0 [/path/to/$expected_archive]" >&2
	exit 2
}

[ "$#" -le 1 ] || usage
[ "$(id -u)" -eq 0 ] || {
	echo "must run as root" >&2
	exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dropin_source=$script_dir/../config/nabu-ssc-iio-sensor-proxy.conf
rule_source=$script_dir/../config/90-nabu-ssc-accelerometer.rules
light_patch=$script_dir/../patches/0002-ssc-light-filter.patch
light_filter=$script_dir/../userspace/nabu-light-filter.h
gyro_patch=$script_dir/../patches/0003-ssc-gyroscope-magnetometer.patch
archive=

for source in "$dropin_source" "$rule_source" "$light_patch" "$light_filter" "$gyro_patch"; do
	[ -f "$source" ] || {
		echo "missing packaged configuration: $source" >&2
		exit 1
	}
done
if [ "$#" -eq 1 ]; then
	archive=$(realpath -- "$1")
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
fi

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
			echo "existing binary lacks the SSC $backend backend: $binary" >&2
			exit 1
		}
	done
fi

if [ -n "$archive" ]; then
	apt-get install --no-install-recommends -y \
		build-essential \
		patch \
		meson \
		ninja-build \
		pkgconf \
		libglib2.0-dev \
		libgudev-1.0-dev \
		libpolkit-gobject-1-dev

	# Extract and build inside the repository so the sources remain inspectable.
	project_dir=$(dirname -- "$script_dir")
	build_root=$project_dir/third_party/build/iio-sensor-proxy
	rm -rf -- "$build_root"
	install -d -m 0755 "$build_root"

	source_dir=$build_root/source
	build_dir=$build_root/build
	install -d -m 0755 "$source_dir"
	tar -xzf "$archive" --strip-components=1 -C "$source_dir"
	patch --batch --fuzz=0 -d "$source_dir" -p1 < "$light_patch"
	install -m 0644 "$light_filter" "$source_dir/src/nabu-light-filter.h"
	patch --batch --fuzz=0 -d "$source_dir" -p1 < "$gyro_patch"

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
	dbusconf_source=$build_dir/data/net.hadess.SensorProxy.conf
	strings "$built_binary" | grep -Fq 'Nabu SSC light filter v2 enabled' || {
		echo "built binary lacks the Nabu light filter" >&2
		exit 1
	}
	[ -x "$built_binary" ] || {
		echo "missing built iio-sensor-proxy binary" >&2
		exit 1
	}
	ldd "$built_binary" | grep -Fq 'libssc.so.2' || {
		echo "built binary does not link to libssc" >&2
		exit 1
	}
	for backend in accelerometer light compass gyroscope magnetometer; do
		strings "$built_binary" | grep -Fq "SSC $backend sensor" || {
			echo "built binary does not contain the SSC $backend backend" >&2
			exit 1
		}
	done

	install -d -o root -g root -m 0755 "$(dirname -- "$binary")"
	install -o root -g root -m 0755 "$built_binary" "$binary"
else
	[ -x "$binary" ] || {
		echo "missing $expected_archive and the SSC sensor proxy is not installed" >&2
		exit 1
	}
	if ! strings "$binary" | grep -Fq 'Nabu SSC light filter v2 enabled'; then
		echo "existing SSC proxy has no light filter; rebuild with $expected_archive to enable it" >&2
	fi
fi

if [ -n "$dbusconf_source" ]; then
	install -d -o root -g root -m 0755 "$(dirname -- "$dbusconf")"
	install -o root -g root -m 0644 "$dbusconf_source" "$dbusconf"
	systemctl reload dbus 2>/dev/null || systemctl restart dbus
fi
for iface in Gyroscope Magnetometer; do
	grep -Fq "send_interface=\"net.hadess.SensorProxy.$iface\"" "$dbusconf" || {
		echo "installed D-Bus policy does not allow the $iface interface: $dbusconf" >&2
		echo "rebuild iio-sensor-proxy with $expected_archive to install it" >&2
		exit 1
	}
done

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
	grep -Fqx 'IIO_SENSOR_PROXY_TYPE=ssc-accel ssc-light ssc-compass ssc-gyro ssc-magnetometer'

echo "installed iio-sensor-proxy $version with Qualcomm SSC support: $binary"
[ -z "$archive" ] || echo "source SHA256: $actual_sha256"
echo "installed Nabu accelerometer, light, compass, gyroscope, and magnetometer udev opt-in: $rule"
echo "installed D-Bus policy: $dbusconf"
echo "installed reversible systemd override: $dropin"
echo "the distribution iio-sensor-proxy binary was preserved"
echo "SSC iio-sensor-proxy installation complete"
