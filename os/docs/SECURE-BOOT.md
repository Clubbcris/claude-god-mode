# Secure Boot

Most HP consumer laptops ship with Secure Boot enabled. Secure Boot only runs
bootloaders signed by a key the firmware trusts — in practice, Microsoft's.
An unsigned bootloader does not produce a warning; the firmware skips the
device, and you get "no bootable device found".

## What this build does

`lib/20-image.sh` picks one of two UEFI boot paths automatically, depending on
what it finds in the built rootfs:

1. **Secure Boot capable** (preferred). If Ubuntu's Microsoft-signed
   `shimx64.efi.signed` and `grubx64.efi.signed` are present — they come from the
   `shim-signed` and `grub-efi-amd64-signed` packages in `config/packages.base` —
   they are used as the boot chain:

   ```
   firmware -> shim (signed by Microsoft) -> GRUB (signed by Canonical)
            -> /EFI/ubuntu/grub.cfg -> the ISO's /boot/grub/grub.cfg
   ```

   Ubuntu's signed GRUB is compiled with a fixed prefix of `/EFI/ubuntu`, which
   is why a small stub config has to live at that exact path inside the EFI
   partition. The stub locates the ISO by searching for `/.disk/godmode.id` and
   hands control to the real boot menu.

2. **Unsigned fallback.** If the signed binaries are missing, the build falls
   back to `grub-mkstandalone`. This image is perfectly bootable, but **only with
   Secure Boot disabled.**

Which path was taken is recorded in `<work>/.secureboot` (`1` or `0`) and printed
during the build.

## Checking an ISO you already have

```bash
sudo mount -o loop,ro godmode-os-0.1-amd64.iso /mnt
ls /mnt/EFI/BOOT/        # grubx64.efi present => signed chain
ls /mnt/EFI/ubuntu/      # grub.cfg present    => signed chain
```

Or look at `BOOTX64.EFI` itself — the signed shim contains Microsoft's
certificate name:

```bash
strings /mnt/EFI/BOOT/BOOTX64.EFI | grep -i "Microsoft Corporation UEFI"
```

## Important limitation

Even on the signed path, Secure Boot verifies **the bootloader and kernel**, not
this distribution as a whole. Canonical's signed GRUB will load Ubuntu's signed
kernel, which is what this image ships. But if you ever build a custom kernel or
load unsigned out-of-tree kernel modules (for example the Broadcom Wi-Fi driver,
`bcmwl-kernel-source`), those modules will be refused while Secure Boot is on.

If Wi-Fi needs an out-of-tree driver on your machine, disabling Secure Boot is
the simpler path:

- Power off, tap <kbd>Esc</kbd> at power-on, choose **F10 — BIOS Setup**
- **Security → Secure Boot → Disabled** (you may need to confirm with a 4-digit code)
- <kbd>F10</kbd> to save and exit
