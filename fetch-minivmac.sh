#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#
# fetch-minivmac.sh -- assemble a complete Mini vMac setup: emulator source,
#                      Apple's System 7.0.1 installer, blank floppies, a hard
#                      disk image, and a verified ROM.
#
# What it downloads:
#   - Mini vMac source                     (Gryphel Project, freely distributed)
#   - CopyRoms                             (Gryphel Project, dumps a real Mac's ROM)
#   - Blank disk images                    (Gryphel Project)
#   - System 7.0.1 installer               (Apple's own download server)
#
# What it does NOT download: a ROM image. The Macintosh Plus ROM is
# copyrighted Apple code that Apple never distributed; the Gryphel Project
# tells you to dump it from a Macintosh Plus you own, and copies on GitHub or
# abandonware sites are unlicensed redistributions rather than a source. Supply
# your own with --rom and this script will verify and install it.
#
# Usage:
#     ./fetch-minivmac.sh                    # emulator, system disks, blanks
#     ./fetch-minivmac.sh --rom FILE         # ...and install/verify a ROM
#     ./fetch-minivmac.sh --hd 100           # ...and make a 100 MB HD image
#     ./fetch-minivmac.sh --all --rom FILE   # everything
#
set -euo pipefail

MINIVMAC_VER="${MINIVMAC_VER:-36.04}"
COPYROMS_VER="${COPYROMS_VER:-1.1.0}"
BLANKS_VER="${BLANKS_VER:-1.0.0}"
GRYPHEL="https://www.gryphel.com/d/minivmac"
APPLE="http://download.info.apple.com/Apple_Support_Area/Apple_Software_Updates/English-North_American/Macintosh/System/Older_System"
DEST="${DEST:-$(cd "$(dirname "$0")" && pwd)/minivmac}"
ROMSRC=""; HDSIZE=""; WANT_ALL=0

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\n\033[36m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rom) ROMSRC="${2:-}"; shift 2 || die "--rom needs a file" ;;
        --hd)  HDSIZE="${2:-}"; shift 2 || die "--hd needs a size in MB" ;;
        --all) WANT_ALL=1; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done
[ "$WANT_ALL" = 1 ] && [ -z "$HDSIZE" ] && HDSIZE=100

command -v curl >/dev/null || die "curl is required"
mkdir -p "$DEST"

fetch() {  # <url> <dest> [description]
    local url="$1" out="$2"
    if [ -f "$out" ]; then note "$(basename "$out") already present"; return 0; fi
    if curl -fsSL --retry 2 -o "$out.part" "$url"; then
        mv "$out.part" "$out"
        note "$(basename "$out")  ($(( $(wc -c < "$out") / 1024 )) KiB)"
    else
        rm -f "$out.part"; warn "could not download $url"; return 1
    fi
}

# ------------------------------------------------------------------- ROM ---
# The first four bytes of a Mac ROM are a checksum, big-endian, over the 16-bit
# words that follow. That makes a dump self-verifying: no need to trust where
# it came from, only whether it is internally consistent.
#
# 'od -v' is essential. Without it od collapses runs of identical lines to '*',
# and a ROM has plenty of those -- you get a plausible-looking wrong answer.
rom_checksum() {  # <file> <offset> <length>
    od -An -tu1 -v -j"$2" -N"$3" "$1" \
      | awk '{ for (i = 1; i <= NF; i += 2) s = (s + $i * 256 + $(i+1)) % 4294967296 }
             END { printf "%08x", s }'
}

rom_identify() {
    case "$1" in
        4d1f8172) echo "Macintosh Plus ROM v1" ;;
        4d1eeae1) echo "Macintosh Plus ROM v2" ;;
        4d1eeee1) echo "Macintosh Plus ROM v3" ;;
        28ba61ce) echo "Macintosh 128K/512K (64 KiB ROM)" ;;
        28ba4e50) echo "Macintosh 512Ke (64 KiB ROM)" ;;
        *)        echo "unrecognised" ;;
    esac
}

# Dumps often carry padding or a resource fork after the ROM proper, so look
# for a window that verifies rather than demanding an exact file size.
install_rom() {  # <source file>
    local src="$1" size stored computed
    [ -f "$src" ] || die "no such file: $src"
    size=$(wc -c < "$src" | tr -d ' ')
    note "source: $src ($size bytes)"

    for len in 131072 65536; do
        [ "$size" -lt "$len" ] && continue
        stored=$(od -An -tx1 -N4 "$src" | tr -d ' \n')
        computed=$(rom_checksum "$src" 4 $((len - 4)))
        if [ "$stored" = "$computed" ]; then
            note "checksum $stored verified over $len bytes"
            note "identified: $(rom_identify "$stored")"
            if [ "$size" -ne "$len" ]; then
                note "trimming $((size - len)) bytes of trailing padding"
            fi
            dd if="$src" of="$DEST/vMac.ROM" bs=1 count="$len" 2>/dev/null
            note "installed $DEST/vMac.ROM"
            return 0
        fi
    done
    warn "no valid ROM found in $src"
    note "stored checksum was $stored; nothing consistent with it at 128 or 64 KiB."
    note "The dump is probably truncated or was fetched through something that"
    note "mangled it (a web page rather than the raw file, or text-mode transfer)."
    return 1
}

# ------------------------------------------------------------------ main ---
info "Mini vMac $MINIVMAC_VER source"
fetch "$GRYPHEL/minivmac-$MINIVMAC_VER/minivmac-$MINIVMAC_VER.src.tgz" \
      "$DEST/minivmac-$MINIVMAC_VER.src.tgz" \
  || note "check https://www.gryphel.com/c/minivmac/ for the current version"

