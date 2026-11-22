#!/usr/bin/env bash
# Write GodMode OS to a USB stick, erasing whatever is on it.
#
#   sudo ./write-usb.sh <iso>              list candidate devices, write nothing
#   sudo ./write-usb.sh <iso> /dev/sdX     erase /dev/sdX and write the image
#   sudo ./write-usb.sh <iso> /dev/sdX --zero   also zero the tail past the image
#
# Refuses any target that is not a whole, removable, non-system disk, and makes
# you type the device path before it erases anything. Safe to run on a machine
# whose own disk is attached: picking the wrong device is the thing this guards.
set -euo pipefail

ISO="${1:-}"
DEV="${2:-}"
ZERO=0
[[ "${3:-}" == "--zero" ]] && ZERO=1

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

[[ -n "$ISO" ]] || die "usage: sudo $0 <iso> [/dev/sdX] [--zero]"
[[ $EUID -eq 0 ]] || die "must run as root (writing to a raw device)"
[[ -f "$ISO" ]]  || die "no such file: $ISO"
for t in lsblk findmnt dd sha256sum wipefs; do
  command -v "$t" >/dev/null || die "missing required tool: $t"
done

# Disks that hold a mounted system path. Never offer or accept these.
system_disks() {
  local mp src pk
  for mp in / /boot /boot/firmware /home; do
    src="$(findmnt -no SOURCE --target "$mp" 2>/dev/null | head -1)" || true
    [[ -n "${src:-}" && "$src" == /dev/* ]] || continue
    pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)"
    [[ -n "$pk" ]] && echo "$pk" || echo "$(basename "$src")"
  done | sort -u
}
SYS="$(system_disks)"

if [[ -z "$DEV" ]]; then
  note "Removable disks on this machine (system disks excluded)"
  printf '\n  %-12s %-8s %-6s %s\n' DEVICE SIZE BUS MODEL
  found=0
  while read -r name size model tran rm type; do
    [[ "$type" == "disk" ]] || continue
    grep -qx "$name" <<<"$SYS" && continue
    [[ "$rm" == "1" || "$tran" == "usb" ]] || continue
    printf '  %-12s %-8s %-6s %s\n' "/dev/$name" "$size" "${tran:-?}" "${model:-unknown}"
    found=1
  done < <(lsblk -dno NAME,SIZE,MODEL,TRAN,RM,TYPE)
  [[ $found -eq 1 ]] || echo "  (none found - is the stick plugged in?)"
  echo
  echo "  System disks, which this script will refuse:"
  printf '    /dev/%s\n' $SYS
  echo
  echo "Re-run with the device you want, e.g.:  sudo $0 $ISO /dev/sdX"
  exit 0
fi

# --- validate the target ------------------------------------------------
[[ -b "$DEV" ]] || die "$DEV is not a block device"
BASE="$(basename "$DEV")"
[[ "$(lsblk -dno TYPE "$DEV")" == "disk" ]] \
  || die "$DEV is a partition. Give the whole disk, e.g. /dev/sda not /dev/sda1"
grep -qx "$BASE" <<<"$SYS" \
  && die "$DEV holds a mounted system path on THIS machine. Refusing."
RM="$(lsblk -dno RM "$DEV")"; TRAN="$(lsblk -dno TRAN "$DEV" || true)"
[[ "$RM" == "1" || "$TRAN" == "usb" ]] \
  || die "$DEV is not removable and not on USB. Refusing, in case it is an internal disk."

ISO_SIZE=$(stat -c%s "$ISO")
DEV_SIZE=$(blockdev --getsize64 "$DEV")
(( DEV_SIZE >= ISO_SIZE )) \
  || die "$DEV is $(numfmt --to=iec "$DEV_SIZE") but the image needs $(numfmt --to=iec "$ISO_SIZE")"

# --- verify the image before trusting it --------------------------------
if [[ -f "$ISO.sha256" ]]; then
  note "Checking image against $ISO.sha256"
  ( cd "$(dirname "$ISO")" && sha256sum -c "$(basename "$ISO").sha256" ) \
    || die "checksum mismatch - the download is corrupt, do not write it"
else
  note "No .sha256 beside the image; skipping checksum check"
fi

# --- show exactly what is about to be destroyed -------------------------
echo
note "About to ERASE this device and write $(basename "$ISO") to it"
echo
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DEV" | sed 's/^/    /'
echo
printf '    image: %s (%s)\n' "$ISO" "$(numfmt --to=iec "$ISO_SIZE")"
printf '    target: %s (%s)\n' "$DEV" "$(numfmt --to=iec "$DEV_SIZE")"
echo
echo "    Everything on $DEV will be gone. This cannot be undone."
echo
read -rp "    Type the device path to confirm ($DEV): " reply
[[ "$reply" == "$DEV" ]] || die "did not match - nothing was written"

# --- write ---------------------------------------------------------------
note "Unmounting any partitions on $DEV"
while read -r part; do
  [[ -n "$part" ]] || continue
  umount "/dev/$part" 2>/dev/null && echo "    unmounted /dev/$part" || true
done < <(lsblk -lno NAME "$DEV" | tail -n +2)

note "Clearing old filesystem signatures"
wipefs -a "$DEV" >/dev/null

if [[ $ZERO -eq 1 ]]; then
  note "Zeroing the whole device first (slow, you asked for --zero)"
  dd if=/dev/zero of="$DEV" bs=4M status=progress conv=fsync || true
fi

note "Writing the image - do not unplug"
if ! dd if="$ISO" of="$DEV" bs=4M status=progress conv=fsync oflag=direct 2>&1; then
  note "Retrying without O_DIRECT"
  dd if="$ISO" of="$DEV" bs=4M status=progress conv=fsync
fi
sync
blockdev --flushbufs "$DEV" 2>/dev/null || true

# --- verify what actually landed on the stick ---------------------------
note "Reading the stick back to verify (${ISO_SIZE} bytes)"
want="$(sha256sum "$ISO" | cut -d' ' -f1)"
got="$(head -c "$ISO_SIZE" "$DEV" | sha256sum | cut -d' ' -f1)"
if [[ "$want" != "$got" ]]; then
  die "VERIFY FAILED - the stick does not match the image.
       expected $want
       got      $got
       Do not boot from it. Try a different USB port or stick."
fi

sync
echo
note "Done. The stick matches the image byte for byte."
echo
echo "    sha256 $want"
echo
echo "  Next: eject it, plug it into the target laptop, and boot from it"
echo "  (HP: tap Esc at power-on, then F9 for the boot menu)."
echo
echo "  The laptop's hard drive is NOT touched by booting the stick."
echo "  It is only erased if you run \"Install GodMode OS\" from the desktop."
