# Bringing Up a Minimal TUI/GUI Windowing Environment on the Raspberry Pi Zero 1 and Zero 2 W Using Alpine Linux

*Lab Report — IEEE Format*

<!-- SPDX-License-Identifier: MIT -->
Copyright (c) 2026 paulr@sdf.org. MIT licensed — see `LICENSE`. Copal Linux is
an aggregation of Alpine Linux, not a derivative work of it; Alpine and its
packages remain under their own licences.

---

## Abstract

This report documents the procedure for provisioning a minimal Linux userland
capable of hosting a text-user-interface (TUI) windowing system, and optionally
a minimal graphical user interface (GUI), on the Raspberry Pi Zero (BCM2835,
ARM1176JZF-S) and the Raspberry Pi Zero 2 W (BCM2710, Cortex-A53). Alpine Linux
is selected as the base distribution owing to its minimal installed footprint
(on the order of tens of megabytes) and its low resident memory requirement,
both of which are material constraints on the 512 MB single-board targets under
test. The primary display target is the framebuffer device exposed by the
VideoCore firmware; a network-attached display path (SSH/serial console) is
retained as an accepted fallback for the Zero 1 class device. Media preparation
is performed from macOS. The Raspberry Pi Imager path is shown to fail, and the
manual media-preparation procedure published by the Alpine Linux project is
adopted in its place.

## I. Objective

1. Boot Alpine Linux on Raspberry Pi Zero 1 (and Zero W) and Raspberry Pi Zero 2 W.
2. Bring up the VideoCore framebuffer (`/dev/fb0`) as the primary display device.
3. Host a TUI windowing system, or a minimal GUI, on that framebuffer.
4. Accept a network-device console path (headless, over SSH or USB gadget) as a
   valid outcome for the Zero 1 class device, where framebuffer or GUI
   performance is expected to be marginal.
5. Record the configuration required in each case.

## II. Materials

| Item | Detail |
|---|---|
| Target A | Raspberry Pi Zero / Zero W — BCM2835, ARM1176JZF-S (ARMv6 + VFPv2), 512 MB RAM |
| Target B | Raspberry Pi Zero 2 W — BCM2710A1, quad Cortex-A53 (ARMv8), 512 MB RAM |
| Media | SD cards, initially blank/unformatted |
| Host | macOS workstation with internet access |
| Software (host) | Raspberry Pi Imager (evaluated, see § IV-A) |
| Distribution | Alpine Linux 3.24.1, released 13 Jun 2026 |
| Source | `https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/` |

**Scope of this report.** The experiment is confined to Targets A and B above.
The installer it produced (`copal-prep.sh` / `copal-init.sh`) has since been
extended to the Pi 1, 2B, 3, 4 and 5 and to 32- and 64-bit PCs via UEFI, and to a
fifteen-stage build-out of the installed system. **None of that is within the
scope of these results**, and no claim is made here about hardware not listed
above. See `README.md` for the installer as it now stands, and
`development-report.md` for an audit of it. Where this report's findings have been
superseded by later work, the superseding is marked in place rather than by
silent revision.

## III. Background and Rationale

### A. Choice of Distribution

Alpine Linux was selected on the basis of installed size and memory footprint.
The base system is on the order of 35 MB, which is the smallest of the
candidate distributions surveyed. On a 512 MB target where the GPU split
further reduces available system RAM, minimizing the resident set of the base
system directly increases the memory budget available to the windowing layer.

### B. Choice of Architecture Port

Alpine publishes distinct ARM ports, which map onto the Raspberry Pi families
as follows:

| Alpine port | Instruction set | Raspberry Pi models |
|---|---|---|
| `armhf` | ARMv6 + VFPv2, hard-float | Pi 1, Pi Zero, Pi Zero W |
| `armv7` | ARMv7-A, hard-float | Pi 2, Pi 3 (32-bit) |
| `aarch64` | ARMv8-A, 64-bit | Pi 3, Pi 4, Pi 5, Pi Zero 2 W |

Accordingly, the two targets in this experiment do **not** share a port image:

- **Target A (Zero 1 / Zero W)** requires `armhf`. The ARM1176 core does not
  implement the ARMv7-A instruction set, so an `armv7` image will not execute.
- **Target B (Zero 2 W)** is Cortex-A53. It is nominally capable of `armv7` or
  `aarch64`, but the `armv7` **kernel** Alpine ships in its `rpi` tarball is
  built for the BCM2836/Cortex-A7 and the `aarch64` kernel for the BCM2710, so
  in practice `aarch64` is the port for this board. This was established
  experimentally and at some cost; see § IV-C.

