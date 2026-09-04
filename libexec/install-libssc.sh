#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

version=0.4.4
expected_archive=libssc-v$version.tar.gz
expected_sha256=716d6bd6b34d2d753060c6b54c9a87e34fae75b724c763bf9ef487efa3621587

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

archive=$(realpath -- "$1")
[ -s "$archive" ] || {
	echo "missing libssc source archive: $archive" >&2
	exit 1
}
[ "$(basename -- "$archive")" = "$expected_archive" ] || {
	echo "unexpected archive name: $(basename -- "$archive")" >&2
	exit 1
}

actual_sha256=$(sha256sum "$archive" | cut -d ' ' -f 1)
[ "$actual_sha256" = "$expected_sha256" ] || {
	echo "libssc source archive SHA256 mismatch" >&2
	echo "expected: $expected_sha256" >&2
	echo "actual:   $actual_sha256" >&2
	exit 1
}

[ -c /dev/fastrpc-sdsp ] || {
	echo "missing SLPI FastRPC device: /dev/fastrpc-sdsp" >&2
	exit 1
}
systemctl is-active --quiet hexagonrpcd.service || {
	echo "hexagonrpcd.service is not active" >&2
	exit 1
}

# Ubuntu 26.04 already provides new enough Meson, GLib and libqmi. Keep the
# dependency list explicit so this produces the same build on a clean target.
apt-get install --no-install-recommends -y \
	build-essential \
	meson \
	ninja-build \
	pkgconf \
	libglib2.0-dev \
	libqmi-glib-dev \
	libprotobuf-c-dev \
	python3-dev \
	protobuf-c-compiler \
	protobuf-compiler

build_root=$(mktemp -d /tmp/nabu-libssc-build.XXXXXX)
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
	--buildtype=release
meson compile -C "$build_dir"
meson install -C "$build_dir"
ldconfig

command -v /usr/local/bin/ssccli >/dev/null
[ "$(/usr/local/bin/ssccli --version)" = "libssc version $version" ] || {
	echo "installed ssccli version check failed" >&2
	exit 1
}

echo "installed pinned libssc $version from $expected_archive"
echo "source SHA256: $actual_sha256"
echo "ssccli: /usr/local/bin/ssccli"
echo "SLPI and hexagonrpcd were left running"
echo "libssc installation complete"
