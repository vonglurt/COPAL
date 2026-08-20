#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  COPAL LINUX -- boot a Copal disk image in QEMU on Apple Silicon.
#
# copal-prep.sh writes the image; this runs it. Written as a separate script
# rather than folded into the prep because the two have different lifetimes:
# an image is prepared once and booted many times, usually while changing
# something and looking again.
#
# Usage:
#   ./copal-vm.sh                          boot ./copal-vm.img, serial here
#   ./copal-vm.sh path/to/other.img        boot a different image
#   ./copal-vm.sh --graphical              open a window instead of serial
#   ./copal-vm.sh --log boot.log           also tee the serial to a file
#   ./copal-vm.sh --snapshot               discard all writes on exit
#   ./copal-vm.sh --check                  boot, capture, report, exit
#
#   MEM=4096 CPUS=4 ./copal-vm.sh          override the defaults
#
# --check is the automated one: it boots headless with no terminal attached,
# waits for the system to come up or for a known failure to appear, prints a
# verdict and exits non-zero if the boot did not reach a login prompt. That is
# the thing to run after changing copal-prep.sh, and it takes about a minute
# instead of a card and a reboot.
#
# Ctrl-A X quits a serial session. Ctrl-A C reaches the QEMU monitor.
set -euo pipefail

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

IMAGE=""
GRAPHICAL=0
SNAPSHOT=0
CHECK=0
LOGFILE=""
MEM="${MEM:-2048}"
CPUS="${CPUS:-2}"
# How long --check waits before calling the boot hung. Alpine reaches a login
# prompt in well under a minute on an M-series host; the margin is for a first
# boot that runs copal-init.sh.
CHECK_TIMEOUT="${CHECK_TIMEOUT:-180}"

while [ $# -gt 0 ]; do
    case "$1" in
        --graphical|-g) GRAPHICAL=1; shift ;;
        --snapshot|-s)  SNAPSHOT=1; shift ;;
        --check|-c)     CHECK=1; shift ;;
        --log)          LOGFILE="${2:-}"; [ -n "$LOGFILE" ] || die "--log needs a path"; shift 2 ;;
        --log=*)        LOGFILE="${1#--log=}"; shift ;;
        -h|--help)      sed -n '5,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)             die "unknown option '$1'. See --help." ;;
        *)              [ -z "$IMAGE" ] || die "only one image at a time"
                        IMAGE="$1"; shift ;;
    esac
done

# ------------------------------------------------------------------ checks ---
command -v qemu-system-aarch64 >/dev/null 2>&1 \
    || die "qemu-system-aarch64 not found. Install it with:  brew install qemu"

[ "$(uname -m)" = arm64 ] || warn "this host is $(uname -m), not arm64 -- an aarch64 guest
         will be emulated rather than virtualised, and will be very slow."

# The UEFI firmware. QEMU's aarch64 'virt' machine has no built-in firmware the
# way a PC does: EDK2 is supplied as a pflash image, and without it the machine
# starts with nothing to execute and sits there.
FW=""
for candidate in \
    "$(brew --prefix qemu 2>/dev/null)/share/qemu/edk2-aarch64-code.fd" \
    /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
    /usr/local/share/qemu/edk2-aarch64-code.fd
do
    [ -f "$candidate" ] && { FW="$candidate"; break; }
done
[ -n "$FW" ] || die "could not find edk2-aarch64-code.fd (the UEFI firmware).
       It ships with QEMU:  brew install qemu"

if [ -z "$IMAGE" ]; then
    for candidate in copal-vm.img work/copal-vm.img work/copal-vm64.img; do
        [ -f "$candidate" ] && { IMAGE="$candidate"; break; }
    done
fi
[ -n "$IMAGE" ] || die "no image found. Make one with:
       MODEL=vm ./copal-prep.sh --image copal-vm.img
       or name one:  ./copal-vm.sh path/to/image.img"
[ -f "$IMAGE" ] || die "no such image: $IMAGE"

