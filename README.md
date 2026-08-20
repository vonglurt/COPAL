<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 paulr@sdf.org -- copal-alpine-linux -->
```
 ██████  ██████  ██████   █████  ██
██      ██    ██ ██   ██ ██   ██ ██
██      ██    ██ ██████  ███████ ██
██      ██    ██ ██      ██   ██ ██
 ██████  ██████  ██████  ██   ██ ███████
```

# copal-alpine-linux

**One Alpine installer, many targets — an SD card for a Raspberry Pi, a UEFI
disk for a PC, or a virtual machine under UTM on an Apple Silicon Mac.**

This is [Copal Linux](docs/copal-handbook.md) — the Raspberry Pi Zero installer
— rebuilt as a *hybrid* installer. The same fifteen stages that turn a diskless
Alpine into a persistent ext4 system with a tiling desktop now run on whichever
of those three media you point them at, and the two UTM targets exist so that
the other three can be verified without a card, a Pi, or a reboot cycle.

**Copal** is tree resin caught halfway to amber — sap that has hardened, but is
not yet stone. That is this system's whole trick. Alpine boots *diskless*: the
root filesystem is a tmpfs that evaporates at power-off. Copal is what sets it,
without giving up any of the smallness that made it worth booting.

Copal is an *aggregation* of Alpine — it downloads stock Alpine and calls
Alpine's own tools — **not** a derivative work of it, and not a fork. It is not
affiliated with or endorsed by the Alpine project. *(The resemblance to the name
of Alpine's founder, Natanael **Copa**, is a genuine accident — noticed after the
fact and kept because it was too good to throw away.)*

---

## The idea

The original Copal wrote SD cards from a Mac. That worked, but every change to
an 11,720-line installer cost a card write, a power cycle and a walk to the Pi,
and a mistake showed up as the firmware's rainbow test pattern with no
diagnosis attached. There is no debugger at that end of the wire.

A virtual machine removes all of that, but only if it runs *the same code*. So
the VM targets here are not a separate porting effort — they are the existing
targets, pointed at a different medium:

- **`utm-aarch64`** boots the same aarch64 Alpine payload, the same GRUB
  configuration and the same `copal-init.sh` that a **Pi Zero 2 W, Pi 3, 4 or 5**
  boots. Under HVF on Apple Silicon it runs at native speed.
- **`utm-x86_64`** does the same for the **PC / laptop / Intel Mac** path. On an
  Apple Silicon host this is QEMU TCG emulation rather than virtualisation, so
  it is slow — but it is the *real* x86_64 code path, and slow is a great deal
  faster than finding a spare PC.

What that buys is a regression test. Change the installer, boot both VMs
headless, and see whether they still reach a login prompt — in about a minute,
with a serial log to read when they do not.

## Targets

A target is the pair *(what medium it is written to, what loads the kernel)*.
That second half is the only real difference between a Pi and everything else:
on a Pi the GPU firmware **is** the bootloader and reads the kernel off a FAT
partition unaided, so writing a card is genuinely just a file copy. Everywhere
else something has to load the kernel, which here means GRUB on an EFI system
partition.

| Target | Arch | Medium | Loads the kernel | Role |
|---|---|---|---|---|
| `rpi-zero` | armhf | SD card | GPU firmware | Pi Zero 1, Zero W, Pi 1, CM1 |
| `rpi-zero2` | aarch64 | SD card | GPU firmware | Pi Zero 2 W, Pi 3, CM3 |
| `rpi-pi4`, `rpi-pi5` | aarch64 | SD card | GPU firmware | Pi 4, 400, CM4, Pi 5 |
| `rpi-pi2b` | armv7 | SD card | GPU firmware | Pi 2 B v1.1 |
| `pc` | x86_64 | card, USB or `.img` | GRUB + UEFI | Any PC since ~2012, Intel Mac |
| `pc32` | x86 | card, USB or `.img` | GRUB + UEFI | 32-bit UEFI machines |
| **`utm-aarch64`** | aarch64 | `.utm` bundle | GRUB + edk2 | **Verifies the ARM path** |
| **`utm-x86_64`** | x86_64 | `.utm` bundle | GRUB + OVMF | **Verifies the PC path** |

Getting the architecture wrong is not a degraded system, it is a machine that
stops dead — so the target is chosen explicitly and the installer refuses a
payload whose kernel config disagrees with it.

**UEFI only, on everything that is not a Pi.** This is a limit of the writing
machine, not a preference: a legacy-BIOS boot needs `syslinux` or
`grub-install` to write a boot sector, and both are Linux tools that do not
exist on macOS. UEFI needs no installer at all — the firmware reads a FAT
partition and executes `\EFI\BOOT\BOOTX64.EFI`, which is a file copy. So Copal
supports UEFI and says so plainly rather than writing a card that will not boot.

