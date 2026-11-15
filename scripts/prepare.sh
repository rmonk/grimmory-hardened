#!/usr/bin/env bash
# Fetch upstream grimmory at the pinned tag and apply the hardening overlay.
# Result: build/src is a ready-to-build Docker context.
#
# Usage: scripts/prepare.sh [upstream-ref]   (default: contents of UPSTREAM_VERSION)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="${1:-$(tr -d '[:space:]' < "$root/UPSTREAM_VERSION")}"
src="$root/build/src"
upstream="${UPSTREAM_REPO:-https://github.com/grimmory-tools/grimmory.git}"

rm -rf "$src"
mkdir -p "$root/build"
git clone --quiet --depth 1 --branch "$ref" "$upstream" "$src"
echo "prepare: upstream $ref @ $(git -C "$src" rev-parse --short HEAD)"

python3 -I "$root/scripts/harden-dockerfile.py" "$src/Dockerfile"

mkdir -p "$src/hardening"
cp "$root/overlay/security-overrides.init.gradle.kts" "$src/hardening/"

echo "prepare: build context ready at $src"
