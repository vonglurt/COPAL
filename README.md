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

Every target gets NAT. On a Pi that is whatever the network hands out. Under
UTM there are two NATs to choose between, and the difference matters more than
the names suggest — established by reading the QEMU command line UTM actually
builds, not from its documentation:

| `--net` | UTM `Mode` | QEMU backend | Guest address | Reachable from host | ICMP |
|---|---|---|---|---|---|
| `shared` *(default)* | `Shared` | `vmnet-shared` | `192.168.64.x` by DHCP | **directly, at its own IP** | yes |
| `emulated` | `Emulated` | `user` (slirp) | private to the guest | only via a forwarded port | dropped |

`vmnet-shared` is Apple's own framework. The guest gets a real DHCP lease that
macOS records in `/var/db/dhcpd_leases`, and the host reaches it directly — so
there is nothing to forward. `ping` works, which makes it a usable connectivity
test. It is also considerably faster than slirp.

**Host port forwarding only works in `Emulated` mode.** UTM accepts a
`PortForward` entry in `Shared` mode and silently ignores it — no `hostfwd`
appears on the command line — so a config that sets one there is lying about
what it does. `utm-vm.sh` therefore emits `PortForward` only for
`--net emulated`, and provides `utm-vm.sh ip`, which resolves the guest's real
address by matching its MAC against the lease file:

```sh
utm/utm-vm.sh ip --target aarch64     # -> 192.168.64.7
ssh root@192.168.64.7
```

Either way the point is the same: once the guest is on the network, the fifteen
stages can be driven over SSH with real output and real scrollback instead of
through a VM console window.

**The guest has no address until stage 1.** Alpine's diskless boot leaves
`eth0` down; `setup-alpine` is what configures it. That is expected, not a
fault. To test connectivity before stage 1, from the guest console:

```sh
ip link set eth0 up && udhcpc -i eth0 && ping -c3 dl-cdn.alpinelinux.org
```

## Who the machine is for

`copal-prep.sh` asks for the admin username immediately before the download —
the last quiet moment before it either transfers several hundred megabytes or
erases something. It is a question rather than a default because the answer
lands in `USEROPTS`, `copal.conf`, the `doas` rule, the home directory path and
the SSH policy, and changing it afterwards means re-running stage 1 on the
target.

- Press Enter and it stays **`user`**, exactly as before.
- `CFG_USER=alice` in the environment skips the question — which is what the
  Makefile's unattended targets and any scripted caller should use.
- Non-interactive runs never block; the prompt is guarded on a tty.

The git identity is offered the same way. It is read from *this Mac's* git
config and proposed as the default the target will suggest in stage 1 — but it
is now shown and confirmed rather than baked in silently, and declining leaves
it empty so the target asks instead. Whoever writes the card is usually, but
not always, whoever will commit from the machine it boots.

## Consoles

Every UTM target gets **both** a graphical display and a serial console, on
purpose. The graphical one is for watching i3 come up; the serial one is for
when it cannot, and it is the more reliable of the two:

```
the VM window's toolbar  ->  Displays  ->  Serial 1
```

The serial port is a plain UART whose driver is built into the kernel, so it
works from the first frame. The graphical console's keyboard may not be, and on
x86 that distinction bit us. UTM attaches a `usb-kbd`, and with
`PS2Controller: false` it also passes `i8042=off`, leaving USB as the only
keyboard — but Alpine builds USB HID as *modules* and PS/2 into the kernel:

```
CONFIG_USB_HID=m   CONFIG_HID_GENERIC=m   CONFIG_USB_XHCI_HCD=m
CONFIG_KEYBOARD_ATKBD=y   CONFIG_SERIO_I8042=y
```

So the USB keyboard needs three modules out of modloop before it types
anything, while the PS/2 one needs none. `utm-vm.sh` now sets
`PS2Controller: true` for `utm-x86_64`. It stays `false` for `utm-aarch64`,
where there is no i8042 to enable — the i8042 is an x86 device, so ARM guests
depend on USB HID either way.

## Status

This is a migration in progress, and the table says where it actually stands
rather than where it is going.

| Piece | State |
|---|---|
| Pi targets (`armhf`, `armv7`, `aarch64`) | **Working** — inherited unchanged from Copal |
| PC targets (`x86_64`, `x86`) | **Working** — inherited unchanged from Copal |
| `MODEL=vm` aarch64 image for QEMU/UTM | **Working** — inherited; boots under `copal-vm.sh` |
| `utm-aarch64` as a registered UTM VM | **Working** — `utm/utm-vm.sh` builds, registers and starts it; NAT, VirtFS share and UEFI boot all verified on UTM 4.7.4 |
| `utm-x86_64` as a target at all | **Working** — `MODEL=vmx86` sets `ARCH=x86_64` with `VM=1`, and the VM serial console now follows the architecture (`ttyAMA0` on ARM, `ttyS0` on x86) instead of being hardcoded |
| Desktop (stage 4) under virtio-gpu | Stage 4 completes; whether X starts is still being confirmed. It installs `xf86-video-fbdev`, chosen for the Pi's VideoCore |
| SSH key lockout in stages 6 + 13 | **Fixed** — see below |
| Split of `copal-prep.sh` into `lib/` + a real `guest/copal-init.sh` | Not yet done |

### The lockout, and why it happened

A full automatic run produced a machine that refused every SSH login by every
method, reachable only from its console:

```
login: can't change directory to '/home/user': Permission denied
```