# An image attached to macOS and open in QEMU at the same time is two writers
# on one file. hdiutil pads its keys, so the separator is matched as
# whitespace-colon-whitespace rather than as a literal string.
IMAGE_ABS="$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")"
attached=$(hdiutil info 2>/dev/null | awk -v f="$IMAGE_ABS" '
    /^image-path[[:space:]]*:/ {
        line = $0
        sub(/^image-path[[:space:]]*:[[:space:]]*/, "", line)
        cur = (line == f)
    }
    cur && /^\/dev\/disk[0-9]+/ { print $1; exit }') || true
[ -z "$attached" ] || die "$IMAGE is attached to macOS as $attached.
       Booting it now would give two writers on one file. Detach it first:
           hdiutil detach $attached"

# EFI variables. EDK2 needs somewhere writable to record the boot entry it
# found, and it is per-image: a store from a different image names a device
# path that is not there any more, which shows up as a boot that drops to the
# EFI shell for no visible reason.
VARS="${IMAGE_ABS%.img}-efivars.fd"
if [ ! -f "$VARS" ]; then
    info "Creating the EFI variable store: $VARS"
    dd if=/dev/zero of="$VARS" bs=1m count=64 2>/dev/null \
        || die "could not create $VARS"
fi

# ------------------------------------------------------------------- build ---
# romfile= (empty) strips the PXE option ROM from the NIC.
#
# With the ROM present, EDK2 creates "UEFI PXEv4" and "UEFI PXEv6" boot entries
# and will happily put them ahead of the disk in BootOrder. QEMU's user-mode
# network answers no DHCP offer, so each one runs to its own timeout first:
#
#     >>Start PXE over IPv4.
#       PXE-E16: No valid offer received.
#     BdsDxe: failed to load Boot0002 "UEFI PXEv4 ..." : Not Found
#     >>Start PXE over IPv6.
#
# which is a minute or more of nothing before the disk is even tried. It is not
# a hang, but it looks like one. Removing the ROM removes the entries; the
# guest still gets a working NIC, because Linux drives virtio-net itself and
# has no use for the firmware's PXE stack.
#
# bootindex=0 on the disk is the other half, and the one that does not depend
# on the variable store: it tells the firmware which device to try first
# regardless of what a previous boot recorded in BootOrder. Without it, a fresh
# store boots straight to disk and a used one may not -- which is exactly the
# difference that made this invisible in testing.
set -- \
    -machine virt,accel=hvf \
    -cpu host \
    -smp "$CPUS" \
    -m "$MEM" \
    -drive "if=pflash,format=raw,readonly=on,file=$FW" \
    -drive "if=pflash,format=raw,file=$VARS" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,romfile= \
    -device virtio-rng-pci

# --snapshot keeps every write in a temporary overlay that is thrown away when
# QEMU exits, so a run that breaks the system costs nothing. Not the default:
# the usual reason to boot is to make a change and keep it.
# if=none plus an explicit -device, rather than if=virtio, because bootindex is
# a property of the device and if=virtio builds the device implicitly with no
# way to set it.
if [ "$SNAPSHOT" -eq 1 ]; then
    set -- "$@" -drive "if=none,id=hd0,format=raw,snapshot=on,file=$IMAGE_ABS"
    info "Snapshot mode: writes are discarded when the VM exits."
else
    set -- "$@" -drive "if=none,id=hd0,format=raw,file=$IMAGE_ABS"
fi
set -- "$@" -device virtio-blk-pci,drive=hd0,bootindex=0

info "Image    : $IMAGE_ABS ($(du -h "$IMAGE_ABS" | awk '{print $1}') on disk)"
info "Firmware : $FW"
info "Machine  : virt, ${CPUS} cpu, ${MEM} MB, HVF acceleration"

# -------------------------------------------------------------------- run ----
if [ "$CHECK" -eq 1 ]; then
    LOG="${LOGFILE:-$(dirname "$IMAGE_ABS")/copal-vm-check.log}"
    : > "$LOG"
    info "Check mode: booting headless, up to ${CHECK_TIMEOUT}s. Log: $LOG"

    # No terminal attached: serial straight to the file, no monitor, no
    # display. Anything that would wait for a keypress simply never gets one,
    # which is what makes this safe to run unattended.
    qemu-system-aarch64 "$@" -display none -monitor none -serial "file:$LOG" &
    QPID=$!
    trap 'kill "$QPID" 2>/dev/null || true' EXIT INT TERM

    # Poll rather than sleep out the whole timeout: a boot that reaches a login
    # prompt in 40 seconds should not take three minutes to report.
    elapsed=0
    verdict=""
    while [ "$elapsed" -lt "$CHECK_TIMEOUT" ]; do
        kill -0 "$QPID" 2>/dev/null || { verdict="qemu exited early"; break; }
        if grep -qE 'login:|Welcome to Alpine' "$LOG" 2>/dev/null; then
            verdict="ok"; break
        fi
        # The two known failure modes, both of which sit at a shell for ever
        # rather than exiting, so waiting out the timeout would tell us nothing
        # we do not already know at this point.
        if grep -q 'Mounting boot media: failed' "$LOG" 2>/dev/null; then
            verdict="boot media not found -- apks/.boot_repository missing from the card"; break
        fi
        if grep -q '/sbin/init not found in new root' "$LOG" 2>/dev/null; then
            verdict="empty package repository -- apks/<arch> has no packages"; break
        fi
        if grep -q 'Kernel panic' "$LOG" 2>/dev/null; then
            verdict="kernel panic"; break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    kill "$QPID" 2>/dev/null || true
    wait "$QPID" 2>/dev/null || true
    trap - EXIT INT TERM

    echo >&2
    printf '    %-28s %s\n' "serial log"      "$LOG ($(wc -l < "$LOG" | xargs) lines)" >&2
    printf '    %-28s %s\n' "time to verdict" "${elapsed}s" >&2
    echo >&2
    case "$verdict" in
        ok) info "BOOT OK -- reached a login prompt."
            grep -m1 -E 'Welcome to Alpine|login:' "$LOG" | sed 's/^/    /' >&2
            exit 0 ;;
        "") die "TIMED OUT after ${CHECK_TIMEOUT}s with no login prompt and no known
       failure. Last 15 lines of $LOG:
$(tail -15 "$LOG" | sed 's/^/         /')" ;;
        *)  die "BOOT FAILED: $verdict
       Last 15 lines of $LOG:
$(tail -15 "$LOG" | sed 's/^/         /')" ;;
    esac
fi

if [ "$GRAPHICAL" -eq 1 ]; then
    # A window, for looking at i3 on the framebuffer. The serial console is
    # still wired up, on the second GRUB entry.
    info "Graphical mode. Close the window to stop the VM."
    exec qemu-system-aarch64 "$@" -device virtio-gpu-pci -device qemu-xhci \
        -device usb-kbd -device usb-tablet
fi

info "Serial console. Ctrl-A X quits, Ctrl-A C reaches the QEMU monitor."
if [ -n "$LOGFILE" ]; then
    # -serial mon:stdio keeps Ctrl-A working; tee copies it without taking the
    # terminal away.
    info "Logging to $LOGFILE"
    exec qemu-system-aarch64 "$@" -display none -serial mon:stdio 2>&1 | tee "$LOGFILE"
fi
exec qemu-system-aarch64 "$@" -nographic
