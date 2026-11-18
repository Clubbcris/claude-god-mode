#!/usr/bin/env bash
# Offline checks against a built ISO: structure, boot records, and the
# contents of the squashfs root.
#
#   verify-image.sh <iso> [filesystem.squashfs]
#
# Reads the image with xorriso and unsquashfs rather than loop-mounting it,
# so it needs no root and no iso9660 kernel module (CI containers lack it).
# Pass the build's work copy of filesystem.squashfs as the second argument
# to skip extracting a 2 GB file back out of the ISO.
set -uo pipefail

ISO="${1:?usage: verify-image.sh <iso> [filesystem.squashfs]}"
SQ_IN="${2:-}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; note=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
inf()  { printf '  \033[33mNOTE\033[0m %s\n' "$*"; note=$((note+1)); }
chk()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "== ISO: $(basename "$ISO") ($(du -h "$ISO" | cut -f1)) =="

# ---- ISO structure -----------------------------------------------------
xorriso -indev "$ISO" -find / 2>/dev/null | tr -d "'" | sed 's/^ *//' > "$TMP/iso-paths"
[[ -s "$TMP/iso-paths" ]] || { echo "could not read ISO with xorriso"; exit 1; }
iso_has() { grep -Fxq "$1" "$TMP/iso-paths"; }
iso_get() {
  xorriso -osirrox on -indev "$ISO" -extract "$1" "$TMP/$(basename "$1")" \
    >/dev/null 2>&1 && echo "$TMP/$(basename "$1")"
}

echo
echo "-- image structure --"
for p in /casper/vmlinuz /casper/initrd /casper/filesystem.squashfs \
         /casper/filesystem.size /casper/filesystem.manifest \
         /boot/grub/grub.cfg /boot/grub/bios.img \
         /EFI/efiboot.img /EFI/BOOT/BOOTX64.EFI /md5sum.txt; do
  chk "present: $p" "iso_has '$p'"
done
chk "medium id for grub search" "iso_has '/.disk/godmode.id'"

echo
echo "-- boot menu --"
cfg="$(iso_get /boot/grub/grub.cfg)"
if [[ -n "$cfg" ]]; then
  chk "live entry uses boot=casper"  "grep -q 'boot=casper' '$cfg'"
  chk "persistence entry present"    "grep -q 'persistent' '$cfg'"
  chk "safe-graphics entry present"  "grep -q 'nomodeset' '$cfg'"
  chk "integrity-check entry present" "grep -q 'integrity-check' '$cfg'"
else bad "could not extract grub.cfg"; fi

echo
echo "-- boot records --"
elt="$(xorriso -indev "$ISO" -report_el_torito plain 2>&1)"
chk "El Torito catalog has 2 entries" "[ \$(echo \"\$elt\" | grep -c 'El Torito boot img') -ge 2 ]"
if echo "$elt" | grep -qi 'BIOS'; then ok "El Torito BIOS entry"; else bad "El Torito BIOS entry"; fi
if echo "$elt" | grep -qi 'UEFI'; then ok "El Torito UEFI entry"; else bad "El Torito UEFI entry"; fi
# A hybrid image must carry boot code in the first sector for legacy BIOS.
mbr="$(od -An -tx1 -N4 "$ISO" | tr -d ' \n')"
if [[ -n "$mbr" && "$mbr" != "00000000" ]]; then
  ok "MBR boot code present, starts 0x${mbr:0:2} (legacy BIOS bootable)"
else bad "MBR boot code present (got '${mbr:-empty}')"; fi

echo
echo "-- secure boot --"
if iso_has /EFI/BOOT/grubx64.efi && iso_has /EFI/ubuntu/grub.cfg; then
  ok "signed shim + GRUB chain present"
  shimf="$(iso_get /EFI/BOOT/BOOTX64.EFI)"
  if [[ -n "$shimf" ]] && strings "$shimf" 2>/dev/null | grep -qi "Microsoft Corporation UEFI"; then
    ok "BOOTX64.EFI carries Microsoft's UEFI CA"
  else bad "BOOTX64.EFI does not look Microsoft-signed"; fi
  stub="$(iso_get /EFI/ubuntu/grub.cfg)"
  chk "signed-GRUB stub chains to the ISO menu" "grep -q 'configfile' '$stub'"
else
  inf "unsigned GRUB -- Secure Boot must be disabled to boot this image"
fi

# ---- squashfs contents -------------------------------------------------
if [[ -n "$SQ_IN" && -s "$SQ_IN" ]]; then
  SQ="$SQ_IN"
else
  echo
  echo "-- extracting filesystem.squashfs from the ISO (no path given) --"
  SQ="$(iso_get /casper/filesystem.squashfs)"
  [[ -n "$SQ" ]] || { echo "could not extract squashfs"; exit 1; }
fi

unsquashfs -ll "$SQ" > "$TMP/ll" 2>/dev/null || { echo "unsquashfs failed"; exit 1; }
awk '{ for (i=1;i<=NF;i++) if ($i ~ /^squashfs-root(\/|$)/) {
         p = substr($i,14); print $1 "\t" (p==""?"/":p); break } }' "$TMP/ll" > "$TMP/paths"
sq_mode() { awk -F'\t' -v p="$1" '$2==p{print $1; exit}' "$TMP/paths"; }
sq_has()  { awk -F'\t' -v p="$1" '$2==p{found=1; exit} END{exit !found}' "$TMP/paths"; }
sq_exec() { [[ "$(sq_mode "$1")" =~ ^-.*x ]]; }
sq_link() { [[ "$(sq_mode "$1")" == l* ]]; }
sq_cat()  { unsquashfs -cat "$SQ" "$1" 2>/dev/null; }