Three things had to line up, and they did. Stage 3 moves `/` onto ext4 and the
admin user's home does not survive intact. `ensure_user_home` is meant to repair
that, and its ownership check read

```sh
_now=$(stat -c '%u' "$_pfx$_uh" 2>/dev/null || echo "$_uid")
[ "$_now" = "$_uid" ] && return 0
```

— which reports the ownership as *already correct* whenever `stat` cannot
answer, and returns having repaired nothing. It failed open, in the direction
that leaves an account unable to enter its own home. It also never looked at
`/home` itself, so a correctly-owned home under an untraversable parent passed
every check it made.

Then stage 6 asked `ssh_has_key()` whether a key was installed. That function
runs as **root**, and root can read anything — so it answers *"is the file
there"*, not *"will sshd accept it"*. It said yes, and the policy disabled
password authentication on the strength of it. Stage 13 then locked root, as
designed. Every route in was now closed.

The fix is in three places: `ensure_user_home` no longer treats an unreadable
`stat` as success and now makes the parent chain traversable; a new
`ssh_key_usable()` applies sshd's own StrictModes rules *and* asks the OS
directly, via `su`, whether the account can reach its own key; and stage 6 gates
the password-disabling decision on that instead of on mere existence.

The guard was always there in intent — the code says *"NOT disabling password
login -- that would lock you out entirely."* It just asked the wrong question.

### The umask leak — the cause behind both failures

The lockout above had a cause one line long, two stages upstream of where it
showed up. `admin_sync_password` sets `umask 077` before writing a temporary
`/etc/shadow`, which is correct, and never restores it — which is not.

`umask` is a property of the shell, and `copal-init.sh` runs every stage in
**one** shell. So from the middle of stage 1 onward, every directory the
installer created was `0700`. Stage 3 is what turned that into a broken system:
`setup-disk` populates the new root with `apk add --root /mnt`, so `/mnt/etc`
and `/mnt/home` were created `0700`, and after the reboot onto that root:

```
login: can't change directory to '/home/user': Permission denied
id: unknown ID 1000
```

A system that boots, looks perfectly healthy to root, and is unusable as anybody
else — because `/etc/passwd`, `/etc/group` and `/etc/resolv.conf` are read by
every name lookup and every DNS query any account makes.

Two changes. The mask is now set, used for the one file that needs it, and put
back immediately. And `fix_system_dir_modes` checks `/etc`, `/home`, `/usr`,
`/var` and the rest for world-traversability — on the new root while it is still
mounted at `/mnt`, and again on the running system in stage 1 — so a machine
built by a version that had the leak repairs itself instead of staying broken.

### Still to do

Today `copal-init.sh` is a 9,600-line quoted heredoc inside `copal-prep.sh`.
Making it a real file is the single most valuable structural change available —
it becomes editable, `shellcheck`-able and testable — but it is a refactor of
working code, so it happens *after* the two VMs can prove a refactor did not
break anything.

## Quick start

Requires macOS, `curl`, `bsdtar` and `shasum` (all stock), plus
[UTM](https://mac.getutm.app) for the VM targets.

```sh
./copal
```

That is the front door, and it is the recommended way in. It shows the whole
process on one screen before anything happens — what runs on this Mac, what
runs on the machine being built, and where the line between them falls — then a
target menu where each entry states its equipment, CPU, minimum requirements and
expected use case. It writes nothing and touches no disk; every path out of it
ends in an explicit *Begin* that names the script it hands over to.

```sh
./copal --flow      # the flow chart alone
./copal --check     # what THIS Mac can build: tools, RAM, disk, UTM, qemu
./copal --targets   # the target list, one per line
```

The underlying script is still there, and still takes the same variables — the
menu is a front door, not a wrapper that hides things:

```sh
MODEL=zero2 ./copal-prep.sh                      # a card for a Pi
MODEL=pc    ./copal-prep.sh                      # a PC / Intel Mac, 64-bit UEFI
MODEL=vm    ./copal-prep.sh --image copal-vm.img # an image; nothing physical is touched
./copal-vm.sh --graphical
```

### Sizing

`IMAGE_SIZE` defaults to **64g**, which yields a 4 GB FAT boot partition and
**~60 GiB of root**. The image is sparse — a fresh one is about 550 MB on disk
and grows only as it is written, reaching 15–25 GB after a full fifteen-stage
run. The number is a ceiling, not an allocation.

It used to default to 16g, and that was too small for what this builds: minus
the boot partition it leaves ~12 GiB, and `texlive-full` (~4 GB), KiCad (~2 GB),
the toolchain (~2–3 GB) and the catalogue (~3–5 GB) do not fit. The big installs
are gated on `df` and skip themselves rather than filling the disk, so a 16 GB
image did not break — it quietly produced a system missing half the catalogue,
which is a worse failure for being silent.

Lower it freely for a test image that will never run past stage 4:

```sh
IMAGE_SIZE=12g MODEL=vm ./copal-prep.sh --fresh --image test.img
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
| `copal` | **Start here.** The front door: flow chart, target menu, per-target briefing. Writes nothing |
| `copal-prep.sh` | Runs on the **Mac**. Downloads and verifies Alpine, prepares the medium, generates everything the target needs |
| `copal-vm.sh` | Boots a prepared image under QEMU. `--check` boots headless and reports a verdict — **the automated verification path** |
| `utm/utm-vm.sh` | Wraps a prepared image in a UTM VM: NAT, shared folder, UEFI boot — **the interactive path** |
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
