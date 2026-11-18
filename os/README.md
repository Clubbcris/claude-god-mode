# GodMode OS

A bootable Linux distribution with **Claude Code, Google Chrome and Node 22 already
installed**, tuned to run fast on modest laptops.

It boots from a USB stick on bare metal — there is no host operating system
underneath it, and nothing is virtualised. Your existing drive is not touched
unless you explicitly choose to install.

To be straight about what this is: it is a **custom Ubuntu 24.04 LTS distribution**,
not a kernel written from scratch. That is deliberate. Writing a new kernel would
mean no Wi-Fi driver, no GPU support and no browser — strictly worse than Linux at
everything. What makes this *your* OS is the layer on top: the preinstalled agent
toolchain, the access model, the tuning, and the fact that you build the image
yourself from this repo.

---

## What's inside

| | |
|---|---|
| Base | Ubuntu 24.04 LTS (`noble`), kernel 6.8 |
| Desktop | XFCE 4.18 + LightDM, autologin |
| Agent | Claude Code (latest from npm) on Node 22 |
| Browser | Google Chrome (stable, real Chrome — not Chromium) |
| Dev tools | git, build-essential, Python 3, ripgrep, fd, jq, tmux, htop |
| Installer | Calamares (optional install to disk) |
| Notably absent | **snapd** — it is pinned out entirely |

---

## Getting the ISO

**Option A — let GitHub build it for you (no Linux machine needed).**
Go to the repo's **Actions** tab → *Build GodMode OS ISO* → **Run workflow**.
About 25 minutes later, download `godmode-os-iso` from that run's artifacts.

> GitHub only offers the **Run workflow** button for workflows that exist on
> the repository's **default branch**. Until this lands on `main`, the button
> will not appear. Merge it first, or use Option B.

**Option B — build it yourself** on any Linux box with ~15 GB free:

```bash
sudo apt-get install -y debootstrap squashfs-tools xorriso mtools dosfstools \
                        grub-pc-bin grub-efi-amd64-bin grub2-common
sudo ./os/build.sh
```

The ISO lands in `os/out/` with a `.sha256` beside it.

---

## Writing it to a USB stick

You need a stick of **4 GB or more**. Everything on it will be erased.