info "CopyRoms $COPYROMS_VER -- dumps the ROM from a real 680x0 Mac"
fetch "$GRYPHEL/extras/copyroms/copyroms-$COPYROMS_VER.zip" \
      "$DEST/copyroms-$COPYROMS_VER.zip" || true

info "Blank disk images"
fetch "$GRYPHEL/extras/blanks/blanks-$BLANKS_VER.zip" \
      "$DEST/blanks-$BLANKS_VER.zip" || true

info "Apple System 7.0.1 installer"
note "from Apple's own download server, which is still serving these"
fetch "$APPLE/System_7.0.x/System_7.0.1.smi.bin" "$DEST/System_7.0.1.smi.bin" || true
note "System 6 is not at a stable path on Apple's server any more; the"
note "Gryphel recipes cover getting a bootable System 6 utility disk:"
note "  https://www.gryphel.com/c/minivmac/recipes/sys6util/"

if [ -n "$ROMSRC" ]; then
    info "Installing the ROM you supplied"
    install_rom "$ROMSRC"
elif [ -f "$DEST/vMac.ROM" ]; then
    info "Verifying the ROM already in place"
    install_rom "$DEST/vMac.ROM" || warn "the installed ROM does not verify"
else
    info "ROM: absent, and not downloadable"
    cat <<'ROMHELP'
    Mini vMac will not start without vMac.ROM. To make one from a Macintosh
    Plus you own:
        1. Put CopyRoms (downloaded above) on a disk the Mac can read.
        2. Run it. It writes out a ROM image; there is no user interface.
        3. Bring that file back, then:
               ./fetch-minivmac.sh --rom /path/to/that/file
    Step 3 verifies the dump against the ROM's own checksum before installing.
ROMHELP
fi

# -------------------------------------------------------------------- HD ---
if [ -n "$HDSIZE" ]; then
    info "Hard disk image: ${HDSIZE} MB"
    HDFILE="$DEST/disk1.dsk"
    if [ -f "$HDFILE" ]; then
        note "disk1.dsk already exists -- leaving it alone"
    else
        # Mini vMac treats any image larger than a floppy as a hard disk. A
        # zero-filled file is unformatted; the emulated Mac offers to
        # initialise it on first boot, which is how it gets an HFS filesystem.
        dd if=/dev/zero of="$HDFILE" bs=1048576 count="$HDSIZE" 2>/dev/null
        note "created $HDFILE ($HDSIZE MB, unformatted)"
        note "the Mac will offer to initialise it the first time it boots"
    fi
fi

# ----------------------------------------------------------------- guide ---
cat <<EOF

$(info "Contents of $DEST")
$(ls -la "$DEST" | tail -n +2 | sed 's/^/    /')

────────────────────────────────────────────────────────────────────────────
 BUILDING
────────────────────────────────────────────────────────────────────────────
  On the Pi, copal-init.sh stage 9 does this. By hand:

      tar xzf minivmac-$MINIVMAC_VER.src.tgz
      cd minivmac          # the archive unpacks into its own directory
      gcc setup/tool.c -o setup_t
      ./setup_t -t larm > setup.sh      # larm = Linux ARM;  lx64 = this Mac
      . ./setup.sh
      make

────────────────────────────────────────────────────────────────────────────
 DISKS
────────────────────────────────────────────────────────────────────────────
  At startup Mini vMac automatically mounts disk1.dsk, disk2.dsk, disk3.dsk...
  from its working directory, in order, and boots from the first one that has
  a System Folder. Anything larger than a floppy is treated as a hard disk.

  The layout this script sets up:

      disk1.dsk   the hard disk (unformatted until you initialise it)
      disk2.dsk   put your bootable system floppy here
      disk3.dsk   and so on for further floppies

  An unformatted disk1 cannot boot, so the Mac falls through to the floppy on
  disk2 and then offers to initialise disk1 once it is up. After you install a
  System Folder onto the hard disk, disk1 boots on its own and the floppies
  become optional.

  The .smi.bin files above are Apple "Self Mounting Images" and are NOT
  directly bootable .dsk files. Converting them needs a running Mac -- which
  is the chicken-and-egg problem Gryphel's recipes exist to solve:

      https://www.gryphel.com/c/minivmac/recipes/sys7inst/

  The short version: boot something that already runs (System 6, or the
  British System 7.0.1 utility disk from the recipes), use ImportFl to bring
  the .smi.bin inside, then run the installer onto your hard disk image.

────────────────────────────────────────────────────────────────────────────
 SWITCHING FLOPPIES WHILE IT RUNS  <-- the thing you will want constantly
────────────────────────────────────────────────────────────────────────────
  Mini vMac has a "control mode": hold Control, then press a letter.

      Control-H   list the available commands
      Control-R   reset the emulated Mac
      Control-I   interrupt (programmer's switch)
      Control-A   version and copyright
      Control-S   change emulated CPU speed
      Control-M   toggle magnification
      Control-F   toggle full screen
      Control-Q   quit

  IMPORTANT, and easy to lose an evening to:

      Control-O (Open Disk Image) exists ONLY on the Mac and Windows builds.
      On Linux/X11 -- which is what you are running on the Pi -- there is no
      open-file dialog at all.

  So on the Pi you insert a disk by DRAGGING the .dsk file onto the Mini vMac
  window, from pcmanfm (stage 4 installs it). That is the only way to insert a
  disk once the emulator is running.

  To EJECT, do it inside the emulated Mac, exactly like real hardware:
      - drag the disk icon to the Trash, or
      - select it and press Command-E (Put Away / Eject)
  Mini vMac maps Command to your Alt/Meta key.

  Practical consequence: a multi-floppy install goes
      eject inside the Mac  ->  drag the next .dsk onto the window  ->  repeat
  Have all the .dsk files visible in a pcmanfm window before you start.

────────────────────────────────────────────────────────────────────────────
EOF
