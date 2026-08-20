#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
# shared.sh -- move files between the host and the emulated Mac.
#
# Mini vMac has no host folder sharing. There is no equivalent of a VM shared
# directory: the emulated Mac sees disk images and nothing else. What works
# instead is a dedicated HFS volume that both sides can touch --
# mounted as a disk inside the emulator, and read/written on the host with
# hfsutils (hformat, hmount, hcopy, hdir).
#
# The catch worth knowing up front: do NOT write to shared.dsk from the host
# while the emulator has it mounted. Both sides cache HFS metadata and neither
# expects the other; you will corrupt the volume. Quit the emulator first.
#
# Usage:
#     ./shared.sh init [MB]        create and format the volume (default 20 MB)
#     ./shared.sh put FILE...      copy files from the host into it
#     ./shared.sh get FILE...      copy files out of it to ./shared/
#     ./shared.sh ls               list what is on it
#
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="${SHARED_IMG:-$HERE/shared.dsk}"
OUT="$HERE/shared"
VOLNAME="${SHARED_VOL:-Shared}"

say()  { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need_hfsutils() {
    command -v hmount >/dev/null 2>&1 && return 0
    cat >&2 <<'EOF'
error: hfsutils is not installed.

It provides hformat/hmount/hcopy/hdir, which read and write classic HFS
volumes -- the filesystem a Mac Plus uses. HFS+ tools (hfsprogs) are a
different thing and will not work here.

    Alpine :  apk add hfsutils
    macOS  :  brew install hfsutils

Without it you can still move files by mounting shared.dsk in the emulator,
but only from the Mac side.
EOF
    exit 1
}

in_use_warning() {
    # A crude but effective check: if a profile has it linked and a minivmac
    # process is alive, the volume is probably mounted inside the emulator.
    if pgrep -x minivmac >/dev/null 2>&1; then
        die "minivmac is running. Quit it (Control-Q) before touching $IMG from the host."
    fi
}

cmd="${1:-}"; [ $# -gt 0 ] && shift

case "$cmd" in
init)
    MB="${1:-20}"
    need_hfsutils
    in_use_warning
    [ -f "$IMG" ] && die "$IMG already exists; delete it first if you mean to start over"
    say "Creating a ${MB} MB HFS volume named '$VOLNAME'"
    dd if=/dev/zero of="$IMG" bs=1048576 count="$MB" 2>/dev/null
    hformat -l "$VOLNAME" "$IMG" >/dev/null
    mkdir -p "$OUT"
    note "created $IMG"
    note "The run-*.sh profiles attach it automatically when it exists."
    note "Put files in with:  ./shared.sh put FILE"
    ;;
put)
    [ $# -gt 0 ] || die "usage: ./shared.sh put FILE..."
    need_hfsutils; in_use_warning
    [ -f "$IMG" ] || die "no $IMG -- run ./shared.sh init first"
    hmount "$IMG" >/dev/null
    for f in "$@"; do
        [ -f "$f" ] || { note "skipping $f (not a file)"; continue; }
        # -r copies raw bytes. Text files usually want -t so line endings
        # become CR, which is what classic Mac software expects.
        case "$f" in
            *.txt|*.c|*.h|*.md|*.sh) hcopy -t "$f" :: && note "$f (text, CR line endings)" ;;
            *)                       hcopy -r "$f" :: && note "$f (raw)" ;;
        esac
    done
    humount >/dev/null
    ;;
get)
    [ $# -gt 0 ] || die "usage: ./shared.sh get FILE..."
    need_hfsutils; in_use_warning
    [ -f "$IMG" ] || die "no $IMG"
    mkdir -p "$OUT"
    hmount "$IMG" >/dev/null
    for f in "$@"; do
        hcopy -r ":$f" "$OUT/$f" && note "-> $OUT/$f"
    done
    humount >/dev/null
    ;;
ls)
    need_hfsutils
    [ -f "$IMG" ] || die "no $IMG -- run ./shared.sh init first"
    hmount "$IMG" >/dev/null
    hdir
    humount >/dev/null
    ;;
*)
    sed -n '2,25p' "$0"
    exit 1
    ;;
esac