> **Note (discrepancy to resolve during procedure).** The download identified at
> the outset of this experiment was
> `alpine-standard-3.24.1-armv7.iso`, i.e. the **armv7** port, while the stated
> intent was **armhf** for the Zero 1. These are not interchangeable on Target A.
> The corresponding `armhf` artifact is
> `https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/armhf/`. This is recorded
> here and revisited in the Procedure where the media are written.
>
> **This note was correct and was wrongly set aside once.** § IV-B Step 1
> originally concluded that a single `armhf` image served both targets and that
> this note was thereby superseded. That conclusion was false and is retracted in
> § IV-C. Per-port images are required, and the doubt recorded here should not
> have been dismissed on the evidence then available.

## IV. Procedure

### A. Attempt 1 — Raspberry Pi Imager (unsuccessful)

1. Alpine Linux was written to the SD card using Raspberry Pi Imager on macOS.
2. On first boot the target did not reach a console. The display remained at the
   VideoCore firmware's colour-test pattern ("boot rainbow"), indicating that
   `start.elf` ran but no kernel was subsequently loaded and started.
3. **Result:** failure. The Imager path does not produce a bootable Alpine card
   for these targets, and was abandoned.

*Interpretation:* the boot rainbow persisting past the firmware stage is
consistent with the firmware being unable to locate or load a kernel image and
its accompanying `config.txt` / `cmdline.txt` from the FAT boot partition —
i.e. a media-layout problem rather than a hardware or image-corruption problem.

### B. Attempt 2 — Manual media preparation per Alpine Linux documentation

Per § IV-A, media preparation follows the Alpine Linux project's own
instructions rather than a third-party imaging tool.

#### Step 1 — Acquire and extract the Raspberry Pi image

The artifact obtained was **not** the `alpine-standard-*.iso` installer image
originally identified, but the Raspberry Pi–specific release tarball:

```
alpine-rpi-3.24.1-armhf.tar.gz          69,090,580 bytes
```

This is the correct artifact for these targets. The `alpine-standard-*.iso`
images are installer media intended for platforms with a conventional
bootloader; the Raspberry Pi firmware boot chain instead expects a FAT
partition containing `bootcode.bin`, `start.elf`, `config.txt`, a kernel, and
device trees. The `alpine-rpi-*` tarball supplies exactly that layout, and its
contents are copied — not written as a block image — onto a FAT-formatted
partition.

Extraction was performed on macOS by double-clicking the archive in Finder,
yielding `~/Downloads/alpine-rpi-3.24.1-armhf/`. Verified contents:

| Component | Files | Function |
|---|---|---|
| Stage-1/2 firmware | `bootcode.bin`, `start.elf`, `start4.elf`, `fixup*.dat` | Proprietary VideoCore firmware; runs before the ARM core is released |
| Boot configuration | `config.txt`, `cmdline.txt` | Firmware and kernel command-line parameters |
| Device trees | 37 × `bcm*.dtb`, `overlays/` (374 files) | Per-model hardware description |
| Kernel | `boot/vmlinuz-rpi` (7.6 MB), kernel 6.18.35-0-rpi | Linux kernel |
| Initramfs | `boot/initramfs-rpi` (6.1 MB) | Early userspace |
| Modloop | `boot/modloop-rpi` (37.7 MB) | SquashFS of kernel modules, loop-mounted at runtime |
| Local package cache | `apks/armhf/` | Offline APK repository for installation |
| Release marker | `.alpine-release` → `alpine-rpi-3.24.1 260613` | Version identification |

**Hypothesis (subsequently falsified) — one image covers both targets.** The
extracted device-tree set includes `bcm2710-rpi-zero-2-w.dtb` and
`bcm2837-rpi-zero-2-w.dtb` alongside `bcm2835-rpi-zero.dtb` and
`bcm2708-rpi-zero-w.dtb`. The `armhf` (ARMv6) userland executes correctly on the
Zero 2 W's Cortex-A53, which is backward-compatible with ARMv6 user-mode code. It
was therefore inferred that a single `armhf` image would serve both Target A and
Target B, that the `armv7`-port download anticipated in § III-B was unnecessary,
and that the note in § III-B was superseded.

> **This inference was wrong, and was recorded here as an observation when it was
> not one.** It was tested on Target B and failed: see § IV-C. The two premises —
> the device tree is present, and ARMv6 userland runs on an A53 — are both true,
> and the conclusion does not follow from them, because neither premise concerns
> the **kernel**. The error is retained rather than deleted because the shape of
> it is the finding: two verified facts, an unstated third assumption, and a
> conclusion labelled "observation" without a boot to support it.

As-shipped boot configuration:

```
# config.txt
kernel=boot/vmlinuz-rpi
initramfs boot/initramfs-rpi
arm_64bit=0
include usercfg.txt
```

```
# cmdline.txt
modules=loop,squashfs,sd-mod,usb-storage quiet console=tty1
```

Two points are material to the objective of § I:

1. `config.txt` is declared non-editable ("will be overwritten on upgrade") and
   ends with `include usercfg.txt`. All framebuffer, GPU-memory-split, and HDMI
   parameters required in § IV-D must therefore be placed in a **`usercfg.txt`**
   file created alongside it, not in `config.txt`.
2. `cmdline.txt` already specifies `console=tty1`, i.e. the kernel console is
   directed to the framebuffer console rather than to the serial UART. The
   framebuffer path is thus the default, and the network/serial fallback of
   § I-4 would be an added configuration rather than a removal.

#### Step 2 — SD card preparation

The SD card used was the same medium that produced the § IV-A failure. Its
partition table, as written by Raspberry Pi Imager, was inspected on the macOS
host:

```
/dev/disk4 (external, physical):
   #:                       TYPE NAME              SIZE        IDENTIFIER
   0:     FDisk_partition_scheme                  *128.2 GB    disk4
   1:                 DOS_FAT_16 COPALBOOT            135.3 MB    disk4s1
                    (free space)                   128.0 GB    -
```

Two properties of this layout are noted:

- The FAT partition is **135.3 MB** on a 128.2 GB card, formatted **FAT16**.
- **128.0 GB is unallocated.** Deleting the previous image's files through the
  macOS Finder removes file contents but does not alter the partition table, so
  the geometry written by the Imager persisted.

The Alpine payload was copied into the root of this partition via Finder.