## Networking

Every target gets NAT. On a Pi that is whatever the wireless network hands out;
under UTM it is UTM's **Shared Network** mode, which is NAT with a built-in
DHCP server and DNS forwarder on a private subnet. The guest reaches the
internet and the Alpine mirrors; the host is reachable at the gateway address;
nothing on the LAN can reach the guest unless a port is forwarded.

That last part matters for the install itself. A forwarded port means the
fifteen stages can be driven over SSH from the host, with real output and real
scrollback, instead of through a VM console window.

## Status

This is a migration in progress, and the table says where it actually stands
rather than where it is going.

| Piece | State |
|---|---|
| Pi targets (`armhf`, `armv7`, `aarch64`) | **Working** — inherited unchanged from Copal |
| PC targets (`x86_64`, `x86`) | **Working** — inherited unchanged from Copal |
| `MODEL=vm` aarch64 image for QEMU/UTM | **Working** — inherited; boots under `copal-vm.sh` |
| `utm-aarch64` as a registered UTM VM | Not yet built |
| `utm-x86_64` as a target at all | Not yet built — `MODEL=vm` implies aarch64, and the VM GRUB config hardcodes `console=ttyAMA0`, which is the ARM PL011 and does not exist on x86 |
| Desktop (stage 4) under virtio-gpu | Not yet verified — stage 4 installs `xf86-video-fbdev`, chosen for the Pi's VideoCore |
| Split of `copal-prep.sh` into `lib/` + a real `guest/copal-init.sh` | Not yet done |

Today `copal-init.sh` is a 9,600-line quoted heredoc inside `copal-prep.sh`.
Making it a real file is the single most valuable structural change available —
it becomes editable, `shellcheck`-able and testable — but it is a refactor of
working code, so it happens *after* the two VMs can prove a refactor did not
break anything.

## Quick start

Requires macOS, `curl`, `bsdtar` and `shasum` (all stock), plus
[UTM](https://mac.getutm.app) for the VM targets.

```sh
# A card for a Pi
MODEL=zero2 ./copal-prep.sh

# A PC / Intel Mac, 64-bit UEFI
MODEL=pc ./copal-prep.sh

# A disk image instead of a card -- nothing physical is touched
MODEL=vm ./copal-prep.sh --image copal-vm.img
./copal-vm.sh --graphical
```

Then, on the target, as root:

```sh
sh /media/mmcblk0p1/copal-init.sh     # the menu: fifteen optional stages
copal --auto                          # or run all of them unattended
```

The full account of what those stages do — the catalogue, the desktop, the key
bindings, the account model, the SD-card wear analysis — is in
**[the handbook](docs/copal-handbook.md)**.

## What is where

| Path | What it is |
|---|---|
| `copal-prep.sh` | Runs on the **Mac**. Downloads and verifies Alpine, prepares the medium, generates everything the target needs |
| `copal-vm.sh` | Boots a prepared image under QEMU. `--check` boots it headless and reports a verdict |
| `Makefile` | `make image`, `make vm`, `make check`, `make lint` |
| `fetch-minivmac.sh` | Assembles the Mini vMac working set on demand — nothing binary is tracked here |
| `tools/minivmac/` | Mini vMac launcher scripts |
| `docs/copal-handbook.md` | The original Copal handbook. Alpine, the card, the stages, the desktop, reference |
| `docs/lab-report.md` | Bring-up record for the Pi Zero 1 and Zero 2 W, IEEE format |
| `docs/development-report.md` | Architecture, verification method and results, known defects |

## Repository policy

**No binaries are tracked, ever.** The Alpine payload is downloaded and
SHA256-verified by `copal-prep.sh`; GRUB is extracted from a verified
`alpine-virt-*.iso`; the Mini vMac ROM and disk images are fetched by
`fetch-minivmac.sh` or by stage 9 on the target.

The original repository vendored all of it deliberately, so that a card could be
written with no network at all. That arrangement could not be published:
`macOS755.dsk.zip` was 894 MB — past GitHub's 100 MB per-file limit — and the
Macintosh Plus ROM and Mac OS disk images beside it are copyrighted Apple
material that is not redistributable. So `copal-alpine-linux` starts fresh, with
no history and no blobs. The archive, binaries and history intact, stays at
`~/code/arm-pi-zero` and is not published.

## License

MIT — see [`LICENSE`](LICENSE). The scope matters here: third-party material
that the installer *downloads* is not covered by it, and some of it is not
redistributable at all.
