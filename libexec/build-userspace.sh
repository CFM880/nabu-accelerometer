#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# nabu-main build hook helper for nabu-accelerometer: build the userspace SSC
# stack (libssc and iio-sensor-proxy) from the pinned source archives into
# out/userspace/root.  `make install` then only installs these prebuilt files,
# so install needs neither a compiler toolchain nor network access.
#
# The build is cross aware: when NABU_CROSS_COMPILE does not target the build
# machine, a meson cross file is generated from it.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
module_dir=${NABU_MODULE_DIR:-$project_dir}
cross=${NABU_CROSS_COMPILE:-aarch64-linux-gnu-}
third_party=$module_dir/third_party
build_root=$module_dir/third_party/build
stage=$module_dir/out/userspace/root

libssc_archive=$third_party/libssc-v0.4.4.tar.gz
libssc_sha256=716d6bd6b34d2d753060c6b54c9a87e34fae75b724c763bf9ef487efa3621587
iio_archive=$third_party/iio-sensor-proxy-3.9.tar.gz
iio_sha256=af5edd307dcfa52dc3a242d13b7cc756e90a71640caf332efbad960e21649ae4

die()
{
	echo "$*" >&2
	exit 1
}

check_sha256()
{
	[ -s "$1" ] || die "missing source archive: $1"
	actual=$(sha256sum "$1" | cut -d' ' -f1)
	[ "$actual" = "$2" ] || die "SHA256 mismatch for $1 (expected $2, got $actual)"
}

command -v meson >/dev/null 2>&1 || die "meson is required to build the userspace stack"
command -v ninja >/dev/null 2>&1 || die "ninja is required to build the userspace stack"

# Generate a meson cross file when the requested toolchain targets something
# other than the build machine (e.g. the aarch64 cross toolchain on x86_64).
meson_cross=
target=$("${cross}gcc" -dumpmachine 2>/dev/null || true)
host=$(cc -dumpmachine 2>/dev/null || true)
if [ -n "$target" ] && [ "$target" != "$host" ]; then
	cross_file=$module_dir/out/userspace/meson-cross.txt
	install -d -m 0755 "$(dirname -- "$cross_file")"
	cpu_family=${target%%-*}
	case $cpu_family in
	aarch64*) cpu_family=aarch64 ;;
	arm*) cpu_family=arm ;;
	x86_64*) cpu_family=x86_64 ;;
	i[3-6]86*) cpu_family=x86 ;;
	esac
	pkgconfig_libdir=${NABU_PKG_CONFIG_LIBDIR:-/usr/lib/$target/pkgconfig:/usr/share/pkgconfig}
	{
		echo '[binaries]'
		echo "c = '${cross}gcc'"
		echo "ar = '${cross}ar'"
		echo "strip = '${cross}strip'"
		echo "pkg-config = 'pkg-config'"
		printf "protoc = '%s'\n" "$(command -v protoc || true)"
		printf "protoc-gen-c = '%s'\n" "$(command -v protoc-gen-c || true)"
		printf "glib-compile-resources = '%s'\n" "$(command -v glib-compile-resources || true)"
		echo
		echo '[host_machine]'
		echo "system = 'linux'"
		echo "cpu_family = '$cpu_family'"
		echo "cpu = '$cpu_family'"
		echo "endian = 'little'"
		echo
		echo '[properties]'
		echo "pkg_config_libdir = '$pkgconfig_libdir'"
	} > "$cross_file"
	meson_cross="--cross-file=$cross_file"
	echo "cross building userspace for $target (host $host)"
fi

check_sha256 "$libssc_archive" "$libssc_sha256"
check_sha256 "$iio_archive" "$iio_sha256"

rm -rf -- "$stage" "$build_root/libssc" "$build_root/iio-sensor-proxy"
install -d -m 0755 "$stage"

# --- libssc ---
libssc_src=$build_root/libssc/source
libssc_build=$build_root/libssc/build
install -d -m 0755 "$libssc_src"
tar -xzf "$libssc_archive" --strip-components=1 -C "$libssc_src"
patch --batch --fuzz=0 -d "$libssc_src" -p1 < "$module_dir/patches/0004-libssc-skip-mocking.patch"
# shellcheck disable=SC2086
meson setup "$libssc_build" "$libssc_src" \
	$meson_cross --prefix="$stage/usr/local" --libdir=lib --buildtype=release
meson compile -C "$libssc_build"
meson install -C "$libssc_build"

# --- iio-sensor-proxy ---
iio_src=$build_root/iio-sensor-proxy/source
iio_build=$build_root/iio-sensor-proxy/build
install -d -m 0755 "$iio_src"
tar -xzf "$iio_archive" --strip-components=1 -C "$iio_src"
patch --batch --fuzz=0 -d "$iio_src" -p1 < "$module_dir/patches/0002-ssc-light-filter.patch"
install -m 0644 "$module_dir/userspace/nabu-light-filter.h" "$iio_src/src/nabu-light-filter.h"
patch --batch --fuzz=0 -d "$iio_src" -p1 < "$module_dir/patches/0003-ssc-gyroscope-magnetometer.patch"
patch --batch --fuzz=0 -d "$iio_src" -p1 < "$module_dir/patches/0005-ssc-startup-claim.patch"
# shellcheck disable=SC2086
meson setup "$iio_build" "$iio_src" \
	$meson_cross --prefix="$stage/usr/local" --libdir=lib --buildtype=release \
	-Dssc-support=enabled -Dtests=false -Dgtk-tests=false -Dgtk_doc=false \
	-Dudevrulesdir="$stage/usr/local/lib/udev/rules.d" \
	-Dsystemdsystemunitdir="$stage/usr/local/lib/systemd/system" \
	--pkg-config-path="$stage/usr/local/lib/pkgconfig"
meson compile -C "$iio_build"
# Do not run `meson install` for iio-sensor-proxy: it would write the polkit
# policy to the absolute /usr/share/polkit-1/actions, which is not needed here
# (the distribution already ships it).  Stage only the binary and the generated
# D-Bus policy.
install -D -m 0755 "$iio_build/src/iio-sensor-proxy" \
	"$stage/usr/local/libexec/iio-sensor-proxy"
install -D -m 0644 "$iio_build/data/net.hadess.SensorProxy.conf" \
	"$stage/usr/local/share/dbus-1/system.d/net.hadess.SensorProxy.conf"

# --- verify and declare staged files ---
for rel in \
	usr/local/bin/ssccli \
	usr/local/lib/libssc.so.2 \
	usr/local/libexec/iio-sensor-proxy \
	usr/local/share/dbus-1/system.d/net.hadess.SensorProxy.conf; do
	[ -s "$stage/$rel" ] || die "staged userspace file missing: $stage/$rel"
done
for backend in accelerometer light compass gyroscope magnetometer; do
	strings "$stage/usr/local/libexec/iio-sensor-proxy" | grep -Fq "SSC $backend sensor" ||
		die "built iio-sensor-proxy lacks the SSC $backend backend"
done
strings "$stage/usr/local/libexec/iio-sensor-proxy" | grep -Fq 'Nabu SSC light filter v2 enabled' ||
	die "built iio-sensor-proxy lacks the Nabu light filter"

echo "built Nabu userspace SSC stack: $stage"
