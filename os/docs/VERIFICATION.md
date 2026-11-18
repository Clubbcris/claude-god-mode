# Verification

What has actually been tested, and how to reproduce it. Anything not listed
here has not been verified — see "Not verified" at the bottom.

## Reproducing

```bash
sudo ./os/build.sh                              # build the ISO
sudo ./os/test/verify-image.sh os/out/*.iso     # offline checks, no boot
sudo ./os/test/boot-test.py os/out/*.iso --mode uefi --out /tmp/bt
sudo ./os/test/boot-test.py os/out/*.iso --mode bios --out /tmp/bt
```

`verify-image.sh` loop-mounts the ISO and its squashfs and asserts on
structure, boot records, installed binaries, tuning files, enabled services,
and the absence of build-host leftovers. `boot-test.py` boots the image under
QEMU (OVMF for UEFI, SeaBIOS for legacy) and screenshots the console at
intervals; it needs no KVM and no display.

## Results

_Populated by the run recorded below._

## Not verified

- **Install to disk (Calamares).** The configuration is valid and the module
  sequence is conventional, but a real installation onto real hardware is the
  one thing a VM cannot stand in for. Treat the first install as the test.
- **Real-world Wi-Fi.** Firmware coverage depends on the specific chip. Broadcom
  parts need an out-of-tree driver that cannot be redistributed.
- **Suspend/resume and battery behaviour**, which are hardware-specific.
- **The performance claims as measured on the target laptop.** The tuning is
  well-established and each change is justified in the README, but no
  before/after benchmark has been run on an actual HP 15.
