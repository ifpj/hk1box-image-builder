#!/bin/bash
set -euo pipefail

# ========================================================================
# Build default Debian/Ubuntu arm64 rootfs tarball with mmdebstrap
# Output: <distro>-<suite>-default-arm64.tar.zst + manifest + sha256
# ========================================================================

error_msg() { echo "[ERROR] $1" >&2; exit 1; }
info_msg()  { echo "[INFO]  $1"; }

DISTRO=""
SUITE=""
MIRROR=""
COMPONENTS=""
ARCH="arm64"
OUTPUT_DIR="/tmp"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distro)     DISTRO="$2"; shift 2 ;;
    --suite)      SUITE="$2"; shift 2 ;;
    --mirror)     MIRROR="$2"; shift 2 ;;
    --components) COMPONENTS="$2"; shift 2 ;;
    --arch)       ARCH="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    *) error_msg "Unknown parameter: $1" ;;
  esac
done

[[ -n "$DISTRO" ]] || error_msg "--distro is required"
[[ -n "$SUITE" ]] || error_msg "--suite is required"
[[ -n "$MIRROR" ]] || error_msg "--mirror is required"
[[ -n "$COMPONENTS" ]] || error_msg "--components is required"
mkdir -p "$OUTPUT_DIR"

BASENAME="${DISTRO}-${SUITE}-default-${ARCH}"
TARFILE="${OUTPUT_DIR}/${BASENAME}.tar"
ZSTFILE="${TARFILE}.zst"
MANIFEST="${OUTPUT_DIR}/${BASENAME}-manifest.txt"

info_msg "Building default rootfs: ${BASENAME}"
info_msg "Mirror: ${MIRROR}"
info_msg "Components: ${COMPONENTS}"

# Intentionally do not pass --variant and do not pass --include.
# This uses mmdebstrap's default package set for the suite.
sudo mmdebstrap \
  --architecture="$ARCH" \
  --components="$COMPONENTS" \
  "$SUITE" \
  "$TARFILE" \
  "$MIRROR"

info_msg "Extracting package manifest..."
tar xf "$TARFILE" ./var/lib/dpkg/status -O | \
  awk '/^Package:/{pkg=$2} /^Version:/{ver=$2; print pkg "\t" ver}' | \
  sort > "$MANIFEST"
info_msg "Installed packages: $(wc -l < "$MANIFEST")"

info_msg "Compressing rootfs with zstd -1..."
zstd -T0 -1 -f "$TARFILE" -o "$ZSTFILE"
rm -f "$TARFILE"
sha256sum "$ZSTFILE" > "${ZSTFILE}.sha256"

info_msg "Done: $(ls -lh "$ZSTFILE")"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "tarball=${ZSTFILE}" >> "$GITHUB_OUTPUT"
  echo "manifest=${MANIFEST}" >> "$GITHUB_OUTPUT"
fi