*(Detail of the final, working media preparation to be supplied by the
experimenter and recorded here — specifically whether the 135 MB FAT16
partition was retained as-is or repartitioned/reformatted, given that the
uncompressed payload approaches that partition's capacity.)*

#### Step 2a — Automated media preparation (`copal-prep.sh`)

Following the difficulties recorded in Steps 2 and 5a, media preparation was
reduced to a single reproducible script, `copal-prep.sh`, retained alongside this
report. Automating the step removes the two error classes encountered manually:
mis-identification of the target device, and an under-sized or wrongly
formatted partition inherited from a previous image.

The script implements the following, in order:

0. **Acquires and verifies the release.** With no arguments it downloads
   `alpine-rpi-3.24.1-armhf.tar.gz` from
   `https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/armhf/`, together with
   the published `.sha256`, and refuses to write anything to the card unless
   the archive verifies. An interrupted transfer resumes (`curl -C -`), and an
   archive already present is verified and reused rather than re-fetched.
   The release, architecture, and mirror are overridable by environment
   variable, with `armhf` as the default for the reason given in § III-B.

   The checksum published for this release is:

   ```
   1b32841873b4ff6b7a2f7247d65867545253bf9aa39a3c72be1c33eea9ab4ecd
   ```

   The copy obtained in Step 1 was independently hashed on the host and matched
   this value, confirming the original download was intact and that the
   § IV-A failure was not attributable to a corrupt archive.

1. Locates and validates the extracted `alpine-rpi-*` payload, refusing to
   proceed unless `bootcode.bin`, `start.elf`, `config.txt`, `cmdline.txt`, and
   `boot/vmlinuz-rpi` are all present.
2. Enumerates external physical disks and requires the operator to enter a
   whole-disk identifier, which is then checked: internal, virtual, and
   sub-gigabyte devices are rejected outright, and the device's size and
   removability are displayed for confirmation before any write. Destructive
   action requires typing `ERASE` in full.
3. Partitions the card `MBRFormat` — the VideoCore firmware reads an MBR
   partition table, not GPT — with a 2 GB FAT32 partition labelled `COPALBOOT`,
   **leaving the remainder of the card unallocated**. The free space is
   deliberate: the ext4 partition required in Step 6 must be created on the Pi,
   as macOS cannot create ext4 filesystems.

   > **Superseded, twice.** This describes the script as it stood at this point
   > in the procedure, and both figures have since changed. `COPALBOOT` now
   > defaults to 4 GB, and a second partition `COPALROOT` (MBR type `0x83`) is
   > laid down over the *whole* remainder rather than left unallocated. The
   > intermediate design — a fixed 16 GB `COPALROOT`, per § V-B — was itself
   > abandoned because it stranded most of a large card with no way to reach the
   > space later. macOS still cannot create the ext4 *filesystem*; what it can
   > do, and now does, is create the partition slot for it, which is the part
   > that is awkward to do afterwards on a disk the target is running from.
4. Sets the partition's bootable flag via `fdisk -e`.
5. Copies the payload as **files** (`cp -Rp`, with `COPYFILE_DISABLE=1` to
   suppress AppleDouble sidecars), then removes macOS metadata artefacts
   (`.Spotlight-V100`, `.fseventsd`, `._*`, `.DS_Store`).
6. Verifies each required boot file, kernel, initramfs, modloop, device tree,
   and directory is present on the card, and refuses to declare success
   otherwise.
7. Flushes and ejects.

The distinction preserved by step 5 is the central lesson of § IV-A: the
payload is *copied* onto a filesystem, never written as a block image.

Each stage pauses and describes its action before executing, and the operator
must press Enter to proceed; `SIGINT` is trapped throughout. Stages 0–2 are
non-destructive and abort cleanly. Stage 3 is not reversible, and the trap
reports this explicitly rather than implying the card can be restored.

#### Step 2b — Scripted preparation: result

`copal-prep.sh` was executed on the macOS host with the SD card inserted. The
complete console transcript is retained as `run-log-copal-prep.txt`. **The script
completed successfully on its first execution**, with no errors and no
warnings, including the optional `fdisk` bootable-flag stage.

Measured values from the run:

| Quantity | Value |
|---|---|
| Archive transferred | 65.8 MiB at 63.0 MiB/s (1 s) |
| SHA256 verification | Passed |
| Extracted payload | 73 MiB |
| Release identifier | `alpine-rpi-3.24.1 260613` |
| Target device | `/dev/disk4`, 128 177 930 240 B, External, Removable |
| Partition table written | MBR (`FDisk_partition_scheme`) |
| Boot partition | `DOS_FAT_32`, 2.0 GB, label `COPALBOOT` |
| FAT32 geometry | 3 898 608 sectors, 487 326 clusters, 4096 B/cluster |
| Remainder left unallocated | 126.2 GB |
| Payload on card | 75 MiB of 1.9 GiB (4 % used) |
| Verification | 13 of 13 required files and directories present |

The prior partition layout — `DOS_FAT_16`, 135.3 MB, inherited from Raspberry
Pi Imager — is visible in the transcript's Step 2 listing and was replaced by
the FAT32 layout above, confirming the erase and repartition executed as
specified.

**Correction to § IV-B Step 2.** That step recorded a concern that the
135.3 MB FAT16 partition might be too small for the payload, and that a
silently truncated Finder copy could therefore explain the § IV-A failure. The
measured payload is **75 MiB**, which fits within 135.3 MB. Insufficient
capacity is therefore **excluded** as a cause, and the earlier concern was
unfounded. Combined with the independent SHA256 verification in Step 2a — which
excludes a corrupt download — the § IV-A failure is attributable to the imaging
method alone: an installer ISO written as a block image does not produce the
FAT filesystem layout that the VideoCore firmware requires. The FAT16 format
itself and the absence of a bootable flag remain uneliminated secondary
factors, as the scripted procedure changed both variables alongside the
partition size.

*(Pending: boot of the scripted card on Target A, and repetition of the
configuration sequence of Steps 5–5a using the persistence layout corrected in
Step 6.)*

#### Step 3 — First successful boot (Target A, Raspberry Pi Zero 1)

**Result: SUCCESS.** The Raspberry Pi Zero 1 booted Alpine Linux from the
manually prepared medium and reached a console. The boot-rainbow condition of
§ IV-A did not recur.

This is the controlled comparison that isolates the § IV-A failure: the same
SD card and the same target hardware, differing only in the media-preparation
method, produced a successful boot. The failure is therefore attributable to
the imaging method — the block-image write of an installer ISO — and not to
defective hardware, a corrupt download, or an incompatible architecture port.
It further confirms § IV-B Step 1's finding that the `alpine-rpi-*` tarball's
file-copy layout is what the VideoCore firmware chain requires.

The `armhf` (ARMv6) port is confirmed correct for Target A.

#### Step 4 — Peripheral configuration

The Raspberry Pi Zero 1 exposes a single USB On-The-Go micro-USB data port, so
all peripherals are attached through a hub:

| Item | Device | Interface |
|---|---|---|
| Hub | USB mini hub | Attached to the Zero's USB OTG port |
| HID | Logitech wireless keyboard/mouse combo | Single USB receiver, `usbhid` |
| Network | TP-Link UE306 USB-to-Ethernet | Realtek RTL8153, `r8152` driver |

This satisfies both console paths of § I simultaneously: local keyboard input
against the framebuffer console, and a wired network device available for the
network-attached fallback of § I-4.

**Network interface enumeration.** The TP-Link UE306 was enumerated by the
kernel and presented as `eth0`, initially in the `DOWN` state. This confirms
that the `r8152` driver for the Realtek RTL8153 controller is present in the
stock `modloop-rpi` and requires no additional installation — a prerequisite
for the network-attached fallback of § I-4, and one that would otherwise
present a bootstrapping problem (network access being required to obtain the
driver that provides network access). The `DOWN` state reflects an
unconfigured interface rather than a fault.

#### Step 5 — System configuration (`setup-alpine`)

First-boot login is as `root` with no password. System configuration was then
performed with the interactive `setup-alpine` script.

| Parameter | Value |
|---|---|
| Keyboard layout | `us` / `us` variant |
| Hostname | `hotdog` |
| Network interface | `eth0` (UE306), DHCP |
| Root password | Set; recorded on a physical label affixed to the device |
| Timezone | `US/Pacific` |
| APK mirror | Selected by option `f` (automatic fastest-mirror detection) |
| Mirror chosen | `mirrors.ocf.berkeley.edu` (Open Computing Facility, UC Berkeley) |
| SSH server | *(to be recorded)* |
| Disk mode | `none` — diskless/RAM-resident operation |

The `f` option benchmarks each published mirror and selects the
lowest-latency one automatically, rather than requiring a selection by index.

**Disk-selection hazard (§ IV-B Step 5a).** The `setup-alpine` disk step
presents `Which disk(s) would you like to use?`, listing `mmcblk0` at its full
128.2 GB capacity. Selecting that disk advances to a second prompt offering
`sys`, `data`, or `crypt`. **All three repartition and erase the entire card**,
including the FAT partition holding `bootcode.bin`, `start.elf`, the kernel,
and the device trees. Because Alpine's `sys` installer writes a conventional
Linux partition layout that the VideoCore firmware cannot boot, completing this
path would destroy the working medium prepared in Steps 1–2 and return the
target to the § IV-A failure condition.

The correct answer at the first prompt is `none`. The `alpine-rpi` image is a
diskless (RAM-resident) design: no Linux root partition is created or required,
and the pre-existing FAT partition constitutes the whole of the storage layout.
No manual partitioning is necessary at any point in this procedure.

In this run the second prompt was reached and aborted with `Ctrl-C` before the
`Erase the above disk(s) and continue? [y/N]` confirmation, at which point no
write had yet occurred and the medium was intact. Parameters already accepted
earlier in the script are applied as entered rather than at script completion,
so the abort incurred no loss. Persistence was then configured directly:

| Command | Response | Function |
|---|---|---|
| `setup-lbu` | `mmcblk0p1` | Designates the FAT partition as the `apkovl` store |
| `setup-apkcache` | `/media/mmcblk0p1/cache` | Persistent package cache |
| `lbu commit -d` | — | Writes `hotdog.apkovl.tar.gz` to the FAT partition |

The resulting `hotdog.apkovl.tar.gz` constitutes the installed system state:
the diskless image reconstitutes the configured environment from this archive
at each boot.

**Credential handling note.** The root password was transferred to a physical
label attached to the chassis. For a bench-resident device this is an
acceptable trade against credential loss, but it is recorded here as a
deliberate configuration decision: the credential is legible to anyone with
physical access, and the same account is reachable over the network once SSH
is enabled on `eth0`. Migration to public-key authentication with
`PasswordAuthentication no` is the appropriate hardening step should the device
be deployed outside the bench.

**Diskless-mode persistence.** The `alpine-rpi` image runs from RAM: the root
filesystem is unpacked into a tmpfs at each boot, and modifications are not
written back to the SD card automatically. Configuration is persisted by
committing an overlay archive (`apkovl`) to the FAT partition:

```
lbu commit -d
```

Any change not followed by `lbu commit -d` — including the root password,
network configuration, and installed packages — is lost at the next power
cycle. This is a required step after each configuration change in the
remainder of this procedure, and is a defining operational characteristic of
the diskless image rather than an incidental detail.

*(To be verified and recorded: address acquired by `eth0` via DHCP; `lsusb`
enumeration of the HID receiver and hub; whether the hub supplies sufficient
current for the combined load; and baseline free memory as measured by
`free -m`, which establishes the memory budget available to the windowing
layer of § I-3.)*

### C. Attempt 3 — the `armhf` image on Target B (unsuccessful; § IV-B Step 1 falsified)

A card was written with the `armhf` payload and booted on Target B (Zero 2 W), on
the hypothesis recorded in § IV-B Step 1 that one image serves both targets.

**Result: failure, and a failure with no diagnostic output of any kind.** The
board produced no display, no boot rainbow, and no console. It was
indistinguishable from a dead card or a dead board. The cost was one card's
preparation and one debug cycle.

*Interpretation.* Note that this failure is *not* the § IV-A boot rainbow. The
rainbow indicates the VideoCore firmware ran and then failed to load a kernel;
here the firmware handed off successfully and the **kernel itself** stopped before
initialising any output device.

The mechanism is in the ARM kernel's early boot path. Alpine's `armhf` `rpi`
kernel is configured `CONFIG_ARCH_MULTI_V6` / `CONFIG_CPU_V6K` with
`ARCH_BCM2835`, and **without** `CONFIG_CPU_V7`. Before the MMU is enabled and
long before any console exists, `__lookup_processor_type` in `arch/arm/kernel/head.S`
matches the running CPU's MIDR against the `proc_info_list` entries compiled into
the image. The Cortex-A53 reports `0x410fd034`, for which an ARMv6-only kernel
carries no entry; the lookup fails, execution branches to `__error_p`, and the
core spins. Nothing has been initialised at that point, so there is no channel
through which to report it.

This resolves the two premises of § IV-B Step 1 as follows:

| Premise | Status | Why it did not support the conclusion |
|---|---|---|
| `bcm2710-rpi-zero-2-w.dtb` is present in the `armhf` tarball | **True** | The device tree is read by the kernel *after* processor identification. Execution never reaches it, so its presence is irrelevant. |
| ARMv6 userland runs on a Cortex-A53 | **True** | It does — but userland is reached only if a kernel boots. The claim was about the userland and the obstacle was in the kernel. |

**Conclusion.** Alpine's ARM ports are **not** interchangeable across these
targets, and the correct mapping is by board rather than by userland
compatibility:

| Board | Port required |
|---|---|
| Pi Zero, Zero W, Pi 1, CM1 | `armhf` |
| Pi 2B v1.1 | `armv7` |
| Pi Zero 2 W, Pi 3, Pi 4, Pi 5, CM3/CM4 | `aarch64` |

**Method correction adopted.** A payload is henceforth identified by its
**kernel configuration, not its filename** — `CONFIG_ARM64=y` → `aarch64`,
`CONFIG_CPU_V7=y` → `armv7`, `CONFIG_CPU_V6K=y` → `armhf`. `copal-prep.sh` was
amended to take a `MODEL=` parameter, to derive the required architecture from
it, to refuse an `ARCH` that contradicts the `MODEL`, and to cross-check the
payload's own `boot/config-*` before writing anything to the card. The failure
mode being silent is what justifies checking before the write rather than
diagnosing after the boot.

*A note on evidence.* § IV-B Step 1 labelled an inference "Observation". The two
facts it rested on were verified; the proposition it asserted was not tested until
this step. On this hardware the distinction is not academic — the penalty for an
untested boot-path assumption is a target that removes every diagnostic channel
before it fails, and which therefore cannot tell you what you got wrong.

## V. Results

### A. Baseline memory, Target A (Raspberry Pi Zero 1)

Measured with `free -m` at the console immediately after first boot from the
scripted medium, before `setup-alpine` and before any package installation:

| Quantity | Value |
|---|---|
| Total memory visible to Linux | 427 MiB |
| Free | 391 MiB |
| Physical memory on the SoC | 512 MiB |
| Consumed by GPU split and kernel | ≈ 85 MiB |

The 85 MiB difference between the 512 MiB physical total and the 427 MiB
visible to Linux is accounted for by the VideoCore firmware's default GPU
memory reservation together with the kernel image and its static allocations.
The GPU reservation is adjustable via `gpu_mem` in `usercfg.txt` (§ IV-B
Step 1), which is the principal lever available for trading framebuffer
capability against system memory.

**Interpretation.** 391 MiB free establishes that *memory is not the binding
constraint* on the § I-3 objective for Target A. A TUI windowing system —
`tmux`, `dvtm`, or a framebuffer-hosted equivalent — occupies a few megabytes
and is comfortably accommodated. Even a minimal X11 or Wayland stack, which
typically requires on the order of 40–80 MiB resident, fits within this budget
with margin.

The limiting factor for a graphical target on Target A is therefore expected to
be **processing throughput rather than memory**: the ARM1176JZF-S is a
single-core in-order design at 1 GHz without NEON, and the `armhf` port is
compiled to ARMv6 with VFPv2 only. This displaces the anticipated
memory-exhaustion failure mode identified in § I and reframes the GUI-versus-TUI
decision as one of interactive latency. The measurement is repeated on Target B
in § V-B for comparison, that device differing principally in core count and
architecture rather than in installed memory.

### B. Failure of the diskless model under a graphical workload

Installation of the X11 stack on Target A terminated with
`ERROR: No space left on device`. Filesystem utilisation at the point of
failure:

| Filesystem | Utilisation |
|---|---|
| `/` (tmpfs, RAM-backed) | **100 %** |
| `/media/mmcblk0p1` (FAT32, 2 GB) | 1 % |

The exhausted resource is **RAM, not storage**. In diskless operation the root
filesystem is a tmpfs sized at approximately half of available memory — on the
order of 200 MiB of the 427 MiB measured in § V-A — and every installed package
is resident within it. The SD card was 99 % empty at the moment of failure, so
no partitioning or reformatting of the card could have prevented it while the
root filesystem remained RAM-backed.

**This is the principal negative result of the experiment.** The property that
motivated the choice of Alpine in § III-A — a minimal, RAM-resident system — is
the same property that prevents a graphical environment from being installed.
The saving is not free: memory not spent on a base system is spent instead on
holding the root filesystem, and the trade becomes unfavourable as soon as the
installed footprint approaches the tmpfs ceiling. A TUI target, whose packages
total a few megabytes, remains comfortably within the diskless model; a
graphical target does not.

Note that this ceiling is invisible in the § V-A measurement. 391 MiB free
correctly indicated that a running X server would fit in memory; it gave no
indication that *installing* one would not, because the constraint is the
tmpfs root rather than working set. The two are easily conflated.

**Resolution.** The diskless model is abandoned for Target A in favour of a
persistent ext4 root filesystem on a second SD partition, retaining the FAT
partition as the firmware boot partition and directing the kernel to the new
root via `root=/dev/mmcblk0p2` in `cmdline.txt`. This converts the system to
conventional operation, in which installed packages are written to the card and
persist without `lbu commit`, and the installable footprint is bounded by
partition size rather than by RAM.

`copal-prep.sh` was amended accordingly to lay down both partitions on the host at
preparation time (`COPALBOOT`, 2 GB FAT32; `COPALROOT`, 16 GB, MBR type `0x83`),
rather than leaving free space to be partitioned later on the Pi. Partitioning
the card in the host avoids a documented difficulty: the kernel will not re-read
the partition table of a device it is running from, because the boot partition
is mounted and the running system is loop-mounted from `modloop-rpi` on it, so
partition changes made on the target require a reboot to take effect.

**Revision to the sizes.** The 16 GB figure was a second error of the same family
as § IV-C's, if a much cheaper one: a number chosen as "surely enough" without
asking what it cost. On the 128 GB card actually in use it stranded roughly 108 GB
that no later step could reach, because extending a partition requires free space
*immediately after it* and the unallocated region was already accounted for.
`ROOT_SIZE` now defaults to `R` — `diskutil`'s syntax for the rest of the device —
and `BOOT_SIZE` to 4 GB, sized for headroom to keep several kernels and a rescue
image rather than because the ~110 MB payload needs it. Stage 8 (`stage_grow`)
remains in the installer for cards partitioned under the old default, and is a
no-op when `COPALROOT` already reaches the end of the device.

## VI. Discussion

### A. The objective was met, but not by the route anticipated

§ I posed a TUI windowing system on the framebuffer as the primary goal, with a
minimal GUI as a stretch and a network console as an accepted fallback for
Target A. The outcome inverts the expected difficulty. A **graphical** environment
runs on Target A — X.Org on the framebuffer via `xf86-video-fbdev`, with i3 — and
the network fallback of § I-4 proved unnecessary for reaching a console at all,
because `cmdline.txt` ships `console=tty1` and the framebuffer console is
therefore the default (§ IV-B Step 1). What blocked the objective was neither
display nor memory, but the **storage model**, which § I did not identify as a
variable.

### B. Two constraints were misidentified at the outset

| Anticipated constraint | What was actually measured |
|---|---|
| Memory would bind the windowing layer | 391 MiB free (§ V-A). Memory was never the limit for *running* a desktop. |
| The Zero 1's ARMv6 core would bind the GUI | Not reached as a limit. The install failed before performance could be assessed. |
| Storage was ample — a 128 GB card | The binding resource was the **tmpfs root**, ~200 MiB of RAM, with the card 99 % empty (§ V-B). |

The § V-A measurement is the instructive one, because it was correct and
misleading at once. 391 MiB free accurately predicted that an X server would fit
in memory. It carried no information about whether one could be *installed*,
because installation consumes the tmpfs root while execution consumes working
set. A single "free memory" figure silently conflates two different budgets, and
on a diskless system they are not interchangeable.

### C. The cost of Alpine's central virtue

§ III-A selected Alpine for a small installed footprint and low resident memory.
§ V-B is the bill for that choice: the same RAM-resident design that makes the
base system small is what prevents a graphical one from being installed. The
saving is not free — memory not spent on a base system is spent holding the root
filesystem instead, and the trade turns unfavourable exactly when the installed
footprint approaches the tmpfs ceiling. A TUI target of a few megabytes stays
comfortably inside the model; a graphical target of several hundred does not.

This is not an argument against Alpine, and the resolution retains it. Moving `/`
onto ext4 on the card converts the system to conventional operation and bounds the
footprint by partition size rather than by RAM, while keeping musl, busybox, `apk`
and the small base that motivated the choice. What is discarded is only the
diskless *mode*, which is a property of the `alpine-rpi` image rather than of
Alpine. Stage 2 of the installer preserves the diskless model for exactly the case
where it remains the better trade — a TUI system, where a RAM-resident root is
gentler on the card and entirely sufficient.

### D. Failures that remove their own evidence

Three distinct failure modes in this procedure produced little or no diagnostic
output, and they are worth separating because they look alike and are not:

| Failure | Symptom | Stage reached |
|---|---|---|
| Block-imaged installer ISO (§ IV-A) | Boot rainbow persists | Firmware ran; no kernel loaded |
| `armhf` kernel on Cortex-A53 (§ IV-C) | No display at all | Firmware handed off; kernel died in `head.S` |
| `gpu_mem=16` in `usercfg.txt` | No display at all | Firmware halted before HDMI init |

The second and third are indistinguishable from each other, and from a dead card
or dead board, by observation alone. The third is the sharpest: at exactly 16 the
bootloader elects to load `start_cd.elf` and `fixup_cd.dat`, which the
`alpine-rpi` tarball does not ship, so a single untested line in a configuration
file removed every diagnostic channel simultaneously.

The methodological consequence is that on this class of hardware, **verification
must precede the write rather than follow the boot**, because a failed boot may
carry no information about its own cause. This is why the port check in
§ IV-C reads the payload's kernel configuration on the host, and why
`usercfg.txt` is changed one directive at a time with a boot in between.

### E. On labelling inference as observation

§ IV-B Step 1 and the 16 GB partition size were both errors of the same
structure: a conclusion that followed comfortably from true premises, recorded
with the confidence of a measurement, and not tested. In the partition case the
penalty was stranded capacity, recoverable by repartitioning. In the port case it
was a silent failure on hardware that could not report what was wrong. The
premises in § IV-C's table are *still true* — the device tree is present, ARMv6
userland does run on an A53 — which is precisely what made the inference feel
safe. Neither premise was about the kernel, and the unstated third assumption was
never examined because it was never articulated.

## VII. Conclusion

1. **The Raspberry Pi Imager path fails for Alpine on these targets** and the
   failure is attributable to the imaging method alone. The `alpine-rpi-*.tar.gz`
   payload must be **copied as files** onto a FAT partition; an installer ISO
   written as a block image does not produce the layout the VideoCore firmware
   requires. Corrupt download (excluded by SHA256, § IV-B Step 2a), insufficient
   partition capacity (excluded by measurement, § IV-B Step 2b) and defective
   hardware (excluded by the successful boot of the same card on the same board,
   § IV-B Step 3) were each eliminated independently.

2. **Alpine's ARM ports are not interchangeable across Raspberry Pi models**, and
   the mapping is by board, not by userland compatibility: `armhf` for the
   Zero/Zero W/Pi 1, `armv7` for the Pi 2B v1.1, `aarch64` for the Zero 2 W and
   later. The `armhf` kernel halts in `__lookup_processor_type` on a Cortex-A53
   with no output of any kind (§ IV-C). A payload should be identified by its
   kernel configuration rather than its filename.

3. **Memory is not the binding constraint on a windowing system on a 512 MB
   Zero.** 391 MiB free after boot accommodates a TUI comfortably and a minimal
   X11 stack with margin (§ V-A).

4. **The diskless model cannot host a graphical installation, and this is the
   principal negative result.** The root filesystem is a tmpfs of roughly half of
   available memory; installing X11 exhausts it while the card remains 99 % empty
   (§ V-B). The exhausted resource is RAM, not storage, so no partitioning scheme
   addresses it while the root remains RAM-backed.

5. **A persistent ext4 root resolves it** without abandoning Alpine, bounding the
   installable footprint by partition size. Both partitions are created on the
   host, because the kernel will not re-read the partition table of a device it is
   running from.

6. **The framebuffer console is the default, not the fallback.** `cmdline.txt`
   ships `console=tty1`; the serial/network path of § I-4 is the configuration
   that would need adding, and it was not required.

7. **Nothing persists in diskless mode without `lbu commit -d`** — including the
   root password, network configuration and installed packages. This is a defining
   operational characteristic of the image rather than an incidental detail.

**Outstanding.** Two measurements remain uncollected and are the natural
continuation of this work: the `free -m` comparison of X.Org against `tmux` on the
bare framebuffer, which is the GUI-versus-TUI evidence for § I-3 and which only
hardware can supply; and the § IV-B Step 5 observations listed there (DHCP lease,
`lsusb` enumeration, hub current adequacy). Stages 4–15 of the installer are
written but, apart from the desktop bring-up noted in § VI-A, unexercised on
hardware; their state is tracked in `development-report.md` rather than here.

## References

[1] Alpine Linux, "Alpine Linux 3.24.1 release," 13 Jun. 2026. [Online].
    Available: https://alpinelinux.org/

[2] Alpine Linux Wiki, "Raspberry Pi." [Online].
    Available: https://wiki.alpinelinux.org/wiki/Raspberry_Pi

[3] Raspberry Pi Ltd., "Raspberry Pi Documentation — Processors." [Online].
    Available: https://www.raspberrypi.com/documentation/computers/processors.html