echo
echo "-- squashfs contents ($(awk 'END{print NR}' "$TMP/paths") entries) --"
CC_BIN=/opt/node/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
chk "Claude Code launcher is a symlink" "sq_link /opt/node/bin/claude"
chk "Claude Code binary executable"     "sq_exec \$CC_BIN"
chk "claude symlinked onto PATH"    "sq_link /usr/local/bin/claude"
chk "Node 22 executable"            "sq_exec /opt/node/bin/node"
chk "Google Chrome executable"      "sq_exec /opt/google/chrome/chrome"
chk "godmode command executable"    "sq_exec /usr/local/bin/godmode"
chk "godmode-tune executable"       "sq_exec /usr/local/bin/godmode-tune"
chk "godmode-welcome executable"    "sq_exec /usr/local/bin/godmode-welcome"
chk "XFCE session present"          "sq_has /usr/bin/xfce4-session"
chk "LightDM present"               "sq_has /usr/sbin/lightdm"
chk "Calamares present"             "sq_has /usr/bin/calamares"
chk "calamares settings.conf"       "sq_has /etc/calamares/settings.conf"
chk "calamares unpackfs config"     "sq_has /etc/calamares/modules/unpackfs.conf"
chk "calamares branding"            "sq_has /etc/calamares/branding/godmode/branding.desc"
chk "xfce desktop session file"     "sq_has /usr/share/xsessions/xfce.desktop"
chk "desktop entry: Claude Code"    "sq_has /usr/share/applications/godmode-claude.desktop"
chk "skel desktop shortcuts"        "sq_has /etc/skel/Desktop/godmode-claude.desktop"
chk "skel claude settings"          "sq_has /etc/skel/.claude/settings.json"

echo
echo "-- configuration content --"
chk "casper live user is godmode"   "sq_cat /etc/casper.conf | grep -q 'USERNAME=\"godmode\"'"
chk "os-release branded"            "sq_cat /usr/lib/os-release | grep -q 'GodMode OS'"
chk "swappiness tuned for zram"     "sq_cat /etc/sysctl.d/99-godmode.conf | grep -q 'vm.swappiness = 180'"
chk "zram uses zstd"                "sq_cat /etc/default/zramswap | grep -q 'ALGO=zstd'"
chk "earlyoom args unquoted"        "sq_cat /etc/default/earlyoom | grep -q 'EARLYOOM_ARGS=-r'"
chk "io scheduler udev rules"       "sq_has /etc/udev/rules.d/60-godmode-ioschedulers.rules"
chk "passwordless sudo for live user" "sq_cat /etc/sudoers.d/90-godmode | grep -q 'NOPASSWD'"
chk "lightdm autologins godmode"    "sq_cat /etc/lightdm/lightdm.conf.d/10-godmode-autologin.conf | grep -q 'autologin-user=godmode'"
chk "snapd pinned out"              "sq_cat /etc/apt/preferences.d/no-snapd | grep -q 'Pin-Priority: -10'"
chk "grub drops mitigations hint"   "sq_cat /etc/default/grub.d/99-godmode.cfg | grep -q 'mitigations=off'"

echo
echo "-- must NOT be present --"
chk "snapd not installed"            "! sq_has /usr/lib/snapd/snapd"
chk "no build-host proxy apt conf"   "! sq_has /etc/apt/apt.conf.d/01build-proxy"
chk "no build-host CA certificate"   "! sq_has /usr/local/share/ca-certificates/build-proxy.crt"
chk "no policy-rc.d left behind"     "! sq_has /usr/sbin/policy-rc.d"
chk "no diverted initctl left"       "! sq_has /sbin/initctl"

echo
echo "-- enabled services --"
for s in zramswap earlyoom tlp irqbalance NetworkManager fstrim; do
  if grep -E "\.wants/${s}" "$TMP/paths" >/dev/null 2>&1; then ok "enabled: $s"
  else bad "enabled: $s"; fi
done
chk "enabled: lightdm (display-manager)" "sq_link /etc/systemd/system/display-manager.service"
for s in NetworkManager-wait-online apport whoopsie; do
  if [[ "$(unsquashfs -ll "$SQ" "/etc/systemd/system/$s.service" 2>/dev/null | grep -o '\-> .*' | head -1)" == "-> /dev/null" ]]; then
    ok "masked: $s"
  else bad "masked: $s"; fi
done

echo
echo "-- versions --"
printf '  node          v%s\n' "$(sq_cat /opt/node/include/node/node_version.h \
  | awk '$1=="#define" && $2=="NODE_MAJOR_VERSION"{a=$3}
         $1=="#define" && $2=="NODE_MINOR_VERSION"{b=$3}
         $1=="#define" && $2=="NODE_PATCH_VERSION"{c=$3}
         END{print a"."b"."c}')"
printf '  claude-code   %s\n' "$(sq_cat /opt/node/lib/node_modules/@anthropic-ai/claude-code/package.json | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null)"
printf '  kernel        %s\n' "$(grep -oE 'vmlinuz-[0-9][^ ]*' "$TMP/paths" | head -1 | sed 's/vmlinuz-//')"
printf '  packages      %s\n' "$(xorriso -osirrox on -indev "$ISO" -extract /casper/filesystem.manifest "$TMP/man" >/dev/null 2>&1 && wc -l < "$TMP/man")"
printf '  squashfs      %s\n' "$(du -h "$SQ" | cut -f1)"

echo
echo "================================"
printf '  passed: %d   failed: %d   notes: %d\n' "$pass" "$fail" "$note"
echo "================================"
[[ "$fail" -eq 0 ]]
