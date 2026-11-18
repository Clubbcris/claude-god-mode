# Stage 3: squash the rootfs and assemble a hybrid bootable ISO.

SQUASH_LEVEL="${SQUASH_LEVEL:-15}"

stage_image() {
  local iso="${OUT}/${OS_ID}-os-${OS_VERSION}-${ARCH}.iso"
  log "Preparing ISO tree"
  rm -rf "$ISODIR"
  mkdir -p "${ISODIR}/casper" "${ISODIR}/boot/grub" "${ISODIR}/EFI/BOOT" "${ISODIR}/.disk"

  log "Copying kernel and initramfs"
  cp "$(ls -1 "${ROOT}"/boot/vmlinuz-* | sort -V | tail -1)" "${ISODIR}/casper/vmlinuz"
  cp "$(ls -1 "${ROOT}"/boot/initrd.img-* | sort -V | tail -1)" "${ISODIR}/casper/initrd"

  log "Writing package manifest"
  chroot "$ROOT" dpkg-query -W --showformat='${Package} ${Version}\n' \
    > "${ISODIR}/casper/filesystem.manifest"
  cp "${ISODIR}/casper/filesystem.manifest" "${ISODIR}/casper/filesystem.manifest-desktop"
  # Packages that exist only to run the live session / installer.
  printf '%s\n' casper calamares calamares-settings-ubuntu-common discover \
    > "${ISODIR}/casper/filesystem.manifest-remove"

  du -sx --block-size=1 "$ROOT" | cut -f1 > "${ISODIR}/casper/filesystem.size"
  local sq="${WORK}/filesystem.squashfs"
  if [[ "${REUSE_SQUASHFS:-0}" == "1" && -s "$sq" ]]; then
    log "Reusing previously built squashfs (REUSE_SQUASHFS=1)"
  else
    log "Compressing root filesystem (zstd level ${SQUASH_LEVEL}) -- several minutes"
    rm -f "$sq"
    mksquashfs "$ROOT" "$sq" \
      -comp zstd -Xcompression-level "$SQUASH_LEVEL" -b 1M \
      -noappend -no-progress \
      -e boot/grub
  fi
  # Hardlink rather than copy; these are 1.5 GB+ and share a filesystem.
  rm -f "${ISODIR}/casper/filesystem.squashfs"
  ln "$sq" "${ISODIR}/casper/filesystem.squashfs" 2>/dev/null \
    || cp -f "$sq" "${ISODIR}/casper/filesystem.squashfs"

  log "Writing disk metadata"
  echo "${OS_NAME} ${OS_VERSION} (${ARCH})" > "${ISODIR}/.disk/info"
  : > "${ISODIR}/.disk/base_installable"
  echo "full_cd/single" > "${ISODIR}/.disk/cd_type"
  # grub searches for this file to locate the boot medium.
  echo "${OS_ID}-${OS_VERSION}" > "${ISODIR}/.disk/${OS_ID}.id"

  write_grub_cfg
  build_bios_image
  build_efi_image

  log "Writing md5sum.txt"
  ( cd "$ISODIR" && find . -type f \
      -not -path './md5sum.txt' \
      -not -path './boot/grub/boot.cat' \
      -not -path './EFI/efiboot.img' \
      -print0 | sort -z | xargs -0 md5sum > md5sum.txt )

  log "Building ISO with xorriso"
  rm -f "$iso"
  xorriso -as mkisofs \
    -iso-level 3 -rock -joliet -full-iso9660-filenames \
    -volid "GODMODE_OS" \
    -appid "${OS_NAME} ${OS_VERSION}" \
    -publisher "clubbcris/claude-god-mode" \
    -eltorito-boot boot/grub/bios.img \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      --eltorito-catalog boot/grub/boot.cat \
      --grub2-boot-info --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
    -eltorito-alt-boot \
      -e EFI/efiboot.img -no-emul-boot \
      -isohybrid-gpt-basdat \
    -output "$iso" \
    "$ISODIR"

  ( cd "$OUT" && sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256" )
}

write_grub_cfg() {
  log "Writing boot menu"
  cat > "${ISODIR}/boot/grub/grub.cfg" <<GRUB
set default=0
set timeout=10
set timeout_style=menu

insmod all_video
insmod gfxterm
terminal_output gfxterm

menuentry "Try ${OS_NAME} (live)" {
    linux  /casper/vmlinuz boot=casper quiet splash nowatchdog ---
    initrd /casper/initrd
}

menuentry "Try ${OS_NAME} with persistence (saves your files)" {
    linux  /casper/vmlinuz boot=casper persistent quiet splash nowatchdog ---
    initrd /casper/initrd
}

menuentry "Try ${OS_NAME} (safe graphics)" {
    linux  /casper/vmlinuz boot=casper nomodeset quiet splash ---
    initrd /casper/initrd
}

menuentry "Try ${OS_NAME} (verbose, for debugging)" {
    linux  /casper/vmlinuz boot=casper ---
    initrd /casper/initrd
}

menuentry "Check this medium for defects" {
    linux  /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}
GRUB

  # Embedded in the standalone grub binaries: find the medium, then hand
  # over to the menu above.
  cat > "${WORK}/grub-early.cfg" <<EARLY
search --no-floppy --set=root --file /.disk/${OS_ID}.id
if [ -z "\$root" ]; then set root=(cd0); fi
set prefix=(\$root)/boot/grub
configfile (\$root)/boot/grub/grub.cfg
EARLY
}

build_bios_image() {
  log "Building legacy BIOS boot image"
  # "search" is only a dispatcher; without search_fs_file compiled in, the
  # early config cannot find the medium and GRUB drops to a bare prompt
  # instead of showing the menu. The UEFI path does not hit this because it
  # uses Ubuntu's signed GRUB, which already carries a full module set.
  local mods="normal linux linux16 iso9660 biosdisk part_gpt part_msdos \
search search_fs_file search_fs_uuid search_label configfile echo test \
all_video gfxterm videoinfo minicmd loadenv halt reboot ls cat"
  grub-mkstandalone \
    --format=i386-pc \
    --output="${WORK}/core.img" \
    --install-modules="$mods tar memdisk" \
    --modules="$mods" \
    --locales="" --fonts="" \
    "boot/grub/grub.cfg=${WORK}/grub-early.cfg"
  cat /usr/lib/grub/i386-pc/cdboot.img "${WORK}/core.img" > "${ISODIR}/boot/grub/bios.img"
}

# Resolve a path inside the rootfs (following symlinks relative to it) and
# echo the host-visible path, or nothing if it does not exist.
resolve_in_root() {
  local target
  target="$(chroot "$ROOT" readlink -f "$1" 2>/dev/null || true)"
  [[ -n "$target" && -f "${ROOT}${target}" ]] && { echo "${ROOT}${target}"; return 0; }
  [[ -f "${ROOT}$1" ]] && { echo "${ROOT}$1"; return 0; }
  return 0
}

build_efi_image() {
  local img="${ISODIR}/EFI/efiboot.img"
  local shim grubsigned secureboot=0
  # shimx64.efi.signed is an alternatives symlink to an absolute path that
  # only resolves *inside* the rootfs, so resolve it there rather than
  # letting a host-side cp follow it to nowhere.
  shim="$(resolve_in_root /usr/lib/shim/shimx64.efi.signed)"
  [[ -n "$shim" ]] || shim="$(resolve_in_root /usr/lib/shim/shimx64.efi.signed.latest)"
  grubsigned="$(resolve_in_root /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed)"

  if [[ -n "$shim" && -n "$grubsigned" ]]; then
    log "Building UEFI boot image (Secure Boot capable: shim + signed GRUB)"
    secureboot=1
    cp -f "$shim"       "${ISODIR}/EFI/BOOT/BOOTX64.EFI"
    cp -f "$grubsigned" "${ISODIR}/EFI/BOOT/grubx64.efi"
    # Ubuntu's signed GRUB is built with a fixed prefix of /EFI/ubuntu, so
    # its first config has to sit there on the EFI partition itself.
    mkdir -p "${ISODIR}/EFI/ubuntu"
    cp -f "${WORK}/grub-early.cfg" "${ISODIR}/EFI/ubuntu/grub.cfg"
  else
    log "Building UEFI boot image (unsigned standalone GRUB -- Secure Boot must be disabled)"
    grub-mkstandalone \
      --format=x86_64-efi \
      --output="${ISODIR}/EFI/BOOT/BOOTX64.EFI" \
      --locales="" --fonts="" \
      "boot/grub/grub.cfg=${WORK}/grub-early.cfg"
  fi

  # A FAT El Torito image is what UEFI firmware actually boots from.
  rm -f "$img"
  dd if=/dev/zero of="$img" bs=1M count=24 status=none
  mkfs.vfat -F 16 -n GODMODEEFI "$img" >/dev/null
  mmd   -i "$img" ::/EFI ::/EFI/BOOT
  mcopy -i "$img" "${ISODIR}/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
  if [[ $secureboot -eq 1 ]]; then
    mcopy -i "$img" "${ISODIR}/EFI/BOOT/grubx64.efi" ::/EFI/BOOT/grubx64.efi
    mmd   -i "$img" ::/EFI/ubuntu
    mcopy -i "$img" "${ISODIR}/EFI/ubuntu/grub.cfg" ::/EFI/ubuntu/grub.cfg
  fi
  echo "$secureboot" > "${WORK}/.secureboot"
}
