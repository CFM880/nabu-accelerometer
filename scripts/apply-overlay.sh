#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

expected_base=5181e1358ddd6ea8028e841d928942373e6aebc8

if [ "$#" -ne 1 ]; then
	echo "usage: $0 /path/to/linux" >&2
	exit 2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
overlay_dir=$(dirname -- "$script_dir")/kernel-overlay
fastrpc_patch=$(dirname -- "$script_dir")/patches/0001-sm8150-slpi-fastrpc-pdr.patch
kernel_tree=$1

if [ ! -f "$kernel_tree/Makefile" ] ||
   ! git -C "$kernel_tree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "not a Linux Git worktree: $kernel_tree" >&2
	exit 1
fi

current=$(git -C "$kernel_tree" rev-parse HEAD)
if [ "$current" != "$expected_base" ]; then
	echo "expected base $expected_base, found $current" >&2
	exit 1
fi

[ -f "$fastrpc_patch" ] || {
	echo "missing FastRPC patch: $fastrpc_patch" >&2
	exit 1
}

# The tracked FastRPC changes are kept as a focused patch so the project does
# not duplicate complete upstream sources. Accept either a clean base or this
# exact patch already applied, but never overwrite other local FastRPC work.
if git -C "$kernel_tree" apply --reverse --check "$fastrpc_patch" >/dev/null 2>&1; then
	fastrpc_state=already-applied
elif git -C "$kernel_tree" diff --quiet HEAD -- drivers/misc/fastrpc.c; then
	git -C "$kernel_tree" apply --check "$fastrpc_patch"
	git -C "$kernel_tree" apply "$fastrpc_patch"
	fastrpc_state=applied
else
	echo "refusing to overwrite unrelated changes in drivers/misc/fastrpc.c" >&2
	exit 1
fi

# Permit unrelated overlays, but never overwrite a target path carrying
# unknown local changes. Reapplying this overlay is idempotent.
find "$overlay_dir" -type f -print | sort | while IFS= read -r source; do
	relative=${source#"$overlay_dir"/}
	target=$kernel_tree/$relative

	if [ -f "$target" ] && cmp -s "$source" "$target"; then
		continue
	fi

	if git -C "$kernel_tree" ls-files --error-unmatch "$relative" >/dev/null 2>&1; then
		if ! git -C "$kernel_tree" diff --quiet HEAD -- "$relative"; then
			echo "refusing to overwrite locally changed path: $relative" >&2
			exit 1
		fi
	elif [ -e "$target" ]; then
		echo "refusing to overwrite untracked path: $relative" >&2
		exit 1
	fi
done

# Give installed sources fresh timestamps so an incremental O= build cannot
# reuse objects produced from an older revision of the overlay.
cp -R "$overlay_dir/." "$kernel_tree/"

echo "installed nabu-accelerometer overlay into $kernel_tree"
echo "FastRPC SM8150 SDSP IOVA/PDR patch: $fastrpc_state"
echo "production DTB target: qcom/sm8150-xiaomi-nabu-iris-camera-accelerometer-slpi-boot-only.dtb"
git -C "$kernel_tree" status --short
