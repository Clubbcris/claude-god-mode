#!/usr/bin/env python3
"""Boot a GodMode OS ISO under QEMU and capture screenshots.

No KVM required (falls back to TCG, which is slow but faithful enough to
prove the bootloader and the live session come up).

  ./boot-test.py ISO --mode uefi --shots 25,70,240,420,600 --out DIR
"""
import argparse, json, os, shutil, signal, socket, struct, subprocess
import sys, time, zlib

# "uefi" boots plain UEFI. "uefi-secureboot" uses the Secure Boot enforcing
# firmware with Microsoft's keys already enrolled, which is how a retail
# laptop ships -- so it proves the image boots without touching BIOS.
FIRMWARE = {
    "uefi": ("/usr/share/OVMF/OVMF_CODE_4M.fd",
             "/usr/share/OVMF/OVMF_VARS_4M.fd"),
    "uefi-secureboot": ("/usr/share/OVMF/OVMF_CODE_4M.secboot.fd",
                        "/usr/share/OVMF/OVMF_VARS_4M.ms.fd"),
}


class Qmp:
    def __init__(self, path, timeout=120):
        deadline = time.time() + timeout
        while True:
            try:
                self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.s.connect(path)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.3)
        self.f = self.s.makefile("rwb")
        self._read()                      # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise EOFError("qmp closed")
            msg = json.loads(line)
            if "event" in msg:            # ignore async events
                continue
            return msg

    def cmd(self, name, **args):
        self.f.write(json.dumps({"execute": name, "arguments": args}).encode() + b"\n")
        self.f.flush()
        return self._read()


def ppm_to_png(src, dst):
    """Minimal P6 PPM -> PNG, stdlib only."""
    data = open(src, "rb").read()
    if not data.startswith(b"P6"):
        return False
    fields, pos = [], 2
    while len(fields) < 3:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            while data[pos:pos + 1] != b"\n":
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1
    w, h, _maxv = fields
    px = data[pos:pos + w * h * 3]
    raw = b"".join(b"\x00" + px[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload +
                struct.pack(">I", zlib.crc32(tag + payload) & 0xffffffff))

    png = (b"\x89PNG\r\n\x1a\n" +
           chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
           chunk(b"IDAT", zlib.compress(raw, 6)) +
           chunk(b"IEND", b""))
    open(dst, "wb").write(png)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("iso")
    ap.add_argument("--mode", choices=["uefi", "uefi-secureboot", "bios"],
                    default="uefi")
    ap.add_argument("--shots", default="25,70,240,420,600",
                    help="seconds after launch at which to screenshot")
    ap.add_argument("--out", default="boot-test-out")
    ap.add_argument("--mem", default="4096")
    ap.add_argument("--smp", default="4")
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    mon = os.path.join(out, f"qmp-{args.mode}.sock")
    serial = os.path.join(out, f"serial-{args.mode}.log")
    for p in (mon, serial):
        if os.path.exists(p):
            os.remove(p)

    machine = "q35,smm=on" if args.mode == "uefi-secureboot" else "q35"
    cmd = [
        "qemu-system-x86_64",
        "-machine", machine,
        "-m", args.mem, "-smp", args.smp,
        "-cdrom", args.iso, "-boot", "d",
        "-vga", "std",
        "-display", "none",
        "-serial", f"file:{serial}",
        "-qmp", f"unix:{mon},server,nowait",
        "-rtc", "base=utc",
        "-no-reboot",
    ]
    if args.mode in FIRMWARE:
        code, varsrc = FIRMWARE[args.mode]
        vars_copy = os.path.join(out, f"OVMF_VARS-{args.mode}.fd")
        shutil.copy(varsrc, vars_copy)
        cmd += [
            "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={code}",
            "-drive", f"if=pflash,format=raw,unit=1,file={vars_copy}",
        ]
        if args.mode == "uefi-secureboot":
            cmd += ["-global", "driver=cfi.pflash01,property=secure,value=on",
                    "-global", "ICH9-LPC.disable_s3=1"]

    print(f"[boot-test] mode={args.mode}  (TCG: no /dev/kvm)" if not os.path.exists("/dev/kvm")
          else f"[boot-test] mode={args.mode} (kvm)")
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    captured = []
    try:
        qmp = Qmp(mon)
        shots = sorted(int(s) for s in args.shots.split(","))
        t0 = time.time()
        for when in shots:
            delay = when - (time.time() - t0)
            if delay > 0:
                time.sleep(delay)
            if proc.poll() is not None:
                print(f"[boot-test] qemu exited early (rc={proc.returncode})")
                break
            ppm = os.path.join(out, f"{args.mode}-{when:04d}s.ppm")
            png = os.path.join(out, f"{args.mode}-{when:04d}s.png")
            r = qmp.cmd("screendump", filename=ppm)
            if "error" in r:
                print(f"[boot-test] screendump failed: {r['error']}")
                continue
            # QEMU writes the file asynchronously on some versions.
            for _ in range(40):
                if os.path.exists(ppm) and os.path.getsize(ppm) > 1024:
                    break
                time.sleep(0.25)
            if ppm_to_png(ppm, png):
                os.remove(ppm)
                captured.append(png)
                print(f"[boot-test] t={when:>4}s  {os.path.basename(png)}"
                      f"  ({os.path.getsize(png)//1024} KiB)")
            else:
                print(f"[boot-test] t={when:>4}s  could not decode screendump")
    finally:
        if proc.poll() is None:
            # Only ever signal the PID we spawned ourselves.
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                proc.kill()
        if os.path.exists(mon):
            os.remove(mon)

    if os.path.exists(serial) and os.path.getsize(serial):
        print(f"[boot-test] serial log: {serial} ({os.path.getsize(serial)} bytes)")
    print(f"[boot-test] captured {len(captured)} screenshot(s) in {out}")
    return 0 if captured else 1


if __name__ == "__main__":
    sys.exit(main())
