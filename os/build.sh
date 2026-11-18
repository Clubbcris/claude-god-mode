#!/usr/bin/env bash
# GodMode OS - bootable live ISO builder.
# Produces a hybrid (UEFI + legacy BIOS) Ubuntu-based live ISO with
# Claude Code, Node 22 and Google Chrome preinstalled.
#
# Usage:  sudo ./build.sh [--work DIR] [--out DIR] [--skip-rootfs] [--skip-chroot]
#
# REUSE_SQUASHFS=1 reuses an existing squashfs instead of recompressing.
set -euo pipefail

export OS_NAME="GodMode OS"
export OS_ID="godmode"
export OS_VERSION="0.1"
export UBUNTU_SUITE="noble"          # 24.04 LTS
export ARCH="amd64"
export NODE_VERSION="v22.23.5"
export LIVE_USER="godmode"
export LIVE_HOST="godmode"
export UBUNTU_MIRROR="${UBUNTU_MIRROR:-https://archive.ubuntu.com/ubuntu/}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${HERE}/work"
OUT="${HERE}/out"
SKIP_ROOTFS=0
SKIP_CHROOT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work) WORK="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --skip-rootfs) SKIP_ROOTFS=1; shift ;;
    --skip-chroot) SKIP_CHROOT=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

export HERE WORK OUT
export ROOT="${WORK}/rootfs"
export ISODIR="${WORK}/iso"

[[ $EUID -eq 0 ]] || { echo "build.sh must run as root (needs chroot + loop devices)" >&2; exit 1; }

log() { printf '\n\033[1;35m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

# Unmount in reverse order on any exit so a failed build never leaves the
# host's /proc or /dev bind-mounted inside the rootfs.
cleanup() {
  local m
  for m in "${ROOT}/dev/pts" "${ROOT}/dev/shm" "${ROOT}/dev" "${ROOT}/proc" "${ROOT}/sys" "${ROOT}/run"; do
    mountpoint -q "$m" && umount -lf "$m" || true
  done
}
trap cleanup EXIT

mkdir -p "$WORK" "$OUT"

source "${HERE}/lib/00-rootfs.sh"
source "${HERE}/lib/10-chroot.sh"
source "${HERE}/lib/20-image.sh"

if [[ $SKIP_ROOTFS -eq 0 ]]; then
  stage_rootfs
else
  log "Skipping debootstrap (--skip-rootfs)"
fi
if [[ $SKIP_CHROOT -eq 0 ]]; then
  stage_chroot
else
  log "Skipping chroot setup (--skip-chroot)"
fi
stage_image

log "Done: ${OUT}/${OS_ID}-os-${OS_VERSION}-${ARCH}.iso"
ls -lh "${OUT}/${OS_ID}-os-${OS_VERSION}-${ARCH}.iso"
