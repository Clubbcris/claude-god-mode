#!/usr/bin/env bash
# Offline checks against a built ISO: structure, boot images, and the
# contents of the squashfs root. Does not boot anything.
set -uo pipefail
ISO="${1:?usage: verify-image.sh <iso>}"
MNT=$(mktemp -d); SQ=$(mktemp -d)
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
chk()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

cleanup() { umount -l "$SQ" 2>/dev/null; umount -l "$MNT" 2>/dev/null; rmdir "$MNT" "$SQ" 2>/dev/null; }
trap cleanup EXIT

echo "== ISO: $(basename "$ISO") ($(du -h "$ISO" | cut -f1)) =="
mount -o loop,ro "$ISO" "$MNT" || { echo "cannot mount ISO"; exit 1; }

echo
echo "-- image structure --"
chk "casper/vmlinuz present"              "[ -f '$MNT/casper/vmlinuz' ]"
chk "casper/initrd present"               "[ -f '$MNT/casper/initrd' ]"
chk "casper/filesystem.squashfs present"  "[ -f '$MNT/casper/filesystem.squashfs' ]"
chk "filesystem.size present"             "[ -s '$MNT/casper/filesystem.size' ]"
chk "package manifest present"            "[ -s '$MNT/casper/filesystem.manifest' ]"
chk "boot menu present"                   "[ -s '$MNT/boot/grub/grub.cfg' ]"
chk "BIOS boot image present"             "[ -s '$MNT/boot/grub/bios.img' ]"
chk "UEFI El Torito image present"        "[ -s '$MNT/EFI/efiboot.img' ]"
chk "UEFI bootloader present"             "[ -s '$MNT/EFI/BOOT/BOOTX64.EFI' ]"
chk "medium id for grub search"           "[ -f '$MNT/.disk/godmode.id' ]"
chk "md5sum.txt present"                  "[ -s '$MNT/md5sum.txt' ]"

echo
echo "-- boot records --"
if xorriso -indev "$ISO" -report_el_torito plain 2>/dev/null | grep -q 'El Torito boot img.*BIOS'; then
  ok "El Torito BIOS entry"
else bad "El Torito BIOS entry"; fi
if xorriso -indev "$ISO" -report_el_torito plain 2>/dev/null | grep -q 'El Torito boot img.*UEFI'; then
  ok "El Torito UEFI entry"
else bad "El Torito UEFI entry"; fi
if [ "$(head -c 2 "$ISO" | xxd -p)" != "0000" ]; then
  ok "MBR present (legacy BIOS bootable)"
else bad "MBR present"; fi

echo
echo "-- squashfs contents --"
mount -o loop,ro "$MNT/casper/filesystem.squashfs" "$SQ" || { echo "cannot mount squashfs"; exit 1; }
chk "Claude Code binary"          "[ -x '$SQ/opt/node/bin/claude' ]"
chk "claude on PATH"              "[ -L '$SQ/usr/local/bin/claude' ]"
chk "Node 22 present"             "[ -x '$SQ/opt/node/bin/node' ]"
chk "Google Chrome present"       "[ -x '$SQ/opt/google/chrome/chrome' ]"
chk "godmode command"             "[ -x '$SQ/usr/local/bin/godmode' ]"
chk "godmode-tune command"        "[ -x '$SQ/usr/local/bin/godmode-tune' ]"
chk "XFCE session"                "[ -f '$SQ/usr/bin/xfce4-session' ]"
chk "LightDM"                     "[ -f '$SQ/usr/sbin/lightdm' ]"
chk "Calamares installer"         "[ -x '$SQ/usr/bin/calamares' ]"
chk "calamares settings.conf"     "[ -f '$SQ/etc/calamares/settings.conf' ]"
chk "casper live-boot support"    "[ -d '$SQ/usr/share/initramfs-tools/scripts/casper-bottom' ]"
chk "casper.conf names godmode"   "grep -q 'USERNAME=\"godmode\"' '$SQ/etc/casper.conf'"
chk "sysctl tuning installed"     "[ -f '$SQ/etc/sysctl.d/99-godmode.conf' ]"
chk "zram configured"             "grep -q 'ALGO=zstd' '$SQ/etc/default/zramswap'"
chk "io scheduler rules"          "[ -f '$SQ/etc/udev/rules.d/60-godmode-ioschedulers.rules' ]"
chk "passwordless sudo rule"      "grep -q 'NOPASSWD' '$SQ/etc/sudoers.d/90-godmode'"
chk "skel desktop shortcuts"      "[ -f '$SQ/etc/skel/Desktop/godmode-claude.desktop' ]"
chk "os-release branded"          "grep -q 'GodMode OS' '$SQ/etc/os-release'"

echo
echo "-- things that must NOT be in the image --"
chk "snapd absent"                "[ ! -e '$SQ/usr/lib/snapd' ]"
chk "snapd pinned out"            "grep -q 'Pin-Priority: -10' '$SQ/etc/apt/preferences.d/no-snapd'"
chk "no build-host proxy apt conf" "[ ! -e '$SQ/etc/apt/apt.conf.d/01build-proxy' ]"
chk "no build-host CA cert"       "[ ! -e '$SQ/usr/local/share/ca-certificates/build-proxy.crt' ]"
chk "no policy-rc.d left behind"  "[ ! -e '$SQ/usr/sbin/policy-rc.d' ]"
chk "machine-id blank"            "[ ! -s '$SQ/etc/machine-id' ]"

echo
echo "-- enabled services --"
for s in zramswap earlyoom tlp lightdm NetworkManager; do
  if ls "$SQ"/etc/systemd/system/*.target.wants/ 2>/dev/null | grep -q "^$s" \
     || find "$SQ/etc/systemd/system" -name "$s.service" 2>/dev/null | grep -q .; then
    ok "enabled: $s"
  else bad "enabled: $s"; fi
done
if [ -L "$SQ/etc/systemd/system/NetworkManager-wait-online.service" ] \
   && [ "$(readlink "$SQ/etc/systemd/system/NetworkManager-wait-online.service")" = "/dev/null" ]; then
  ok "masked: NetworkManager-wait-online"
else bad "masked: NetworkManager-wait-online"; fi

echo
echo "-- versions --"
printf '  node        %s\n' "$(grep -m1 -o '"version": *"[^"]*"' "$SQ/opt/node/package.json" 2>/dev/null | cut -d'"' -f4 || echo '?')"
printf '  claude-code %s\n' "$(python3 -c "import json;print(json.load(open('$SQ/opt/node/lib/node_modules/@anthropic-ai/claude-code/package.json'))['version'])" 2>/dev/null || echo '?')"
printf '  chrome      %s\n' "$(grep -m1 -a -o '[0-9]\{2,3\}\.0\.[0-9]\{4\}\.[0-9]\{1,3\}' "$SQ/opt/google/chrome/chrome" 2>/dev/null | head -1 || echo '?')"
printf '  packages    %s\n' "$(wc -l < "$MNT/casper/filesystem.manifest")"
printf '  squashfs    %s\n' "$(du -h "$MNT/casper/filesystem.squashfs" | cut -f1)"

echo
echo "=============================="
printf '  passed: %d   failed: %d\n' "$pass" "$fail"
echo "=============================="
[ "$fail" -eq 0 ]