On Windows, use [Rufus](https://rufus.ie): select the ISO, leave the defaults
(`GPT` / `UEFI`), click Start. If Rufus offers "ISO mode" vs "DD mode", either
works — this is a hybrid image.

On macOS or Linux:

```bash
sudo dd if=godmode-os-0.1-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Be certain about `/dev/sdX`. Writing to the wrong device destroys that disk.

---

## Booting it on an HP 15

**Boot it:** power off, insert the stick, tap <kbd>Esc</kbd> at power-on, choose
**F9 — Boot Device Options**, and pick your USB stick.

At the GRUB menu, take the first entry. If the screen stays black or garbled,
reboot and choose **safe graphics**.

### Secure Boot

You should not need to disable it. The image boots through Ubuntu's
Microsoft-signed shim and Canonical-signed GRUB, and this was tested against
firmware with Microsoft's keys enrolled and Secure Boot enforcing — see
[VERIFICATION.md](docs/VERIFICATION.md).

If your machine still refuses the stick ("no bootable device"), disable it:

- Power off. Press the power button, then tap <kbd>Esc</kbd> repeatedly.
- Choose **F10 — BIOS Setup**.
- **Security** → **Secure Boot** → *Disabled*. (Some models bury this under
  *Boot Options*. You may be asked to type a 4-digit code to confirm.)
- <kbd>F10</kbd> to save and exit.

You will also need Secure Boot off if your Wi-Fi turns out to need the
out-of-tree Broadcom driver, since unsigned kernel modules are refused while it
is on. See [SECURE-BOOT.md](docs/SECURE-BOOT.md).

### Turn off Windows Fast Startup

If Windows is still installed: *Control Panel → Power Options → Choose what the
power buttons do → Change settings that are currently unavailable →* untick
*Turn on fast startup*. Fast Startup leaves the disk in a hibernated state that
Linux cannot safely read.

## First steps once it boots

You are logged in automatically as `godmode`, with passwordless `sudo`.

| Command | What it does |
|---|---|
| `claude` | Claude Code, normal mode — asks before it acts |
| `godmode` | Claude Code with **every permission prompt bypassed** |
| `godmode-tune` | Shows what the performance tuning is actually doing |
| `google-chrome` | Browser |

Claude Code needs to sign in once: run `claude` and follow the browser prompt.

### About `godmode`

`godmode` runs `claude --dangerously-skip-permissions`. It will not ask before
editing files, deleting things, installing packages or running shell commands,
and it has passwordless sudo. That is the point, and it is genuinely useful — it
is also how people lose work. It asks you to confirm once, the first time, then
never again.

Two habits make it safe: keep your work in git and committed, and run it on this
machine rather than on anything you cannot rebuild.

---

## Saving your work across reboots

A live USB is amnesiac by default — reboot and everything is gone, including
your Claude Code login.

Pick **"Try GodMode OS with persistence"** at the boot menu, and give the stick
somewhere to save to. On a second Linux machine, or from the live session itself
on a *different* stick:

```bash
# Create a 4 GB persistence file on the USB stick's partition.
sudo dd if=/dev/zero of=/media/<stick>/casper-rw bs=1M count=4096
sudo mkfs.ext4 -F -L casper-rw /media/<stick>/casper-rw
```

Alternatively add a second partition labelled `casper-rw` to the stick. Casper
looks for either.

For day-to-day use, installing to disk is a far better experience than
persistence on a USB stick.

---

## Installing to the hard drive

Double-click **Install GodMode OS** on the desktop.

This **erases the drive you point it at**, Windows and all your files included.
Back up first, and be aware that if the machine uses BitLocker you will need your
recovery key to ever read that data again.

The installer removes the live-session bits (autologin as `godmode`, the
passwordless sudo rule, the installer itself) and sets up your own account.
The installed system shows a normal login screen; your account is in `sudo`,
so `sudo` asks for your password as usual. `godmode` still works — it skips
Claude Code's prompts, not the system's.

---

## What was tuned, and why

"Faster" on a machine like this is mostly about memory pressure and I/O, not CPU.

| Change | Why |
|---|---|
| **No snapd** | Snap-packaged apps cold-start in seconds rather than milliseconds. Pinned out, so apt refuses to reinstall it. |
| **zram, 60% of RAM, zstd** | Compressed swap in RAM. On an 8 GB machine this behaves like ~12-14 GB. The single biggest win on a 4-8 GB laptop. |
| **`vm.swappiness=180`** | Correct for zram, where swapping is cheap. The default 60 assumes a slow disk. |
| **earlyoom** | Kills the worst memory hog *before* the kernel OOM killer locks the desktop up for minutes. Prefers Chrome tabs; never the session. |
| **`vfs_cache_pressure=50`** | Keeps directory metadata cached, so repeated `git status` / `ripgrep` runs stay fast. |
| **Per-device I/O schedulers** | `none` for NVMe, `mq-deadline` for SSD/eMMC, `bfq` for spinning disks. One global default is wrong for at least one of them. |
| **`NetworkManager-wait-online` masked** | Routinely adds 15-30s to boot and nothing here needs it. |
| **apport / whoopsie off** | Crash reporting that uploads to Canonical; pure overhead. |
| **TLP + thermald** | Battery life and thermal behaviour, which on these chassis means staying off the thermal ceiling. |
| **XFCE, not GNOME** | GNOME's shell alone wants more RAM than XFCE's whole session. |
| **`inotify` watches to 512k** | The default 8192 is exhausted by editors and agents watching file trees. |

Run `godmode-tune` to see all of it live, including `systemd-analyze blame`.

CPU vulnerability mitigations are left **on**. Turning them off is worth a real
5-15% on older Intel chips; if you want that trade, uncomment the `mitigations=off`
line in `/etc/default/grub.d/99-godmode.cfg` and run `sudo update-grub`.

---

## Honest status

**Verified** (details and screenshots in [VERIFICATION.md](docs/VERIFICATION.md)):

- The ISO builds from these scripts, and 65/65 offline image checks pass.
- It boots to the XFCE desktop under QEMU **with Secure Boot enforcing and
  Microsoft's keys enrolled**, autologging in as `godmode`.
- Claude Code 2.1.327, Node v22.23.5 and Google Chrome 158 were each executed
  from the built image, not merely found on disk.
- No build-host state (proxy config, private CA, `policy-rc.d`) survives into
  the image, and snapd is absent and pinned out.

**Configured but not fully exercised:**

- **Install to disk (Calamares).** The configs parse inside the image and the
  module sequence is conventional, but a real install onto real hardware is the
  one thing a VM cannot stand in for. Treat your first install as the test, and
  keep a backup.
- **Wi-Fi on your specific machine.** Broadcom chips, common in some HP 15
  models, need a driver that cannot be redistributed. If Wi-Fi is missing, use
  Ethernet or USB-tether a phone, then `sudo apt install bcmwl-kernel-source`.
- **Suspend/resume and battery life**, which are hardware-specific.
- **The performance claims, measured on your laptop.** Every change below is
  justified and well-established, but no before/after benchmark has been run on
  an actual HP 15. `godmode-tune` will show you what is active.

## A note on redistribution

The build downloads Google Chrome from Google at build time. Chrome is proprietary
and its terms do not allow you to redistribute the ISO publicly with Chrome inside
it. Building it for your own machines is fine. If you want a publicly shareable
image, swap Chrome for Chromium in `config/packages.base`.
