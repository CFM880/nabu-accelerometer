#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

[ "$#" -eq 1 ] || {
	echo "usage: $0 /path/to/nabu-tablet-mode" >&2
	exit 2
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_file=$script_dir/../userspace/nabu-tablet-mode.c
destination=$1
temporary=$destination.new
compiler=${CC:-aarch64-linux-gnu-gcc}

[ -f "$source_file" ] || {
	echo "missing source: $source_file" >&2
	exit 1
}
command -v "$compiler" >/dev/null 2>&1 || {
	echo "missing compiler: $compiler" >&2
	exit 1
}

rm -f -- "$temporary"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
	-Wl,-z,relro,-z,now \
	-o "$temporary" "$source_file"
chmod 0755 "$temporary"
mv -f -- "$temporary" "$destination"

file "$destination" | grep -Fq 'ARM aarch64' || {
	echo "built binary is not AArch64" >&2
	exit 1
}
strings "$destination" | grep -Fq 'Nabu Tablet Mode Switch' || exit 1

echo "built Nabu tablet-mode helper: $destination"
sha256sum "$destination"
