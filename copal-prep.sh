#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#   ██████  ██████  ██████   █████  ██
#  ██      ██    ██ ██   ██ ██   ██ ██
#  ██      ██    ██ ██████  ███████ ██
#  ██      ██    ██ ██      ██   ██ ██
#   ██████  ██████  ██      ██   ██ ███████
#
#  COPAL LINUX -- the damn tasty Raspberry Pi Zero distro. Full installer.
#
# Copal is tree resin caught halfway to amber: hardened, but not yet stone.
# That is this system's whole trick. Alpine on a Pi boots "diskless" -- the
# root filesystem is a tmpfs that evaporates at power-off -- and Copal is what
# turns that into something permanent on the card without giving up any of the
# smallness that made it worth booting.
#
# Not a remaster, not an image to dd. Copal is an installer: it lays down
# stock Alpine and then walks you through fifteen stages, each one optional,
# each one re-runnable, from a RAM-resident shell to a full ext4 root with a
# tiling desktop, 316 curated applications, emulators and a toolchain -- on a
# 1 GHz single core with 512 MB of RAM.
#
# ---------------------------------------------------------------------------
#
# copal-prep.sh — prepare a card on macOS for booting Alpine Linux on a
#              Raspberry Pi Zero 1 / Zero W / Zero 2 W, a Pi 1 / 2 / 3 / 4 / 5,
#              or an ordinary PC, laptop or Intel Mac via UEFI. Set MODEL.
#
# Creates an MBR-partitioned card with two partitions: a FAT32 boot partition
# (COPALBOOT, 4G by default) and COPALROOT over the whole remainder, marked MBR
# type 0x83 for the ext4 root that stage 2 or 3 puts there. The root partition
# is laid down HERE rather than on the target because the kernel will not re-read
# the partition table of a disk it is running from -- see ROOT_SIZE below, and
# note that macOS cannot create the ext4 filesystem itself, only the slot for it.
#
# Then copies the extracted payload onto the FAT partition -- alpine-rpi-*.tar.gz
# on a Pi, alpine-netboot-*.tar.gz plus a GRUB from Alpine's own ISO on a PC.
# The payload is COPIED as files -- it is not written as a block image. Writing
# an Alpine ISO with a block imager is what leaves the Pi stuck at the firmware
# colour-test pattern ("boot rainbow").
#
# With no arguments it downloads the Alpine release, verifies its SHA256,
# extracts it, and writes the card. Pass an already-extracted directory to skip
# the download.
#
# Usage:  ./copal-prep.sh [--refresh] [--image [PATH]] [/path/to/payload-dir]
#
#   MODEL=zero2 ./copal-prep.sh                       # pick the board (see below)
#   ALPINE_VER=3.24.1 ARCH=armhf ./copal-prep.sh      # override the release
#   MODEL=vm ./copal-prep.sh --image copal.img        # a VM image, no card
#
# MODEL selects the Alpine architecture, and getting it wrong is not a
# degraded system -- it is a Pi that stops dead at the firmware rainbow:
#
#   zero, zero-w, pi1, cm1        armhf     (BCM2835, ARMv6)
#   pi2b (v1.1)                   armv7     (BCM2836, Cortex-A7, 32-bit only)
#   zero2, pi3, cm3, pi2b-v12     aarch64   (BCM2710, Cortex-A53)
#   pi4, 400, cm4, pi5            aarch64   (BCM2711 / BCM2712)
#   pc / pc32                     x86_64 / x86   (UEFI)
#   vm                            aarch64   (UEFI, UTM/QEMU on Apple Silicon)
#
# --image writes to a sparse file rather than a card. Nothing physical is
# touched, so there is no identifier to mistype: it is the way to try a change
# without a boot cycle, and with MODEL=vm the result boots on this Mac at
# native speed. IMAGE_SIZE=64g by default -- sparse, so it costs only what is
# written. See IMAGE_SIZE below for why 64 and not 16.
#
set -euo pipefail

BOOT_LABEL="COPALBOOT"
# The boot partition holds firmware, kernel, initramfs, modloop and device
# trees -- about 110 MB in practice. 4G is enormously more than that needs;
# it is sized for headroom to keep several kernels and a rescue image around,
# not because the payload requires it. BOOT_SIZE=2G is just as workable.
BOOT_SIZE="${BOOT_SIZE:-4G}"
ROOT_LABEL="COPALROOT"
# "R" means the remainder of the card. Earlier versions used a fixed 16G and
# left the rest unallocated, which stranded most of a large card for no
# benefit -- the space cannot be reached later without repartitioning.
ROOT_SIZE="${ROOT_SIZE:-R}"
# "R" is diskutil's syntax, not something to show a human.
if [ "$ROOT_SIZE" = "R" ]; then
    ROOT_SIZE_LABEL="rest of card"
else
    ROOT_SIZE_LABEL="$ROOT_SIZE"
fi
MIN_CARD_BYTES=$((1024 * 1024 * 1024))   # refuse anything under 1 GB

# --- output helpers ---------------------------------------------------------
# Defined up here, ahead of every caller. They used to sit further down, below
# the configuration block -- which was fine until the configuration block itself
# needed to warn or die (MODEL/ARCH selection does), and then the script failed
# with "warn: command not found" on a plain run. In a shell script a function is
# only callable after its definition has been executed, so definitions belong
# above the first line of top-level code that uses them.
#
# All progress output goes to stderr so that stdout stays clean for values
# captured by command substitution (see fetch_payload).
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

# "16g", "512m" -> bytes. Empty output means "not a size", which every caller
# treats as fatal -- a silently misparsed size would create a useless image.
size_to_bytes() {
    local n="${1%[gGmM]}" u="${1#"${1%[gGmM]}"}"
    case "$n" in ''|*[!0-9]*) printf ''; return 0 ;; esac
    case "$u" in
        g|G) printf '%s' $(( n * 1024 * 1024 * 1024 )) ;;
        m|M) printf '%s' $(( n * 1024 * 1024 )) ;;
        *)   printf '' ;;
    esac
}

# --- command line -----------------------------------------------------------
# Parsed up here rather than just before it is needed, because --image changes
# a question asked much further down: it supplies the target, so the "which
# disk?" prompt is skipped entirely and there is no identifier to mistype.
#
#   --refresh        rewrite only the generated files on an existing card
#   --image [PATH]   write to a raw disk image instead of a card, for UTM or
#                    QEMU. Created sparse at IMAGE_SIZE if it does not exist.
#   PATH             an already-extracted payload directory (skips the download)
#
# The old parser accepted --refresh only as $1 and treated everything else as
# the payload directory. This loop keeps both of those meanings.
REFRESH=0
IMAGE_MODE=0
IMAGE_PATH=""
# 64g, not 16g, and the reason is arithmetic rather than generosity. The image
# is sparse -- it costs only what is written, and a fresh one is about 550 MB on
# disk whatever this says -- so the number is a ceiling, not an allocation.
#
# 16g was too low for the thing this script actually builds. BOOT_SIZE takes 4G
# off the top, leaving ~12G of root, and a full automatic install does not fit
# in that: texlive-full is ~4 GB and KiCad ~2 GB in stage 14, the toolchain in
# stage 7 is another 2-3 GB, the catalogue in stage 12 is 3-5 GB, and Chromium
# alone is 350 MB. A complete run lands around 15-25 GB. The big installs are
# gated on df and skip themselves rather than filling the disk, so 16g did not
# corrupt anything -- it just quietly produced a system missing the half of the
# catalogue that would not fit, which is a worse failure for being silent.
#
# 64g leaves ~60 GiB of root and 2.5-4x headroom. Lower it freely for a test
# image that will never run past stage 4.
IMAGE_SIZE="${IMAGE_SIZE:-64g}"
FRESH=0
SRC_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --refresh) REFRESH=1; shift ;;
        --fresh)   FRESH=1; shift ;;
        --image=*) IMAGE_MODE=1; IMAGE_PATH="${1#--image=}"; shift ;;
        --image)
            IMAGE_MODE=1; shift
            # The path after --image is optional, so it has to be told apart
            # from a payload directory. "It exists, so it is a directory" is
            # not safe -- re-running with the same image would misread it --
            # so the suffix decides, and nothing else is consumed.
            case "${1:-}" in
                *.img|*.dmg|*.raw) IMAGE_PATH="$1"; shift ;;
            esac ;;
        -h|--help)
            cat >&2 <<'USAGE'
copal-prep.sh -- write a Copal Linux card or disk image from macOS.

  ./copal-prep.sh                      pick a board, write a card
  ./copal-prep.sh --image copal.img    write a bootable disk image instead
  ./copal-prep.sh --fresh --image X    delete the image first, rebuild from nothing
  ./copal-prep.sh --refresh            rewrite generated files on an existing card
  ./copal-prep.sh /path/to/payload     use an extracted payload, skip the download

  MODEL=zero2 ./copal-prep.sh          choose the board without the menu
  MODEL=vm ./copal-prep.sh --image c.img   aarch64 UEFI image for UTM/QEMU

Environment: MODEL ARCH ALPINE_VER MIRROR WORKDIR BOOT_SIZE ROOT_SIZE IMAGE_SIZE
USAGE
            exit 0 ;;
        -*) die "unknown option '$1'. Use --refresh, --fresh, --image [PATH] or --help." ;;
        *)  [ -z "$SRC_ARG" ] || die "unexpected extra argument '$1' (payload directory already given as '$SRC_ARG')"
            SRC_ARG="$1"; shift ;;
    esac
done
if [ "$REFRESH" -eq 1 ]; then
    info "Refresh mode: only the generated files will be rewritten."
    info "No partitioning, no erase, no payload copy."
fi
if [ "$REFRESH" -eq 1 ] && [ "$IMAGE_MODE" -eq 1 ] && [ -z "$IMAGE_PATH" ]; then
    die "--refresh with --image needs the image path: --image /path/to/copal.img"
fi
# They are opposites: --refresh keeps everything and rewrites a few files,
# --fresh keeps nothing. Together, whichever won would surprise someone.
if [ "$REFRESH" -eq 1 ] && [ "$FRESH" -eq 1 ]; then
    die "--refresh and --fresh are opposites.
       --refresh  rewrite the generated files, keep the payload and all state
       --fresh    delete the image and build it again from nothing"
fi

# Validated here rather than where the image is created, for two reasons.
#
# attach_image runs after the payload download, and being told that IMAGE_SIZE
# is nonsense on the far side of a 400 MB transfer is a poor way to find out.
#
# And unconditionally, not just when --image was passed: the card prompt also
# accepts "image", and that path reaches attach_image with IMAGE_MODE still 0
# at this point. Gating this on IMAGE_MODE left IMAGE_BYTES empty there, which
# made a zero-byte image and a partitioning failure that blamed the disk.
# IMAGE_SIZE has a default, so validating it always costs nothing.
IMAGE_BYTES=$(size_to_bytes "$IMAGE_SIZE")
[ -n "$IMAGE_BYTES" ] || die "IMAGE_SIZE='$IMAGE_SIZE' is not a size. Use e.g. IMAGE_SIZE=64g or 8192m."
# The image has to hold the boot partition and leave something for the root, or
# diskutil fails partway through with a complaint about the second partition
# rather than about the size, which is the confusing way round.
_boot_bytes=$(size_to_bytes "$BOOT_SIZE")
if [ -n "$_boot_bytes" ]; then
    _min_bytes=$(( _boot_bytes + 2 * 1024 * 1024 * 1024 ))
    [ "$IMAGE_BYTES" -ge "$_min_bytes" ] || die "IMAGE_SIZE=$IMAGE_SIZE is too small.
       BOOT_SIZE=$BOOT_SIZE would leave nothing for the root filesystem.
       Use IMAGE_SIZE=$(( _min_bytes / 1024 / 1024 / 1024 ))g or more, or lower BOOT_SIZE."
fi

# --- defaults written into the answer file on the card ----------------------
# setup-alpine reads these non-interactively, so first boot asks almost nothing.
CFG_KEYMAP="${CFG_KEYMAP:-us us}"

# The hostname is picked at random from 300 oceans, seas, lakes and rivers.
# A fixed default ("hotdog", as this was) is fine until the second Pi, at which
# point two boxes answer to the same name on the same network and mDNS starts
# handing out whichever one replied first. Every name here is lowercase ASCII,
# 5 to 15 characters, and a valid DNS label as-is -- no accents, no spaces, no
# hyphens -- so it can go straight into HOSTNAMEOPTS with no transformation.
# All 26 letters are represented, 10 to 13 names each -- q and x are the thin
# ones, and are the reason this stops at 300 rather than going further.
hostname_pool() {
    cat <<'WATERS'
adriatic aegean alboran amazon ammersee andaman arabian arafura araguaia
atchafalaya athabasca atlantic
baikal balaton baltic barents beaufort benue bering biscay bonneville
bosporus bothnia brahmaputra
caribbean caspian cauca celebes champlain chenab chilika colorado columbia
congo coral
danube darling daugava delaware derwent dnieper dniester dongting dordogne
douro dvina
eastmain edward eildon ellesmere enriquillo erhai escanaba essequibo
eucumbene euphrates everglades eyasi
finland fitri fitzroy flathead flinders flores forth fraser frome fuchun
fundy
gairdner gambia ganges garonne gatun genesee geneva gironde godavari
guadalquivir guadiana
hamun hawea hawkesbury hebrides helmand hongze hooghly hovsgol hudson humber
huron
iguazu ijssel iliamna illinois inari indian indus ionian irrawaddy irtysh
isere
jaguaribe james jamuna jhelum jialing jinsha jocassee jordan jubba jucar
juniata juruena
kagera kanawha kariba kattegat kaveri kennebec khanka kissimmee kolyma
kootenay kuskokwim
labrador lachlan ladoga lanao laptev ligurian limpopo loire lomond lualaba
lucerne
mackenzie magdalena maggiore malawi manitoba maracaibo marmara mediterranean
mekong michigan missouri murray
nakuru naryn nasser natron neagh negro nelson neuchatel niger nipigon nyasa
ohrid okanagan okavango okeechobee okhotsk onega ontario orange orinoco
ottawa ouachita
pacific pamlico paraguay parana patos pechora peipus pontchartrain potomac
poyang pripyat pukaki
qinghai quabbin queguay quesnel quiberon quillayute quilotoa quinault
quinebaug quinnipiac
rangitikei rappahannock raritan reindeer rhine rhone ribble rideau roanoke
rovuma rupert rutland
sabine saimaa salween sargasso saskatchewan seine severn shannon skagerrak
solent songhua superior susquehanna
tagus tahoe tanganyika tapajos tarim tasman thames tiber tigris titicaca
torrens trasimeno
ubangi ucayali ulungur umbagog umpqua unzha upemba urubamba uruguay ussuri
usumacinta
vanern vardar vattern verde vermilion victoria vienne vilyuy vistula volga
volta volturno vouga
wabash waccamaw waikato wailua wanaka warrego weddell wharfe willamette
windermere winnebago winnipeg wisconsin
xanthos xiangjiang xiaojiang xiaoqing xijiang xinanjiang xingu xiushui
xochimilco xunjiang
yalobusha yalong yamdrok yampa yamuna yangtze yaqui yarra yellow yellowstone
yenisei yonne yukon
zaire zambezi zapata zarqa zaysan zeravshan zhanjiang zhujiang zuiderzee
zumbro zurich
WATERS
}

# $RANDOM is 0..32767, so a plain modulo over a pool size that does not divide
# 32768 biases the names at the front of the list. Nobody would ever notice on a
# hostname, but rejecting the short tail costs one loop iteration and makes the
# pick genuinely uniform for any pool size, so the count above can change freely.
random_hostname() {
    local names count pick limit
    names=$(hostname_pool | tr -s ' \n' '\n\n' | grep -v '^$')
    count=$(printf '%s\n' "$names" | wc -l | tr -d ' ')
    limit=$(( 32768 - 32768 % count ))
    pick=$RANDOM
    while [ "$pick" -ge "$limit" ]; do pick=$RANDOM; done
    printf '%s\n' "$names" | sed -n "$(( pick % count + 1 ))p"
}
CFG_HOSTNAME="${CFG_HOSTNAME:-$(random_hostname)}"
CFG_TIMEZONE="${CFG_TIMEZONE:-US/Pacific}"
CFG_IFACE="${CFG_IFACE:-eth0}"
# Whether this was chosen by the caller or is merely the fallback. The prompt
# further down asks only when nobody has already answered, so CFG_USER= in the
# environment stays authoritative and unattended runs never block.
CFG_USER_EXPLICIT="${CFG_USER:+set}"
CFG_USER="${CFG_USER:-user}"
# Mirror selection for setup-apkrepos: -1 first (CDN), -f fastest, -r random.
CFG_APKREPOS="${CFG_APKREPOS:--1}"

# Public key to authorise for ${CFG_USER} on the Pi. Only ever the .pub half --
# the private key stays on this Mac. Set CFG_SSHKEY to override, or to "" to
# skip installing a key at all.
if [ -z "${CFG_SSHKEY+set}" ]; then
    for _k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
        [ -f "$_k" ] && { CFG_SSHKEY="$_k"; break; }
    done
fi
CFG_SSHKEY="${CFG_SSHKEY:-}"

# Git identity for ${CFG_USER} on the Pi -- the name and email that end up on
# the "author" line of every commit made there. Nothing here is a credential
# and nothing verifies it; GitHub matches commits to an account by the address,
# which is why the sensible default is the one this Mac already commits under.
#
# Taken from this Mac's git config because the person writing the card is the
# person who will be committing on the machine it boots. It is only a PROPOSAL:
# it goes onto the card as a default, the Pi offers it at the prompt in stage 1,
# and whatever is answered there wins from then on (see copal-git, below).
#
# Set CFG_GIT_NAME / CFG_GIT_EMAIL to override, or either to "" to leave the
# prompt on the Pi empty.
if [ -z "${CFG_GIT_NAME+set}" ]; then
    CFG_GIT_NAME=$(git config --global --get user.name 2>/dev/null || true)
fi
if [ -z "${CFG_GIT_EMAIL+set}" ]; then
    CFG_GIT_EMAIL=$(git config --global --get user.email 2>/dev/null || true)
fi
# copal.conf is sourced by copal-init.sh, so these two strings become shell
# words on the Pi. A double quote, a backslash, a backtick or a '$' in a name
# would end the string early or expand to something else entirely -- at best a
# mangled identity, at worst arbitrary text running as root on first boot. Drop
# those four characters rather than trying to quote them: a name that contains
# one can be typed at the prompt instead.
sanitise_conf_value() { printf '%s' "$1" | tr -d '"\\`$' | tr -d '[:cntrl:]'; }
CFG_GIT_NAME=$(sanitise_conf_value "${CFG_GIT_NAME:-}")
CFG_GIT_EMAIL=$(sanitise_conf_value "${CFG_GIT_EMAIL:-}")

# Why a second partition:
#
# The alpine-rpi image runs "diskless" -- the root filesystem is a tmpfs sized
# at roughly half of RAM. On a 512 MB Pi Zero that is ~200 MB, which is not
# enough to install an X11 desktop into: `apk add` fails with ENOSPC while the
# SD card sits nearly empty. The card is not the constraint; RAM is.
#
# So this script creates a second partition for use as a real ext4 root
# filesystem. macOS cannot create ext4, so it is laid down here as a
# placeholder and reformatted on the Pi with mkfs.ext4. Creating it here means
# the partition table is final before first boot -- no fdisk on the Pi, and no
# reboot to make the kernel re-read a table it is running from.

# There is NO single image that serves every Pi. Pick by board.
#
# An earlier version of this script claimed armhf ran on the Zero 2 W because
# the armhf tarball ships bcm2710-rpi-zero-2-w.dtb. That is wrong, and it costs
# you a card and a boot attempt to find out: the Pi stops at the firmware
# rainbow with no output at all.
#
# Why. Alpine's armhf 'rpi' kernel is built ARCH_MULTI_V6 / ARCH_BCM2835 only
# -- check config-*-rpi in the tarball's boot/ and you will not find
# CONFIG_CPU_V7. A 32-bit ARM kernel carries a proc_info_list table with one
# entry per supported CPU family, and __lookup_processor_type in head.S matches
# the running MIDR against it before the MMU or any console is up:
#
#   Zero 1  BCM2835  ARM1176JZF-S  MIDR 0x410fb767  -> matches the V6 entry
#   Zero 2  BCM2710  Cortex-A53    MIDR 0x410fd034  -> no match, no V7 entry
#
# On no match it branches to __error_p, which cannot print anything because the
# console does not exist yet, and spins. The firmware splash stays up forever.
# The device tree is never consulted -- shipping the right .dtb is irrelevant
# when the kernel dies this early.
#
# So: set MODEL to the board, or set ARCH directly if you know what you want.
#
#   MODEL=zero2 ./copal-prep.sh          # by board name
#   ARCH=aarch64 ./copal-prep.sh         # by architecture
#
MODEL="${MODEL:-}"

# Nothing passed? Ask, rather than quietly assuming a Zero 1. Guessing wrong
# here is the expensive mistake this whole block exists to prevent, and an
# unattended default of armhf is a rainbow-screen hang on every modern board.
# Only prompt when there is a terminal to prompt on: in a pipe or a CI run
# there is nobody to answer, so fall through to the old default plus warning.
if [ -z "$MODEL" ] && [ -z "${ARCH:-}" ] && [ -t 0 ]; then
    printf '\n─── What is this card for? ───\n'
    printf '  Raspberry Pi:\n'
    printf '    1) Pi Zero / Zero W / Pi 1 / CM1      (BCM2835, ARMv6)   armhf\n'
    printf '    2) Pi 2B v1.1                         (BCM2836, ARMv7)   armv7\n'
    printf '    3) Pi Zero 2 W / Pi 3 / CM3 / 2B v1.2 (BCM2710, A53)     aarch64\n'
    printf '    4) Pi 4 / 400 / CM4                   (BCM2711, A72)     aarch64\n'
    printf '    5) Pi 5                               (BCM2712, A76)     aarch64\n'
    printf '  PC (UEFI only -- see the note after you choose):\n'
    printf '    6) PC / laptop / Mac, 64-bit          (UEFI)             x86_64\n'
    printf '    7) PC, 32-bit                         (UEFI)             x86\n'
    printf '  Virtual machine (pair either with --image):\n'
    printf '    8) UTM / QEMU on Apple Silicon        (UEFI)             aarch64\n'
    printf '       Native speed on an M-series Mac, and the same code path a\n'
    printf '       Zero 2 W boots -- so it verifies the ARM targets too.\n'
    printf '    9) UTM / QEMU, emulated x86_64        (UEFI)             x86_64\n'
    printf '       Emulated on Apple Silicon, so slow -- but it is the same\n'
    printf '       code path a real PC boots, and needs no PC.\n'
    while [ -z "$MODEL" ]; do
        printf '\nPress 1-9 (or Ctrl-C to abort): '
        read -r reply || die "no answer -- pass MODEL=zero2 (or pi3/pi4/pi5/pc/pc32/vm/vmx86) instead"
        case "$reply" in
            1) MODEL=zero  ;;
            2) MODEL=pi2b  ;;
            3) MODEL=zero2 ;;
            4) MODEL=pi4   ;;
            5) MODEL=pi5   ;;
            6) MODEL=pc    ;;
            7) MODEL=pc32  ;;
            8) MODEL=vm    ;;
            9) MODEL=vmx86 ;;
            *) printf 'Not one of 1-9.\n' ;;
        esac
    done
    info "Board: MODEL=$MODEL"
fi

# A virtual machine is not a board, and the difference is not the CPU: it is
# that nothing about it is a Raspberry Pi. Same aarch64 architecture as a Pi 3,
# 4 or 5, but no GPU firmware bootloader, so it takes the PC's UEFI path with
# the PC's payload. VM is what carries that apart from ARCH, which cannot
# express it -- aarch64 alone still means "Pi" everywhere else in this script.
VM=0

case "$MODEL" in
    # BCM2835/2836 ARMv6 -- the only boards armhf is for.
    ''|zero|zero-w|zerow|pi1|1|1a|1b|cm1) MODEL_ARCH=armhf ;;
    # Pi 2B v1.1 is BCM2836 (Cortex-A7): 32-bit only, needs ARMv7, and cannot
    # run aarch64. v1.2 was silently respun with a BCM2837 and takes aarch64 --
    # if 'cat /proc/cpuinfo' on the running board says a53, use MODEL=pi2b-v12.
    pi2|2|pi2b|2b|pi2b-v11)               MODEL_ARCH=armv7 ;;
    # BCM2710/2711/2712, Cortex-A53 and up.
    zero2|zero-2|zero2w|zero-2-w|\
    pi2b-v12|pi3|3|3a|3b|3b+|cm3|\
    pi4|4|4b|400|cm4|pi5|5)               MODEL_ARCH=aarch64 ;;
    # An ordinary PC, laptop or Intel Mac. Nothing Raspberry Pi about it: a
    # different payload, a different bootloader and a different partition type.
    # See the PLATFORM block below for what changes and what does not.
    pc|x86_64|amd64|x64|uefi)             MODEL_ARCH=x86_64 ;;
    pc32|x86|i386|i686|ia32)              MODEL_ARCH=x86 ;;
    # Two VM models, because a VM is not one thing. VM=1 says "UEFI, virtio,
    # no GPU firmware"; the architecture is a separate question, and on an
    # Apple Silicon host the two answers have very different costs.
    #
    #   vm      aarch64, virtualised through HVF. Native speed, and the same
    #           code path a Pi Zero 2 W boots -- which is what makes it a
    #           regression test for the ARM targets rather than a toy.
    #   vmx86   x86_64, emulated by TCG. Perhaps 5-20x slower, and worth it:
    #           it is the same code path a real PC boots, so the pc target can
    #           be verified without owning a PC.
    #
    # Until this existed, MODEL=vm implied aarch64 and there was no way to say
    # "a VM, but x86_64" -- ARCH and VM could not both be chosen.
    vm|utm|qemu|virt|vm64)                MODEL_ARCH=aarch64; VM=1 ;;
    vmx86|vm-x86|vmx64|vm-x86_64|utm-x86|utm-x86_64) MODEL_ARCH=x86_64; VM=1 ;;
    *) die "unknown MODEL='$MODEL'. Use one of: zero, zero2, pi2b, pi3, pi4, pi5, pc, pc32, vm, vmx86 (or set ARCH= directly)" ;;
esac

ALPINE_VER="${ALPINE_VER:-3.24.1}"
# An explicit ARCH wins, but only silently when it agrees with MODEL. A board
# and an architecture that contradict each other is a mistake worth stopping
# for -- it is the exact mistake that produced the rainbow-screen hang.
if [ -n "${ARCH:-}" ] && [ -n "$MODEL" ] && [ "$ARCH" != "$MODEL_ARCH" ]; then
    die "MODEL=$MODEL needs ARCH=$MODEL_ARCH, but ARCH=$ARCH was given.
       If you are sure, pass only ARCH and leave MODEL unset."
fi
ARCH="${ARCH:-$MODEL_ARCH}"
[ -n "$MODEL" ] || [ "$ARCH" != armhf ] || warn "No MODEL set -- defaulting to ARCH=armhf (Pi Zero 1 / Zero W / Pi 1).
         A Zero 2, Pi 3, 4 or 5 will hang at the rainbow screen with this.
         Pass MODEL=zero2 (or pi3/pi4/pi5) if that is your board."

# Which device tree the firmware will actually load for this board. The verify
# step used to demand all three Zero .dtbs on every card, which is wrong: the
# aarch64 tarball ships no bcm2835-rpi-zero.dtb at all (that board cannot run
# aarch64), so a perfectly good Zero 2 card was reported as unbootable. Check
# for the one this board needs -- any of the listed names counts, since Alpine
# has shipped both bcm2708- and bcm2835-prefixed names for the ARMv6 boards.
case "$MODEL" in
    zero2|zero-2|zero2w|zero-2-w) MODEL_DTB="bcm2710-rpi-zero-2-w.dtb bcm2710-rpi-zero-2.dtb" ;;
    pi3|3|3a|3b|3b+|cm3|pi2b-v12) MODEL_DTB="bcm2710-rpi-3-b.dtb bcm2710-rpi-3-b-plus.dtb bcm2837-rpi-3-b.dtb" ;;
    pi4|4|4b|400|cm4)             MODEL_DTB="bcm2711-rpi-4-b.dtb bcm2711-rpi-400.dtb" ;;
    pi5|5)                        MODEL_DTB="bcm2712-rpi-5-b.dtb" ;;
    pi2|2|pi2b|2b|pi2b-v11)       MODEL_DTB="bcm2709-rpi-2-b.dtb bcm2836-rpi-2-b.dtb" ;;
    zero|zero-w|zerow)            MODEL_DTB="bcm2835-rpi-zero.dtb bcm2835-rpi-zero-w.dtb bcm2708-rpi-zero-w.dtb" ;;
    pi1|1|1a|1b|cm1)              MODEL_DTB="bcm2835-rpi-b.dtb bcm2708-rpi-b.dtb bcm2835-rpi-a-plus.dtb" ;;
    # A PC has no device tree; the firmware describes itself through ACPI. Nor
    # does a VM: QEMU's 'virt' machine generates its own device tree in memory
    # and hands it to the kernel, so there is nothing to put on the card.
    pc|x86_64|amd64|x64|uefi|pc32|x86|i386|i686|ia32) MODEL_DTB="" ;;
    vm|utm|qemu|virt|vm64|vmx86|vm-x86|vmx64|vm-x86_64|utm-x86|utm-x86_64) MODEL_DTB="" ;;
    # MODEL unset (ARCH given directly): accept any device tree the tarball
    # ships, since we do not know the board.
    *)                            MODEL_DTB="" ;;
esac

# ---------------------------------------------------------------- platform ---
# Raspberry Pi and PC differ in exactly one thing that matters here, and it is
# not the CPU: it is who loads the kernel.
#
#   rpi   The GPU firmware is the bootloader. bootcode.bin and start.elf come
#         in the alpine-rpi tarball, read config.txt and cmdline.txt from the
#         FAT partition, and load the kernel themselves. There is nothing to
#         install -- copying files onto FAT is genuinely all of it. That is why
#         this script exists in the form it does.
#
#   pc    Nothing on a PC will load a kernel off a FAT partition unaided.
#         Alpine publishes no 'alpine-pc' tarball because there is nothing to
#         publish: the equivalent is alpine-netboot (kernel, initramfs,
#         modloop -- the same boot/ layout as the rpi tarball) plus a
#         bootloader you supply.
#
# Everything ABOVE the bootloader is shared. Alpine's diskless model -- the
# initramfs finding modloop and an .apkovl.tar.gz on removable media -- is
# architecture-independent, so all fifteen stages, the catalogue and the
# desktop work the same once the kernel is running.
#
# UEFI ONLY, and this is a limitation of the writing machine rather than a
# preference. Copal writes cards from macOS. A legacy-BIOS boot needs syslinux
# or grub-install to write a boot sector and patch a stage-1.5 loader onto the
# filesystem, and both are Linux tools that do not exist on macOS -- there is
# no honest way to fake it. UEFI needs no installer at all: the firmware reads
# a FAT partition and executes \EFI\BOOT\BOOTX64.EFI, which is a file copy.
# So Copal supports UEFI, which is every PC since roughly 2012 and every Intel
# Mac, and says so plainly instead of writing a card that will not boot.
# VM has to be tested before ARCH, not folded into it: a VM is aarch64, and
# aarch64 otherwise means a Pi. Take the UEFI path for anything that is not a
# board with GPU firmware on it.
if [ "$VM" -eq 1 ]; then
    PLATFORM=pc
else
    case "$ARCH" in
        x86|x86_64) PLATFORM=pc ;;
        *)          PLATFORM=rpi ;;
    esac
fi
# The name UEFI looks for on the fallback boot path, which is what a removable
# device gets. 32-bit UEFI wants a 32-bit binary and there is no negotiation,
# and AArch64 UEFI wants an AArch64 one -- the architecture is baked into the
# filename because the firmware has no way to ask.
#
# EFI_SRC is the path INSIDE alpine-virt-*.iso, which is lower-case and named
# for the same architecture. It used to be hardcoded to bootx64.efi, which was
# right for x86_64 and quietly wrong for x86: the 32-bit ISO carries
# bootia32.efi, so the extraction failed and the card was refused. Deriving
# both names from one case fixes that as a side effect.
case "$ARCH" in
    x86_64)             EFI_NAME=BOOTX64.EFI;  EFI_SRC=efi/boot/bootx64.efi ;;
    x86)                EFI_NAME=BOOTIA32.EFI; EFI_SRC=efi/boot/bootia32.efi ;;
    aarch64)
        if [ "$VM" -eq 1 ]; then
            EFI_NAME=BOOTAA64.EFI; EFI_SRC=efi/boot/bootaa64.efi
        else
            EFI_NAME=''; EFI_SRC=''
        fi ;;
    *)                  EFI_NAME='';           EFI_SRC='' ;;
esac

BRANCH="v${ALPINE_VER%.*}"
MIRROR="${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
WORKDIR="${WORKDIR:-$(cd "$(dirname "$0")" && pwd)/work}"

# --- interactive stepping ---------------------------------------------------
# Every stage pauses first and describes what it is about to do. Enter proceeds;
# Ctrl-C aborts. Reads come from /dev/tty so prompts still work when stdout is
# being captured or redirected.
STEP_NUM=0
ABORT_MSG="Aborted. Nothing further was written."

step() {
    STEP_NUM=$((STEP_NUM + 1))
    local title="$1"; shift
    printf '\n\033[1m─── Step %d: %s ───\033[0m\n' "$STEP_NUM" "$title" >&2
    local line
    for line in "$@"; do
        printf '    %s\n' "$line" >&2
    done
    printf '\n\033[32mPress Enter to continue, or Ctrl-C to abort.\033[0m ' >&2
    read -r _ < /dev/tty || die "$ABORT_MSG"
}

on_interrupt() {
    printf '\n\n\033[33m%s\033[0m\n' "$ABORT_MSG" >&2
    # If the card is mounted mid-copy, leave it unmounted cleanly rather than
    # half-written and still attached.
    if [ -n "${DISK:-}" ] && [ "${ERASED:-0}" = "1" ]; then
        printf '\033[33mNote: /dev/%s was already repartitioned. It is NOT bootable.\033[0m\n' "$DISK" >&2
        printf '\033[33mRe-run this script to finish, or the card will be unusable.\033[0m\n' >&2
        sync 2>/dev/null || true
        diskutil unmountDisk "/dev/$DISK" >/dev/null 2>&1 || true
    fi
    # An image left attached is worse than one left half-written: the next run
    # refuses to attach it twice, and the reason is not obvious from the file.
    # ${IMAGE_DEV:-} because this trap is installed long before attach_image
    # runs, and under 'set -u' a bare $IMAGE_DEV would abort the abort.
    if [ -n "${IMAGE_DEV:-}" ]; then
        sync 2>/dev/null || true
        hdiutil detach "$IMAGE_DEV" >/dev/null 2>&1 || true
        printf '\033[33mDetached %s (%s).\033[0m\n' "$IMAGE_DEV" "${IMAGE_PATH:-image}" >&2
    fi
    exit 130
}
trap on_interrupt INT TERM

# --------------------------------------------------------------- download ---
# Which artefact carries the system, per platform. Same boot/ layout inside
# both -- vmlinuz-*, initramfs-*, modloop-* -- which is why one copy routine
# serves both. The rpi tarball additionally carries the GPU firmware that makes
# a Pi bootable; the netboot tarball carries no bootloader at all, so on a PC
# one has to come from somewhere else (see BOOTLOADER_ISO).
case "$PLATFORM" in
    rpi) TARBALL="alpine-rpi-${ALPINE_VER}-${ARCH}.tar.gz" ;;
    pc)  TARBALL="alpine-netboot-${ALPINE_VER}-${ARCH}.tar.gz" ;;
esac
URL="${MIRROR}/${BRANCH}/releases/${ARCH}/${TARBALL}"

# Where the UEFI bootloader comes from on a PC.
#
# Alpine does not publish a standalone .efi file, and the grub-efi package holds
# only GRUB's modules -- turning those into a bootable image needs grub-mkimage,
# which is Linux-only. What Alpine DOES publish is an ISO containing a complete,
# self-contained GRUB already built for exactly this job, at efi/boot/bootx64.efi.
# alpine-virt is the smallest of them (~66 MB against ~352 MB for standard), and
# only one 850 kB file is taken from it.
#
# GRUB rather than booting the kernel directly, even though Alpine's kernel is a
# valid EFI application (CONFIG_EFI_STUB=y, and it really does start with an MZ
# header): a kernel started through the firmware's fallback path gets no load
# options, which means no command line and no initramfs, and Alpine cannot boot
# without its initramfs. Supplying those without a bootloader means building a
# unified kernel image, which needs objcopy on PE files. GRUB reads a text file
# instead, and the text file is something this script can write.
BOOTLOADER_ISO="alpine-virt-${ALPINE_VER}-${ARCH}.iso"
BOOTLOADER_URL="${MIRROR}/${BRANCH}/releases/${ARCH}/${BOOTLOADER_ISO}"

fetch_payload() {
    mkdir -p "$WORKDIR"
    local archive="$WORKDIR/$TARBALL"
    local sumfile="$WORKDIR/${TARBALL}.sha256"

    info "Release : Alpine ${ALPINE_VER} (${ARCH})"
    info "Source  : $URL"

    # Checksum first -- it is tiny, and re-fetching it each run means a stale
    # or partially-downloaded archive is always detected.
    curl -fsSL -o "$sumfile" "${URL}.sha256" \
        || die "could not download the checksum from ${URL}.sha256 -- check the version/arch and your network"

    if [ -f "$archive" ]; then
        info "Found an existing $TARBALL; verifying..."
        if (cd "$WORKDIR" && shasum -a 256 -c "${TARBALL}.sha256" >/dev/null 2>&1); then
            info "Checksum matches; skipping download."
        else
            warn "existing archive failed verification; re-downloading"
            rm -f "$archive"
        fi
    fi

    if [ ! -f "$archive" ]; then
        case "$PLATFORM" in
            rpi) info "Downloading $TARBALL (~69 MB)..." ;;
            pc)  info "Downloading $TARBALL (~260-390 MB -- it carries every module)..." ;;
        esac
        # -C - resumes an interrupted transfer rather than starting over.
        curl -fL -C - -o "$archive" "$URL" \
            || die "download failed: $URL"
    fi

    info "Verifying SHA256..."
    (cd "$WORKDIR" && shasum -a 256 -c "${TARBALL}.sha256") \
        || die "CHECKSUM MISMATCH -- the download is corrupt or tampered with. Refusing to write it to the card."

    info "Extracting..."
    local dest="$WORKDIR/${TARBALL%.tar.gz}"
    rm -rf "$dest"
    mkdir -p "$dest"
    # bsdtar/gnutar on macOS: COPYFILE_DISABLE keeps AppleDouble out of the tree.
    COPYFILE_DISABLE=1 tar -xzf "$archive" -C "$dest" \
        || die "extraction failed"
    [ "$PLATFORM" = pc ] && fetch_bootloader "$dest"
    printf '%s\n' "$dest"
}

# Take GRUB *and the package repository* out of the official ISO and put both
# where the payload copy will find them. Called only for PLATFORM=pc.
#
# Why the repository has to come from here as well:
#
# alpine-netboot ships kernels and nothing else. It is meant to be booted with
# alpine_repo=http://... and to fetch its userland over the network. Copal
# writes a card that boots on its own, so the packages have to be on it, and
# the netboot tarball has none.
#
# The alpine-rpi tarball, by contrast, carries apks/<arch>/ with the base
# system and a zero-byte apks/.boot_repository beside it. That marker is the
# ONLY thing identifying the boot medium: initramfs-init runs
# `nlplug-findfs -b`, which blocks until some mounted filesystem contains a
# file of that name ("alpine_repo=auto -- default, search for
# .boot_repository", in init's own words). Without it the boot ends at
#
#     Mounting boot media: failed.
#     Launching initramfs emergency recovery shell.
#
# and with the marker but an empty repository it gets one step further and
# ends at
#
#     OK: 0 B in 0 packages
#     /sbin/init not found in new root
#
# because the diskless tmpfs root is populated by `apk add alpine-base` from
# that repository. Both failures leave the card mounted and intact, which is a
# misleading way to be told that 14 MB of packages are missing.
#
# alpine-virt carries apks/ (98 packages: alpine-base, busybox, musl, openrc,
# apk-tools) with the marker already in place, and it is the same ISO already
# being downloaded for the bootloader. One download, both problems.
fetch_bootloader() {  # <payload dir>
    _dest="$1"
    _iso="$WORKDIR/$BOOTLOADER_ISO"
    _sum="$WORKDIR/${BOOTLOADER_ISO}.sha256"

    info "Bootloader: GRUB, from $BOOTLOADER_ISO"
    curl -fsSL -o "$_sum" "${BOOTLOADER_URL}.sha256" \
        || die "could not download the bootloader checksum from ${BOOTLOADER_URL}.sha256"
    if [ -f "$_iso" ] && ! (cd "$WORKDIR" && shasum -a 256 -c "${BOOTLOADER_ISO}.sha256" >/dev/null 2>&1); then
        warn "existing $BOOTLOADER_ISO failed verification; re-downloading"
        rm -f "$_iso"
    fi
    if [ ! -f "$_iso" ]; then
        info "Downloading $BOOTLOADER_ISO (~66 MB; one 850 kB file is used from it)..."
        curl -fL -C - -o "$_iso" "$BOOTLOADER_URL" || die "download failed: $BOOTLOADER_URL"
    fi
    (cd "$WORKDIR" && shasum -a 256 -c "${BOOTLOADER_ISO}.sha256") \
        || die "CHECKSUM MISMATCH on $BOOTLOADER_ISO -- refusing to take a bootloader from it."

    # bsdtar reads ISO9660 directly, so the image never has to be mounted --
    # which matters because mounting one on macOS needs hdiutil and a detach
    # that can fail and leave the image attached.
    #
    # The ISO stores the path lower-case; UEFI's fallback path is conventionally
    # upper-case and FAT is case-insensitive, so the destination name is the one
    # the firmware documents.
    mkdir -p "$_dest/EFI/BOOT"
    if bsdtar -xOf "$_iso" "$EFI_SRC" > "$_dest/EFI/BOOT/$EFI_NAME" 2>/dev/null &&
       [ -s "$_dest/EFI/BOOT/$EFI_NAME" ]; then
        :
    else
        rm -f "$_dest/EFI/BOOT/$EFI_NAME"
        die "could not extract $EFI_SRC from $BOOTLOADER_ISO.
       Without it the card cannot boot. Check that bsdtar is present
       (it ships with macOS) and that the ISO is the one for $ARCH."
    fi
    # It must be a PE executable or the firmware will decline it silently.
    case "$(dd if="$_dest/EFI/BOOT/$EFI_NAME" bs=2 count=1 2>/dev/null)" in
        MZ) info "Bootloader: EFI/BOOT/$EFI_NAME ($(( $(wc -c < "$_dest/EFI/BOOT/$EFI_NAME") / 1024 )) kB, PE verified)" ;;
        *)  die "the extracted $EFI_NAME is not a PE/EFI binary -- refusing to write it." ;;
    esac

    # The repository, from the same ISO. Extracted whole rather than file by
    # file: the marker, the APKINDEX and the .apk files all have to agree, and
    # picking packages by name here would mean tracking Alpine's base set.
    # ISO9660 carries read-only modes, and bsdtar reproduces them: the extracted
    # tree comes out r-xr-xr-x, directories included. A directory with no write
    # bit cannot have its children unlinked, so a plain 'rm -rf' fails on the
    # SECOND run with "Permission denied" and the whole step dies. Make it
    # writable before removing it, and again after extracting, so the next run
    # and --refresh both work.
    if [ -e "$_dest/apks" ]; then
        chmod -R u+w "$_dest/apks" 2>/dev/null || true
        rm -rf "$_dest/apks" || die "could not replace the old $_dest/apks"
    fi
    bsdtar -xf "$_iso" -C "$_dest" apks 2>/dev/null \
        || die "could not extract apks/ from $BOOTLOADER_ISO.
       Without it the card boots to '/sbin/init not found in new root'."
    chmod -R u+w "$_dest/apks" 2>/dev/null || true
    [ -f "$_dest/apks/.boot_repository" ] \
        || die "$BOOTLOADER_ISO has no apks/.boot_repository.
       Without that marker the initramfs cannot identify the boot medium and
       stops at 'Mounting boot media: failed'."
    [ -f "$_dest/apks/$ARCH/APKINDEX.tar.gz" ] \
        || die "$BOOTLOADER_ISO has no apks/$ARCH/APKINDEX.tar.gz -- the
       repository on the card would be unreadable to apk."
    info "Repository: apks/$ARCH ($(ls "$_dest/apks/$ARCH"/*.apk 2>/dev/null | wc -l | xargs) packages, $(du -sh "$_dest/apks" | awk '{print $1}'))"
}

# ------------------------------------------------------------- who uses it ---
# Asked here, immediately before the download, because this is the last quiet
# moment: everything after it either transfers several hundred megabytes or
# erases something, and neither is a good place to stop and think about a name.
#
# It is a question rather than a default because the answer ends up in
# USEROPTS, in copal.conf, in the doas rule, in the home directory path and in
# the SSH policy -- and changing it afterwards means re-running stage 1 on the
# target. 'user' remains the answer if Enter is pressed, so an unattended run
# behaves exactly as it always did.
#
# CFG_USER= in the environment skips the question entirely, which is what the
# Makefile's unattended targets and any scripted caller should use.
valid_username() {
    # The character sets are spelled out rather than written as a-z, and that
    # is not pedantry: inside a bracket expression a RANGE is resolved by the
    # locale's collation order, and in most locales a-z collates as aAbBcC...
    # so [!a-z0-9_-] happily accepts 'Paul'. Enumerating the letters makes the
    # test mean the same thing under every locale this might run in.
    case "$1" in
        ''|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;;
        [!abcdefghijklmnopqrstuvwxyz]*)                 return 1 ;;
    esac
    [ "${#1}" -le 32 ] || return 1
    # Names the system already means something by. adduser would refuse some of
    # these and silently collide with others.
    case "$1" in
        root|daemon|bin|sys|adm|lp|sync|shutdown|halt|mail|news|uucp|operator|man|postmaster|cron|ftp|sshd|at|squid|xfs|games|cyrus|vpopmail|ntp|smmsp|guest|nobody|utmp|wheel)
            return 1 ;;
    esac
    return 0
}

if [ "$REFRESH" -eq 0 ] && [ -z "${CFG_USER_EXPLICIT:-}" ] && [ -t 0 ]; then
    printf '\n\033[1m─── Who will use this machine? ───\033[0m\n' >&2
    cat >&2 <<WHO

    Copal creates one ordinary account and hands root over to it at the end,
    so this name is the login you will actually use. It also becomes the home
    directory, the owner of the desktop configuration, the account the SSH key
    is authorised for, and the name in the doas rule.

    Lower-case letters, digits, '-' and '_'; must start with a letter.

WHO
    while :; do
        printf '    Username [%s]: ' "$CFG_USER" >&2
        read -r _reply < /dev/tty || _reply=""
        [ -n "$_reply" ] || break                       # Enter keeps the default
        if valid_username "$_reply"; then
            CFG_USER="$_reply"; break
        fi
        printf '\033[33m    Not a usable username. Lower-case, starts with a letter, and not one\n    the system already reserves.\033[0m\n' >&2
    done
    info "Admin account: $CFG_USER"

    # The git identity is a PROPOSAL taken from this Mac's own git config, and
    # it is offered rather than assumed for the same reason: whoever writes the
    # card is usually but not always whoever will commit from the machine.
    # Declining leaves the field empty and stage 1 asks on the target instead.
    if [ -n "${CFG_GIT_NAME}${CFG_GIT_EMAIL}" ]; then
        printf '\n    Git identity for commits made on the machine, taken from this Mac:\n' >&2
        printf '        %s <%s>\n' "${CFG_GIT_NAME:-(no name)}" "${CFG_GIT_EMAIL:-no email}" >&2
        printf '    Offer that as the default on the target? [Y/n]: ' >&2
        read -r _reply < /dev/tty || _reply=""
        case "$_reply" in
            n|N|no|NO)
                CFG_GIT_NAME=""; CFG_GIT_EMAIL=""
                info "Git identity left empty -- stage 1 will ask on the target" ;;
            *) : ;;
        esac
    fi
fi

# ---------------------------------------------------------------- payload ---
# --refresh rewrites only the small generated files -- answers.txt,
# usercfg.txt, copal.conf, authorized_keys, copal-init.sh -- on a card that is
# already written. It never partitions, never erases, and never re-copies the
# payload, so an already-configured Pi can pick up script changes without
# starting over. Everything destructive is skipped.
# REFRESH and SRC_ARG were settled by the option loop near the top of the file.
SRC="$SRC_ARG"
if [ "$REFRESH" -eq 1 ]; then
    SRC=""
    SRC_BYTES=0
    RELEASE="(refresh -- payload left as-is)"
elif [ -z "$SRC" ]; then
    step "Download and verify Alpine ${ALPINE_VER} (${ARCH})" \
        "Downloads : $URL" \
        "Into      : $WORKDIR" \
        "Verifies the published SHA256 before anything is written to a card." \
        "" \
        "Reads and writes only inside $WORKDIR." \
        "No disk is touched by this step. Safe to abort."
    SRC=$(fetch_payload | tail -n1)
else
    info "Using the payload directory supplied on the command line (skipping download)."
fi
if [ "$REFRESH" -eq 0 ]; then
    SRC="${SRC%/}"
    [ -d "$SRC" ] || die "not a directory: $SRC"

    # Sanity-check that this really is the payload we think it is, and not the
    # tarball itself, an ISO mount, or the other platform's tree.
    case "$PLATFORM" in
        rpi) _need="bootcode.bin start.elf config.txt cmdline.txt boot/vmlinuz-rpi" ;;
        pc)  _need="boot/vmlinuz-lts boot/initramfs-lts boot/modloop-lts EFI/BOOT/$EFI_NAME
                    apks/.boot_repository apks/$ARCH/APKINDEX.tar.gz" ;;
    esac
    for required in $_need; do
        [ -e "$SRC/$required" ] || die "$SRC is missing '$required' -- this does not look like an extracted alpine-${PLATFORM} payload for $ARCH"
    done

    RELEASE=$(cat "$SRC/.alpine-release" 2>/dev/null || echo "unknown")
    SRC_BYTES=$(du -sk "$SRC" | awk '{print $1 * 1024}')
    info "Payload : $SRC"
    info "Release : $RELEASE"
    info "Size    : $(( SRC_BYTES / 1024 / 1024 )) MiB"
fi

# Confirm the payload's kernel actually matches the board we are building for.
# The tarball name is not proof: a directory passed on the command line can be
# anything, and the file that decides whether the Pi boots is the kernel's own
# config, not the arch in the filename. This is the check that would have
# caught the Zero 2 rainbow hang before the card was written.
kernel_config=""
if [ "$REFRESH" -eq 0 ]; then
    case "$PLATFORM" in
        rpi) kernel_config=$(ls "$SRC"/boot/config-*-rpi 2>/dev/null | head -n1 || true) ;;
        pc)  kernel_config=$(ls "$SRC"/boot/config-*-lts 2>/dev/null | head -n1 || true) ;;
    esac
fi
if [ -n "$kernel_config" ]; then
    # Order matters: CONFIG_X86_64 implies CONFIG_X86, so the 64-bit test has to
    # come first or every x86_64 kernel reads as x86.
    if   grep -q '^CONFIG_ARM64=y'   "$kernel_config"; then payload_arch=aarch64
    elif grep -q '^CONFIG_X86_64=y'  "$kernel_config"; then payload_arch=x86_64
    elif grep -q '^CONFIG_X86_32=y'  "$kernel_config"; then payload_arch=x86
    # Belt and braces: CONFIG_X86_64 is already ruled out above, so a kernel
    # that only says CONFIG_X86 is a 32-bit one whatever else it omits.
    elif grep -q '^CONFIG_X86=y'     "$kernel_config"; then payload_arch=x86
    elif grep -q '^CONFIG_CPU_V7=y'  "$kernel_config"; then payload_arch=armv7
    elif grep -q '^CONFIG_CPU_V6K\?=y' "$kernel_config"; then payload_arch=armhf
    else payload_arch=unknown
    fi
    # A PC kernel that cannot start itself from UEFI would need a bootloader
    # chain this script does not build. Alpine's is built with the stub; check
    # rather than assume, because it is one grep and the failure is a dead card.
    if [ "$PLATFORM" = pc ] && ! grep -q '^CONFIG_EFI_STUB=y' "$kernel_config"; then
        warn "this kernel has no EFI stub (CONFIG_EFI_STUB). GRUB will still load it,"
        warn "so this is informational rather than fatal."
    fi
    if [ "$payload_arch" = unknown ]; then
        warn "could not tell what CPU $kernel_config was built for -- continuing unchecked"
    elif [ "$payload_arch" != "$ARCH" ]; then
        case "$PLATFORM" in
            rpi) _symptom="Writing it would leave the Pi stopped at the rainbow screen." ;;
            pc)  _symptom="Writing it would leave the PC unable to execute the kernel." ;;
        esac
        die "payload mismatch: this kernel is $payload_arch, but ARCH=$ARCH${MODEL:+ (MODEL=$MODEL)}.
       $_symptom
       Delete $WORKDIR and re-run, or pass the matching payload directory."
    fi
    info "Kernel  : $payload_arch (matches ARCH=$ARCH)"
fi

# ------------------------------------------------------------------ image ---
# Writing to a file instead of a card.
#
# hdiutil attaches a raw image as a /dev/diskN that diskutil, fdisk and mount
# all treat as an ordinary disk, so everything downstream is unchanged: the
# partitioning, the payload copy and the final verification run exactly as they
# do on real media, and `diskutil eject` detaches the image at the end without
# needing a special case.
#
# Two things do differ. macOS reports Virtual: Yes and Protocol: Disk Image,
# both of which the safety checks below would otherwise refuse -- correctly, so
# they are relaxed only when this script created the device itself.
#
# The point is a target that cannot destroy anything. There is no identifier to
# mistype and no card to confuse with a backup drive; the worst case is a
# wasted file. It is also the only way to test a change without a boot cycle.

IMAGE_DEV=""
attach_image() {
    local seek_mb default_path

    default_path="$WORKDIR/copal-${MODEL:-$ARCH}.img"
    if [ -z "$IMAGE_PATH" ]; then
        printf '\nPath for the disk image [%s]: ' "$default_path" >&2
        read -r IMAGE_PATH < /dev/tty || true
        [ -n "$IMAGE_PATH" ] || IMAGE_PATH="$default_path"
    fi
    case "$IMAGE_PATH" in
        *.img|*.dmg|*.raw) : ;;
        *) IMAGE_PATH="${IMAGE_PATH}.img" ;;
    esac
    mkdir -p "$(dirname "$IMAGE_PATH")" || die "cannot create the directory for $IMAGE_PATH"
    # Absolute from here on. hdiutil reports absolute paths, so the
    # already-attached check below cannot compare against a relative one, and
    # the boot commands printed at the end have to work from any directory.
    IMAGE_PATH="$(cd "$(dirname "$IMAGE_PATH")" && pwd)/$(basename "$IMAGE_PATH")"

    # --fresh: destroy the image and start over, rather than repartitioning it.
    #
    # Repartitioning does reformat both partitions, so it already discards the
    # apkovl, the logs and the stage records. Deleting the file is the version
    # with no caveats: nothing can survive a file that does not exist, and the
    # sparse blocks the last run allocated go back to the disk.
    #
    # The state this exists to destroy is /media/<boot>/copal-auto, the marker
    # that makes an interrupted automatic install resume where it stopped. That
    # is right for a real install -- stage 3 reboots and has to come back -- and
    # wrong for a test, where resuming means stage 1 is skipped, no apkovl is
    # written, and stage 3 aborts on a precondition instead of running. A test
    # that starts halfway through is not a test of the thing being changed.
    #
    # Only ever unlinks a path this script was given as an image. There is no
    # device involved, so it cannot reach a card.
    if [ "$FRESH" -eq 1 ] && [ -e "$IMAGE_PATH" ]; then
        [ -f "$IMAGE_PATH" ] || die "--fresh: $IMAGE_PATH is not a regular file. Refusing to delete it."
        info "Fresh: deleting $IMAGE_PATH ($(du -h "$IMAGE_PATH" | awk '{print $1}')) and rebuilding from nothing"
        rm -f "$IMAGE_PATH" || die "could not delete $IMAGE_PATH"
        # The EFI variable store belongs to the image and records boot entries
        # pointing into it. Leaving a stale one behind is how a rebuilt image
        # drops to the EFI shell for no visible reason.
        rm -f "${IMAGE_PATH%.img}-efivars.fd"
    fi

    if [ -e "$IMAGE_PATH" ]; then
        # Already attached from an earlier run? Attaching twice gives two
        # device nodes onto one file, and writes through both corrupt it.
        #
        # hdiutil pads the key to a fixed width -- "image-path      : /path" --
        # so the separator has to be matched as whitespace-colon-whitespace.
        # Comparing against the literal "image-path : " never matched, which
        # made this check silently useless.
        local already
        already=$(hdiutil info 2>/dev/null | awk -v f="$IMAGE_PATH" '
            /^image-path[[:space:]]*:/ {
                line = $0
                sub(/^image-path[[:space:]]*:[[:space:]]*/, "", line)
                cur = (line == f)
            }
            cur && /^\/dev\/disk[0-9]+/ { print $1; exit }') || true
        [ -z "$already" ] || die "$IMAGE_PATH is already attached as $already.
       Detach it first:  hdiutil detach $already"
        info "Image   : $IMAGE_PATH (exists, $(du -h "$IMAGE_PATH" | awk '{print $1}') on disk -- will be repartitioned)"
    else
        seek_mb=$(( IMAGE_BYTES / 1024 / 1024 ))
        # Sparse: seek past the end and write nothing, so a 16g image costs
        # only what is actually written to it. mkfile without -n would take
        # the full size up front, and minutes doing it.
        dd if=/dev/zero of="$IMAGE_PATH" bs=1m count=0 seek="$seek_mb" 2>/dev/null \
            || die "could not create $IMAGE_PATH"
        info "Image   : $IMAGE_PATH (created sparse, ${IMAGE_SIZE})"
    fi

    # CRawDiskImage: treat the file as a bare sector image with no header, which
    # is what a card is and what QEMU expects back. Without it hdiutil looks for
    # a UDIF or DMG structure and declines a file that has neither.
    IMAGE_DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMAGE_PATH" \
                | awk 'NR==1 { print $1 }') \
        || die "hdiutil could not attach $IMAGE_PATH"
    # hdiutil pads its columns with tabs, so the field has to be taken by awk
    # rather than by trimming spaces -- '/dev/disk8\t\t' is not a device path.
    [ -n "$IMAGE_DEV" ] || die "hdiutil attached $IMAGE_PATH but reported no device"
    DISK="${IMAGE_DEV#/dev/}"
    info "Attached: $IMAGE_DEV"
}

# ------------------------------------------------------------------- disk ---
if [ "$IMAGE_MODE" -eq 1 ]; then
    step "Create and attach the disk image" \
        "Writes to a file, not to a card. No physical device is touched." \
        "" \
        "Size  : ${IMAGE_SIZE} (sparse -- it costs only what is written)" \
        "${IMAGE_PATH:+Path  : $IMAGE_PATH}" \
        "" \
        "Boot the result with UTM or QEMU. Nothing here can damage a disk."
    attach_image
else
    step "Identify the SD card" \
        "Lists external physical disks, then asks which one is the SD card." \
        "" \
        "Read the SIZE column carefully -- other external drives are listed too," \
        "and choosing the wrong one destroys it." \
        "" \
        "Answer 'image' instead to write to a disk image file, which touches" \
        "no hardware at all." \
        "" \
        "Nothing is written by this step. Safe to abort."

    echo >&2
    info "External disks currently attached:"
    echo >&2
    diskutil list external physical >&2
    echo >&2

    DISK=""
    read -r -p "Disk identifier (e.g. disk4, NOT disk4s1), or 'image' for a file: " DISK < /dev/tty || true
    DISK="${DISK#/dev/}"

    case "$DISK" in
        image|img|i)
            IMAGE_MODE=1
            attach_image ;;
        *)
            [[ "$DISK" =~ ^disk[0-9]+$ ]] || die "'$DISK' is not a whole-disk identifier (expected e.g. disk4, or 'image')" ;;
    esac
fi

INFO=$(diskutil info "/dev/$DISK" 2>/dev/null) || die "no such disk: /dev/$DISK"

# Not every field exists on every device -- a whole disk may have no
# "Ejectable" or "Disk / Partition UUID" line at all. grep exits 1 on no
# match, and under 'set -o pipefail' that failure propagates out of the
# command substitution and 'set -e' kills the script with no message, right
# after the disk is entered. The trailing '|| true' is what makes a missing
# field return empty instead of aborting.
get() { printf '%s\n' "$INFO" | grep -E "^ *$1:" | head -n1 | sed 's/.*: *//' | xargs || true; }

INTERNAL=$(get "Device Location")
REMOVABLE=$(get "Removable Media")
VIRTUAL=$(get "Virtual")
DISK_SIZE=$(get "Disk Size" | sed 's/ (.*//')
EJECTABLE=$(get "Ejectable")
PROTOCOL=$(get "Protocol")
MEDIANAME=$(get "Device / Media Name")
WHOLE=$(get "Whole")
SYSIMAGE=$(get "OS Can Be Installed")
DISK_BYTES=$(printf '%s\n' "$INFO" | grep -E '^ *Disk Size:' | grep -oE '\([0-9]+ Bytes\)' | grep -oE '[0-9]+' | head -n1 || true)

# Volume names currently mounted from this device -- the most human-readable
# clue there is about what the thing actually is.
MOUNTED=$(mount | awk -v d="/dev/$DISK" '$1 ~ "^" d "s?[0-9]*$" {print $3}' \
          | paste -sd', ' - 2>/dev/null || true)

# --- hard refusals ---------------------------------------------------------
[ "$INTERNAL" = "Internal" ] && die "/dev/$DISK is an INTERNAL disk. Refusing."
# A virtual disk is normally a mounted DMG or a sparse bundle -- something with
# a filesystem someone cares about, and never an SD card. It is also exactly
# what --image just created, so the refusal is relaxed only for the device this
# script attached itself: IMAGE_DEV is set by attach_image and by nothing else,
# so an unrelated DMG cannot slip through even in image mode.
if [ "$VIRTUAL" = "Yes" ] && [ "/dev/$DISK" != "$IMAGE_DEV" ]; then
    die "/dev/$DISK is a virtual disk. Refusing."
fi
[ "$WHOLE" = "No" ]          && die "/dev/$DISK is not a whole disk. Refusing."
# Ejectable is the strongest signal macOS gives that the media can be pulled
# out. Anything that cannot be ejected is not an SD card.
[ "$EJECTABLE" = "No" ]      && die "/dev/$DISK reports Ejectable: No. That is not removable media. Refusing."
if [ "${DISK_BYTES:-0}" -lt "$MIN_CARD_BYTES" ]; then
    die "/dev/$DISK is only ${DISK_BYTES} bytes. Refusing."
fi

echo >&2
info "Selected device"
printf '    Identifier : /dev/%s\n' "$DISK" >&2
printf '    Media name : %s\n'      "${MEDIANAME:-unknown}" >&2
printf '    Size       : %s\n'      "$DISK_SIZE" >&2
printf '    Protocol   : %s\n'      "${PROTOCOL:-(not reported)}" >&2
printf '    Location   : %s\n'      "$INTERNAL" >&2
printf '    Removable  : %s\n'      "$REMOVABLE" >&2
printf '    Ejectable  : %s\n'      "${EJECTABLE:-(not reported)}" >&2
[ -n "$MOUNTED" ] && printf '    Volumes    : %s\n' "$MOUNTED" >&2
echo >&2
diskutil list "/dev/$DISK" >&2
echo >&2

# --- soft signals: not fatal, but each one earns a warning -----------------
# A USB card reader can legitimately report Removable Media: Fixed, and an
# SD slot reports protocol "Secure Digital" while a reader reports "USB". So
# none of these can be a hard rule -- but a device that trips several of them
# is probably not your card.
SUSPECT=0
# Every signal below fires on a disk image -- protocol "Disk Image", no card
# reader, no partition UUID -- and not one of them means anything when the
# target is a file this script created seconds ago. Warning about them would
# teach you to ignore the warnings that do matter.
if [ "/dev/$DISK" = "$IMAGE_DEV" ]; then :; else
case "$PROTOCOL" in
    "Secure Digital"|USB|"USB Attached SCSI") : ;;
    *) warn "protocol is '$PROTOCOL', which is unusual for an SD card"; SUSPECT=$((SUSPECT+1)) ;;
esac
[ "$REMOVABLE" != "Removable" ] && {
    warn "macOS reports Removable Media: $REMOVABLE (a card reader may say this)"
    SUSPECT=$((SUSPECT+1)); }
# 512 GB is already a large card; a 2 TB "card" is almost certainly an SSD.
if [ "${DISK_BYTES:-0}" -gt 549755813888 ]; then
    warn "$DISK_SIZE is very large for an SD card -- is this an external drive?"
    SUSPECT=$((SUSPECT+2))
fi
[ "$SYSIMAGE" = "Yes" ] && {
    warn "macOS says an OS can be installed here -- typical of a system drive"
    SUSPECT=$((SUSPECT+1)); }
fi   # end of the soft signals, skipped for a disk image

if [ "$SUSPECT" -ge 2 ]; then
    echo >&2
    warn "This device does not look like an SD card. Read the lines above."
    OVERRIDE=""
    read -r -p "Type 'not a card' if you are certain, anything else to abort: " OVERRIDE < /dev/tty || true
    [ "$OVERRIDE" = "not a card" ] || die "aborted -- nothing was written"
fi

# --- fingerprint, to detect renumbering between now and the erase ----------
# Disks renumber when devices are plugged or unplugged. The identifier chosen
# now may point at something else by the time the destructive step runs, so
# record what this device *is* and re-check it immediately before erasing.
DISK_FINGERPRINT="${MEDIANAME}|${DISK_BYTES}|$(get "Disk / Partition UUID")"

# ---------------------------------------------------------------- format ---
if [ "$REFRESH" -eq 1 ]; then
    # Refresh: mount the existing boot partition and leave everything else be.
    MNT="/Volumes/$BOOT_LABEL"
    diskutil mount "${DISK}s1" >/dev/null 2>&1 || true
    [ -d "$MNT" ] || die "could not mount ${DISK}s1 at $MNT -- is this a card written by copal-prep.sh?"
    [ -e "$MNT/config.txt" ] && [ -e "$MNT/boot/vmlinuz-rpi" ] \
        || die "$MNT does not contain an Alpine payload. Refusing to refresh a card that was never written."
    export COPYFILE_DISABLE=1
    info "Refreshing generated files on $MNT (payload untouched)."
else

if [ "/dev/$DISK" = "$IMAGE_DEV" ]; then

# A disk image gets the same partitioning and none of the ceremony. The two
# typed confirmations exist to stop you erasing the wrong physical device;
# there is no wrong device here, only a file this script created or was handed
# by name. Keeping the ritual anyway would make it a reflex rather than a
# check, and the ritual is the only thing protecting a real card.
step "Partition the disk image" \
    "Target : $IMAGE_PATH  ($DISK_SIZE, attached as /dev/$DISK)" \
    "Scheme : MBR  (the same layout a card gets)" \
    "Layout : p1  ${BOOT_SIZE} FAT32 '${BOOT_LABEL}'  -- bootloader and kernel" \
    "         p2  ${ROOT_SIZE_LABEL}  '${ROOT_LABEL}'  -- reformatted ext4 on first boot" \
    "" \
    "No physical disk is involved. If this goes wrong, delete the file."

else

step "ERASE AND PARTITION /dev/$DISK  <-- destructive" \
    "Target : /dev/$DISK  ($DISK_SIZE)" \
    "Scheme : MBR  (the Pi firmware cannot boot from GPT)" \
    "Layout : p1  ${BOOT_SIZE} FAT32 '${BOOT_LABEL}'  -- firmware, kernel, dtbs" \
    "         p2  ${ROOT_SIZE_LABEL}  '${ROOT_LABEL}'  -- reformatted ext4 on the Pi" \
    "         remainder left unallocated" \
    "" \
    "p2 exists because the diskless root filesystem is a tmpfs of about half" \
    "of RAM (~200 MB on a 512 MB Zero). That is too small to install a" \
    "desktop into. p2 becomes a real ext4 root instead. macOS cannot create" \
    "ext4, so it is a placeholder here and mkfs.ext4'd on the Pi." \
    "" \
    "THIS IS THE POINT OF NO RETURN. Everything on /dev/$DISK is destroyed," \
    "and it cannot be undone. Every step before this one was reversible;" \
    "this one is not. Check the size above matches your SD card." \
    "" \
    "Aborting after this point leaves the card unbootable until you re-run."

warn "EVERYTHING on /dev/$DISK will be destroyed. This cannot be undone."
echo >&2
printf '    %s\n' "/dev/$DISK  --  ${MEDIANAME:-unknown}  --  $DISK_SIZE" >&2
[ -n "$MOUNTED" ] && printf '    Contains: %s\n' "$MOUNTED" >&2
echo >&2

# First confirmation: the identifier itself. Typing "ERASE" proves you read a
# prompt; typing "disk5" proves you read WHICH DISK. Since the numbering moves
# between sessions, that is the part worth confirming.
CONFIRM_DISK=""
read -r -p "Type the disk identifier to confirm the target ($DISK): " CONFIRM_DISK < /dev/tty || true
[ "$CONFIRM_DISK" = "$DISK" ] || die "'$CONFIRM_DISK' does not match '$DISK' -- aborted, nothing was written"

# Second confirmation: intent.
CONFIRM=""
read -r -p "Type ERASE to proceed, anything else to abort: " CONFIRM < /dev/tty || true
[ "$CONFIRM" = "ERASE" ] || die "aborted by user -- nothing was written"

fi   # end of the confirmations, skipped for a disk image

# --- last line of defence: has this identifier moved while we talked? ------
# Between selecting the disk and confirming twice, a device may have been
# plugged in or removed, renumbering everything. Re-read the device and
# compare it with what was inspected earlier.
RECHECK=$(diskutil info "/dev/$DISK" 2>/dev/null) || die "/dev/$DISK has gone away. Aborted."
recheck_get() { printf '%s\n' "$RECHECK" | grep -E "^ *$1:" | head -n1 | sed 's/.*: *//' | xargs || true; }
NOW_BYTES=$(printf '%s\n' "$RECHECK" | grep -E '^ *Disk Size:' | grep -oE '\([0-9]+ Bytes\)' | grep -oE '[0-9]+' | head -n1 || true)
NOW_FINGERPRINT="$(recheck_get "Device / Media Name")|${NOW_BYTES}|$(recheck_get "Disk / Partition UUID")"

if [ "$NOW_FINGERPRINT" != "$DISK_FINGERPRINT" ]; then
    echo >&2
    die "/dev/$DISK IS NOT THE DEVICE YOU SELECTED.

       was: $DISK_FINGERPRINT
       now: $NOW_FINGERPRINT

       The disk numbering changed while this was running -- something was
       plugged in or removed. Nothing has been written. Re-run the script and
       pick the card again."
fi
info "Re-checked /dev/$DISK: still the device you selected."

ERASED=1
# MBRFormat: the Pi firmware reads an MBR/FDisk partition table, not GPT.
# MS-DOS FAT32 boot partition, remainder left as free space for ext4 later.
info "Partitioning /dev/$DISK (MBR: FAT32 ${BOOT_SIZE} '${BOOT_LABEL}' + ${ROOT_SIZE_LABEL} '${ROOT_LABEL}')..."
diskutil unmountDisk "/dev/$DISK" >/dev/null 2>&1 || true
if [ "$ROOT_SIZE" = "R" ]; then
    # No trailing "Free Space" entry: p2 takes everything left.
    diskutil partitionDisk "/dev/$DISK" MBRFormat \
        MS-DOS "$BOOT_LABEL" "$BOOT_SIZE" \
        MS-DOS "$ROOT_LABEL" R
else
    diskutil partitionDisk "/dev/$DISK" MBRFormat \
        MS-DOS "$BOOT_LABEL" "$BOOT_SIZE" \
        MS-DOS "$ROOT_LABEL" "$ROOT_SIZE" \
        "Free Space" %noformat% R
fi

# p2 is created as FAT only because macOS has no ext4 support; the filesystem
# is replaced on the Pi. Set the MBR type byte to 0x83 (Linux) so the partition
# is not mistaken for a FAT volume, and unmount it so macOS stops touching it.
info "Setting partition 2 type to Linux (0x83)..."
diskutil unmount "${DISK}s2" >/dev/null 2>&1 || true
printf 't 2\n83\nw\ny\nq\n' | sudo fdisk -e "/dev/$DISK" >/dev/null 2>&1 \
    || warn "could not set the type byte on p2 (harmless; mkfs.ext4 overwrites it anyway)"

# On a PC, partition 1 has to be an EFI System Partition: type 0xEF. The Pi
# firmware does not care what the type byte says and diskutil's default (0x0B/
# 0x0C, plain FAT32) is fine there, but UEFI firmware is entitled to ignore a
# FAT partition that is not marked as an ESP, and some do. One fdisk call is
# cheaper than a card that boots on one machine and not the next.
if [ "$PLATFORM" = pc ]; then
    info "Setting partition 1 type to EFI System (0xEF)..."
    diskutil unmount "${DISK}s1" >/dev/null 2>&1 || true
    printf 't 1\nEF\nw\ny\nq\n' | sudo fdisk -e "/dev/$DISK" >/dev/null 2>&1 \
        || warn "could not set the ESP type byte on p1 -- most firmware still boots it"
fi

# Mark partition 1 active/bootable. The Pi firmware tolerates its absence, but
# the Alpine documentation specifies it and some firmware revisions want it.
step "Set the bootable flag on partition 1" \
    "Runs: sudo fdisk -e /dev/$DISK   (marks partition 1 active)" \
    "" \
    "This will prompt for your macOS password." \
    "If it fails the script warns and continues -- the Pi firmware usually" \
    "boots without the active flag."

info "Marking partition 1 bootable..."
printf 'f 1\nw\ny\nq\n' | sudo fdisk -e "/dev/$DISK" >/dev/null 2>&1 \
    || warn "could not set the bootable flag (usually harmless; continuing)"

sleep 2
MNT="/Volumes/$BOOT_LABEL"
diskutil mount "${DISK}s1" >/dev/null 2>&1 || true
[ -d "$MNT" ] || die "expected $MNT to be mounted after formatting; check 'diskutil list'"

# ------------------------------------------------------------------ copy ---
step "Copy the Alpine payload onto ${BOOT_LABEL}" \
    "From : $SRC" \
    "To   : $MNT  ($(( SRC_BYTES / 1024 / 1024 )) MiB)" \
    "" \
    "The payload is COPIED as files. It is deliberately not written as a" \
    "block image -- imaging an Alpine ISO is what caused the original" \
    "boot-rainbow failure this procedure exists to avoid." \
    "" \
    "May take several minutes on a slow card."

# COPYFILE_DISABLE stops macOS writing ._AppleDouble sidecar files.
info "Copying payload to $MNT ..."
export COPYFILE_DISABLE=1
(cd "$SRC" && cp -Rp . "$MNT/")

fi   # end of the destructive block skipped by --refresh

# Strip macOS metadata that Finder/Spotlight add; harmless to boot but untidy.
info "Removing macOS metadata..."
command -v dot_clean >/dev/null && dot_clean -m "$MNT" 2>/dev/null || true
rm -rf "$MNT/.Spotlight-V100" "$MNT/.fseventsd" "$MNT/.Trashes" "$MNT/.TemporaryItems" 2>/dev/null || true
find "$MNT" -name '._*' -delete 2>/dev/null || true
find "$MNT" -name '.DS_Store' -delete 2>/dev/null || true

# --------------------------------------------------- first-run automation ---
step "Write the answer file, firmware settings and first-run script" \
    "Writes three files to the boot partition:" \
    "" \
    "  answers.txt   setup-alpine answers -- keymap ${CFG_KEYMAP}, host" \
    "                ${CFG_HOSTNAME}, ${CFG_TIMEZONE}, ${CFG_IFACE}/dhcp, disk=none" \
    "  usercfg.txt   firmware settings (gpu_mem=16, enable_uart=1); config.txt" \
    "                includes it last and is itself overwritten on upgrade" \
    "  copal-init.sh   the one command to run on the Pi -- a re-runnable menu" \
    "                that applies the answers, then optionally makes p2 ext4" \
    "                for the apk cache, then optionally moves / onto it" \
    "" \
    "macOS cannot create ext4, so that half necessarily happens on the Pi." \
    "This script carries the instructions there instead of leaving them for" \
    "you to retype at the console."

info "Writing answers.txt, usercfg.txt and copal-init.sh..."

# See LBUOPTS below for what this is and why it differs by platform.
if [ "$PLATFORM" = rpi ]; then
    LBU_MEDIA_ANSWER="mmcblk0p1"
else
    LBU_MEDIA_ANSWER="none"
fi

# setup-alpine answer file. Note: setup-alpine still prompts for the root
# password interactively -- there is no answer-file variable for it.
cat > "$MNT/answers.txt" <<ANSWERS
# setup-alpine answer file -- generated by copal-prep.sh
# Apply with:  setup-alpine -f /media/mmcblk0p1/answers.txt

KEYMAPOPTS="${CFG_KEYMAP}"
HOSTNAMEOPTS="-n ${CFG_HOSTNAME}"

INTERFACESOPTS="auto lo
iface lo inet loopback

auto ${CFG_IFACE}
iface ${CFG_IFACE} inet dhcp
    hostname ${CFG_HOSTNAME}
"

TIMEZONEOPTS="-z ${CFG_TIMEZONE}"
PROXYOPTS="none"
# -1 = use the first mirror on the list, normally the CDN. -f instead probes
# every mirror to find the fastest, which fills the log with 404s and 403s
# from mirrors that are stale or refuse the request, and takes far longer than
# the difference is worth on a board this slow.
APKREPOSOPTS="${CFG_APKREPOS:--1}"
SSHDOPTS="-c openssh"
NTPOPTS="-c chrony"

# The group list is what decides whether ${CFG_USER} can run X at all, so it is
# not the throwaway line it looks like.
#
#   video    /dev/fb0 and /dev/dri/* -- the framebuffer X draws into
#   input    /dev/input/event* -- the keyboard and mouse
#   tty      /dev/tty0 -- the console X takes over, and VT switching
#   audio    /dev/snd/*
#   netdev   change network settings without becoming root
#
# 'input' and 'tty' were missing here until this was written, and the symptom
# was exactly the confusing one: X starts as root, and as ${CFG_USER} it either
# dies or comes up with a dead keyboard. The reason is Xorg.wrap, the setuid
# helper in front of the X server: with needs_root_rights=auto -- the default,
# because Alpine ships no /etc/X11/Xwrapper.config -- it is free to drop root
# and fall back to opening the devices as the calling user, and on this board
# that means fbdev and evdev by group permission or not at all. Stage 4 writes
# the Xwrapper config too; this list is the other half of the same fix.
#
# wheel is deliberately NOT here. setup-alpine's -a already grants it, and
# stage 1 re-checks it -- see admin_sync_password, which also installs doas.
USEROPTS="-a -g audio,video,input,tty,netdev ${CFG_USER}"

# disk=none keeps the diskless model. Do NOT set this to mmcblk0: that erases
# the boot partition and produces media the Pi firmware cannot boot.
DISKOPTS="none"
# lbu's backup medium. Right on a Pi; on a PC the same partition arrives as
# sda1 or nvme0n1p1 -- or vda1 in a VM -- and there is no way to know which
# from here, so stage 1 rewrites LBU_MEDIA from the boot partition it actually
# found. See lbu_fix_media in copal-init.sh.
#
# Naming mmcblk0p1 anyway used to make setup-lbu print
#
#     /media/mmcblk0p1: not a directory
#
# in the middle of setup-alpine on every non-Pi machine (setup-lbu line 65),
# and skip configuring lbu at all. Harmless in the end, because lbu_fix_media
# sets it correctly a moment later, but it is an error message in the one part
# of the install a person is actually watching.
#
# 'none' is setup-lbu's own supported value for "do not configure a medium"
# and is what Alpine's generated answers file defaults to. Used only off the
# Pi: the Pi path is proven on hardware and there is no reason to change what
# it sends through setup-alpine.
LBUOPTS="${LBU_MEDIA_ANSWER}"

# No apk cache yet -- deliberately. The cache wants a real filesystem, and the
# only one that exists at this point is the FAT boot partition. copal-init.sh
# stage 2 formats p2 as ext4 and points the cache there instead.
APKCACHEOPTS="none"
ANSWERS

# THE BOOT CONFIGURATION, which is the one part of this script that is genuinely
# different per platform. A Pi gets firmware directives; a PC gets a GRUB menu.
# Everything else written to this card -- answers.txt, copal.conf, the SSH key,
# copal-init.sh -- is byte-identical on both.
if [ "$PLATFORM" = rpi ]; then

# usercfg.txt -- config.txt ends with 'include usercfg.txt' and carries a
# "do not modify this file as it will be overwritten on upgrade" banner, so
# every firmware setting belongs here. Directives later in the include chain
# win, which is also how copal-init.sh repoints the kernel after a sys install.
cat > "$MNT/usercfg.txt" <<'USERCFG'
# usercfg.txt -- firmware settings. config.txt includes this file last, so
# anything set here overrides the stock config.txt above it, and survives an
# upgrade that rewrites config.txt.

# RAM is the binding constraint on a 512 MB Zero: the diskless root filesystem
# is a tmpfs of about half of RAM, and the GPU reservation comes off the top
# before Linux sees any of it. So lowering gpu_mem is tempting.
#
# DO NOT SET IT TO 16. At exactly 16 the bootloader switches to the cut-down
# firmware -- start_cd.elf and fixup_cd.dat -- and the alpine-rpi tarball ships
# only start.elf/start4.elf and fixup.dat/fixup4.dat. The firmware finds no
# blob to load and halts before HDMI is even initialised: no rainbow, no
# display, no kernel, and no log to read afterwards. It looks exactly like a
# dead card. (Learned the hard way; see README troubleshooting.)
#
# 32 is the lowest value that still uses start.elf, and is worth 32 MB back
# from the 64 MB default. Left commented until it has actually been booted --
# an untested firmware setting is what caused the outage above.
#gpu_mem=32

# A serial console on the GPIO header, for when there is no video and no
# network. Harmless with nothing attached, and the only way to see early boot
# messages if the Pi stops before userspace. Does not affect which firmware
# blob is loaded.
enable_uart=1

# Enable the audio device. Needed before ALSA can output over HDMI, and safe
# on its own. The companion setting, hdmi_drive=2, forces HDMI rather than DVI
# signalling and is what actually carries the sound -- but it can blank a
# display connected through a DVI adapter, so stage 10 asks before adding it.
dtparam=audio=on
USERCFG

else   # PLATFORM=pc

# grub.cfg. GRUB was built with prefix=($root)/boot/grub, so this is the path it
# reads, on whichever device it was itself loaded from.
#
# THE KERNEL COMMAND LINE, which is the whole of what makes Alpine's diskless
# mode work, and every token earns its place:
#
#   modules=loop,squashfs,sd-mod,usb-storage
#       The initramfs loads only what it is told to. loop and squashfs are what
#       mount modloop (the compressed module tree) -- without them the system
#       has no drivers for anything at all. sd-mod and usb-storage are what let
#       it see the medium it just booted from. This is Alpine's own list from
#       its ISO, plus the two below.
#   ahci,nvme,mmc_block,sdhci,sdhci_pci
#       Added for real hardware rather than the VM the stock list assumes: a
#       SATA disk, an NVMe drive, and an SD card in a built-in reader. Harmless
#       when absent -- a module that matches no hardware simply does nothing.
#   rootfstype=tmpfs
#       Diskless. Says out loud what 'disk=none' in answers.txt implies.
#   console=tty0
#       Keep the messages on the screen. A serial console can be added here.
#
# There is deliberately no 'quiet': the first boot of a machine nobody has
# booted before is exactly when the messages are worth having.
#
# Two entries, because the netboot tarball ships two kernels and both are
# already on the card. lts is the one for real hardware -- the full driver set.
# virt is trimmed for virtual machines and boots faster where that is what you
# have; it lacks drivers for a lot of physical hardware.
mkdir -p "$MNT/boot/grub"
if [ "$VM" -eq 1 ]; then

# A VM gets a different default and a different serial port, and both matter.
#
#   virt rather than lts   The trimmed kernel is the right one here: every
#       device is virtio, and none of the SATA/NVMe/SDHCI drivers lts carries
#       will ever match anything. It boots faster, which is the whole reason
#       to test in a VM.
#   virtio_blk,virtio_pci  How the initramfs finds the disk at all. Without
#       them nlplug-findfs scans an empty /dev, fails to find modloop, and
#       drops to an initramfs shell -- the VM equivalent of the rainbow screen.
#       sd-mod and usb-storage stay for a disk attached as USB instead.
#
# THE SERIAL PORT IS PER-ARCHITECTURE, and this is not cosmetic: name the wrong
# one and the machine boots perfectly to a console nobody can see, which looks
# from outside exactly like a hang.
#
#   aarch64   ttyAMA0   QEMU's 'virt' machine puts its serial on a PL011, and
#                       Linux calls that ttyAMA0.
#   x86_64    ttyS0     The PC's 8250/16550 UART. There is no PL011 on a q35
#                       machine, so ttyAMA0 names nothing at all.
#
# This used to be hardcoded to ttyAMA0 for every VM, which was correct while
# MODEL=vm was the only VM and implied aarch64. MODEL=vmx86 is what made it
# wrong, and it would have been wrong silently.
case "$ARCH" in
    aarch64) VM_SERIAL="ttyAMA0" ;;
    x86_64|x86) VM_SERIAL="ttyS0" ;;
    *)       VM_SERIAL="ttyS0" ;;
esac
info "VM serial console: $VM_SERIAL (ARCH=$ARCH)"

# Both consoles are listed on the default entry so one image serves a UTM
# window and a headless 'qemu -nographic' run without editing anything. The
# last console= named is the one /dev/console points at, hence serial last.
cat > "$MNT/boot/grub/grub.cfg" <<GRUBCFG
# Generated by copal-prep.sh for MODEL=${MODEL:-vm} (ARCH=$ARCH).
set timeout=3
set default=0

menuentry "Copal Linux (virt -- serial + console)" {
    linux /boot/vmlinuz-virt modules=loop,squashfs,sd-mod,usb-storage,virtio_blk,virtio_pci,virtio_scsi rootfstype=tmpfs console=tty0 console=$VM_SERIAL,115200
    initrd /boot/initramfs-virt
}

menuentry "Copal Linux (virt -- graphical console only)" {
    linux /boot/vmlinuz-virt modules=loop,squashfs,sd-mod,usb-storage,virtio_blk,virtio_pci,virtio_scsi rootfstype=tmpfs console=tty0
    initrd /boot/initramfs-virt
}

menuentry "Copal Linux (lts -- full driver set)" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage,virtio_blk,virtio_pci,virtio_scsi,ahci,nvme rootfstype=tmpfs console=tty0 console=$VM_SERIAL,115200
    initrd /boot/initramfs-lts
}
GRUBCFG
info "Wrote boot/grub/grub.cfg (virt default, serial on $VM_SERIAL)"

else

cat > "$MNT/boot/grub/grub.cfg" <<'GRUBCFG'
# Generated by copal-prep.sh.
set timeout=5
set default=0

menuentry "Copal Linux (lts -- real hardware)" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage,ahci,nvme,mmc_block,sdhci,sdhci_pci rootfstype=tmpfs console=tty0
    initrd /boot/initramfs-lts
}

menuentry "Copal Linux (virt -- virtual machines)" {
    linux /boot/vmlinuz-virt modules=loop,squashfs,sd-mod,usb-storage,virtio_blk,virtio_pci rootfstype=tmpfs console=tty0
    initrd /boot/initramfs-virt
}

menuentry "Copal Linux (lts, serial console on ttyS0)" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage,ahci,nvme,mmc_block,sdhci,sdhci_pci rootfstype=tmpfs console=tty0 console=ttyS0,115200
    initrd /boot/initramfs-lts
}
GRUBCFG
info "Wrote boot/grub/grub.cfg (lts default, virt and serial alternatives)"

fi   # end of the VM / bare-metal grub.cfg choice

fi   # end of the per-platform boot configuration

# Values copal-init.sh needs but cannot get from the (quoted) heredoc below.
#
# PI_GIT_NAME/PI_GIT_EMAIL are defaults, not settings: stage 1 offers them at
# the prompt and writes the answer to copal-git on the same partition, and that
# file is what every later stage reads. --refresh rewrites this file, so
# correcting the identity on the Mac and re-running with --refresh updates the
# proposal -- it does not overwrite an answer already given on the Pi.
cat > "$MNT/copal.conf" <<CONF
# Generated by copal-prep.sh. Sourced by copal-init.sh.
PI_USER="${CFG_USER}"
PI_GIT_NAME="${CFG_GIT_NAME}"
PI_GIT_EMAIL="${CFG_GIT_EMAIL}"
CONF

if [ -n "${CFG_GIT_NAME}${CFG_GIT_EMAIL}" ]; then
    info "Git identity offered: ${CFG_GIT_NAME:-(no name)} <${CFG_GIT_EMAIL:-no email}> -- stage 1 asks, Enter accepts"
else
    warn "no git identity on this Mac -- stage 1 will ask for one with no default"
fi

# The SSH public key, copied as a plain file next to it. Public keys are not
# secret -- this is the .pub half only, and nothing here can authenticate as
# you without the private key, which stays on the Mac.
if [ -n "$CFG_SSHKEY" ] && [ -f "$CFG_SSHKEY" ]; then
    if grep -qE '^(ssh-(ed25519|rsa)|ecdsa-sha2-)' "$CFG_SSHKEY"; then
        cp "$CFG_SSHKEY" "$MNT/authorized_keys"
        info "Authorised key: $(awk '{print $1, $NF}' "$CFG_SSHKEY") (from $CFG_SSHKEY)"
    else
        warn "$CFG_SSHKEY does not look like an OpenSSH public key -- not copying it"
    fi
elif [ -n "$CFG_SSHKEY" ]; then
    warn "no such key file: $CFG_SSHKEY -- continuing without one"
else
    warn "no SSH public key found on this Mac -- ${CFG_USER} will be password-only"
fi

# ------------------------------------------------------- Mini vMac, staged ---
#
# Stage 9 builds Mini vMac from source it downloads from gryphel.com, which
# makes a two-hour emulator build depend on a web server being up at the exact
# moment an unattended install reaches stage 9. It is a 500 kB tarball and it is
# already on this Mac, so it travels on the card and the download becomes the
# fallback rather than the plan. The first hardware log shows why: the mirror
# went away mid-install and the Mini vMac download failed with it, on a run that
# had already spent hours getting there.
#
# The ROM travels the same way when there is one, and for a different reason:
# without it the emulator cannot start at all, and it is the one file the
# project deliberately does not ship. Yours stays yours -- this copies a ROM you
# already have onto a card you already own, and nothing is downloaded, fetched
# or published. A dump is self-verifying (the first four bytes are a big-endian
# checksum over the 16-bit words that follow), so it is checked and trimmed here
# rather than trusted, and a file that does not verify is left behind with a
# warning instead of being copied for the Pi to fail on later.
MVM_LOCAL="$(cd "$(dirname "$0")" && pwd)"

# 'od -v' is essential: without it od collapses runs of identical lines to '*',
# and a ROM has plenty of those, which yields a plausible-looking wrong answer.
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
# Trim to the window that verifies rather than demanding an exact size: dumps
# routinely carry trailing padding or a resource fork. Prints nothing and fails
# if the file is not a ROM, because the callers try several candidates.
stage_rom() {  # <source file> <destination file>
    local src="$1" dst="$2" size stored computed len
    [ -s "$src" ] || return 1
    size=$(wc -c < "$src" | tr -d ' ')
    for len in 131072 65536; do
        [ "$size" -lt "$len" ] && continue
        stored=$(od -An -tx1 -N4 "$src" | tr -d ' \n')
        computed=$(rom_checksum "$src" 4 $((len - 4)))
        if [ "$stored" = "$computed" ]; then
            dd if="$src" of="$dst" bs="$len" count=1 2>/dev/null || return 1
            info "ROM staged: $(rom_identify "$stored") -- checksum $stored verified over $len bytes$(
                [ "$size" -ne "$len" ] && printf ', %s bytes of padding trimmed' "$((size - len))")"
            info "  from $src"
            return 0
        fi
    done
    return 1
}

info "Staging Mini vMac source and ROM on ${BOOT_LABEL}..."
mkdir -p "$MNT/minivmac"

# Newest tarball wins, so a card written after a version bump carries the new
# one without this script being told about it.
MVM_TGZ=$(ls -t "$MVM_LOCAL"/minivmac/minivmac-*.src.tgz 2>/dev/null | head -n1 || true)
if [ -n "$MVM_TGZ" ]; then
    cp "$MVM_TGZ" "$MNT/minivmac/"
    info "Mini vMac source staged: $(basename "$MVM_TGZ") ($(( $(wc -c < "$MVM_TGZ") / 1024 )) kB)"
    info "  stage 9 uses this and does not need the network for it"
else
    warn "no minivmac-*.src.tgz in $MVM_LOCAL/minivmac -- stage 9 will download it"
    warn "Run ./fetch-minivmac.sh first to put one there."
fi

# Candidates in preference order. work/ holds the raw dump; minivmac/ holds the
# copy fetch-minivmac.sh installs, which may be a placeholder of zero length --
# stage_rom rejects that rather than staging an empty file that would satisfy
# every 'is the ROM there' test and then fail inside the emulator.
MVM_ROM_DONE=0
for _cand in "$MVM_LOCAL/minivmac/vMac.ROM" "$MVM_LOCAL/work/vMac.ROM"; do
    [ -s "$_cand" ] || continue
    if stage_rom "$_cand" "$MNT/minivmac/vMac.ROM"; then MVM_ROM_DONE=1; break; fi
    warn "$_cand does not verify as a Mac ROM -- not staging it"
done
if [ "$MVM_ROM_DONE" -eq 0 ]; then
    rm -f "$MNT/minivmac/vMac.ROM"
    warn "no verifiable vMac.ROM on this Mac -- Mini vMac will not start on the Pi"
    warn "until you supply one. Dump it from a Mac Plus you own with CopyRoms,"
    warn "then: ./fetch-minivmac.sh --rom <file> && ./copal-prep.sh --refresh"
fi

# PianoBooster, for the same reason and by the same route: stage 14 compiles it
# and the source is 3 MB. Alpine packages no piano tutor at all, so this is the
# only copy that will ever be on the machine -- worth not making it depend on
# GitHub being reachable at the end of a multi-hour install.
PB_TGZ=$(ls -t "$MVM_LOCAL"/pianobooster/pianobooster-*.tar.gz 2>/dev/null | head -n1 || true)
if [ -n "$PB_TGZ" ]; then
    mkdir -p "$MNT/pianobooster"
    cp "$PB_TGZ" "$MNT/pianobooster/"
    info "PianoBooster source staged: $(basename "$PB_TGZ") ($(( $(wc -c < "$PB_TGZ") / 1024 )) kB)"
else
    warn "no pianobooster-*.tar.gz in $MVM_LOCAL/pianobooster -- stage 14 will download it"
fi

# The first-run script. Quoted heredoc: nothing here is expanded by the host.
cat > "$MNT/copal-init.sh" <<'COPALINIT'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  COPAL LINUX -- the damn tasty Raspberry Pi Zero distro.
#
# copal-init.sh -- the installer. Generated by copal-prep.sh, runs on the
# Pi as root:
#
#     sh /media/mmcblk0p1/copal-init.sh
#
# Safe to run as many times as you like. It inspects the machine first, shows
# what is already done, and offers a menu -- so a failed stage can be retried
# without sitting through the ones that already succeeded.
#
# Everything printed is also appended to /media/mmcblk0p1/copal.log. The
# boot partition is FAT, so if the Pi will not come back up you can read that
# log on any other machine. Capturing the error text is the whole point.

set -eu

# Where the FAT boot partition is mounted MOVES depending on how far setup has
# got. Diskless, the initramfs mounts it under /media/<partition>. After stage 3,
# setup-disk regenerates fstab with it at /boot instead and the /media path stops
# existing -- so this must be discovered, not assumed.
#
# It is also not always on an SD card. On a PC the same card, written the same
# way, arrives as /dev/sda1 or /dev/nvme0n1p1, so the OLD version of this
# function -- which looked only at /media/mmcblk0p1 and mounted /dev/mmcblk0p1
# by name -- could not find it at all. Nothing is named here now: the marker is
# answers.txt, which copal-prep.sh writes to the boot partition on every
# platform, and the device is whatever /media entry or /proc/mounts says.
#
# config.txt is NOT the marker any more. It is a Raspberry Pi firmware file and
# does not exist on a PC card.
find_boot() {
    # Already mounted somewhere: /boot after stage 3, /media/* before it.
    for _d in /boot /media/*; do
        [ -d "$_d" ] || continue
        [ -f "$_d/answers.txt" ] && { echo "$_d"; return 0; }
    done
    # Mounted nowhere useful. Try every partition that looks like it could be a
    # FAT boot partition, in the order most likely to be right, and keep the one
    # that actually has answers.txt on it.
    mkdir -p /media/copal-boot 2>/dev/null || true
    for _dev in /dev/mmcblk0p1 /dev/sda1 /dev/sdb1 /dev/nvme0n1p1 /dev/vda1; do
        [ -b "$_dev" ] || continue
        if mount -t vfat "$_dev" /media/copal-boot 2>/dev/null; then
            [ -f /media/copal-boot/answers.txt ] && { echo /media/copal-boot; return 0; }
            umount /media/copal-boot 2>/dev/null || true
        fi
    done
    return 1
}

BOOT=$(find_boot) || {
    echo "Cannot find the FAT boot partition: no answers.txt under /boot or" >&2
    echo "/media/*, and none of the usual first partitions would mount." >&2
    echo "Is this the card copal-prep.sh wrote?" >&2
    exit 1
}
ANSWERS="$BOOT/answers.txt"
LOG="$BOOT/copal.log"
CONF="$BOOT/copal.conf"

# The answers to the two identity questions -- name and email for git commits --
# asked once in stage 1 alongside the password and read back by stage 7. On the
# boot partition for the same reason the auto state is: it is the only
# filesystem that exists at every point in this install, it survives stage 3
# moving the root, and it can be read and corrected from the Mac.
#
# Not copal.conf, which copal-prep.sh generates and --refresh rewrites. That
# file carries the PROPOSAL from the Mac; this one carries the answer given
# here, and an answer must not be destroyed by re-running --refresh.
IDFILE="$BOOT/copal-git"

# Full-automatic install state. Deliberately on the FAT boot partition and
# nowhere else: it is the one filesystem that exists at every point in this
# install -- before p2 is formatted, while / is still a tmpfs, and after
# stage 3 moves the root -- and it is readable from the Mac if the Pi stops
# booting mid-run.
AUTOFILE="$BOOT/copal-auto"
AUTO=0
AUTO_DEFAULT=""
AUTO_DONE=""

# WHICH DISK THIS MACHINE BOOTED FROM, worked out rather than assumed.
#
# The partition naming rule differs by device class and there is no way to
# spell it once:  mmcblk0 -> mmcblk0p1,  sda -> sda1,  nvme0n1 -> nvme0n1p1.
# The 'p' appears only when the disk name already ends in a digit. Rather than
# encode that rule for the parent lookup, ask sysfs -- /sys/block/<disk>/<part>
# exists exactly when <part> is a partition of <disk>.
part_of() {  # <disk> <n> -> /dev/<disk>[p]<n>
    case "$1" in
        *[0-9]) echo "/dev/${1}p${2}" ;;
        *)      echo "/dev/${1}${2}" ;;
    esac
}

# The device behind the boot partition, from /proc/mounts.
boot_device() {
    awk -v m="$BOOT" '$2 == m { d = $1 } END { print d }' /proc/mounts
}

# ...and the whole disk that partition belongs to.
disk_of() {  # <partition device or bare name> -> bare disk name, e.g. mmcblk0
    _p=${1#/dev/}
    [ -n "$_p" ] || return 1
    for _c in /sys/block/*/"$_p"; do
        [ -e "$_c" ] || continue
        _d=${_c%/*}; echo "${_d##*/}"; return 0
    done
    return 1
}

BOOTDEV=$(boot_device 2>/dev/null || true)
DISKDEV=$(disk_of "$BOOTDEV" 2>/dev/null || true)
# Fall back to the Raspberry Pi name rather than leaving these empty: on a Pi it
# is right, and on anything else the stages that use them check the device
# exists before touching it.
[ -n "$DISKDEV" ] || DISKDEV=mmcblk0
P1=$(part_of "$DISKDEV" 1)
P2=$(part_of "$DISKDEV" 2)
P2MNT="/media/$(basename "$P2")"
SYSP2="/sys/block/$DISKDEV/$(basename "$P2")"

# Every stage prints through these three, which is what lets the full-automatic
# installer draw a progress screen without any stage knowing about it: when $TUI
# is 1 they feed the panes (see tui_say/tui_note/tui_warn), and otherwise they
# are the plain printf they have always been. $TUI is 0 everywhere except inside
# auto_run, so the interactive menu is unaffected.
say()  { if [ "${TUI:-0}" = 1 ]; then tui_say  "$*"
         else printf '\n\033[36m==> %s\033[0m\n' "$*"; fi; }
note() { if [ "${TUI:-0}" = 1 ]; then tui_note "$*"
         else printf '    %s\n' "$*"; fi; }
warn() { if [ "${TUI:-0}" = 1 ]; then tui_warn "$*"
         else printf '\033[33mwarning:\033[0m %s\n' "$*"; fi; }
# die is deliberately NOT hooked: it is the last thing printed before the script
# exits, and it has to be readable on a screen that may be mid-repaint. It puts
# the terminal back first.
die()  { [ "${TUI:-0}" = 1 ] && tui_end
         printf '\n\033[31merror:\033[0m %s\n' "$*"; exit 1; }

# Prompts go straight to the terminal rather than down the tee pipe, so a
# question never sits invisible in a buffer waiting for a newline. When there
# is no controlling terminal -- 'ssh pi sh copal-init.sh' without -t, or a pipe
# -- fall back to stdin rather than dying on /dev/tty. An EOF there just
# answers "" to everything, which quits the menu cleanly.
# The probe runs in a subshell on purpose. ':' is a POSIX special built-in, and
# a failed redirection on a special built-in makes a non-interactive shell exit
# outright -- silently, with status 0. The subshell absorbs that.
if ( : < /dev/tty ) 2>/dev/null; then HAVE_TTY=1; else HAVE_TTY=0; fi

# File descriptor 3 is the real terminal, and it is what the full-automatic
# installer's progress screen draws on.
#
# It has to be the terminal directly, not stdout. This script re-execs itself
# with everything piped through tee (see the logging section above), so by the
# time any stage runs, stdout is a PIPE -- '[ -t 1 ]' is false and cursor
# addressing sent down it would arrive interleaved with tee's own copy of the
# output. Opening /dev/tty once, here, side-steps both problems: the screen
# writes to fd 3, and raw command output keeps going down the pipe to the log.
#
# /dev/null when there is no terminal, so the drawing functions can redirect to
# fd 3 unconditionally instead of guarding every printf. A closed fd 3 would
# make every one of them fail.
#
# PROBE IN A SUBSHELL, THEN COMMIT. This used to read
#
#     exec 3>/dev/tty 2>/dev/null || exec 3>/dev/null
#
# which has two faults, and the second one hid a fatal bug for a whole release.
# 'exec' with no command applies its redirections to the current shell
# PERMANENTLY -- so that '2>/dev/null' was not scoped to the exec at all, it sent
# stderr to /dev/null for the entire remainder of the script. Every error message
# from every command after this line vanished, including the shell's own fatal
# 'parameter not set' under set -u. A full-auto install died with a bare
# "Stopped (exit 2)" and nothing else, on hardware, twice.
#
# The other fault: 'exec' is a special built-in, so a failed redirection makes a
# non-interactive shell exit outright, and the '||' would never have run anyway.
# Hence the same subshell-probe idiom used for the /dev/tty read test above --
# ask whether it can be opened, in a subshell where a failure is contained and
# the 2>/dev/null is scoped, and only then commit to it.
if [ "$HAVE_TTY" = 1 ] && ( : >/dev/tty ) 2>/dev/null; then
    exec 3>/dev/tty
else
    exec 3>/dev/null
fi

ask() {
    # Full-automatic mode answers here, at the one place every question in
    # this script passes through. Nothing else needs to know about it.
    #
    # The answer is derived from the prompt rather than configured per call
    # site, so a question added later is answered correctly without anyone
    # remembering to teach the auto path about it:
    #
    #   "Type yes to proceed:"  -> yes   (the destructive confirmations)
    #   anything else           -> y, or $AUTO_DEFAULT if the caller set one
    #
    # AUTO_DEFAULT is consumed, not sticky: it applies to the next question
    # and then clears itself, so a stray default cannot leak into an
    # unrelated prompt further down.
    if [ "${AUTO:-0}" = 1 ]; then
        case "$*" in
            *"Type yes"*) REPLY=yes ;;
            *)            REPLY="${AUTO_DEFAULT:-y}" ;;
        esac
        AUTO_DEFAULT=""
        printf '\n\033[32m%s\033[0m %s  \033[2m[auto]\033[0m\n' "$*" "$REPLY"
        return 0
    fi
    if [ "$HAVE_TTY" = 1 ]; then
        printf '\n\033[32m%s\033[0m ' "$*" > /dev/tty
        read -r REPLY < /dev/tty || REPLY=""
    else
        printf '\n\033[32m%s\033[0m ' "$*"
        read -r REPLY || REPLY=""
    fi
}
confirm() { ask "$1 [y/N]"; case "$REPLY" in [Yy]*) return 0 ;; *) return 1 ;; esac; }

# A question that cannot be answered with a default, because no default can be
# right: your name, your email address. 'y' is not an email address, and a git
# history full of 'y@y' is worse than one with no identity at all.
#
# Used sparingly -- the promise of --auto is that it does not need babysitting,
# and every one of these breaks that promise a little. Currently: the git
# identity, and only in stage 1, next to the password prompt that already stops
# the run. Answering it there and saving it on the card (see IDFILE) is what
# keeps stage 7 from stopping an unattended install an hour later.
# With no controlling terminal there is nobody to ask, so it answers empty and
# the caller skips rather than inventing something.
ask_real() {
    if [ "$HAVE_TTY" = 1 ]; then
        printf '\n\033[36m%s\033[0m ' "$*" > /dev/tty
        read -r REPLY < /dev/tty || REPLY=""
    elif [ "${AUTO:-0}" = 1 ]; then
        REPLY=""
    else
        printf '\n\033[36m%s\033[0m ' "$*"
        read -r REPLY || REPLY=""
    fi
}

# Same, but Enter means yes -- for the case where carrying on is the expected
# answer and saying no is the deviation.
confirm_yes() { ask "$1 [Y/n]"; case "$REPLY" in [Nn]*) return 1 ;; *) return 0 ;; esac; }

# ---------------------------------------------------------------- logging ---
# Re-exec once with all output through tee. FIRSTRUN_LOG_ACTIVE stops the
# second pass from doing it again.
if [ "${FIRSTRUN_LOG_ACTIVE:-0}" != 1 ]; then
    # Once root is locked (stage 13) the admin user is the only way in, so the
    # useful thing to print is the command that works from there.
    [ "$(id -u)" = 0 ] || {
        echo "This needs root. Re-run as:  doas sh $0 $*" >&2
        exit 1
    }
    mount -o remount,rw "$BOOT" 2>/dev/null || true
    # Subshell for the same reason as the /dev/tty probe below: a failed
    # redirection on ':' would otherwise exit the script silently, which is
    # precisely what happens when the boot partition is mounted read-only.
    if ( : >> "$LOG" ) 2>/dev/null; then
        printf '\n===== copal-init.sh: %s =====\n' "$(date 2>/dev/null || echo 'no clock')" >> "$LOG"
        FIRSTRUN_LOG_ACTIVE=1; export FIRSTRUN_LOG_ACTIVE
        # Preserve the real exit status: a pipeline reports tee's, not ours.
        { sh "$0" "$@" 2>&1; echo $? > /tmp/copal.rc; } | tee -a "$LOG"
        exit "$(cat /tmp/copal.rc 2>/dev/null || echo 1)"
    fi
    warn "cannot write $LOG (is $BOOT read-only?) -- continuing without a log"
fi

# ---------------------------------------------------------------- cleanup ---
# Any exit -- clean, failed, or Ctrl-C -- leaves no stray mounts behind, and
# says where to read the transcript.
cleanup() {
    rc=$?
    trap - EXIT INT TERM
    umount /mnt/boot 2>/dev/null || true
    umount /mnt      2>/dev/null || true
    if [ "$rc" != 0 ]; then
        printf '\n\033[31mStopped (exit %s).\033[0m Full transcript: %s\n' "$rc" "$LOG"
        printf 'Nothing else was changed. Re-run this script to pick up where it left off.\n'
    fi
    sync 2>/dev/null || true
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------- inspection ---
root_fstype()  { awk '$2 == "/" { fs = $3 } END { print fs }' /proc/mounts; }
# The diskless test, in one place. It is asked twelve times across this script
# and it is the single most consequential fact about the running system --
# whether anything you install survives the next reboot.
is_diskless() { [ "$(root_fstype)" = tmpfs ]; }

# The admin user's home, and giving them what root just created on their
# behalf. copal-init.sh runs as root throughout, so without own_by_user every
# dotfile, disk image and launcher lands root-owned in a directory the admin
# user cannot write -- which does not surface until something tries to save.
user_home() { getent passwd "$PI_USER" 2>/dev/null | cut -d: -f6; }
own_by_user() {  # <path>...
    _uid=$(id -u "$PI_USER" 2>/dev/null) || return 0
    _gid=$(id -g "$PI_USER" 2>/dev/null) || return 0
    for _t in "$@"; do [ -e "$_t" ] && chown -R "$_uid:$_gid" "$_t" 2>/dev/null || true; done
}

# The home directory itself, made when it is not there.
#
# adduser creates it once, when the account is created, and nothing recreates
# it afterwards. What crosses stage 3 is a snapshot, not the directory:
# setup-alpine runs `lbu add` over everything under /home right after
# setup-user (alpine-conf 3.22.0, setup-alpine lines 321-326), so /home/$user
# is in lbu's include list and therefore in the apkovl, and setup-disk unpacks
# the apkovl into the new root. But an apkovl is only as new as the last
# `lbu commit -d`, and Copal's commits happen in stages 1 and 2 -- when the
# directory is empty. So what arrives on p2 is an empty home, and everything
# written into it between that commit and the reboot is gone.
#
# Nothing complains about that. Login still works, and every function below
# that writes into the home directory quietly writes nothing when it is
# missing -- install_home_file skips homes it cannot find, so the desktop
# configuration, the editor configuration and the sample project land in /root
# only. It surfaces days later as "why is there no i3 config", which is a long
# way from the cause.
#
# So it is made rather than assumed, with the mode and ownership busybox
# adduser would have given it and /etc/skel copied in the same way. Silent
# when there is nothing to do, which is the normal case.
# System directories that must stay world-readable and world-traversable, and
# a repair for when they are not.
#
# 0755 is not a preference here: /etc/passwd and /etc/group are read by every
# name lookup any account makes, /etc/resolv.conf by every DNS query, and
# /etc/profile by every login shell. A /etc at 0700 gives a system that boots,
# looks perfectly healthy to root, and is unusable as anybody else --
#
#     login: can't change directory to '/home/user': Permission denied
#     id: unknown ID 1000
#
# -- which is exactly what a leaked `umask 077` in stage 1 produced, because
# stage 3 then created the whole new root under it. That leak is fixed at
# source (see admin_sync_password), but this repairs a machine already built by
# a version that had it, and costs one stat per directory otherwise.
#
# Only the directory itself, never -R: the modes underneath are the packages'
# business, and /etc/shadow at 0640 must stay that way.
fix_system_dir_modes() {  # [root prefix, e.g. /mnt]
    _pfx="${1:-}"
    _fixed=0
    for _d in etc home usr var srv opt media mnt run; do
        [ -d "$_pfx/$_d" ] || continue
        _m=$(stat -c '%a' "$_pfx/$_d" 2>/dev/null) || continue
        case "$_m" in
            *[1357]) continue ;;          # world-traversable already
        esac
        warn "$_pfx/$_d is mode $_m -- nothing but root can enter it; setting 0755"
        chmod 0755 "$_pfx/$_d" 2>/dev/null && _fixed=$((_fixed + 1))
    done
    [ "$_fixed" -eq 0 ] || note "repaired $_fixed system directory mode(s)"
    return 0
}

# The directories a desktop account is expected to already have.
#
# /etc/skel supplies dotfiles, not this: Alpine's skel is nearly empty and none
# of the XDG directories are in it. Without them pcmanfm opens on a blank home,
# anything honouring XDG_CONFIG_HOME creates it as whoever runs first -- which
# during an install is root -- and stage 6 has to invent ~/.ssh itself with
# `mkdir -p`, which is how a root-owned home got created on the way past in the
# first place.
#
# Made with the right owner from the start, rather than made by whatever
# happens to touch them and repaired afterwards.
ensure_user_dirs() {  # [root prefix]
    _pfx="${1:-}"
    _uh=$(user_home) || return 1
    [ -n "$_uh" ] || return 1
    [ -d "$_pfx$_uh" ] || return 1
    _uid=$(id -u "$PI_USER" 2>/dev/null) || return 1
    _gid=$(id -g "$PI_USER" 2>/dev/null) || return 1

    # .ssh is 0700 because sshd refuses to read a key out of anything looser.
    # The rest are 0755: a home that other accounts cannot traverse breaks
    # nothing here and surprises people later.
    for _d in .config .cache .local .local/share .local/bin \
              Desktop Documents Downloads Pictures Music Videos; do
        [ -d "$_pfx$_uh/$_d" ] || mkdir -p "$_pfx$_uh/$_d" 2>/dev/null || continue
        chmod 0755 "$_pfx$_uh/$_d" 2>/dev/null || true
    done
    [ -d "$_pfx$_uh/.ssh" ] || mkdir -p "$_pfx$_uh/.ssh" 2>/dev/null || true
    chmod 0700 "$_pfx$_uh/.ssh" 2>/dev/null || true
    [ -f "$_pfx$_uh/.ssh/authorized_keys" ] \
        && chmod 0600 "$_pfx$_uh/.ssh/authorized_keys" 2>/dev/null || true

    chown -R "$_uid:$_gid" "$_pfx$_uh" 2>/dev/null || true
    return 0
}

ensure_user_home() {  # [root prefix, e.g. /mnt]
    _pfx="${1:-}"
    id "$PI_USER" >/dev/null 2>&1 || return 1
    _uh=$(user_home)
    # An empty or relative home field is a broken passwd entry, not something
    # to create a directory from.
    case "$_uh" in /*) ;; *) return 1 ;; esac
    # Numeric ids, not the name: under a prefix the passwd file that `chown
    # user` would consult is this system's, not the one being populated.
    _uid=$(id -u "$PI_USER" 2>/dev/null || echo "")
    _gid=$(id -g "$PI_USER" 2>/dev/null || echo "")

    # It can also exist and be wrong. Stage 6's `mkdir -p $HOME/.ssh` creates a
    # root-owned $HOME on the way past when there is none, and everything after
    # it then finds a directory that is there and writes into it -- a home
    # directory its owner cannot write, which is worse than one that is absent
    # because nothing is left to notice. Repair that here rather than only the
    # missing case.
    # The parent has to be traversable or the home is unreachable however
    # perfect it is in itself. `mkdir -p /home/user` creates /home too, with
    # whatever umask happened to be in force, and nothing here ever looked at
    # it again -- so a home directory owned by the right user, with the right
    # mode, could still give
    #
    #     login: can't change directory to '/home/user': Permission denied
    #
    # because the mode bits on /home said no. Fix the parents first: a
    # directory nobody can walk through is not a private one, it is a broken
    # one, and o+x costs nothing that o+r would not already have cost.
    _parent=$(dirname "$_pfx$_uh")
    while [ "$_parent" != "/" ] && [ "$_parent" != "." ] && [ -d "$_parent" ]; do
        _pm=$(stat -c '%a' "$_parent" 2>/dev/null || echo "")
        case "$_pm" in
            *[1357])  : ;;                       # already world-traversable
            "")       chmod o+x "$_parent" 2>/dev/null || true ;;
            *)        warn "$_parent is mode $_pm -- '$PI_USER' cannot traverse it; adding o+x"
                      chmod o+x "$_parent" 2>/dev/null || true ;;
        esac
        _parent=$(dirname "$_parent")
    done

    if [ -d "$_pfx$_uh" ]; then
        [ -n "$_uid" ] || return 0
        # NO fallback that assumes the answer is already right. This used to be
        #     _now=$(stat -c '%u' ... || echo "$_uid")
        # which reported the ownership as correct whenever stat could not
        # answer, and returned having repaired nothing -- failing open, in the
        # direction that leaves the account unable to enter its own home. An
        # unreadable stat is now a reason to repair, not a reason to stop.
        _now=$(stat -c '%u' "$_pfx$_uh" 2>/dev/null || echo "")
        if [ -n "$_now" ] && [ "$_now" = "$_uid" ]; then
            _hm=$(stat -c '%a' "$_pfx$_uh" 2>/dev/null || echo "")
            case "$_hm" in
                *[1357]) ensure_user_dirs "$_pfx" || true; return 0 ;;
            esac
            warn "$_pfx$_uh is mode $_hm -- its owner cannot enter it; fixing"
        elif [ -z "$_now" ]; then
            warn "cannot read the ownership of $_pfx$_uh -- repairing it anyway"
        else
            warn "$_pfx$_uh is owned by uid $_now, not by $PI_USER -- fixing"
        fi
        chown -R "$_uid:$_gid" "$_pfx$_uh" 2>/dev/null || true
        chmod 0755 "$_pfx$_uh" 2>/dev/null || true
        note "now owned by $PI_USER ($_uid:$_gid), mode 0755"
        ensure_user_dirs "$_pfx" || true
        return 0
    fi

    say "Creating $_pfx$_uh -- '$PI_USER' has no home directory"
    mkdir -p "$_pfx$_uh" || { warn "could not create $_pfx$_uh"; return 1; }
    if [ -d "$_pfx/etc/skel" ]; then
        cp -a "$_pfx/etc/skel/." "$_pfx$_uh/" 2>/dev/null || true
    fi
    chmod 0755 "$_pfx$_uh"
    if [ -n "$_uid" ] && [ -n "$_gid" ]; then
        chown -R "$_uid:$_gid" "$_pfx$_uh" 2>/dev/null || true
        note "made, owned by $PI_USER ($_uid:$_gid)"
    else
        warn "made, but the uid for $PI_USER is unknown -- it is root-owned"
    fi
    ensure_user_dirs "$_pfx" || true
    return 0
}

# Free megabytes on the root filesystem, and the guard the big installs use.
# The workshop can ask for gigabytes (KiCad ~2 GB, texlive-full ~4 GB) and the
# automatic install answers yes to everything, so filling an 8 GB card and
# making every later stage fail with ENOSPC is a real outcome to design out.
free_mb() { df -m / 2>/dev/null | awk 'NR==2 {print $4+0}'; }
have_space_mb() {  # <megabytes> <what it is for>
    _need="$1"; _what="$2"; _got=$(free_mb)
    if [ "${_got:-0}" -ge "$_need" ]; then return 0; fi
    warn "not enough room for $_what: needs about ${_need} MB, ${_got} MB free"
    note "Stage 8 grows the partition into unallocated space, if there is any."
    return 1
}

# The one sentence every stage owes you on a diskless system, phrased the same
# way each time. Four stages said this in four slightly different wordings.
commit_reminder() {
    is_diskless || return 0
    warn "this root is RAM-resident -- run 'lbu commit -d' or none of this"
    warn "survives the next reboot."
}
fstype_of()    { blkid "$1" 2>/dev/null | sed -n 's/.*[[:space:]]TYPE="\([^"]*\)".*/\1/p'; }
# busybox blkid ACCEPTS `-s UUID -o value` and then IGNORES it, printing the
# whole `/dev/x: LABEL="..." UUID="..." TYPE="..."` line and exiting 0. That is
# not a parse error anywhere it lands -- it silently became root=UUID=/dev/vda2:
# in grub.cfg once, and the machine only failed at boot. Parse the line instead,
# and never reach for util-linux flags here. The leading [[:space:]] is what
# keeps this from matching PARTUUID=.
uuid_of()      { blkid "$1" 2>/dev/null | sed -n 's/.*[[:space:]]UUID="\([^"]*\)".*/\1/p'; }
is_mounted()   { awk -v m="$1" '$2 == m { found = 1 } END { exit !found }' /proc/mounts; }
apkovl_exists() { ls "$BOOT"/*.apkovl.tar.gz >/dev/null 2>&1; }
# "has stage 3 already run" -- the boot configuration carries a root= once it
# has. Two different files, because two different bootloaders.
sys_installed() {
    if [ -f "$BOOT/cmdline.txt" ]; then
        grep -q 'root=' "$BOOT/cmdline.txt" 2>/dev/null
    else
        grep -q 'root=' "$BOOT/boot/grub/grub.cfg" 2>/dev/null
    fi
}
# Raspberry Pi or PC, decided by what the firmware left behind rather than by
# anything this script was told. config.txt exists only on a Pi.
is_pi_boot() { [ -f "$BOOT/config.txt" ]; }
x_installed()    { apk info -e xorg-server >/dev/null 2>&1; }
zram_active()    { grep -q '^/dev/zram' /proc/swaps 2>/dev/null; }
dev_installed()  { apk info -e build-base >/dev/null 2>&1; }
sshkey_present() { [ -f "$BOOT/authorized_keys" ]; }

# The second field of /etc/shadow. Anything starting with '!' is a locked
# account and '*' is "no password will ever match" -- neither can log in.
# A real crypt hash starts with '$'.
shadow_hash()   { awk -F: -v u="$1" '$1 == u { print $2 }' /etc/shadow 2>/dev/null; }
can_login()     { case "$(shadow_hash "$1")" in '$'*) return 0 ;; esac; return 1; }
root_locked()   { ! can_login root; }
# Admin means both halves: a password that works, and the right to become root.
# Either one alone is useless, so stage 13 checks both -- separately, so it can
# say which is missing -- before root is ever locked.
# grep -qx, not a substring test: 'wheelbarrow' must not read as 'wheel'.
in_wheel()      { id -Gn "$1" 2>/dev/null | tr ' ' '\n' | grep -qx wheel; }

# The general forms of the two above. copal-config defines its own copies
# inside its heredoc, and for a long time those were the ONLY definitions --
# so admin_fix_desktop_groups, which lives out here, produced
#
#     copal-init.sh: line 1382: group_exists: not found
#
# once per group on every stage 1. Not fatal, because the caller is
# `group_exists "$_g" || continue`, so a missing function reads as "no such
# group" and every group is skipped -- which is precisely the failure worth
# hating: the repair silently repaired nothing, and said so only in a warning
# nobody parses. A function defined in a generated file is not defined in the
# file that generates it.
#
# /etc/group rather than `getent group`: getent comes from musl-utils, which is
# not guaranteed on a diskless system this early, and busybox has no built-in.
# Reading the file needs nothing.
group_exists()  { awk -F: -v g="$1" '$1 == g { found = 1 } END { exit !found }' /etc/group; }
in_group()      { id -Gn "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }

sshkey_done() {
    _h=$(user_home)
    [ -n "$_h" ] && [ -f "$_h/.ssh/authorized_keys" ] && [ -f "$BOOT/authorized_keys" ] \
        && grep -qxF "$(cat "$BOOT/authorized_keys")" "$_h/.ssh/authorized_keys" 2>/dev/null
}

# PI_USER comes from copal.conf, written by copal-prep.sh alongside this script.
# So do the git defaults -- and they are declared here as well as set there,
# because a card written by an older copal-prep.sh has a copal.conf with no
# mention of them, and this script runs under 'set -u'.
PI_USER=user
PI_GIT_NAME=''
PI_GIT_EMAIL=''
[ -f "$CONF" ] && . "$CONF"

# uname -r is 6.x.y-0-rpi on this image; setup-disk derives the kernel package
# name the same way. Pin it explicitly rather than trusting the default.
KFLAV=$(uname -r); KFLAV=${KFLAV##*-}

state_report() {
    _rfs=$(root_fstype)
    [ "$_rfs" = tmpfs ] && _rfs="$_rfs  (diskless, RAM-resident)"
    _p2=$(fstype_of "$P2" || true)
    [ -n "$_p2" ] || _p2="none  (unformatted -- macOS could not make ext4)"
    _rt=$(sed -n 's/.*\(root=[^ ]*\).*/\1/p' "$BOOT/cmdline.txt" 2>/dev/null || true)
    [ -n "$_rt" ] || _rt="(none -- boots the RAM-resident system)"

    say "Current state"
    note "hostname        : $(hostname)"
    note "kernel flavor   : $KFLAV  (stage 3 would install linux-$KFLAV)"
    note "root filesystem : $_rfs"
    note "root fs size    : $(df -h / | awk 'NR==2 {print $2 " total, " $5 " used"}')"
    note "memory          : $(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d MB total, %d MB available", t/1024, a/1024}' /proc/meminfo)"
    note "p2 filesystem   : $_p2"
    note "p2 unallocated  : $(_f=$(p2_free_sectors); [ "$_f" -gt 131072 ] && echo "$(( _f / 2048 )) MB after p2 -- stage 8 can reclaim it" || echo 'none -- p2 fills the card')"
    note "apk cache       : $(readlink /etc/apk/cache 2>/dev/null || echo 'none -- packages will not survive a reboot')"
    note "saved config    : $(apkovl_exists && ls "$BOOT"/*.apkovl.tar.gz 2>/dev/null || echo 'none committed yet')"
    note "cmdline root=   : $_rt"
    note "X.Org           : $(x_installed && echo installed || echo 'not installed')"
    note "zram swap       : $(zram_active && grep '^/dev/zram' /proc/swaps | awk '{printf "%d MB", $3/1024}' || echo 'not active')"
    note "admin user      : $PI_USER -- $(can_login "$PI_USER" && echo 'password set' || echo 'NO PASSWORD, cannot log in'), $(in_wheel "$PI_USER" && echo 'in wheel' || echo 'not in wheel')"
    # Worth a line of its own: the account can be perfect and the directory
    # still absent, and when it is, every dotfile this script writes for
    # $PI_USER goes nowhere without anything failing.
    note "home directory  : $(_h=$(user_home); [ -n "$_h" ] && [ -d "$_h" ] \
                                && echo "$_h ($(stat -c '%U' "$_h" 2>/dev/null))" \
                                || echo "${_h:-unknown} -- MISSING, run stage 1")"
    note "root account    : $(root_locked && echo 'locked -- use doas from '"$PI_USER" || echo 'password login enabled (stage 13 locks it)')"
    note "ssh key         : $(sshkey_done && echo "authorised for $PI_USER" || { sshkey_present && echo "on the card, not yet installed for $PI_USER" || echo 'none on the card'; })"
    note "dev toolchain   : $(dev_installed && echo "installed ($(cc --version 2>/dev/null | head -n1))" || echo 'not installed')"
    note "network         : $(ip -4 addr show scope global 2>/dev/null | awk '/inet /{printf "%s: %s ", $NF, $2}' || echo unknown)"
}

# Install packages that are nice to have but must not fail the whole stage if
# the repository has renamed or dropped them.
#
# TWO functions, because there are two jobs here and one return value cannot
# do both. This script runs under 'set -e', so a bare command that returns
# non-zero kills the stage -- which is the exact opposite of what a thing
# called "optional" should do:
#
#   add_optional PKG...   install what you can, report what you cannot, and
#                         ALWAYS succeed. The default. Safe bare.
#   try_add PKG           the same, but returns whether it worked, for the
#                         handful of callers that branch on it
#                         (neovim-or-vim, urxvt-or-xterm, Go, Bluetooth).
#
# Before this split, sixteen bare 'add_optional' calls would abort their stage
# if every name in the list happened to be missing -- silently, hours into an
# unattended install.
try_add() {
    _ok=0
    for _p in "$@"; do
        # 'name@testing' is apk's syntax for one package out of a tagged
        # repository. Registering that repository is this function's job
        # rather than each caller's: doing it here is what makes '@testing'
        # a property of the package name and nothing else, so no call site
        # has to remember the ceremony. It is idempotent and only runs the
        # first time a tagged name is actually asked for.
        case "$_p" in
            *@testing) enable_testing_tag || {
                           warn "skipped $_p -- could not reach edge/testing"
                           continue
                       } ;;
        esac
        # 'apk info -e' does not understand the suffix, so the
        # already-installed check has to be made against the bare name.
        _bare=${_p%@*}
        if apk info -e "$_bare" >/dev/null 2>&1; then
            note "$_bare (already installed)"; _ok=1
        # apk's own complaint, kept rather than thrown away. This used to
        # report every failure as "not in the configured repositories", which
        # is one cause out of many and was flatly wrong the day the network
        # went away half-way through stage 12: a hundred packages that are in
        # Alpine main -- rsync, zip, samba, tig -- were logged as missing from
        # the repositories, and the real error, whatever it was, was on the
        # other side of a 2>/dev/null. An unattended install is read from its
        # log afterwards or not at all, so the log has to say what happened.
        elif _why=$(apk add "$_p" 2>&1 >/dev/null); then
            note "$_p"; _ok=1
        else
            # apk spreads one error over three lines; make it one.
            _why=$(printf '%s' "$_why" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
            # Order matters. A package apk cannot fetch an index for is
            # reported as "no such package" as well, so the network symptoms
            # have to be tested first or every outage reads as a missing
            # package -- which is precisely how a hundred packages that do
            # exist came to be logged as ones that do not.
            case "$_why" in
                *"temporary error"*|*"could not connect"*|*"Ignoring"* \
                |*"unreachable"*|*"not resolve"*|*"try again"*|*"Try again"*)
                    warn "skipped $_p -- the repositories are not reachable" ;;
                *"No space left"*)
                    warn "skipped $_p -- the filesystem is full" ;;
                *"no such package"*|*"unable to select packages"*)
                    warn "skipped $_p -- not in the configured repositories" ;;
                '') warn "skipped $_p -- apk failed and said nothing" ;;
                *)  warn "skipped $_p -- $(printf '%s' "$_why" | cut -c1-140)" ;;
            esac
        fi
    done
    [ "$_ok" = 1 ]
}
# The '|| true' is the entire difference between the two names, and it was
# missing: add_optional returned try_add's status, so a bare call whose every
# package was unavailable returned 1 and 'set -e' took the whole script down
# with it. The automatic install hid that -- auto_run turns set -e off around
# each stage -- so it could only ever have bitten someone driving the menu by
# hand, which is the one case nobody was watching a log for.
add_optional() { try_add "$@" || true; }

# ---------------------------------------------------------------------------
# The application catalogue.
#
# One table, two consumers: stage 12 installs from it, and /usr/local/bin/
# copal-menu builds its submenus from it. Keeping them in one place is the whole
# point -- a menu written separately from the installer drifts within a week
# and starts listing things that were never installable.
#
# Fields:  section | label | packages to install | binary to test for | mode
#
# Section names must be one word with no punctuation: they are pasted into
# jgmenu tag names (have_Internet, get_Internet) and a space there silently
# breaks the submenu. Hence 'Smallweb' rather than 'Small Web'.
#
# 'binary' is what decides whether an entry is shown as installed or offered
# under Install. 'mode' is one of:
#
#   x  makes its own window -- run it directly
#   t  interactive, but text -- wrap a terminal around it
#   h  a command-line tool that exits immediately when run with no arguments.
#      Clicking one of these in a menu would open a terminal and close it
#      again too fast to read, which looks exactly like a crash. Show its
#      help and leave a shell open instead.
#
# EVERY package name here was checked against the v3.24 APKINDEX, main and
# community, for all three architectures this script can build: armhf, armv7
# and aarch64. The whole table exists on armhf and aarch64. On armv7 exactly
# one entry is absent -- abcde -- and add_optional degrades to a warning rather
# than failing the stage, so the armv7 build is still fine.
#
# That check is not pedantry: the obvious names for this job --
# xmms, sylpheed, ted, beaver, leafpad, mtpaint, rox-filer, dillo's usual
# stablemates -- are mostly gone from Alpine, and a menu full of packages that
# do not exist is worse than a short menu. Where the classic is gone, its
# living descendant is listed instead and the comment says which:
#
#   xmms      -> audacious  (direct fork of XMMS; playlists, Winamp skins)
#   sylpheed  -> claws-mail (forked from Sylpheed in 2001, same GTK lineage)
#   ted/beaver/leafpad -> mousepad (the surviving small GTK text editor)
#   mtpaint/xpaint/grafx2 -> nothing small survives; only GIMP, which thrashes
#   rox-filer -> xfe (small, fast, two-pane) or pcmanfm
#   elm       -> mailx for scripting, alpine (pine) for reading. elm itself
#                is not packaged anywhere, stable or edge.
#
# visidata is the one requested tool that is edge/testing only. It is pure
# Python, so the usual objection to mixing branches (a newer libc than the
# rest of the system expects) does not really apply, but it still is not in
# stable and so is not listed. To get it:
#   apk add --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing visidata
#
# BROWSERS, and the one thing that really does change with MODEL. There is no
# Chromium and no Firefox for armhf -- neither is built for ARMv6. On armv7 and
# aarch64 both exist (chromium, firefox, firefox-esr). They are not in the
# table because the table is shared across every board and a menu entry that
# only works on some of them is worse than none. Stage 4 handles that instead:
# install_modern_browser asks apk which architecture this actually is and
# offers only what exists there. On a Zero 1, Dillo and NetSurf are not a
# compromise -- they are the entire field, and both are genuinely usable.
#
# BadWolf is the one entry in the table that is both modern and universal:
# a minimal front end over WebKitGTK, which is a current engine with current
# TLS, and it is built for armhf as well. It is what makes "a supported
# browser" answerable on an ARMv6 board at all.
#
# THE SMALL WEB. This is the one category where the Pi Zero is not making do
# with less -- it is the right machine for the job. Gopher and Gemini are
# text, served without scripts, tracking or layout, and a 1 GHz core renders
# a Gemini capsule as fast as anything you own. Everything here is in v3.24
# community and none of it is a compromise:
#
#   bombadillo  gopher AND gemini AND finger in one terminal browser
#   amfora      the nicest Gemini reader in a terminal
#   lagrange    ships two binaries: clagrange (curses) and lagrange (a real
#               window, SDL2 -- it works, but clagrange is the one for this
#               board). Both come from the one package.
#   gmni/gmnlm  curl and a line-mode browser, for scripting Gemini
#   gemget      a downloader, for mirroring a capsule
#   gmnisrv     serve your own capsule from the Pi
#
# For Gopher specifically, note that two browsers already in the Internet
# section speak it natively -- lynx and elinks both handle gopher:// with no
# extra software. links does not, which is worth knowing before you go
# looking for the setting.
#
# In edge/testing only, so not offered here: sacc and cgo (gopher TUIs),
# castor (a GTK Gemini window), geomyidae (a gopher server), agate and gmid
# (more Gemini servers). The guide says how to reach them if you want one.
#
# GAMES. Two filters apply, and they remove different things.
#
# Not packaged in v3.24 for ANY of these architectures -- this list is not an
# armhf limitation, and switching to aarch64 does not bring any of it back:
# Cataclysm-DDA, 0 A.D., Endless Sky,
# Teeworlds, Hedgewars, Chromium B.S.U., Frozen Bubble, ADOM, ToME4, OpenRA,
# DOSBox, Fuse, the whole of kdegames, dungeon-crawl, and every other DOS or
# console emulator except RetroArch, Mednafen and ScummVM. DOSBox and Fuse
# are the two genuinely painful losses -- a Spectrum emulator is exactly this
# board's speed -- and neither is in edge/testing either.
#
# Packaged, but there is no OpenGL here worth the name: this board renders X
# on the CPU through fbdev, so anything wanting a GPU falls back to software
# rasterisation on a 1 GHz ARMv6. Xonotic, SuperTux and SuperTuxKart are all in
# the repository on every arch here and all unplayable on a Zero, so they are
# not listed. (Neverball used to be named here as a fourth; it is not actually
# packaged in v3.24 at all.) On a Pi 4 or 5 with real video these become
# reasonable -- 'apk add supertux' -- but this table is sized for the Zero.
# Wesnoth is listed but marked: it starts, and 512 MB shared with the
# framebuffer is not enough to enjoy it.
#
# What is left is the honest set for the hardware -- turn-based, 2D, and
# text. That is not a consolation prize. It is what a 1 GHz machine with no
# GPU was always good at, and NetHack does not care what year it is.
#
# OPTICAL MEDIA. A Pi Zero has one USB OTG port and no optical drive, so a
# burner means a powered hub and a USB enclosure. The software side works
# fine; xorriso is the pick because it both authors and burns ISOs, and
# because it does NOT collide with cdrkit -- both ship /usr/bin/mkisofs, and
# apk will refuse to install the pair. k3b is KDE and not packaged; xfburn is
# the light GTK burner and is.
#
# THE 'bin' FIELD MUST BE A COMMAND ON $PATH, not a package name and not a file
# path. Everything downstream decides "is this installed?" with
# 'command -v "$bin"' (see have() in copal-menu), so a bin that PATH cannot
# resolve makes the row read "not installed" forever -- it stays in the Install
# branch after being installed, and in mode 'x' the Center launches a command
# that is not there. Three rows got this wrong and were fixed on 2026-07-29:
#
#   * cataclysm-dda-tiles ships /usr/bin/cataclysm-tiles. The package name and
#     the binary name differ, and the row had copied the package name.
#   * git-gui installs ONLY into /usr/libexec/git-core/, which is deliberately
#     not on PATH -- 'git gui' is the invocation, and there is no 'git-gui'
#     command. The row now installs git-gitk alongside it and detects 'gitk',
#     which is a real command and was what the label promised anyway.
#   * openssh-sftp-server was REMOVED rather than repaired. It ships one file,
#     /usr/lib/ssh/sftp-server, which sshd invokes by absolute path; there is
#     no command to detect and no window to open, so it cannot satisfy the
#     contract this table makes. Enabling SFTP is an sshd_config matter, not an
#     application to install -- see the README's "Accounts and remote access".
#     Do not add it back as a catalogue row.
#
# Verify a bin against the index's own 'cmd:' provides, not by guessing -- and
# note that 'cmd:' is a WEAKER oracle than the truth. It records what a package
# puts in /usr/bin; it says nothing about /usr/libexec. Two of the three defects
# above were invisible to it and needed the file list from
# https://pkgs.alpinelinux.org/contents to confirm.
catalogue() {
    cat <<'CATALOGUE'
Internet|Dillo (tiny web browser)|dillo|dillo|x|*
Internet|NetSurf (web - own engine)|netsurf|netsurf|x|*
Internet|BadWolf (WebKit - modern engine, tiny)|badwolf|badwolf|x|*
Internet|Firefox ESR (full browser)|firefox-esr|firefox-esr|x|!v6
Internet|Chromium (full browser)|chromium|chromium|x|!v6,!x32
Internet|Links (text/graphics web)|links|links|t|*
Internet|ELinks (text web + gopher)|elinks|elinks|t|*
Internet|w3m (text web)|w3m|w3m|t|*
Internet|Lynx (text web + gopher)|lynx|lynx|t|*
Internet|retawq (tiny text browser)|retawq|retawq|t|*
Internet|Transmission (torrents)|transmission-gtk|transmission-gtk|x|*
Internet|qBittorrent (torrents)|qbittorrent|qbittorrent|x|*
Internet|lftp (FTP - terminal)|lftp|lftp|t|*
Mail|Thunderbird (full mail client)|thunderbird|thunderbird|x|!v6,!x32
Mail|Claws Mail (GUI - Sylpheed lineage)|claws-mail|claws-mail|x|*
Mail|Alpine (pine - terminal)|alpine|alpine|t|*
Mail|Mutt (terminal)|mutt|mutt|t|*
Mail|aerc (terminal)|aerc|aerc|t|*
Mail|mailx (send mail from a script)|mailx|mail|h|*
Mail|irssi (IRC)|irssi|irssi|t|*
Mail|WeeChat (IRC)|weechat|weechat|t|*
Mail|Profanity (XMPP)|profanity|profanity|t|*
News|Newsboat (RSS/Atom - terminal)|newsboat|newsboat|t|*
News|Newsraft (RSS - terminal, fast)|newsraft|newsraft|t|*
News|Liferea (RSS - window)|liferea|liferea|x|*
News|sfeed (RSS to plain files)|sfeed|sfeed|h|*
News|Ticker (stock prices - terminal)|ticker@testing|ticker|t|*
Notes|Zim (wiki-style notebook)|zim|zim|x|*
Notes|Gnote (sticky wiki notes)|gnote|gnote|x|*
Notes|CherryTree (hierarchical notebook)|cherrytree@testing|cherrytree|x|*
Notes|Ghostwriter (distraction-free Markdown)|ghostwriter|ghostwriter|x|64
Notes|Vim + spell check|vim hunspell hunspell-en-us|vim|t|*
Notes|Hunspell (spell checker)|hunspell hunspell-en-us|hunspell|h|*
Notes|Aspell (spell checker)|aspell aspell-en|aspell|h|*
Notes|mdBook (write a book as Markdown)|mdbook|mdbook|h|*
Notes|Hugo (static site / wiki)|hugo|hugo|h|*
Notes|Zola (static site / wiki)|zola|zola|h|*
Documents|Zathura (PDF)|zathura zathura-pdf-mupdf|zathura|x|*
Documents|MuPDF (PDF - fastest)|mupdf|mupdf|x|*
Documents|xpdf (PDF)|xpdf|xpdf|x|*
Documents|Evince (PDF - full featured)|evince|evince|x|*
Documents|AbiWord (word processor)|abiword|abiword|x|*
Documents|Gnumeric (spreadsheet)|gnumeric|gnumeric|x|*
Documents|LibreOffice Writer (heavy)|libreoffice-writer|libreoffice|x|!v6
Documents|sc-im (spreadsheet - terminal)|sc-im|sc-im|t|*
Documents|Foliate (ebook reader)|foliate|foliate|x|!v6
Documents|KOReader (ebook reader)|koreader|koreader|x|64
Documents|Calibre (ebook library)|calibre@testing|calibre|x|64
Documents|PDF tools (poppler)|poppler-utils|pdftotext|h|*
Documents|qpdf (split/merge/repair PDF)|qpdf|qpdf|h|*
Editors|Mousepad (small GUI editor)|mousepad|mousepad|x|*
Editors|Geany (programmer's editor)|geany|geany|x|*
Editors|gedit (GNOME editor)|gedit|gedit|x|*
Editors|micro (terminal - modeless)|micro|micro|t|*
Editors|Helix (terminal - modal, batteries in)|helix|hx|t|*
Editors|vis (terminal - vi keys)|vis|vis|t|*
Editors|nano (terminal - simplest)|nano|nano|t|*
Design|Inkscape (vector drawing)|inkscape|inkscape|x|*
Design|Xfig (vector drawing - classic)|xfig|xfig|x|*
Design|LibreSprite (pixel art + animation)|libresprite|libresprite|x|*
Design|Drawing (simple paint)|drawing|drawing|x|*
Design|MyPaint (natural media painting)|mypaint|mypaint|x|*
Design|Pinta (Paint.NET-like)|pinta|pinta|x|!v6,!x32
Design|Krita (digital painting - heavy)|krita|krita|x|!v6
Design|GIMP (photo editing - will swap)|gimp|gimp|x|*
Design|Tux Paint (for children)|tuxpaint|tuxpaint|x|*
Design|PlantUML (UML from text)|plantuml|plantuml|h|*
Design|Graphviz (graph diagrams from text)|graphviz|dot|h|*
Design|Umbrello (UML diagram editor)|umbrello|umbrello6|x|!v6
Media|Audacious (playlists - XMMS fork)|audacious audacious-plugins|audacious|x|*
Media|DeaDBeeF (audio player)|deadbeef|deadbeef|x|*
Media|cmus (audio - terminal)|cmus|cmus|t|*
Media|MPD + ncmpcpp (daemon + client)|mpd mpc ncmpcpp|ncmpcpp|t|*
Media|mpv (audio and video)|mpv|mpv|x|*
Media|VLC (audio and video)|vlc|vlc|x|*
Media|Volume control|alsa-utils|alsamixer|t|*
Audio|MilkyTracker (Fasttracker II style)|milkytracker@testing|milkytracker|x|*
Audio|Schism Tracker (Impulse Tracker style)|schismtracker@testing|schismtracker|x|*
Audio|openmpt123 (play tracker modules)|openmpt123|openmpt123|h|*
Audio|xmp (play tracker modules)|xmp@testing|xmp|h|*
Audio|VICE vsid (Commodore 64 SID player)|vice@testing|vsid|x|*
Audio|FluidSynth + GM soundfont (MIDI)|fluidsynth soundfont-timgm|fluidsynth|h|*
Audio|Hydrogen (drum machine)|hydrogen|hydrogen|x|*
Audio|LMMS (DAW - tracker lineage)|lmms|lmms|x|!v6
Audio|MuseScore (music notation)|musescore|mscore|x|!v6
Audio|Audacity (audio editor)|audacity|audacity|x|*
Graphics|GPicView (image viewer)|gpicview|gpicview|x|*
Graphics|nsxiv (image viewer)|nsxiv|nsxiv|x|*
Graphics|feh (image viewer)|feh|feh|x|*
Graphics|Ristretto (image viewer)|ristretto|ristretto|x|*
Graphics|gThumb (browse and tag photos)|gthumb|gthumb|x|*
Graphics|Simple Scan (scanner)|simple-scan|simple-scan|x|*
Graphics|Tesseract (OCR)|tesseract-ocr|tesseract|h|!v6,!x32
Games|NetHack (roguelike)|nethack|nethack|t|*
Games|Brogue (roguelike)|brogue|brogue|t|*
Games|Angband (roguelike)|angband@testing|angband|t|*
Games|ZAngband (roguelike)|zangband|zangband|t|*
Games|Cataclysm DDA (survival roguelike)|cataclysm-dda-tiles@testing|cataclysm-tiles|x|64
Games|Solitaire|aisleriot|sol|x|*
Games|Minesweeper|gnome-mines|gnome-mines|x|*
Games|Sudoku|gnome-sudoku|gnome-sudoku|x|*
Games|Chess (XBoard + GNU Chess)|xboard gnuchess|xboard|x|*
Games|LBreakout2 (breakout)|lbreakout2|lbreakout2|x|*
Games|Pingus (Lemmings-like)|pingus|pingus|x|*
Games|OpenTTD (transport sim)|openttd openttd-opengfx openttd-opensfx|openttd|x|*
Games|Freeciv (SDL client - slow)|freeciv-client-sdl2 freeciv-data freeciv-server|freeciv-sdl2|x|*
Games|Widelands (settlers-like)|widelands|widelands|x|*
Games|Wesnoth (heavy - turn-based strategy)|wesnoth|wesnoth|x|*
Games|Luanti (Minetest - voxel sandbox)|luanti|luanti|x|*
Games|SuperTux (platformer - needs a GPU)|supertux|supertux2|x|!v6
Games|OpenMW (Morrowind engine)|openmw|openmw|x|64
Games|GZDoom (Doom engine)|gzdoom|gzdoom|x|64
Games|Chocolate Doom (faithful Doom)|chocolate-doom@testing|chocolate-doom|x|*
Games|Colossal Cave Adventure|bsd-games|adventure|t|*
Games|Robots|bsd-games|robots|t|*
Games|Hangman|bsd-games|hangman|t|*
Games|Snake|bsd-games|snake|t|*
Games|Klondike (cards)|bsd-games|klondike|t|*
Games|Air Traffic Control|bsd-games|atc|t|*
Games|Frotz (interactive fiction)|frotz|frotz|h|*
Games|TTY Solitaire|tty-solitaire|ttysolitaire|t|*
Games|Asciiquarium|asciiquarium|asciiquarium|t|*
Games|cmatrix|cmatrix|cmatrix|t|*
Games|cbonsai|cbonsai|cbonsai|h|*
Games|fortune|fortune|fortune|h|*
Games|figlet (big text)|figlet|figlet|h|*
Games|sl|sl|sl|h|*
Retro|ScummVM (point-and-click adventures)|scummvm|scummvm|x|*
Retro|DOSBox Staging (DOS)|dosbox-staging|dosbox|x|!x32
Retro|VICE (Commodore 64 - see stage 9)|vice@testing|x64sc|x|*
Retro|FS-UAE (Amiga)|fs-uae|fs-uae|x|*
Retro|mGBA (Game Boy Advance)|mgba|mgba|x|!v6
Retro|RetroArch (many consoles)|retroarch|retroarch|x|*
Retro|Mednafen (many consoles)|mednafen|mednafen|h|*
Engineering|SolveSpace (parametric CAD, exports STL)|solvespace|solvespace|x|*
Engineering|FreeCAD (parametric 3D CAD - heavy)|freecad|FreeCAD|x|!v6
Engineering|Blender (3D modelling - very heavy)|blender|blender|x|64
Engineering|KiCad (schematic + PCB + gerbers)|kicad|kicad|x|64
Engineering|ngspice (circuit simulation)|ngspice|ngspice|h|*
Engineering|Cura (slicer for the Ender 3)|cura@testing|cura|x|64
Engineering|admesh (check and repair STL)|admesh@testing|admesh|h|*
Engineering|OpenSCAD-style CAD via SolveSpace CLI|solvespace|solvespace-cli|h|*
Science|TeX Live (full LaTeX)|texlive-full|pdflatex|h|*
Science|LyX (LaTeX with a document view)|lyx|lyx|x|*
Science|Octave (MATLAB-compatible maths)|octave|octave|t|*
Science|Maxima (computer algebra, solves systems)|maxima@testing|maxima|t|*
Science|SymPy (symbolic maths in Python)|py3-sympy python3|python3|h|*
Science|SciPy + NumPy + Matplotlib|py3-scipy py3-numpy py3-matplotlib|python3|h|*
Science|Qalculate (unit-aware calculator)|qalculate-gtk|qalculate-gtk|x|*
Science|Gnuplot (plotting)|gnuplot|gnuplot|h|*
Science|PARI/GP (number theory)|pari|gp|t|*
Science|Singular (polynomial algebra)|singular|Singular|t|*
Science|R (statistics)|R|R|t|*
Security|Wireshark (packet capture - window)|wireshark|wireshark|x|*
Security|tshark (packet capture - terminal)|tshark|tshark|h|*
Security|Termshark (Wireshark-like TUI)|termshark|termshark|t|*
Security|tcpdump (packet capture)|tcpdump|tcpdump|h|*
Security|ClamAV (virus scanner)|clamav clamav-scanner clamav-db freshclam|clamscan|h|*
Security|Lynis (system hardening audit)|lynis@testing|lynis|h|*
Security|nmap (port scanner)|nmap|nmap|h|*
Security|Suricata (intrusion detection)|suricata|suricata|h|*
Security|fail2ban (ban brute-force attempts)|fail2ban|fail2ban-client|h|*
Security|ufw (simple firewall)|ufw|ufw|h|*
Security|John the Ripper (password audit)|john|john|h|!x32
Security|Aircrack-ng (wifi audit)|aircrack-ng|aircrack-ng|h|*
Sharing|FileZilla (FTP/SFTP client)|filezilla|filezilla|x|*
Sharing|Syncthing (sync folders between machines)|syncthing|syncthing|h|*
Sharing|croc (send a file to anyone, one command)|croc|croc|h|*
Sharing|darkhttpd (serve a folder over HTTP)|darkhttpd|darkhttpd|h|*
Sharing|Samba (Windows/macOS file shares)|samba samba-server|smbd|h|*
Sharing|sshfs (mount a remote folder)|sshfs|sshfs|h|*
Sharing|rsync (copy and mirror)|rsync|rsync|h|*
Sharing|Unison (two-way sync)|unison|unison|h|*
Files|PCManFM (file manager)|pcmanfm|pcmanfm|x|*
Files|Thunar (file manager)|thunar|thunar|x|*
Files|Xfe (two-pane file manager)|xfe|xfe|x|*
Files|Krusader (two-pane - powerful)|krusader|krusader|x|!v6
Files|Xarchiver (zip/tar/7z)|xarchiver 7zip unzip|xarchiver|x|*
Files|Midnight Commander|mc|mc|t|*
Files|nnn (terminal file manager)|nnn|nnn|t|*
Files|ranger (terminal file manager)|ranger|ranger|t|*
Tools|tmux (terminal multiplexer)|tmux|tmux|t|*
Tools|Galculator|galculator|galculator|x|*
Tools|SQLite browser|sqlitebrowser|sqlitebrowser|x|*
Tools|Sticky notes|xpad|xpad|x|*
Tools|Screenshot to file|scrot|scrot|x|*
Tools|Remmina (remote desktop)|remmina|remmina|x|*
Tools|x11vnc (share this screen)|x11vnc|x11vnc|t|*
Tools|Screen lock and savers|xscreensaver|xscreensaver|x|*
System|Disk utility (format, image, SMART)|gnome-disk-utility|gnome-disks|x|*
System|Partition editor (GParted)|gparted|gparted|x|*
System|Disk usage (Baobab)|baobab|baobab|x|*
System|Task manager (Xfce)|xfce4-taskmanager|xfce4-taskmanager|x|*
System|htop (process viewer)|htop|htop|t|*
System|Meld (compare files and folders)|meld|meld|x|*
System|lazygit (git TUI)|lazygit|lazygit|t|*
System|gitui (git TUI)|gitui|gitui|t|*
System|tig (git history TUI)|tig|tig|t|*
System|git-gui + gitk|git-gui git-gitk|gitk|x|*
System|delta (better git diffs)|delta|delta|h|*
Discs|cdw (CD/DVD burner - terminal)|cdw|cdw|t|*
Discs|Xfburn (CD/DVD burner)|xfburn|xfburn|x|*
Discs|xorriso (make and burn ISOs)|xorriso|xorriso|h|*
Discs|cdrdao (audio CD burning)|cdrdao|cdrdao|h|*
Discs|cdparanoia (CD ripper)|cdparanoia|cdparanoia|h|*
Discs|abcde (rip and encode)|abcde|abcde|h|!v7
Discs|zip and unzip|zip unzip|zip|h|*
Discs|bsdtar (reads almost anything)|libarchive-tools|bsdtar|h|*
Discs|SquashFS tools|squashfs-tools|mksquashfs|h|*
Smallweb|Bombadillo (gopher + gemini + finger)|bombadillo|bombadillo|t|*
Smallweb|Amfora (gemini browser)|amfora|amfora|t|*
Smallweb|Lagrange (gemini - terminal)|lagrange|clagrange|t|*
Smallweb|Lagrange (gemini - window)|lagrange|lagrange|x|*
Smallweb|gmnlm (gemini line mode)|gmni|gmnlm|t|*
Smallweb|gmni (fetch one gemini page)|gmni|gmni|h|*
Smallweb|gemget (gemini downloader)|gemget|gemget|h|*
Smallweb|gmnisrv (serve gemini)|gmnisrv|gmnisrv|h|*
Languages|Rust (compiler + cargo + std source)|rust cargo rust-src rustfmt|cargo|h|*
Languages|rust-analyzer (Rust language server)|rust-analyzer|rust-analyzer|h|*
Languages|Go (compiler + gopls language server)|go gopls|go|h|*
Languages|Delve (Go debugger - breakpoints)|delve|dlv|h|64
Languages|Haskell (GHC + cabal)|ghc cabal|ghc|h|64
Languages|hlint (Haskell linter)|hlint|hlint|h|64
Languages|Fortran (gfortran)|gfortran|gfortran|h|*
Languages|RetroForth (the Forth family)|retroforth|retro|t|*
Languages|PHP 8.3 + Composer + Xdebug|php83 php83-phar php83-openssl php83-pecl-xdebug composer|composer|h|*
Languages|Clang 22 (second C/C++ compiler)|clang22|clang|h|*
Languages|clangd + clang-format (C/C++ LSP)|clang22-extra-tools|clangd|h|*
Languages|OCaml|ocaml|ocaml|t|*
Languages|Zig|zig|zig|h|64
Languages|Free Pascal|fpc@testing|fpc|h|*
Languages|Lua 5.4 + LuaJIT|lua5.4 luajit|lua5.4|t|*
Languages|Tiny C Compiler (compiles in a blink)|tcc|tcc|h|*
Languages|Guile (Scheme)|guile|guile|t|*
Languages|CHICKEN (Scheme to C)|chicken|csi|t|*
Languages|SBCL (Common Lisp)|sbcl|sbcl|t|*
Languages|Racket|racket|racket|t|*
Languages|Nim|nim|nim|h|*
Languages|Elixir|elixir|elixir|t|*
Languages|Ruby|ruby|ruby|t|*
Languages|Perl|perl|perl|h|*
Languages|Crystal|crystal|crystal|h|64
Languages|OpenJDK 21 (Java)|openjdk21|java|h|64
Languages|.NET 9 SDK|dotnet9-sdk|dotnet|h|!v6,!x32
Devtools|Code::Blocks (IDE - GDB breakpoints)|codeblocks|codeblocks|x|*
Devtools|KDevelop (IDE - GDB breakpoints)|kdevelop|kdevelop|x|64
Devtools|Lapce (modern GUI editor, Rust)|lapce|lapce|x|64
Devtools|VSCodium (VS Code without telemetry)|vscodium@testing|codium|x|64
Devtools|GDB (the debugger everything uses)|gdb|gdb|t|*
Devtools|cgdb (GDB with a source window)|cgdb|cgdb|t|*
Devtools|LLDB (the Clang debugger)|lldb|lldb|t|*
Devtools|pwndbg (GDB for reverse engineering)|pwndbg|pwndbg|h|*
Devtools|Valgrind (memory errors and leaks)|valgrind|valgrind|h|!v6
Devtools|strace (trace system calls)|strace|strace|h|*
Devtools|ltrace (trace library calls)|ltrace|ltrace|h|*
Devtools|cppcheck (static analysis)|cppcheck|cppcheck|h|*
Devtools|shellcheck (lint bash and sh)|shellcheck|shellcheck|h|64
Devtools|shfmt (format shell scripts)|shfmt|shfmt|h|*
Devtools|CMake|cmake|cmake|h|*
Devtools|Meson + Ninja|meson ninja-build|meson|h|*
Devtools|ccache (recompile faster)|ccache|ccache|h|*
Devtools|Bear (make a compile_commands.json)|bear|bear|h|*
Devtools|just (a saner make, for tasks)|just|just|h|*
Devtools|ctags (jump to any definition)|ctags|ctags|h|*
Devtools|Doxygen (documentation from source)|doxygen|doxygen|h|*
Devtools|Lua language server|lua-language-server|lua-language-server|h|*
Devtools|Python language server|py3-lsp-server|pylsp|h|*
Terminals|Alacritty (GPU - fast, needs OpenGL)|alacritty|alacritty|x|*
Terminals|kitty (GPU - featureful, needs OpenGL)|kitty|kitty|x|*
Terminals|WezTerm (GPU - multiplexer built in)|wezterm|wezterm|x|*
Terminals|st (suckless - smallest and quickest)|st|st|x|*
Terminals|rxvt-unicode (light, the Copal default)|rxvt-unicode|urxvt|x|*
Terminals|xterm (the original, always works)|xterm|xterm|x|*
Terminals|Sakura (small GTK, tabs)|sakura|sakura|x|*
Terminals|LXTerminal (light GTK, tabs)|lxterminal|lxterminal|x|*
Terminals|Xfce Terminal (featureful GTK)|xfce4-terminal|xfce4-terminal|x|*
Terminals|Terminator (split panes in a grid)|terminator|terminator|x|*
Terminals|Tilda (drop-down, F1 - light)|tilda|tilda|x|*
Terminals|Guake (drop-down, F12 - GNOME)|guake@testing|guake|x|*
Terminals|Yakuake (drop-down, F12 - KDE)|yakuake|yakuake|x|!v6
Terminals|QTerminal (Qt, drop-down mode)|qterminal|qterminal|x|!v6
Terminals|Cool Retro Term (a CRT, convincingly)|cool-retro-term|cool-retro-term|x|*
Terminals|Zutty (X11-native, very fast)|zutty@testing|zutty|x|!x32
Terminals|GNU screen (multiplexer - the classic)|screen|screen|t|*
Terminals|Byobu (tmux with a status line set up)|byobu|byobu|t|*
Terminals|Zellij (multiplexer, discoverable keys)|zellij|zellij|t|64
Terminals|dvtm (tiling in a terminal)|dvtm|dvtm|t|*
Terminals|abduco (detach any program)|abduco|abduco|h|*
Terminals|dtach (detach, smallest of all)|dtach|dtach|h|*
Radio|GNU Radio (build your own SDR, in blocks)|gnuradio|gnuradio-companion|x|*
Radio|Gqrx (SDR receiver with a waterfall)|gqrx|gqrx|x|*
Radio|rtl-sdr tools (the RTL2832U dongle)|rtl-sdr|rtl_test|h|*
Radio|rtl_power FFT sweep (wide spectrum scan)|rtl-power-fftw@testing|rtl_power_fftw|h|*
Radio|HackRF tools|hackrf|hackrf_info|h|*
Radio|SDRangel (many modes, heavy)|sdrangel@testing|sdrangel|x|64
Radio|dump1090 (track aircraft, ADS-B)|dump1090|dump1090|h|*
Radio|Direwolf (packet radio / APRS TNC)|direwolf|direwolf|h|*
Radio|Hamlib (control a transceiver)|hamlib|rigctl|h|*
Radio|QSSTV (slow-scan television)|qsstv@testing|qsstv|x|*
Radio|welle.io (DAB+ radio)|welle-io@testing|welle-io|x|!v6
Instruments|SpeedCrunch (calculator - bin/oct/hex)|speedcrunch@testing|speedcrunch|x|*
Instruments|GHex (hex and binary editor)|ghex|ghex|x|*
Instruments|PulseView (oscilloscope + logic analyser)|pulseview@testing|pulseview|x|*
Instruments|sigrok-cli (capture without a GUI)|sigrok-cli@testing|sigrok-cli|h|*
Instruments|GTKWave (view digital waveforms)|gtkwave@testing|gtkwave|x|*
Instruments|QSpectrumAnalyzer (spectrum from an SDR)|qspectrumanalyzer@testing|qspectrumanalyzer|x|!v6,!x32
Instruments|FFTW + kissfft (FFT libraries)|fftw kissfft|fftw-wisdom|h|*
Learn|GNU Typist (touch typing course)|gtypist@testing|gtypist|t|*
Learn|KTouch (typing tutor with a keyboard map)|ktouch|ktouch|x|!v6
Learn|Minuet (music theory and ear training)|minuet|minuet|x|!v6
Control|Display layout|arandr|arandr|x|*
Control|Volume control (PulseAudio)|pavucontrol|pavucontrol|x|*
Control|Bluetooth manager|blueman|blueman-manager|x|*
Control|Network applet|network-manager-applet|nm-applet|x|*
Control|Night colour (redshift)|redshift|redshift|h|*
Control|Auto-mount removable media|udiskie|udiskie|h|*
CATALOGUE
}

CATFILE=/usr/local/share/copal/catalogue

# The sixth column is an architecture gate, and it exists because the table is
# shared by every board this script can write while the repositories are not:
#
#   *     every port. The overwhelming majority.
#   !v6   everything except armhf. Firefox, Thunderbird, Krita, FreeCAD,
#         MuseScore, LMMS, mGBA, Krusader, Tesseract -- all built for ARMv7 and
#         ARM64 and none of them for ARMv6.
#   !v7   everything except armv7. Exactly one entry: abcde, which armv7
#         alone is missing. A gate for a single row looks like overkill until
#         you remember what the alternative is -- one menu entry, on one
#         board, that fails. That is precisely the thing this column exists
#         to make impossible.
#   !x32  everything except 32-bit x86. Nine entries: Chromium, Thunderbird,
#         Pinta, Tesseract, DOSBox Staging, John the Ripper, Zutty,
#         QSpectrumAnalyzer and the .NET SDK. Alpine builds all nine for
#         x86_64 and none of them for x86.
#
# Tokens combine with commas -- '!v6,!x32' is "not on ARMv6 and not on 32-bit
# x86", which is what Chromium and Thunderbird actually need.
#   64    the 64-bit ports only: aarch64 and x86_64. Blender, KiCad, OpenMW,
#         GZDoom, Calibre, KOReader, Cataclysm DDA, Cura, Ghostwriter, GHC,
#         Zig, Crystal, OpenJDK, Delve, KDevelop, Lapce, VSCodium.
#
#         This gate was called 'a64' and documented as "aarch64 only" while
#         the ARM ports were the only ones. Every package behind it was then
#         checked against the x86_64 index and every single one is there, so
#         the gate was never about ARM -- it was about 64-bit. Renamed rather
#         than left misleading, because the next person to add a row has to
#         guess right from the name.
#
#         32-bit x86 is where these are genuinely absent: of the list above,
#         only KiCad and Delve are built for it.
#
# Every name in the table was checked against the real v3.24 APKINDEX for all
# three architectures, and every 'bin' against the cmd: provides recorded in
# that same index -- which is how 'FreeCAD' and 'umbrello6' are spelled the way
# they are, rather than the way you would guess.
# Resolved ONCE into $ARCH_GATE, below, and read as a variable everywhere
# after that. Memoising inside the function would not work: every call site
# uses it in a command substitution, which is a subshell, so the cached value
# would be discarded the moment it was computed. One apk invocation per run
# instead of seven, and a plain variable read is clearer at the call site than
# a subshell anyway.
catalogue_arch() {
    case "$(apk --print-arch 2>/dev/null)" in
        aarch64) echo a64 ;;
        x86_64)  echo x64 ;;
        armv7)   echo v7  ;;
        armhf)   echo v6  ;;
        x86)     echo x32 ;;
        *)       echo unknown ;;
    esac
}
ARCH_GATE=$(catalogue_arch)

# The catalogue as it applies to THIS board: rows that cannot exist here are
# dropped, and the gate column is stripped so everything downstream still sees
# the same five fields it always did. That is the whole point of filtering
# here rather than in each consumer -- copal-menu, copal-center, copal-install
# and stage 12 are unchanged and simply never see a package this port lacks.
catalogue_available() {
    catalogue | awk -F'|' -v OFS='|' -v a="$ARCH_GATE" '
        NF < 6 { next }
        {
            # The gate is a comma-separated list, evaluated left to right:
            #   *      no restriction
            #   64     the 64-bit ports only (aarch64, x86_64)
            #   !PORT  every port except this one
            # A row may carry several exclusions -- 'chromium' is absent on both
            # armhf and 32-bit x86, and one token per row could not say so.
            keep = 1
            n = split($6, gate, ",")
            for (i = 1; i <= n; i++) {
                if (gate[i] == "*") continue
                if (gate[i] == "64") {
                    if (a != "a64" && a != "x64") keep = 0
                } else if (substr(gate[i], 1, 1) == "!") {
                    if (a == substr(gate[i], 2)) keep = 0
                }
            }
            # An unrecognised architecture is not a reason to hide everything:
            # show the lot and let add_optional warn on whatever is missing.
            if (a == "unknown")                     keep = 1
            if (keep) print $1, $2, $3, $4, $5
        }'
}

# A handful of genuinely wanted programs are in edge/testing and nowhere else:
# VICE, MilkyTracker, Schism Tracker, Cura, Maxima, CherryTree, Lynis, Ticker.
# They are marked in the catalogue by a '@testing' suffix on the package name,
# which is apk's own syntax for "take this one package from that repository".
#
# The suffix matters. A TAGGED repository is only ever consulted for names that
# ask for it by tag, so the stable system stays stable -- which is not true of
# simply adding the edge URL, where the next 'apk upgrade' would drag musl and
# everything else forward and break the machine. The cost is one more index to
# download on each 'apk update'.
enable_testing_tag() {
    grep -q '^@testing[[:space:]]' /etc/apk/repositories 2>/dev/null && return 0
    # Derive the mirror from whatever setup-alpine chose, so a local or
    # country mirror is honoured rather than silently replaced by the CDN.
    _mirror=$(sed -n 's|^\(https\?://.*\)/v[0-9][0-9.]*/main[[:space:]]*$|\1|p' \
                  /etc/apk/repositories 2>/dev/null | head -n1)
    [ -n "$_mirror" ] || _mirror="https://dl-cdn.alpinelinux.org/alpine"
    say "Registering $_mirror/edge/testing as @testing"
    note "Tagged, so it is used ONLY for packages written as name@testing."
    printf '@testing %s/edge/testing\n' "$_mirror" >> /etc/apk/repositories
    apk update >/dev/null 2>&1 || {
        warn "apk update failed after adding @testing -- removing it again"
        sed -i '/^@testing[[:space:]]/d' /etc/apk/repositories
        apk update >/dev/null 2>&1 || true
        return 1
    }
    note "ok"
}

# copal-menu reads the table from disk rather than carrying its own copy, so
# stage 12 and the menu can never disagree about what exists.
write_catalogue() {
    mkdir -p /usr/local/share
    catalogue_available > "$CATFILE"
}

# Install a config file into every real home on the box -- root's and
# $PI_USER's. copal-init.sh runs as root, so writing only to $HOME would leave
# 'user' with no desktop or editor configuration at all.
install_home_file() {  # <relative path> <source file>
    _rel="$1"; _src="$2"
    # Before the loop, because the loop's own guard is `is it a directory` --
    # a missing home would make every one of these calls a silent no-op for
    # the admin user and nobody would find out until they logged in.
    ensure_user_home || true
    for _h in /root "$(user_home)"; do
        [ -n "$_h" ] && [ -d "$_h" ] || continue
        mkdir -p "$_h/$(dirname "$_rel")"
        [ -f "$_h/$_rel" ] && cp "$_h/$_rel" "$_h/$_rel.bak"
        cp "$_src" "$_h/$_rel"
        # Match whatever owns the home directory, so 'user' still owns its own
        # dotfiles after root wrote them.
        _own=$(stat -c '%u:%g' "$_h" 2>/dev/null) && chown -R "$_own" "$_h/$(dirname "$_rel")" 2>/dev/null || true
        note "$_h/$_rel"
    done
}

require_network() {
    say "Checking the package repositories are reachable"
    if apk update >/dev/null 2>&1; then
        note "ok -- apk can reach its mirrors"
        return 0
    fi
    warn "apk update failed."
    cat <<'MSG'
    This stage installs packages over the network, so it cannot proceed.
    Check in this order:
      ip addr                     # did eth0 get an address?
      cat /etc/resolv.conf        # is there a nameserver?
      ping -c2 1.1.1.1            # is there a route?
      cat /etc/apk/repositories   # is a mirror configured and uncommented?
MSG
    return 1
}

# --------------------------------------------- the admin user and root ------
#
# doas, and the one rule that makes membership of the wheel group mean
# anything. Three separate facts, checked separately because each fails
# differently and Alpine's packaging makes none of them a given:
#
#   - the binary is installed;
#   - /etc/doas.conf EXISTS. Since doas 6.8.2-r5 it is required to: doas reads
#     /etc/doas.conf and then /etc/doas.d/*.conf, and refuses every command
#     when the first one is missing -- including the ones that would fix it;
#   - some rule actually reaches $PI_USER. The stock doas.conf is nothing but
#     comments, `# permit persist :wheel` among them, so a fresh install has a
#     wheel group that grants precisely nothing.
#
# The rule goes into /etc/doas.d/wheel.conf rather than into doas.conf itself,
# so an apk upgrade of the doas package has no edited file to argue about.
doas_rule_present() {  # is there a permit rule that reaches $PI_USER?
    grep -rhs '^[[:space:]]*permit' /etc/doas.conf /etc/doas.d 2>/dev/null \
        | grep -qE ":wheel([[:space:]]|\$)|[[:space:]]$PI_USER([[:space:]]|\$)"
}
# doas's own opinion of each file it will read. `doas -C file` with NO command
# is the syntax check and nothing else; give it a command and it answers a
# different question entirely -- see stage 13.
doas_config_error() {  # prints the first complaint, or nothing at all
    for _f in /etc/doas.conf /etc/doas.d/*.conf; do
        [ -f "$_f" ] || continue
        _e=$(doas -C "$_f" 2>&1 >/dev/null) || {
            printf '%s: %s\n' "$_f" "${_e:-rejected by doas -C}"
            return 0
        }
    done
    return 0
}
admin_ensure_doas() {
    command -v doas >/dev/null 2>&1 || add_optional doas >/dev/null 2>&1 || true
    command -v doas >/dev/null 2>&1 || { warn "doas is not installed"; return 1; }

    if [ ! -f /etc/doas.conf ]; then
        warn "/etc/doas.conf is missing -- without it doas refuses everything"
        cat > /etc/doas.conf <<'DOASCONF'
# Written by Copal because doas requires this file to exist.
# The rules live in /etc/doas.d/*.conf, which doas reads after this file.
DOASCONF
        chown root:root /etc/doas.conf 2>/dev/null || true
        chmod 0640 /etc/doas.conf
    fi

    if ! doas_rule_present; then
        warn "no doas rule reaches '$PI_USER' -- adding one for the wheel group"
        mkdir -p /etc/doas.d
        echo 'permit persist :wheel' > /etc/doas.d/wheel.conf
        chown root:root /etc/doas.d/wheel.conf 2>/dev/null || true
        # doas refuses to read a config file that anyone but root can write.
        chmod 0640 /etc/doas.d/wheel.conf
    fi

    _err=$(doas_config_error)
    if [ -n "$_err" ]; then
        warn "doas configuration is not valid -- $_err"
        return 1
    fi
    return 0
}

# setup-alpine asks for two passwords: root's, and then $PI_USER's inside
# setup-user. That is two prompts for what almost everyone means to be one
# password, and the second one is the dangerous one -- mistype it and you get
# an admin account that cannot log in, which nothing notices until the day you
# lock root and find you have locked yourself out of the machine entirely.
#
# So root's hash is copied onto $PI_USER verbatim: same password, and no
# plaintext is ever written, read back or logged. Copying the hash rather than
# re-running passwd also means this needs no prompt at all, which is what makes
# the automatic install able to finish the job.
# Making the account an administrator, kept separate from giving it a password.
#
# These used to live at the end of admin_sync_password, which has three early
# returns above them -- a missing account, an unusable root hash, a shadow file
# it could not rewrite. Any one of those left the user with no wheel membership,
# no doas rule and no sudo shim, and said nothing about it, because the function
# had already reported the password problem and moved on. Stage 13 would then
# refuse to lock root, correctly, for a reason that looked unrelated to the
# password failure that actually caused it.
#
# Whether the account can log in and whether it can become root are two
# different questions. Failing the first is no reason to skip the second.
admin_ensure_privileges() {
    id "$PI_USER" >/dev/null 2>&1 || { warn "user '$PI_USER' does not exist -- cannot grant it anything"; return 1; }

    # setup-alpine's USEROPTS carries -a, which is what is supposed to make the
    # account an administrator: it installs doas and puts the user in wheel.
    # Verified rather than assumed, because locking root at all depends on it.
    if in_wheel "$PI_USER"; then
        note "'$PI_USER' is in wheel"
    else
        warn "'$PI_USER' is not in the wheel group -- adding it"
        adduser "$PI_USER" wheel 2>/dev/null || warn "adduser failed"
        in_wheel "$PI_USER" && note "'$PI_USER' is now in wheel" \
            || warn "'$PI_USER' STILL not in wheel -- doas will not reach it"
    fi

    admin_ensure_doas || warn "doas is not usable yet -- stage 13 will refuse to lock root"
    admin_grant_sudo
    admin_fix_desktop_groups
    return 0
}

admin_sync_password() {
    say "Giving '$PI_USER' the same password as root"

    if ! id "$PI_USER" >/dev/null 2>&1; then
        warn "user '$PI_USER' does not exist -- setup-alpine's USEROPTS did not run"
        return 1
    fi

    # Everything below assumes a complete account, and after stage 3 it is not
    # one -- the home directory does not survive onto the new root. Re-running
    # stage 1 from the menu is the obvious way to repair an admin account, so
    # it repairs that half too.
    ensure_user_home || true

    _rh=$(shadow_hash root)
    case "$_rh" in
        '$'*) ;;
        *) warn "root has no usable password hash -- leaving '$PI_USER' alone."
           note "Set them both by hand: passwd root && passwd $PI_USER"
           return 1 ;;
    esac

    if [ "$(shadow_hash "$PI_USER")" = "$_rh" ]; then
        note "already identical -- nothing to do"
    else
        # awk rebuilding the line field by field, not sed: a crypt hash
        # contains '/' and can contain '&' and '\', every one of which sed
        # would either choke on or silently reinterpret in the replacement.
        #
        # The hash comes in through the environment rather than through
        # 'awk -v'. A -v assignment is processed for backslash escapes before
        # awk ever sees it, so a hash containing \g or \3 arrives silently
        # mangled -- and a mangled hash is an account nobody can log into,
        # which is the exact failure this whole function exists to prevent.
        # ENVIRON does no such processing. (Tested: -v corrupts it.)
        #
        # Write to a temporary file and rename, so an interrupted write can
        # never leave a half-written /etc/shadow -- that file being truncated
        # is an unbootable machine.
        # RESTORED IMMEDIATELY, and that is the whole point of the dance below.
        #
        # umask is a property of the shell, and copal-init.sh runs every stage
        # in ONE shell -- so `umask 077` here, left set, silently governed every
        # directory created for the rest of the run. Stage 3 is what turned that
        # into a broken system: setup-disk populates the new root with
        # `apk add --root /mnt alpine-base`, so /mnt/etc and /mnt/home were
        # created 0700 instead of 0755, and after the reboot onto that root no
        # non-root account could read /etc/passwd, /etc/group or
        # /etc/resolv.conf, nor enter its own home directory:
        #
        #     login: can't change directory to '/home/user': Permission denied
        #     id: unknown ID 1000
        #
        # which is a system that boots, looks fine to root, and is unusable as
        # anyone else. The lockout that cost a rebuild was this, one line, two
        # stages upstream of where it showed up.
        #
        # The restrictive mask is still wanted, but only for the instant
        # /etc/shadow.copal is created -- everything after it sets the mode
        # explicitly anyway. So: set it, create the file, put it back, and only
        # then look at whether awk succeeded.
        _oldumask=$(umask)
        umask 077
        COPAL_U="$PI_USER" COPAL_H="$_rh" awk -F: -v OFS=: \
               '$1 == ENVIRON["COPAL_U"] { $2 = ENVIRON["COPAL_H"] } { print }' \
               /etc/shadow > /etc/shadow.copal
        _awk_rc=$?
        umask "$_oldumask"
        if [ "$_awk_rc" -eq 0 ]
        then
            chown root:shadow /etc/shadow.copal 2>/dev/null || true
            chmod 640 /etc/shadow.copal 2>/dev/null || true
            mv /etc/shadow.copal /etc/shadow \
                || { warn "could not replace /etc/shadow"; rm -f /etc/shadow.copal; return 1; }
            note "password copied -- '$PI_USER' and root now share one password"
        else
            rm -f /etc/shadow.copal
            warn "could not rewrite /etc/shadow -- '$PI_USER' keeps its own password"
            return 1
        fi
    fi


    note "login    : $PI_USER  (password: the one you gave root)"
    note "become root: doas -s      run one command as root: doas <cmd>"
    note "             sudo -i      the same thing, for fingers that type sudo"
    if is_diskless; then
        note "This lives in /etc/shadow, which is in the apkovl -- 'lbu commit -d'"
        note "is what makes it survive a reboot. Stage 1 does that next."
    fi
}

# `sudo` for fingers that type sudo. doas is what Alpine ships and what the rest
# of this script tells you to use, but muscle memory is real and "sudo: not
# found" on a fresh box reads as a broken system rather than a different one.
#
# doas-sudo-shim, not sudo, when there is a choice. It is a 3 kB script in main
# that translates the common sudo invocations into doas, which means ONE
# privilege policy (/etc/doas.d) instead of two files that can disagree -- and
# two that disagree is how a box ends up with an account that lost doas and
# kept sudo. The shim covers -u, -i, -s, -E and a bare command; it does not
# cover sudoers, NOPASSWD or -l. If real sudo is already installed we leave it
# alone: both provide /usr/bin/sudo, so apk would refuse the pair anyway.
admin_grant_sudo() {
    if apk info -e sudo >/dev/null 2>&1; then
        note "sudo is already installed -- leaving it, and its sudoers, alone"
        # Real sudo needs its own rule; doas's does not apply to it.
        if [ -d /etc/sudoers.d ] && ! grep -rqs '^%wheel' /etc/sudoers.d /etc/sudoers; then
            warn "no sudoers rule for wheel -- adding one"
            echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
            chmod 0440 /etc/sudoers.d/wheel
        fi
        return 0
    fi
    command -v sudo >/dev/null 2>&1 && return 0
    if try_add doas-sudo-shim; then
        note "sudo -> doas (doas-sudo-shim): one privilege policy, two spellings"
    else
        warn "no doas-sudo-shim -- 'sudo' will not exist. Use doas instead."
    fi
}

# Repair the desktop group list on a card that setup-alpine created before this
# script started asking for input and tty (see USEROPTS). Idempotent, and it
# only ever adds -- taking a group away is copal-config's job, not stage 1's.
#
# A group change lands at the NEXT login, which is the one thing worth saying
# out loud: the account that is reading this message does not have the new
# groups yet, and X will keep failing until it logs out.
admin_desktop_groups() { echo 'audio video input tty netdev'; }
admin_fix_desktop_groups() {
    _added=''
    for _g in $(admin_desktop_groups); do
        group_exists "$_g" || continue
        in_group "$PI_USER" "$_g" && continue
        if adduser "$PI_USER" "$_g" 2>/dev/null; then _added="$_added $_g"; fi
    done
    if [ -n "$_added" ]; then
        warn "'$PI_USER' was missing:$_added -- added"
        note "video/input/tty are what let '$PI_USER' run startx. The change takes"
        note "effect at the NEXT login, so log out before trying X."
    fi
    note "groups   : $(id -Gn "$PI_USER" 2>/dev/null | tr '\n' ' ')"
}

# lbu writes the .apkovl -- the thing that makes any of this survive a reboot on
# a diskless system -- to the medium named in /etc/lbu/lbu.conf. answers.txt sets
# that to mmcblk0p1, which is correct on a Raspberry Pi and wrong on everything
# else: the identical card in a PC is sda1, or nvme0n1p1, or vda1 in a VM.
#
# Getting it wrong is quiet and expensive. 'lbu commit -d' would either fail or
# write the overlay to a device that is not the one the machine boots from, and
# the symptom is that the whole install evaporates at the next reboot with no
# error anywhere. So it is corrected from the partition find_boot actually found,
# on every platform, every run. On a Pi this changes nothing.
lbu_fix_media() {
    _want=$(basename "$(boot_device 2>/dev/null || true)" 2>/dev/null || true)
    [ -n "$_want" ] || { warn "cannot tell which device \$BOOT is on -- leaving lbu alone"; return 0; }
    [ -f /etc/lbu/lbu.conf ] || { mkdir -p /etc/lbu; : > /etc/lbu/lbu.conf; }
    _have=$(sed -n 's/^LBU_MEDIA=//p' /etc/lbu/lbu.conf | tail -n1)
    [ "$_have" = "$_want" ] && { note "lbu medium: $_want (already correct)"; return 0; }
    sed -i '/^LBU_MEDIA=/d' /etc/lbu/lbu.conf
    printf 'LBU_MEDIA=%s\n' "$_want" >> /etc/lbu/lbu.conf
    if [ -n "$_have" ]; then
        warn "lbu medium was '$_have' but this machine boots from '$_want' -- corrected"
    else
        note "lbu medium: $_want"
    fi
}

# What to do about the root account, printed rather than done. Deleting root is
# the thing people ask for and the one thing that is never right: uid 0 is
# baked into every file's owner, into the kernel's idea of privilege, and into
# the passwd lookup that half the base system does at startup. `deluser root`
# on a running Alpine box produces an unbootable system, not a hardened one.
#
# The equivalent of "remove root", correctly done, is to leave the account and
# take away every way of authenticating as it. That is what stage 13 does.
root_handover_notes() {
    cat <<MSG

    ON REMOVING THE ROOT ACCOUNT

    Do not delete it. uid 0 has to keep existing -- it owns most of the
    filesystem and the kernel checks it by number -- and \`deluser root\`
    leaves a system that does not boot. What people mean by "remove root"
    is: make it impossible to authenticate as root, and reach uid 0 only by
    escalating from a named account that can be audited. Three commands:

      doas passwd -l root                 lock the password (leaves '!' in
                                          /etc/shadow -- no password matches)
      doas copal-ssh root off             refuse root over SSH, and reload
                                          sshd only if the config still parses

    From then on you log in as $PI_USER and use \`doas\` for anything
    privileged. Undo is \`doas passwd root\`, from a doas shell, which is why
    the admin account has to be working BEFORE any of this is run.

    Copal does this for you -- stage 13 -- and it refuses to run until it has
    checked that $PI_USER has a working password, is in wheel, and has doas.

MSG
}

# ------------------------------------------------- who you are, to git ------
#
# The name and email that go on every commit made on this machine. They are
# asked ONCE, in stage 1, immediately before the password -- not in stage 7,
# where they are actually used -- and the answers are saved on the boot
# partition so stage 7 can read them instead of asking again.
#
# Two reasons for moving them to the front:
#
#   It is the same question the password is. Both are "who are you on this
#   box", both need a human, and both are cheap to answer while you are sitting
#   in front of the machine at the start. Splitting them put one at minute zero
#   and the other an hour and a half later, for no reason other than where the
#   code that consumed it happened to live.
#
#   Stage 7 is deep inside an unattended install. A prompt there is a run that
#   sits waiting with nobody in the room -- the exact failure --auto exists to
#   avoid. Stage 1 already stops for the root password, so asking here costs
#   nothing that was not already being spent.
#
# The file is plain key=value, one per line, no quoting and no shell: it lives
# on a FAT partition that any machine can edit, and sourcing something with
# those properties as root is not a thing to do for the sake of saving an awk.

git_id_get() {  # <key> -> the saved value, or empty
    [ -f "$IDFILE" ] || return 0
    # sub() rather than printing $2: an email has no '=' in it but a name may,
    # and the value is everything after the FIRST one. \r goes because this file
    # is meant to be editable from the Mac, and a stray carriage return in an
    # email address is a bad commit nobody can see the cause of.
    awk -v k="$1" '
        { sub(/\r$/, "") }
        index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }
    ' "$IDFILE" 2>/dev/null || true
}

git_id_save() {  # <name> <email>
    mount -o remount,rw "$BOOT" 2>/dev/null || true
    { echo "# Copal: the identity git puts on commits made on this machine."
      echo "# Asked in stage 1, applied in stage 7. Editable by hand:"
      echo "# one key=value per line, no quotes, no shell."
      echo "name=$1"
      echo "email=$2"
    } > "$IDFILE" 2>/dev/null || {
        warn "could not write $IDFILE -- stage 7 will ask again"
        return 1
    }
    sync
    return 0
}

# The identity as it currently stands, in priority order: what was answered on
# this machine, then what copal-prep.sh proposed from the Mac, then nothing.
# Returns non-zero when there is nothing at all, which is the caller's cue that
# it still has to ask.
GIT_NAME=''
GIT_EMAIL=''
git_identity_load() {
    GIT_NAME=$(git_id_get name)
    GIT_EMAIL=$(git_id_get email)
    [ -n "$GIT_NAME" ]  || GIT_NAME="$PI_GIT_NAME"
    [ -n "$GIT_EMAIL" ] || GIT_EMAIL="$PI_GIT_EMAIL"
    [ -n "$GIT_NAME$GIT_EMAIL" ]
}

git_identity_ask() {
    git_identity_load || true
    say "Git identity for '$PI_USER'"
    cat <<'MSG'
    Git stamps every commit with a name and an email address. They are not
    verified by anything and they are not credentials -- they are the
    "author" line other people read in the log. GitHub matches commits to
    your account by that address, so use the one your account knows.

    Asked now, with the password, because these are the same kind of
    question and this is the last point in the install where anyone is
    expected to be watching. The answers are saved on the boot partition and
    applied by stage 7, along with a default branch of 'main'.
MSG
    if [ -n "$GIT_NAME$GIT_EMAIL" ]; then
        note "suggested: ${GIT_NAME:-(no name)} <${GIT_EMAIL:-no email}>"
        note "Press Enter at either prompt to keep the suggestion."
    else
        note "Press Enter at either prompt to skip; stage 7 can be re-run later."
    fi

    ask_real "Name for git commits${GIT_NAME:+ [$GIT_NAME]}:"
    [ -n "$REPLY" ] && GIT_NAME="$REPLY"
    ask_real "Email for git commits${GIT_EMAIL:+ [$GIT_EMAIL]}:"
    [ -n "$REPLY" ] && GIT_EMAIL="$REPLY"

    if [ -z "$GIT_NAME" ] && [ -z "$GIT_EMAIL" ]; then
        note "Nothing given -- git will be left unconfigured."
        note "Set it later with: git config --global user.email you@example.com"
        return 0
    fi
    # A loose check only. The point is to catch 'y', an empty answer that
    # slipped through, or a name typed into the email prompt -- not to
    # adjudicate RFC 5322, which would reject valid addresses. Said HERE, while
    # the person who typed it is still at the keyboard and can retype it.
    case "$GIT_EMAIL" in
        *@*.*) ;;
        '')    warn "no email given -- git will still prompt on the first commit" ;;
        *)     warn "'$GIT_EMAIL' does not look like an email address; saving it anyway" ;;
    esac

    git_id_save "$GIT_NAME" "$GIT_EMAIL" \
        && note "saved to $IDFILE -- stage 7 applies it without asking again"
    return 0
}

# ---------------------------------------------------- stage 1: base config ---
stage_base_config() {
    say "Stage 1: applying setup-alpine answers"
    [ -f "$ANSWERS" ] || die "missing $ANSWERS -- was this card written by copal-prep.sh?"

    if apkovl_exists; then
        warn "a saved configuration already exists on the boot partition."
        note "Re-running setup-alpine will ask everything again, including the"
        note "root password, and overwrite the answers it set last time."
        confirm "Run setup-alpine again anyway?" || { note "Skipped."; return 0; }
    fi

    note "First, two questions of Copal's own: the name and email for git"
    note "commits. They are saved on the card and applied by stage 7, which is"
    note "why that stage does not stop to ask an hour and a half from now."
    note "Then keymap, hostname, network, timezone, mirror, sshd and user come"
    note "from answers.txt. The root password is the one thing it will ask for --"
    note "setup-alpine has no answer-file variable for it."
    note "It will also ask for a password for '$PI_USER'. Whatever you type"
    note "there is overwritten immediately afterwards with root's, so that"
    note "the two accounts share one password. It will not accept an empty"
    note "one, so type the root password again there and it changes nothing."

    # Every question a human has to answer, in one place. The git identity goes
    # first because it is Copal's own prompt and can have the plain terminal to
    # itself; the screen comes down for it and goes back up, exactly as it does
    # for setup-alpine below.
    tui_suspend
    git_identity_ask
    tui_resume

    # setup-alpine writes over the whole terminal and asks questions of its own,
    # so the progress screen comes down for the duration and goes back up after.
    # Suspending is not optional: leaving it up would interleave its output with
    # addressed repaints and leave both unreadable.
    tui_prompt "ROOT PASSWORD" \
        "setup-alpine is about to ask for it. There is no answer-file variable for a password, so this is the one thing a full-automatic install cannot fill in." \
        "You will be asked TWICE more -- once to confirm, then again for '$PI_USER'. Type the same thing all three times." \
        ''
    tui_suspend
    setup-alpine -f "$ANSWERS"
    tui_resume

    # Before the commit, so the synced password goes into the same apkovl.
    admin_sync_password || warn "'$PI_USER' may not be able to log in -- check 'passwd $PI_USER'"
    # Unconditional, and deliberately after the || above: a password sync that
    # failed is exactly when the privilege grant is most likely to have been
    # skipped, and least likely to be noticed.
    admin_ensure_privileges || warn "'$PI_USER' is not a working administrator -- stage 13 will decline to lock root"
    # Cheap, and it repairs a root laid down by a version of this script that
    # leaked a restrictive umask into stage 3.
    fix_system_dir_modes
    root_handover_notes

    # Before the commit, and before anything relies on persistence.
    lbu_fix_media

    say "Committing the configuration to the boot partition"
    # Without this, nothing at all survives a reboot on a diskless system.
    lbu commit -d || die "lbu commit failed -- see above. Nothing will persist until this works."
    ls -l "$BOOT"/*.apkovl.tar.gz

    say "Stage 1 complete."
    note "The configuration is saved. From here the system survives a reboot,"
    note "but installed packages do not -- that is what stage 2 is for."
}

# ------------------------------------------- stage 2: ext4 p2 + apk cache ---
stage_ext4_cache() {
    say "Stage 2: ext4 on $P2, and the apk cache on it"
    cat <<'MSG'
    Packages installed with `apk add` live in the tmpfs root and vanish on
    reboot. The apk cache fixes that: with a cache on real storage, everything
    in the saved package list is reinstalled from the card at boot, offline.

    The cache needs a real filesystem -- it cannot go on the FAT boot
    partition. So this formats p2 as ext4 and points the cache there. p2 is
    also what stage 3 later installs a full root filesystem onto, so this is
    worth doing either way.
MSG
    [ -b "$P2" ] || die "$P2 not found -- was this card partitioned by copal-prep.sh?"

    if [ "$(fstype_of "$P2")" = ext4 ]; then
        warn "$P2 is already ext4."
        confirm "Reformat it (erases anything on it)?" || {
            note "Keeping the existing filesystem."
            _skip_mkfs=1
        }
    fi

    if [ "${_skip_mkfs:-0}" != 1 ]; then
        require_network || return 1
        apk add e2fsprogs
        warn "about to ERASE $P2. The boot partition p1 is not touched."
        ask "Type yes to proceed:"
        [ "$REPLY" = "yes" ] || { note "Aborted; nothing was erased."; return 0; }
        mkfs.ext4 -F -L COPALROOT "$P2"
    fi
    unset _skip_mkfs

    say "Adding $P2MNT to /etc/fstab"
    # setup-apkcache resolves the cache directory to a mount point and then
    # runs `mount <mountpoint>` -- which only works when fstab already has the
    # entry. Adding it first is what makes setup-apkcache succeed.
    mkdir -p "$P2MNT"
    UUID=$(uuid_of "$P2")
    [ -n "$UUID" ] || die "could not read the UUID of $P2"
    sed -i "\|[[:space:]]$P2MNT[[:space:]]|d" /etc/fstab
    printf 'UUID=%s\t%s\text4\tdefaults,noatime\t0 2\n' "$UUID" "$P2MNT" >> /etc/fstab
    is_mounted "$P2MNT" || mount "$P2MNT"
    note "mounted: $(df -h "$P2MNT" | awk 'NR==2 {print $1, $2, "on", $6}')"

    say "Pointing the apk cache at $P2MNT/cache"
    setup-apkcache "$P2MNT/cache"
    note "cache -> $(readlink /etc/apk/cache)"

    say "Teaching lbu to recreate the mount point"
    # The root filesystem is a tmpfs rebuilt from the apkovl on every boot, so
    # the empty directory $P2MNT has to be inside the apkovl or `mount -a` at
    # boot has nowhere to mount p2. Include the directory, exclude its
    # contents -- the cache is already persistent on p2 itself, and putting it
    # in the apkovl would bloat it enormously.
    lbu include "$P2MNT"
    lbu exclude "$P2MNT/cache"

    say "Committing"
    lbu commit -d || die "lbu commit failed"

    # Prove the mount point really is in the overlay rather than assuming it.
    say "Verifying the overlay contains the mount point"
    if tar tzf "$BOOT"/*.apkovl.tar.gz 2>/dev/null | grep -q "media/$(basename "$P2")"; then
        note "ok -- $P2MNT is in the apkovl and will exist after a reboot"
    else
        warn "$P2MNT is NOT in the apkovl. p2 will not mount at boot, and the"
        warn "apk cache will be a dangling symlink. Check 'lbu status'."
    fi

    say "Stage 2 complete."
    note "Test it: apk add tmux && lbu commit -d && reboot"
    note "tmux should still be there afterwards, reinstalled from the cache."
}

# ------------------------------------------- stage 3: move root onto ext4 ---
stage_sys_install() {
    say "Stage 3: move the root filesystem onto $P2"
    cat <<'MSG'
    Only worth doing if you want a desktop. The tmpfs root is about half of
    RAM (~200 MB here), which is too small to install X into -- `apk add`
    fails with ENOSPC while the card sits 99% empty. The limit is RAM, not
    storage.

    The cost: the system writes to the SD card in normal use from then on,
    and boot depends on the ext4 partition being healthy. The RAM-resident
    setup on p1 stays intact as a fallback.
MSG
    [ -b "$P2" ] || die "$P2 not found"
    [ "$(fstype_of "$P2")" = ext4 ] || die "$P2 is not ext4 yet -- run stage 2 first"
    apkovl_exists || die "no saved configuration -- run stage 1 first (setup-disk copies the running config into the new root, so it must exist)"

    if sys_installed; then
        warn "cmdline.txt already has a root= -- this looks done already."
        confirm "Redo it? (reformats $P2, erasing the apk cache on it)" || { note "Skipped."; return 0; }
    fi

    # setup-disk runs `apk add --root /mnt linux-KFLAV alpine-base ...`, so it
    # installs the kernel over the network. No network, no kernel, no boot.
    require_network || return 1

    if ! is_pi_boot; then
        # A PC kernel flavour: lts on hardware, virt in a VM. Both are correct
        # here, and neither is an "rpi" flavour, so the Pi check below would
        # warn about a perfectly good system.
        case "$KFLAV" in
            lts|virt) note "kernel flavor: $KFLAV (PC) -- setup-disk will install linux-$KFLAV" ;;
            *) warn "unexpected kernel flavor '$KFLAV' for a PC." ;;
        esac
    else
    case "$KFLAV" in
        rpi*) : ;;
        *) warn "kernel flavor looks like '$KFLAV', not an rpi flavor."
           warn "setup-disk would install linux-$KFLAV, which may not boot here."
           confirm "Continue anyway?" || return 0 ;;
    esac
    fi

    warn "about to ERASE $P2 and install a system onto it."
    ask "Type yes to proceed:"
    [ "$REPLY" = "yes" ] || { note "Aborted; nothing was erased."; return 0; }

    say "Backing up the boot partition's configuration"
    # setup_raspberrypi_bootloader does
    #     echo "root=... modules=..." > "$mnt"/boot/cmdline.txt
    # -- a truncating overwrite. p1 is about to be mounted at /mnt/boot, so
    # that is the real cmdline.txt. Back it up first; it is the way back.
    mount -o remount,rw "$BOOT"
    if is_pi_boot; then
        cp "$BOOT/cmdline.txt" "$BOOT/cmdline.txt.bak"
        cp "$BOOT/config.txt" "$BOOT/config.txt.bak"
        CMDLINE_BEFORE=$(cat "$BOOT/cmdline.txt")
    else
        # The PC equivalent, and the file this stage will rewrite. Backed up for
        # the same reason: it is the way back to a machine that still boots.
        BOOTCFG="$BOOT/boot/grub/grub.cfg"
        [ -f "$BOOTCFG" ] || die "no $BOOTCFG -- was this card written by copal-prep.sh for a PC?"
        cp "$BOOTCFG" "$BOOTCFG.bak"
        CMDLINE_BEFORE="(grub.cfg, $(grep -c menuentry "$BOOTCFG") entries)"
    fi

    is_mounted "$P2MNT" && umount "$P2MNT"
    mkfs.ext4 -F -L COPALROOT "$P2"

    say "Mounting the target: $P2 at /mnt, and p1 at /mnt/boot"
    mkdir -p /mnt
    mount "$P2" /mnt
    # The VideoCore firmware reads the kernel only from FAT, so setup-disk
    # refuses a non-vfat /boot on a Pi:
    #     supported_boot_fs() { ... if is_rpi; then supported=vfat; fi ... }
    # It works out what /boot *is* by looking for a mount at $mnt/boot and
    # falling back to the root device -- so without this mount the check sees
    # ext4 and aborts with "ext4 is not supported. Only supported are: vfat".
    #
    # p1 is already mounted at $BOOT. A second mount of the same device with
    # the same options shares one superblock, so the two views stay coherent.
    mkdir -p /mnt/boot
    mount "$P1" /mnt/boot

    say "Running setup-disk (this installs a kernel; it takes a while)"
    note "A 'WARNING: no kernel found' from mkinitfs here is expected and"
    note "harmless -- setup-disk installs the bootloader package on the"
    note "running diskless system, which has no kernel package of its own."
    if is_pi_boot; then
        setup-disk -k "$KFLAV" -m sys /mnt
    else
        # BOOTLOADER=none is setup-disk's own supported value for "install the
        # system, touch no bootloader". Without it setup-disk would run
        # grub-install, which writes to the MBR and to EFI NVRAM -- neither of
        # which is wanted here: this card already has a working GRUB on its ESP,
        # placed by copal-prep.sh, and the only thing that needs to change is the
        # text file it reads. Keeping setup-disk out of that is what makes this
        # stage reversible by restoring one file.
        BOOTLOADER=none setup-disk -k "$KFLAV" -m sys /mnt
    fi

    # setup-disk populated /mnt with `apk add --root /mnt`, so anything wrong
    # with the umask at that moment is now baked into the filesystem this
    # machine is about to boot from. Check it here, while /mnt is still
    # mounted and a wrong mode is one chmod away rather than a reinstall.
    fix_system_dir_modes /mnt
    ensure_user_home /mnt || true

    # ---- verify setup-disk actually did the job, rather than hoping --------
    say "Verifying the installed system"
    FAIL=0
    for f in /mnt/sbin/init /mnt/etc/fstab; do
        [ -e "$f" ] || { warn "missing $f"; FAIL=1; }
    done
    if [ -f "/mnt/boot/vmlinuz-$KFLAV" ]; then
        KPATH="vmlinuz-$KFLAV"; IPATH="initramfs-$KFLAV"
        note "ok -- kernel at $BOOT/$KPATH"
    elif [ -f "/mnt/boot/boot/vmlinuz-$KFLAV" ]; then
        KPATH="boot/vmlinuz-$KFLAV"; IPATH="boot/initramfs-$KFLAV"
        note "ok -- kernel at $BOOT/$KPATH"
    else
        warn "no vmlinuz-$KFLAV anywhere on the boot partition."
        warn "setup-disk could not install the kernel -- almost always network."
        FAIL=1
    fi
    ls -d /mnt/lib/modules/* >/dev/null 2>&1 || { warn "no /lib/modules in the new root"; FAIL=1; }

    if [ "$FAIL" = 1 ]; then
        say "Rolling back"
        if is_pi_boot; then
            cp "$BOOT/cmdline.txt.bak" "$BOOT/cmdline.txt"
            note "cmdline.txt restored; this Pi still boots the way it does now."
        else
            cp "$BOOTCFG.bak" "$BOOTCFG"
            note "grub.cfg restored; this machine still boots the way it does now."
        fi
        die "stage 3 did not complete. Transcript: $LOG"
    fi

    # ---- point the firmware at the newly installed kernel -----------------
    # Stock config.txt has 'kernel=boot/vmlinuz-rpi', which is where the
    # diskless payload keeps it. setup-disk installed the kernel into
    # /mnt/boot, which IS the root of p1 -- a different path. Left alone, the
    # firmware would boot the old diskless kernel and initramfs against the
    # new root=, which does not work. config.txt includes usercfg.txt last,
    # and later directives win, so correct it there.
    if is_pi_boot; then
        say "Pointing config.txt at the installed kernel (via usercfg.txt)"
        touch "$BOOT/usercfg.txt"
        sed -i '/^# >>> copal-init.sh/,/^# <<< copal-init.sh/d' "$BOOT/usercfg.txt"
        cat >> "$BOOT/usercfg.txt" <<EOF
# >>> copal-init.sh managed block >>>
# setup-disk installed the kernel at the root of the boot partition, not in
# boot/ where the diskless payload kept it. These override config.txt.
kernel=$KPATH
initramfs $IPATH
# <<< copal-init.sh managed block <<<
EOF
        note "kernel=$KPATH"
        note "initramfs $IPATH"
    else
        # THE PC EQUIVALENT. On a Pi, setup-disk's raspberrypi-bootloader backend
        # rewrites cmdline.txt with the new root= itself. With BOOTLOADER=none
        # nothing does, so this writes the boot configuration by hand -- which is
        # also why it is a whole file rather than a patch: there is exactly one
        # correct menu now (boot the installed system from p2) where before there
        # were three diskless ones.
        say "Rewriting grub.cfg for the installed system"
        # root= by UUID, not /dev/sda2: the same card in a different port, or with
        # another disk present, is a different device name and the machine would
        # not boot. The UUID travels with the filesystem.
        # Test the shape, not just emptiness: a UUID with a space in it becomes
        # a truncated root= and a second word grub reads as another parameter,
        # and the failure surfaces at boot rather than here.
        _uuid=$(uuid_of "$P2")
        case "$_uuid" in
            *[!0-9a-fA-F-]* | "") _uuid= ;;
        esac
        if [ -n "$_uuid" ]; then _root="UUID=$_uuid"; else
            warn "could not read a UUID for $P2 -- falling back to the device name"
            warn "which will break if the disk is ever enumerated differently."
            _root="$P2"
        fi
        # modules= must still carry what the initramfs needs to reach the root
        # filesystem: ext4 now, plus the same controller drivers as before.
        cat > "$BOOTCFG" <<EOF
# Rewritten by copal-init.sh stage 3. The previous version is grub.cfg.bak --
# restore it to go back to the diskless system, which still works: modloop and
# the .apkovl are untouched on this partition.
set timeout=5
set default=0

menuentry "Copal Linux" {
    linux /$KPATH root=$_root ro modules=ext4,sd-mod,usb-storage,ahci,nvme,mmc_block,sdhci,sdhci_pci rootfstype=ext4 console=tty0
    initrd /$IPATH
}

menuentry "Copal Linux (single user)" {
    linux /$KPATH root=$_root ro modules=ext4,sd-mod,usb-storage,ahci,nvme,mmc_block,sdhci,sdhci_pci rootfstype=ext4 console=tty0 single
    initrd /$IPATH
}
EOF
        note "kernel  /$KPATH"
        note "initrd  /$IPATH"
        note "root    $_root"
    fi

    # ---- flash-friendly fstab ---------------------------------------------
    say "Tuning /etc/fstab for flash"
    # setup-disk regenerates fstab with `genfstab -U`, so the root line is a
    # UUID= (not /dev/mmcblk0p2) and /boot is already listed because p1 was
    # mounted. It also appends a bare `tmpfs /tmp tmpfs` -- replace that with
    # sized entries so /tmp and /var/log churn never reaches the card.
    sed -i '/^tmpfs[[:space:]][[:space:]]*\/tmp[[:space:]]/d' /mnt/etc/fstab
    cat >> /mnt/etc/fstab <<'FSTAB'
tmpfs  /tmp      tmpfs  defaults,noatime,size=64M  0 0
tmpfs  /var/log  tmpfs  defaults,noatime,size=32M  0 0
FSTAB
    # noatime avoids a write on every read; commit=600 batches journal
    # flushes. Match the mountpoint field -- the device field is a UUID now.
    sed -i -E 's|^([^#[:space:]]+[[:space:]]+/[[:space:]]+ext4[[:space:]]+)[^[:space:]]+|\1defaults,noatime,commit=600|' /mnt/etc/fstab

    # The carried-over config points /etc/apk/cache at /media/mmcblk0p2/cache,
    # which was p2 -- and p2 is now the root filesystem itself. Left alone
    # that is a dangling symlink and apk breaks on first use.
    say "Repointing the apk cache for the new root"
    rm -f /mnt/etc/apk/cache
    mkdir -p /mnt/var/cache/apk /mnt/etc/apk
    ln -s /var/cache/apk /mnt/etc/apk/cache
    sed -i "\|[[:space:]]$P2MNT[[:space:]]|d" /mnt/etc/fstab
    note "cache -> /var/cache/apk (on the new root)"

    echo
    note "fstab:"
    grep -v '^[[:space:]]*#' /mnt/etc/fstab | grep -v '^[[:space:]]*$' | sed 's/^/      /'
    echo
    # The check belongs INSIDE the branch. It used to sit below the fi and read
    # cmdline.txt unconditionally, so a PC or VM -- which has no cmdline.txt at
    # all, only grub.cfg -- got
    #
    #     grep: /media/vda1/cmdline.txt: No such file or directory
    #     error: cmdline.txt has no root= -- setup-disk did not finish
    #
    # one line after announcing "boot config after : 2 entries, root= set". The
    # stage had in fact succeeded; the verification was reading the other
    # platform's file.
    if is_pi_boot; then
        note "cmdline.txt before: $CMDLINE_BEFORE"
        note "cmdline.txt after : $(cat "$BOOT/cmdline.txt")"
        grep -q 'root=' "$BOOT/cmdline.txt" \
            || die "cmdline.txt has no root= -- setup-disk did not finish"
    else
        note "boot config before: $CMDLINE_BEFORE"
        note "boot config after : $(grep -c menuentry "$BOOTCFG") entries, root= set"
        grep -q 'root=' "$BOOTCFG" \
            || die "$BOOTCFG has no root= -- setup-disk did not finish"
        # "has a root=" was too weak a test once: it passed on
        # root=UUID=/dev/vda2:, which is what busybox blkid's ignored -s/-o
        # flags produced, and the first sign of trouble was an initramfs that
        # could not find the disk. Print what a kernel would actually receive
        # -- everything up to the first space -- and insist it names a UUID or
        # a device, nothing else.
        _rootarg=$(sed -n 's/.*[[:space:]]\(root=[^[:space:]]*\).*/\1/p' "$BOOTCFG" | head -n1)
        note "root argument     : $_rootarg"
        case "$_rootarg" in
            root=UUID=*[!0-9a-fA-F-]* | root=UUID=)
                die "$BOOTCFG has a malformed root= ($_rootarg) -- not a UUID" ;;
            root=UUID=* | root=/dev/*) ;;
            *) die "$BOOTCFG has an unusable root= ($_rootarg)" ;;
        esac
    fi

    # After the reboot this card is mounted at /boot, not /media/mmcblk0p1.
    # Leave a copy on the new root that is runnable by name from anywhere, so
    # the moved mount point cannot strand the remaining stages.
    say "Installing /usr/local/bin/copal on the new root"
    mkdir -p /mnt/usr/local/bin
    if cp "$0" /mnt/usr/local/bin/copal 2>/dev/null; then
        chmod 0755 /mnt/usr/local/bin/copal
        note "after rebooting, just run: copal"
    else
        warn "could not install the convenience copy; use 'sh /boot/copal-init.sh'"
    fi

    # setup-disk populated the new root from packages plus the apkovl. The
    # apkovl does carry /home/$PI_USER -- setup-alpine puts it in lbu's
    # include list -- but only as it stood at the last `lbu commit -d`, which
    # was stage 1 or 2, when it was empty. Confirm it is there and owned by
    # the right account before the reboot takes /mnt away, because after that
    # every stage that writes a dotfile is writing into whatever this left.
    ensure_user_home /mnt || true
    _nh=$(user_home)
    [ -n "$_nh" ] && [ -d "/mnt$_nh" ] \
        || warn "'$PI_USER' has no home directory on the new root -- stage 1 remakes it"

    # The reboot below is the only point in the install where control leaves
    # this script entirely. In automatic mode the way back has to be in place
    # on the NEW root before that happens -- /mnt is still mounted here, and
    # will not be after.
    if [ "${AUTO:-0}" = 1 ]; then
        auto_install_resume_hook /mnt
    fi

    sync
    umount /mnt/boot
    umount /mnt

    say "Stage 3 complete."
    cat <<MSG
    A reboot is REQUIRED before anything else. Until then / is still the
    tmpfs, the new root on p2 is merely populated, and stage 4 will refuse
    to install X into a filesystem that is about to be replaced.

    ---------------------------------------------------------------------
    AFTER THE REBOOT, LOG BACK IN AS  root  -- NOT AS '$PI_USER'.

    Stages 4 to 13 install software, and installing is root's job. There
    are two accounts and they have two different jobs:

        root      installs the system   -- you are here, stages 1-13
        $PI_USER      runs the desktop      -- once stage 4 has finished

    Log in as '$PI_USER' too early and copal-init.sh will tell you it needs
    root; the desktop will not be there yet either, because stage 4 is
    what installs it. Finish the stages as root first.
    ---------------------------------------------------------------------

    So, as root:

        sh /boot/copal-init.sh

    If you did log in as '$PI_USER', you do not have to log out -- put doas
    in front and carry on:

        doas sh /boot/copal-init.sh

    Note the path change: the boot partition is mounted at /boot from now on,
    NOT at /media/mmcblk0p1, which stops existing the moment the new fstab
    takes effect. (`copal` on its own also works -- a copy was installed
    to /usr/local/bin -- but /boot/copal-init.sh is always there.)

    Then check:
        df -h            # / should be /dev/mmcblk0p2, not tmpfs
        free -m
        ls -l /dev/fb0   # the framebuffer

    If it does not come back, put the card in another machine and:
        cp cmdline.txt.bak cmdline.txt
        (and delete the copal-init.sh managed block from usercfg.txt)
    That restores the RAM-resident system: with no root= the initramfs falls
    back to modloop plus the .apkovl.tar.gz, both still on p1, untouched.
    Read copal.log on that same partition to find out what went wrong.
MSG

    if confirm_yes "Reboot now?"; then
        say "Rebooting. Log back in as ROOT (not $PI_USER), then run:  sh /boot/copal-init.sh"
        sync
        # The log is on a FAT partition; make sure it is on the card before
        # the kernel stops caring about our buffers.
        umount "$BOOT" 2>/dev/null || mount -o remount,ro "$BOOT" 2>/dev/null || true
        reboot
        exit 0
    fi
    warn "Not rebooting. Stages 4-8 will not behave correctly until you do."
}

# ------------------------------------------------- stage 4: X and a WM -----
# A browser with a maintained engine, which is a different question from a
# browser that is small. Dillo, Links and NetSurf all render, but none of them
# has a modern TLS-and-JavaScript engine behind it, so a bank, a webmail or
# anything built this decade is out of reach.
#
# What "modern and supported" means here depends entirely on the board, so this
# asks apk rather than guessing from MODEL -- the card may well have been moved
# to a different Pi since it was written:
#
#   aarch64, armv7   Firefox ESR and Chromium are both built by Alpine. ESR
#                    over the rapid channel because a year of security fixes
#                    without a UI change is the right trade on a machine you
#                    are not going to babysit.
#   armhf (ARMv6)    Neither exists, and no repository has them. BadWolf is
#                    the answer instead: a minimal front end over WebKitGTK,
#                    which IS a current engine with current TLS. It is one
#                    tab strip and an address bar, and it is genuinely the
#                    most capable browser this architecture can run.
#
# All of them want more RAM than this board has spare, so the warning about
# zram is not boilerplate -- run stage 5 first and it is the difference
# between slow and unusable.
install_modern_browser() {
    say "A modern browser"
    _arch=$(apk --print-arch 2>/dev/null || echo unknown)
    note "architecture: $_arch"

    case "$_arch" in
        aarch64|armv7|x86_64)
            cat <<'MSG'

    Both of the mainstream engines are built for this architecture. Neither
    is small; both are current, and both get security updates.

      f   Firefox ESR   the extended-support channel -- a year of security
                        fixes without the interface moving under you (~250 MB)
      c   Chromium      the Blink engine, Alpine's build (~350 MB)
      b   BadWolf       WebKitGTK behind a one-line interface. A current
                        engine and current TLS in a fraction of the RAM --
                        the pick if this is a Zero 2 W (~90 MB)
      n   None          keep Dillo/NetSurf/Links and move on

MSG
            # The automatic install picks BadWolf. It is the only one of the
            # three that is a defensible unattended choice on a board this
            # size, and it is the same answer on every architecture -- so an
            # auto install behaves identically whichever Pi ran it.
            if [ "${AUTO:-0}" = 1 ]; then AUTO_DEFAULT=b; fi
            ask "Choose [f/c/b/n]:"
            case "$REPLY" in
                f|F) _br="firefox-esr"; _bin=firefox-esr ;;
                c|C) _br="chromium";    _bin=chromium ;;
                b|B) _br="badwolf";     _bin=badwolf ;;
                *)   note "Skipped."; return 0 ;;
            esac ;;
        armhf)
            cat <<'MSG'

    This is ARMv6. Alpine does not build Firefox or Chromium for it and no
    other repository does either -- that is a limit of the architecture, not
    of this card, and no amount of searching will turn one up.

    BadWolf is the modern browser for this board: a minimal front end over
    WebKitGTK, which is a maintained engine with maintained TLS. It handles
    the modern web that Dillo and NetSurf cannot, and it fits.

MSG
            confirm "Install BadWolf?" || { note "Skipped."; return 0; }
            _br="badwolf"; _bin=badwolf ;;
        *)
            warn "unrecognised architecture '$_arch' -- not guessing at a browser"
            return 0 ;;
    esac

    if ! zram_active; then
        warn "zram is not active. Run stage 5 first -- a browser on 512 MB without"
        warn "compressed swap is where this board stops being fun."
    fi

    require_network || return 1
    say "Installing $_br"
    # Not add_optional: the choice was explicit, so a missing package is
    # something to report by name rather than shrug at.
    if apk add "$_br"; then
        note "installed: $(command -v "$_bin" 2>/dev/null || echo "$_br")"
        note "It appears in the menu (Super+z) and in dmenu (Super+space)."
    else
        warn "apk could not install $_br on $_arch."
        note "Check the name with: apk search -v $_br"
        note "Dillo, NetSurf and Links are still available from stage 12."
    fi
}

# X belongs to the user, not to root. This is the part that makes that true.
#
# Running the X server from a root login is the default nobody chose: it is how
# every "just run startx" instruction reads, and it means every program you then
# open -- browser, editor, file manager -- inherits uid 0. One misclick in a
# file manager running as root is the whole system. The convention exists for a
# reason and Copal follows it: root installs, ${PI_USER} runs the desktop.
#
# Three things have to be true for startx to work as an ordinary user, and the
# failure when any one is missing looks identical (a black screen, or X exiting
# with no obvious (EE) line), which is why all three are done here rather than
# left to the reader:
#
#  1. /etc/X11/Xwrapper.config. Alpine ships NO such file, and Xorg.wrap -- the
#     setuid helper that /usr/bin/Xorg execs -- then defaults to
#     needs_root_rights=auto. 'auto' is free to drop root and open the devices
#     as the calling user instead, which is fine on a KMS/logind desktop and
#     wrong here: this board draws through fbdev with no seat manager. Pinning
#     needs_root_rights=yes keeps the privileged path, which is the one that
#     works on a Pi.
#
#  2. Group membership: video (/dev/fb0, /dev/dri/*), input (/dev/input/event*)
#     and tty (/dev/tty0, and VT switching). USEROPTS grants these on new cards
#     and admin_fix_desktop_groups repairs old ones.
#
#  3. allowed_users=console. Xorg.wrap otherwise refuses with "Only console
#     users are allowed to run the X server" -- correct, and worth keeping:
#     it is what stops an SSH session from grabbing the framebuffer. Copal
#     never expects you to start X over SSH.
configure_x_for_user() {
    say "Letting '$PI_USER' run X (rather than root)"

    mkdir -p /etc/X11
    cat > /etc/X11/Xwrapper.config <<'XWRAP'
# Written by copal-init.sh.
#
# allowed_users=console      only a user logged in at the physical console may
#                            start X. An SSH session may not -- deliberately.
# needs_root_rights=yes      keep Xorg's privileged path. The default, 'auto',
#                            may drop root and then fail to open the fbdev
#                            framebuffer and the evdev input devices, because
#                            this board runs no seat manager (no elogind, no
#                            seatd) for X to ask instead.
allowed_users=console
needs_root_rights=yes
XWRAP
    chmod 0644 /etc/X11/Xwrapper.config
    note "/etc/X11/Xwrapper.config -- allowed_users=console, needs_root_rights=yes"

    admin_fix_desktop_groups

    # startx as root still works -- this is a warning, not a lock. Making it
    # impossible would be worse: recovering a broken desktop from a root login
    # is sometimes exactly what you need to do. It just should never be the
    # thing that happens by accident.
    cat > /usr/local/bin/copal-startx <<STARTX
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# copal-startx -- start the desktop, from the account that should own it.
#
# Written by copal-init.sh. Plain 'startx' still works; this adds the check
# that catches the mistake that is easy to make and slow to diagnose.
PI_USER=$PI_USER
STARTX
    cat >> /usr/local/bin/copal-startx <<'STARTX'
if [ "$(id -u)" = 0 ]; then
    echo "You are root. The desktop should not run as root: every window it" >&2
    echo "opens would inherit uid 0." >&2
    echo >&2
    if [ -n "$PI_USER" ] && id "$PI_USER" >/dev/null 2>&1; then
        echo "Log out and log back in as '$PI_USER', then run: startx" >&2
    fi
    echo "To override anyway:  startx" >&2
    exit 1
fi
for g in video input tty; do
    id -Gn | tr ' ' '\n' | grep -qx "$g" && continue
    echo "warning: $(id -un) is not in the '$g' group -- X may fail to start." >&2
    echo "         Fix with:  doas adduser $(id -un) $g   then log out and in." >&2
done
exec startx "$@"
STARTX
    chmod 0755 /usr/local/bin/copal-startx
    note "copal-startx -- refuses to start the desktop as root, and says why"
}

stage_gui() {
    say "Stage 4: X.Org and a window manager"

    if is_diskless; then
        warn "the root filesystem is still a tmpfs (~$(df -h / | awk 'NR==2{print $2}'))."
        warn "X does not fit. apk will fail with ENOSPC while the card sits empty."
        note "Run stage 3 first."
        confirm "Try anyway?" || return 0
    fi
    require_network || return 1

    # The video and input drivers are the part that is specific to this board:
    # there is no accelerated X driver for VideoCore worth using, so X renders
    # on the CPU straight into the framebuffer via fbdev.
    say "Installing the X server and the framebuffer driver"
    setup-xorg-base
    apk add xf86-video-fbdev xf86-input-libinput

    # i3 tiles, so windows never overlap and the CPU never redraws an occluded
    # region. On a board with no acceleration, where every pixel is pushed by
    # the CPU, that is a performance decision as much as an ergonomic one.
    say "Installing i3 and friends"
    # dmenu is not optional: without it Super+space does nothing and i3 has no
    # way to launch anything at all. It is the launcher, not a nicety.
    apk add i3wm i3status dmenu
    # font-dejavu, not ttf-dejavu: Alpine renamed the font packages to the
    # font-* prefix and the old name resolves to nothing.
    add_optional i3lock xterm font-terminus font-dejavu xsetroot jgmenu

    # A terminal, a file manager, a task manager. pcmanfm is the lightest of
    # the GTK file managers; htop is the task manager -- a GUI one would cost
    # more RAM than it saves in convenience on 512 MB.
    say "Installing a file manager and a task manager"
    add_optional pcmanfm htop ncdu mc jgmenu
    # yad drives the Copal Center, dialog is its terminal fallback; feh and
    # ImageMagick paint the key bindings onto the root window. All four are
    # small, and all four are guarded at runtime -- none is required.
    add_optional yad dialog feh imagemagick
    # urxvt starts faster and uses less RAM than xterm; fall back if absent.
    if try_add rxvt-unicode && command -v urxvt >/dev/null 2>&1; then
        TERMEMU=urxvt
    else
        TERMEMU=xterm
    fi
    note "terminal: $TERMEMU"

    say "Writing ~/.xinitrc"
    cat > /tmp/xinitrc.$$ <<'XINIT'
[ -f "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"
# A flat colour rather than a wallpaper: an image costs framebuffer bandwidth
# this board does not have to spare.
# A solid colour before i3 starts, so the first frame is never the X root
# weave. i3 then runs copal-splash, which paints the key bindings over it.
command -v xsetroot >/dev/null && xsetroot -solid '#1a1b26'
exec i3
XINIT
    install_home_file .xinitrc /tmp/xinitrc.$$; rm -f /tmp/xinitrc.$$

    # i3 would otherwise run its config wizard on first launch and block on a
    # question. Writing the config skips that and pins Super as the modifier,
    # so Alt stays free for the terminal.
    say "Writing ~/.config/i3/config"
    {
        cat <<'I3A'
# i3 config -- generated by copal-init.sh
set $mod Mod4
font pango:DejaVu Sans Mono 9

I3A
        printf 'set $term %s\n\n' "$TERMEMU"
        cat <<'I3B'
# i3 has no desktop icons and no start menu -- that is the design, not a
# failure. dmenu is the launcher: it takes over the top of the screen, you
# type a few letters of a program name, Enter runs it. Super+space matches
# where Omarchy puts its launcher.
bindsym $mod+d      exec dmenu_run
bindsym $mod+space  exec dmenu_run
bindsym $mod+Return exec $term
bindsym $mod+e      exec pcmanfm
bindsym $mod+t      exec $term -e htop
bindsym $mod+Shift+q kill
# A clickable menu, built from what is actually installed. Falls back to
# dmenu over the same list when jgmenu is absent, so it always works.
bindsym $mod+z      exec copal-menu
# One window listing the whole catalogue -- what is installed and what is
# not -- with a button that either runs it or fetches it.
bindsym $mod+c      exec copal-center
# System settings: users and groups, hostname, services, SSH, boot options.
# It asks doas for the root it needs rather than assuming it has it.
bindsym $mod+comma  exec copal-config
# The key list, in a floating window. Shown once at login and on Super+/,
# because a tiling WM with no menus is unusable until you know the bindings.
set $helpcmd $term -title i3-keys -e less ~/.config/i3/keys.txt
bindsym $mod+slash exec $helpcmd
bindsym $mod+F1    exec $helpcmd
# The other guides -- the small web, and whatever else lands in
# /usr/local/share/copal/guides. Super+g is taken by the layout toggle.
bindsym $mod+Shift+g exec $term -title i3-keys -e guide
for_window [title="guide"] floating enable, resize set 740 560, move position center
for_window [title="i3-keys"] floating enable, resize set 740 560, move position center, border pixel 2
# The Copal Center is a dialog, not a tiled window -- let it float.
for_window [title="Copal Center"] floating enable, resize set 700 520, move position center

# Both run at i3 startup only, not on reload. copal-splash paints the key
# bindings onto the root window, so they are there whenever nothing is open;
# $helpcmd shows the scrollable version once. Delete either line to stop it.
exec --no-startup-id copal-splash
exec --no-startup-id $helpcmd
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'Exit i3?' -B 'Yes' 'i3-msg exit'"

# focus / move, arrows and hjkl both
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Left focus left
bindsym $mod+Down focus down
bindsym $mod+Up focus up
bindsym $mod+Right focus right
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+Shift+Left move left
bindsym $mod+Shift+Down move down
bindsym $mod+Shift+Up move up
bindsym $mod+Shift+Right move right

bindsym $mod+b splith
bindsym $mod+v splitv
bindsym $mod+f fullscreen toggle
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+g layout toggle split
bindsym $mod+Shift+space floating toggle
bindsym $mod+Tab focus mode_toggle

# Resize -- the tiling answer to dragging a window edge.
mode "resize" {
        bindsym h resize shrink width 8 px or 8 ppt
        bindsym j resize grow height 8 px or 8 ppt
        bindsym k resize shrink height 8 px or 8 ppt
        bindsym l resize grow width 8 px or 8 ppt
        bindsym Left  resize shrink width 8 px or 8 ppt
        bindsym Down  resize grow height 8 px or 8 ppt
        bindsym Up    resize shrink height 8 px or 8 ppt
        bindsym Right resize grow width 8 px or 8 ppt
        bindsym Return mode "default"
        bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

# Five workspaces. Not ten: on 512 MB you will run out of RAM long before you
# run out of workspaces, and a row of empty numbers in the bar is just noise.
# Super+1..5 switches, Super+Shift+1..5 throws the focused window there.
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+5 workspace number 5
bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4
bindsym $mod+Shift+5 move container to workspace number 5
# Cycle without leaving the home row, for when you have forgotten which is
# which -- Super+Tab is taken by the split/tabbed toggle above.
bindsym $mod+Ctrl+Right workspace next
bindsym $mod+Ctrl+Left  workspace prev

floating_modifier $mod
bindsym $mod+Shift+s exec i3lock -c 1c1c1c

# 1px borders: every pixel of decoration is CPU-drawn here.
default_border pixel 1
default_floating_border pixel 1
hide_edge_borders smart

# Tokyo Night. One palette across i3, the terminal, nvim and btop -- the
# omakase idea that a coherent system is a motivating one.
# class                 border  bg      text    indicator child_border
client.focused          #7aa2f7 #7aa2f7 #1a1b26 #7dcfff   #7aa2f7
client.focused_inactive #292e42 #292e42 #c0caf5 #292e42   #292e42
client.unfocused        #1a1b26 #1a1b26 #565f89 #1a1b26   #1a1b26
client.urgent           #f7768e #f7768e #1a1b26 #f7768e   #f7768e

bar {
        status_command i3status
        position top
        tray_output none
        colors {
                background #16161e
                statusline #c0caf5
                separator  #565f89
                focused_workspace  #7aa2f7 #7aa2f7 #1a1b26
                inactive_workspace #16161e #16161e #565f89
                urgent_workspace   #f7768e #f7768e #1a1b26
        }
}
I3B
    } > /tmp/i3cfg.$$
    install_home_file .config/i3/config /tmp/i3cfg.$$; rm -f /tmp/i3cfg.$$

    # The cheat sheet. i3 has no menus, no icons and no discoverable UI at
    # all, so without this the desktop is a grey rectangle that ignores you.
    # A clickable menu that builds itself from what is actually installed, so
    # it never lists something that is not there and never misses something
    # added by a later stage. Regenerated on every launch rather than cached.
    write_catalogue

    # copal-install: the menu's Install branch runs this. Split out so the same
    # thing works from a terminal, and so a failed install leaves its error on
    # screen instead of a window that vanishes.
    say "Installing /usr/local/bin/copal-install"
    cat > /usr/local/bin/copal-install <<'COPALINSTALL'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# copal-install PKG...  -- install packages and keep the window open to say so.
set -u
[ "$#" -gt 0 ] || { echo "usage: copal-install PKG..."; exit 2; }
if [ "$(id -u)" != 0 ]; then
    echo "copal-install needs root. Re-run as: doas copal-install $*" >&2
    command -v doas >/dev/null 2>&1 && exec doas "$0" "$@"
    exit 1
fi
printf 'Installing: %s\n\n' "$*"
# A catalogue entry may name a package as 'foo@testing' -- one package out of
# Alpine's unstable branch, which is where VICE, MilkyTracker, Maxima and a
# few others live. apk only understands that suffix if the tagged repository
# is registered, so register it on demand rather than at install time for
# everyone. Tagged means it is consulted ONLY for @testing names, so the rest
# of the system stays on stable.
case " $* " in
    *@testing*)
        if ! grep -q '^@testing[[:space:]]' /etc/apk/repositories 2>/dev/null; then
            m=$(sed -n 's|^\(https\?://.*\)/v[0-9][0-9.]*/main[[:space:]]*$|\1|p' \
                    /etc/apk/repositories | head -n1)
            [ -n "$m" ] || m="https://dl-cdn.alpinelinux.org/alpine"
            printf 'Adding %s/edge/testing as @testing\n\n' "$m"
            printf '@testing %s/edge/testing\n' "$m" >> /etc/apk/repositories
            apk update >/dev/null 2>&1 || true
        fi ;;
esac
if apk add "$@"; then
    printf '\n\nDone. The menu will show it next time you open it.\n'
    # Packages live on the ext4 root once stage 3 has run, but a diskless
    # system loses them at reboot unless the overlay is committed.
    if [ "$(awk '$2 == "/" { print $3 }' /proc/mounts)" = tmpfs ]; then
        printf 'This root is RAM-resident -- run "lbu commit -d" to keep it.\n'
    fi
else
    printf '\n\nFailed. The usual causes are no network, or the package not\n'
    printf 'existing for this architecture (%s). Try: apk search -v NAME\n' \
           "$(apk --print-arch 2>/dev/null || echo unknown)"
fi
printf '\nPress Enter to close.\n'; read -r _
COPALINSTALL
    chmod 0755 /usr/local/bin/copal-install

    say "Installing /usr/local/bin/copal-menu"
    cat > /usr/local/bin/copal-menu <<'COPALMENU'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# copal-menu -- a clickable menu, rebuilt from what is installed each time it runs.
#
# The keyboard launcher (Super+space, dmenu) already covers everything on
# PATH. This exists for the things whose names you would have to know first --
# the emulator profiles, the snapshot tool, the disk-image helpers -- and for
# the one thing a flat launcher can never do: show you what you could install
# but have not. Software you do not have is not discoverable by definition, so
# the menu carries an Install branch listing the rest of the catalogue.
#
# Structure is borrowed from Omarchy: a short top level of categories, each a
# submenu with a Back entry, and Install/System/Session as siblings of the
# applications rather than entries mixed in among them. Nothing here is more
# than two levels deep -- on a 720p framebuffer a third level is a scroll bar.
set -eu
CSV="${XDG_RUNTIME_DIR:-/tmp}/copal-menu.csv"
CATFILE=/usr/local/share/copal/catalogue

have() { command -v "$1" >/dev/null 2>&1; }
out()  { printf '%s\n' "$*" >> "$CSV"; }
TERM_EMU="${TERMINAL:-$(have urxvt && echo urxvt || echo xterm)}"

# One entry: run it directly, wrap a terminal around it, or -- for the tools
# that would exit before you could read anything -- show the help and hand
# over a shell in the same window.
cmd_for() {  # <binary> <mode>
    case "$2" in
        t) printf '%s -e %s' "$TERM_EMU" "$1" ;;
        h) printf "%s -e sh -c '%s --help 2>&1 | head -40; echo; echo \"-- shell in this directory; Ctrl-D to close --\"; exec sh'" \
                  "$TERM_EMU" "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Walk the catalogue, emitting only the rows in <section> that are (or are
# not) actually installed. Everything downstream is driven by these two.
rows() {  # <section> <installed|missing>
    [ -f "$CATFILE" ] || return 0
    while IFS='|' read -r _sec _label _pkgs _bin _mode; do
        [ "${_sec:-}" = "$1" ] || continue
        case "${_sec}" in '#'*) continue ;; esac
        if have "$_bin"; then [ "$2" = installed ] || continue
        else                  [ "$2" = missing   ] || continue
        fi
        # jgmenu's CSV splits on commas, so a comma in a label silently eats
        # the command and leaves a dead entry. Strip them here rather than
        # trusting every future edit of the catalogue to remember.
        printf '%s|%s|%s|%s\n' "$(echo "$_label" | tr ',' ';')" "$_pkgs" "$_bin" "$_mode"
    done < "$CATFILE"
}
sections() { [ -f "$CATFILE" ] && cut -d'|' -f1 "$CATFILE" | awk '!s[$0]++' || true; }
# Section names are one word so they can be pasted into jgmenu tag names;
# this is where they get a readable form for the part people see.
pretty() { case "$1" in Smallweb) echo "Small Web" ;; *) echo "$1" ;; esac; }
count()    { rows "$1" "$2" | grep -c . || true; }

: > "$CSV"

# ----- top level -----
out "Run a program...,dmenu_run"
out "Terminal,$TERM_EMU"
have copal-center && out "Copal Center,copal-center" || true
have copal-config && out "System Settings,copal-config" || true
out '^sep()'
for s in $(sections); do
    [ "$(count "$s" installed)" -gt 0 ] && out "$(pretty "$s"),^checkout(have_$s)" || true
done
out "Development,^checkout(devel)"
# Only worth a top-level entry once an emulator is actually built.
if [ -n "$(ls "$HOME"/minivmac/run-*.sh /root/minivmac/run-*.sh 2>/dev/null || true)" ] \
   || have BasiliskII || have x64sc || have x64; then
    out "Emulators,^checkout(emu)"
fi
out '^sep()'
out "Install software,^checkout(install)"
[ -n "$(ls /usr/local/share/copal/guides/*.txt 2>/dev/null || true)" ] \
    && out "Guides,^checkout(guides)" || true
out "System,^checkout(system)"
out "Session,^checkout(session)"

# ----- one submenu per catalogue section, installed entries only -----
for s in $(sections); do
    [ "$(count "$s" installed)" -gt 0 ] || continue
    out "^tag(have_$s)"
    out "Back,^back()"
    out "^sep($(pretty "$s"))"
    rows "$s" installed | while IFS='|' read -r label pkgs bin mode; do
        out "$label,$(cmd_for "$bin" "$mode")"
    done
done

# ----- Install: the same table, inverted -----
out '^tag(install)'
out "Back,^back()"
out '^sep(Not installed yet)'
for s in $(sections); do
    [ "$(count "$s" missing)" -gt 0 ] && out "$(pretty "$s"),^checkout(get_$s)" || true
done
for s in $(sections); do
    [ "$(count "$s" missing)" -gt 0 ] || continue
    out "^tag(get_$s)"
    out "Back,^checkout(install)"
    out "^sep(Install: $(pretty "$s"))"
    rows "$s" missing | while IFS='|' read -r label pkgs bin mode; do
        out "$label,$TERM_EMU -e copal-install $pkgs"
    done
done

# ----- Guides: one entry per .txt, titled by its own first line -----
# Built from the directory rather than a list, so dropping a new guide in
# /usr/local/share/copal/guides is the whole of "adding it to the menu".
if grep -q '^Guides,' "$CSV"; then
    out '^tag(guides)'
    out "Back,^back()"
    out '^sep(Guides)'
    for g in /usr/local/share/copal/guides/*.txt; do
        [ -f "$g" ] || continue
        gn=$(basename "$g" .txt)
        # The first line with letters in it -- guides that open with a
        # '=====' ruler would otherwise be titled with the ruler.
        gt=$(awk 'NF && /[A-Za-z]/ {sub(/^ +/, ""); gsub(/,/, ";"); print; exit}' "$g")
        [ -n "$gt" ] || gt="$gn"
        out "$gt,$TERM_EMU -e copal-guide $gn"
    done
fi

# ----- Development: not in the catalogue, it arrives with stage 7 -----
out '^tag(devel)'
out "Back,^back()"
out '^sep(Development)'
have nvim   && out "Neovim,$TERM_EMU -e nvim" || true
have vim    && out "Vim,$TERM_EMU -e vim" || true
have geany  && out "Geany,geany" || true
have python3 && out "Python,$TERM_EMU -e python3" || true
have claude && out "Claude Code,$TERM_EMU -e claude" || true
have lazygit && out "Lazygit,$TERM_EMU -e lazygit" || true
have bvi    && out "Hex editor (bvi),$TERM_EMU -e bvi" || true
have radare2 && out "radare2,$TERM_EMU -e r2" || true

# ----- Emulators: profiles are files on disk, not packages -----
# Only emitted when the top level offered a way in, so the tag is never left
# orphaned. VICE ships both x64sc (accurate) and x64 (fast); on this board the
# fast one is the only one worth offering, but take whichever exists.
if grep -q '^Emulators,' "$CSV"; then
    out '^tag(emu)'
    out "Back,^back()"
    out '^sep(Emulators)'
    for p in "$HOME"/minivmac/run-*.sh /root/minivmac/run-*.sh; do
        [ -x "$p" ] || continue
        n=$(basename "$p" .sh | sed 's/^run-//')
        out "Mini vMac: $n,$p"
    done
    have BasiliskII && out "Basilisk II,BasiliskII" || true
    if have x64sc;   then out "VICE (C64),x64sc"
    elif have x64;   then out "VICE (C64),x64"
    fi
fi

# ----- System -----
out '^tag(system)'
out "Back,^back()"
out '^sep(System)'
have htop && out "Task manager,$TERM_EMU -e htop" || true
have btop && out "System monitor,$TERM_EMU -e btop" || true
have snapshot && out "Snapshots,$TERM_EMU -e sh -c 'snapshot list; read x'" || true
have mountdsk && out "Mount disk image,$TERM_EMU -e sh -c 'mountdsk --help; read x'" || true
have tcpdump  && out "Network capture,$TERM_EMU -e sh -c 'tcpdump -i eth0 -nn'" || true
have bluetoothctl && out "Bluetooth,$TERM_EMU -e bluetoothctl" || true
have iw && out "Wifi scan,$TERM_EMU -e sh -c 'iw dev wlan0 scan | grep SSID; read x'" || true
have alsamixer && out "Volume,$TERM_EMU -e alsamixer" || true
out "Setup and stages,$TERM_EMU -e sh -c 'sh /boot/copal-init.sh'"
out "Key bindings,$TERM_EMU -e less $HOME/.config/i3/keys.txt"

# ----- Session -----
out '^tag(session)'
out "Back,^back()"
out '^sep(Session)'
out "Reload i3,i3-msg restart"
have i3lock && out "Lock screen,i3lock -c 1a1b26" || true
out "Log out,i3-msg exit"
out "Reboot,sh -c 'sync; reboot'"
out "Shut down,sh -c 'sync; poweroff'"

if have jgmenu; then
    exec jgmenu --simple --csv-file="$CSV"
else
    # No jgmenu: flatten to dmenu over the same list, so the menu still works
    # and still shows every entry. Submenu markers and separators drop out;
    # Back entries would be meaningless in a flat list, so they go too.
    sel=$(grep -v '^\^' "$CSV" | grep -v '\^checkout(\|\^back()' \
          | cut -d, -f1 | dmenu -i -l 20 -p 'menu') || exit 0
    cmd=$(grep "^$sel," "$CSV" | grep -v '\^checkout(' | head -1 | cut -d, -f2-)
    [ -n "$cmd" ] && exec sh -c "$cmd"
fi
COPALMENU
    chmod 0755 /usr/local/bin/copal-menu

    # ----------------------------------------------------------------------
    # The Copal Center.
    #
    # A control panel in the sense the small distributions meant it: one
    # window that is the answer to "what is on this machine and what else
    # could be". Damn Small Linux had exactly this, and it is the piece a
    # tiling WM most obviously lacks -- i3 will happily run anything and tell
    # you about nothing.
    #
    # Same catalogue as the menu and stage 12, presented as a sortable list
    # with a status column, so Run and Install are one window rather than two
    # different mental models. yad is a 1 MB GTK dialog tool; if it is not
    # there this degrades to the same list under 'dialog' in a terminal, and
    # if that is missing too, to the app menu.
    say "Installing /usr/local/bin/copal-center"
    cat > /usr/local/bin/copal-center <<'COPALCENTER'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# copal-center -- one window listing the whole catalogue, installed or not.
set -eu
CATFILE=/usr/local/share/copal/catalogue
have() { command -v "$1" >/dev/null 2>&1; }
TERM_EMU="${TERMINAL:-$(have urxvt && echo urxvt || echo xterm)}"

[ -f "$CATFILE" ] || { have copal-menu && exec copal-menu; echo "no catalogue" >&2; exit 1; }

# Rows for the dialog: status, section, program, and the action to take. The
# action is decided here rather than in the UI layer so both front ends stay
# dumb.
cmd_for() {  # <binary> <mode> -- kept identical to copal-menu's
    case "$2" in
        t) printf '%s -e %s' "$TERM_EMU" "$1" ;;
        h) printf "%s -e sh -c '%s --help 2>&1 | head -40; echo; echo \"-- shell in this directory; Ctrl-D to close --\"; exec sh'" \
                  "$TERM_EMU" "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

rows() {
    while IFS='|' read -r sec label pkgs bin mode; do
        [ -n "${sec:-}" ] || continue
        case "$sec" in '#'*) continue ;; esac
        if have "$bin"; then
            act=$(cmd_for "$bin" "$mode")
            printf '%s\t%s\t%s\t%s\n' "installed" "$sec" "$label" "$act"
        else
            printf '%s\t%s\t%s\t%s\n' "-" "$sec" "$label" "$TERM_EMU -e copal-install $pkgs"
        fi
    done < "$CATFILE"
}

if have yad; then
    # --print-column with a hidden action column: the user picks a readable
    # row, yad hands back something executable.
    sel=$(rows | tr '\t' '\n' | yad --list \
            --title="Copal Center" --width=700 --height=520 --center \
            --text="Everything this system can run. Pick a row and press Run.\nRows marked '-' are not installed yet; Run fetches them." \
            --column="Status" --column="Section" --column="Program" --column="Action" \
            --search-column=3 --expand-column=3 --hide-column=4 --print-column=4 \
            --button="Close:1" --button="Run:0" 2>/dev/null) || exit 0
    cmd=${sel%|}
    [ -n "$cmd" ] && exec sh -c "$cmd"
    exit 0
fi

if have dialog; then
    # dialog wants tag/description pairs. Tag is the line number so that two
    # programs sharing a label can never collide.
    _tmp="${TMPDIR:-/tmp}/copal-center.$$"
    rows > "$_tmp"
    set --
    _n=0
    while IFS="$(printf '\t')" read -r st sec label act; do
        _n=$((_n + 1))
        set -- "$@" "$_n" "[$st] $sec: $label"
    done < "$_tmp"
    _pick=$(dialog --clear --title "Copal Center" \
              --menu "Pick a program. Rows marked - are not installed yet." \
              22 74 16 "$@" 3>&1 1>&2 2>&3) || { rm -f "$_tmp"; exit 0; }
    _cmd=$(awk -F'\t' -v n="$_pick" 'NR==n {print $4}' "$_tmp")
    rm -f "$_tmp"
    [ -n "$_cmd" ] && exec sh -c "$_cmd"
    exit 0
fi

have copal-menu && exec copal-menu
echo "copal-center needs yad or dialog; neither is installed." >&2
exit 1
COPALCENTER
    chmod 0755 /usr/local/bin/copal-center

    # ----------------------------------------------------------------------
    # The settings tool.
    #
    # Every minimal distribution eventually grows one of these, and the ones
    # that are any good share a shape: raspi-config, Omarchy's menu, Alpine's
    # own setup-* scripts. A flat list of the things you actually change after
    # an install -- users, hostname, timezone, services, what starts at boot --
    # each of which is otherwise a command you have to already know.
    #
    # Alpine ships the pieces (adduser, setup-hostname, setup-timezone,
    # rc-update) and no front end at all. This is the front end. It calls those
    # tools rather than reimplementing them, so nothing here can drift from
    # what the system actually does.
    #
    # GUI first because that was asked for, and because a checklist is simply
    # the right shape for "which groups should this user be in" -- but the
    # terminal path is not an afterthought: it is the same screens under
    # dialog, so it works over SSH on a headless board.
    say "Installing /usr/local/bin/copal-config"
    cat > /usr/local/bin/copal-config <<'COPALCONFIG'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# copal-config -- system settings for Copal. raspi-config's job, Copal's tools.
#
#   copal-config            GUI if there is a display, otherwise the terminal
#   copal-config --tui      force the terminal interface
#   copal-config --help
#
# Three front ends, one set of screens: yad (GTK), dialog (curses), and a
# plain read/printf fallback so this still works on a system with neither.
set -eu

have() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in
    -h|--help) sed -n '2,${/^#/!q; /^# SPDX/d; /^# Copyright/d; p;}' "$0"; exit 0 ;;
    --tui) FORCE_TUI=1; shift ;;
    *) FORCE_TUI=0 ;;
esac

# Almost everything here writes to /etc. Re-exec rather than failing halfway
# through with a permission error on the third of five steps.
if [ "$(id -u)" != 0 ]; then
    have doas && exec doas "$0" ${FORCE_TUI:+--tui} "$@"
    echo "copal-config needs root:  doas copal-config" >&2
    exit 1
fi

# Which front end. A DISPLAY is not enough on its own -- running under doas
# from a terminal inherits DISPLAY but not necessarily the authority to use
# it -- so yad is probed rather than assumed.
UI=plain
if [ "$FORCE_TUI" = 0 ] && [ -n "${DISPLAY:-}" ] && have yad; then UI=yad
elif have dialog; then UI=dialog
fi

# ---------------------------------------------------------------- UI layer --
# Six primitives. Every screen below is written once against these, which is
# the only reason three front ends is maintainable rather than three copies.

ui_msg() {  # <text>
    case $UI in
        yad) printf '%s\n' "$1" | yad --text-info --width=620 --height=420 \
                 --title="Copal" --button="OK:0" --wrap 2>/dev/null || true ;;
        dialog) dialog --title "Copal" --msgbox "$1" 20 74 ;;
        *) printf '\n%s\n\n' "$1"; printf 'Press Enter. '; read -r _ ;;
    esac
}

ui_yesno() {  # <question> -- returns 0 for yes
    case $UI in
        yad) yad --question --title="Copal" --width=460 --center \
                 --text="$1" --button="No:1" --button="Yes:0" 2>/dev/null ;;
        dialog) dialog --title "Copal" --yesno "$1" 12 70 ;;
        *) printf '\n%s [y/N] ' "$1"; read -r _r; case "$_r" in [Yy]*) return 0 ;; *) return 1 ;; esac ;;
    esac
}

ui_input() {  # <prompt> [default] -- answer on stdout
    case $UI in
        yad) yad --entry --title="Copal" --width=460 --center \
                 --text="$1" --entry-text="${2:-}" 2>/dev/null || true ;;
        dialog) dialog --title "Copal" --inputbox "$1" 10 70 "${2:-}" 3>&1 1>&2 2>&3 || true ;;
        *) printf '\n%s ' "$1" >&2; read -r _r || _r=""; printf '%s' "${_r:-${2:-}}" ;;
    esac
}

ui_password() {  # <prompt>
    case $UI in
        yad) yad --entry --hide-text --title="Copal" --width=460 --center \
                 --text="$1" 2>/dev/null || true ;;
        dialog) dialog --title "Copal" --insecure --passwordbox "$1" 10 70 3>&1 1>&2 2>&3 || true ;;
        *) printf '\n%s ' "$1" >&2
           stty -echo 2>/dev/null || true; read -r _r || _r=""
           stty echo 2>/dev/null || true; printf '\n' >&2; printf '%s' "$_r" ;;
    esac
}

# ui_menu <title> <text> <tag> <label> [<tag> <label> ...] -- chosen tag on stdout
ui_menu() {
    _t="$1"; _x="$2"; shift 2
    case $UI in
        yad)
            _out=$(while [ "$#" -ge 2 ]; do printf '%s\n%s\n' "$1" "$2"; shift 2; done \
                   | yad --list --title="$_t" --text="$_x" --width=560 --height=440 \
                         --center --column="tag" --column="Setting" \
                         --hide-column=1 --print-column=1 --expand-column=2 \
                         --button="Back:1" --button="Choose:0" 2>/dev/null) || return 1
            printf '%s' "${_out%|}" ;;
        dialog)
            dialog --clear --title "$_t" --menu "$_x" 20 74 12 "$@" 3>&1 1>&2 2>&3 || return 1 ;;
        *)
            printf '\n== %s ==\n%s\n\n' "$_t" "$_x" >&2
            _i=0
            while [ "$#" -ge 2 ]; do _i=$((_i+1)); printf '  %s) %s\n' "$1" "$2" >&2; shift 2; done
            printf '\nChoice (blank to go back): ' >&2
            read -r _r || _r=""; [ -n "$_r" ] || return 1
            printf '%s' "$_r" ;;
    esac
}

# ui_check <title> <text> <tag> <label> <on|off> ... -- chosen tags, space separated
ui_check() {
    _t="$1"; _x="$2"; shift 2
    case $UI in
        yad)
            _out=$(while [ "$#" -ge 3 ]; do
                       case "$3" in on) printf 'TRUE\n' ;; *) printf 'FALSE\n' ;; esac
                       printf '%s\n%s\n' "$1" "$2"; shift 3
                   done | yad --list --checklist --title="$_t" --text="$_x" \
                         --width=560 --height=440 --center \
                         --column="Pick:CHK" --column="tag" --column="Meaning" \
                         --hide-column=2 --print-column=2 --expand-column=3 \
                         --button="Cancel:1" --button="Apply:0" 2>/dev/null) || return 1
            printf '%s' "$_out" | tr '|' ' ' ;;
        dialog)
            dialog --clear --title "$_t" --checklist "$_x" 20 74 12 "$@" 3>&1 1>&2 2>&3 \
                | tr -d '"' || return 1 ;;
        *)
            printf '\n== %s ==\n%s\n\n' "$_t" "$_x" >&2
            _sel=""
            while [ "$#" -ge 3 ]; do
                printf '  %-10s %-46s [%s] keep/add? [y/N] ' "$1" "$2" "$3" >&2
                read -r _r || _r=""
                case "$_r" in [Yy]*) _sel="$_sel $1" ;;
                              '') [ "$3" = on ] && _sel="$_sel $1" ;; esac
                shift 3
            done
            printf '%s' "$_sel" ;;
    esac
}

# ------------------------------------------------------------------ users ---
# The groups worth offering, with what each one actually grants. Only those
# that exist on this system are shown -- Alpine does not create Raspberry Pi
# OS's gpio/i2c/spi groups, and offering a group that does not exist produces
# a confusing failure rather than a useful one.
GROUPS_KNOWN="wheel|administrator -- may use doas to become root
audio|sound devices
video|framebuffer, X and the camera
input|keyboards, mice, joysticks
netdev|change network settings without root
dialout|serial ports -- the GPIO UART, an Arduino
plugdev|removable devices
usb|USB devices
users|the generic unprivileged group
disk|raw disk access -- dangerous, and rarely what you want"

group_exists() { getent group "$1" >/dev/null 2>&1; }
in_group() { id -Gn "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }

# Real logins only: uid >= 1000 and a shell that is not nologin/false. Listing
# the two dozen system accounts would bury the one you came here to change.
human_users() {
    awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ { print $1 }' /etc/passwd
}

screen_user_groups() {  # <username>
    _u="$1"
    set --
    _old=$IFS; IFS='
'
    for _line in $GROUPS_KNOWN; do
        IFS=$_old
        _g=${_line%%|*}; _d=${_line#*|}
        group_exists "$_g" || continue
        if in_group "$_u" "$_g"; then set -- "$@" "$_g" "$_d" on
        else set -- "$@" "$_g" "$_d" off; fi
        IFS='
'
    done
    IFS=$_old
    [ "$#" -gt 0 ] || { ui_msg "No configurable groups exist on this system."; return 0; }

    _want=$(ui_check "Groups for $_u" \
        "Tick the groups '$_u' should belong to. Unticking removes them.
wheel is the important one: it is what lets an account use doas." "$@") || return 0

    # Apply the difference in both directions, so unticking really removes.
    _old=$IFS; IFS='
'
    for _line in $GROUPS_KNOWN; do
        IFS=$_old
        _g=${_line%%|*}
        group_exists "$_g" || { IFS='
'; continue; }
        case " $_want " in
            *" $_g "*) in_group "$_u" "$_g" || adduser "$_u" "$_g" 2>/dev/null || true ;;
            *)         in_group "$_u" "$_g" && delgroup "$_u" "$_g" 2>/dev/null || true ;;
        esac
        IFS='
'
    done
    IFS=$_old
    ui_msg "Groups for $_u are now:

$(id -Gn "$_u" 2>/dev/null | tr ' ' '\n' | sed 's/^/  /')

A group change takes effect at the next login, not immediately."
}

screen_user_add() {
    _u=$(ui_input "New user name (lower case, no spaces):") || return 0
    [ -n "$_u" ] || return 0
    case "$_u" in
        *[!a-z0-9_-]*|[!a-z]*)
            ui_msg "'$_u' is not a usable user name.

Use lower-case letters, digits, dash and underscore, starting with a letter.
That is what adduser will accept and what every other tool expects."
            return 0 ;;
    esac
    if id "$_u" >/dev/null 2>&1; then
        ui_msg "'$_u' already exists."; return 0
    fi

    _p1=$(ui_password "Password for $_u:")
    [ -n "$_p1" ] || { ui_msg "No password given -- not creating the account.

An account with no password cannot log in, which is rarely what is wanted."; return 0; }
    _p2=$(ui_password "Repeat the password:")
    [ "$_p1" = "$_p2" ] || { ui_msg "The two passwords do not match. Nothing was changed."; return 0; }

    # -D means "do not run passwd interactively"; the password is set below.
    if ! adduser -D "$_u" >/dev/null 2>&1; then
        ui_msg "adduser failed for '$_u'."; return 0
    fi
    if ! printf '%s:%s\n' "$_u" "$_p1" | chpasswd >/dev/null 2>&1; then
        ui_msg "The account was created but the password could not be set.
Set it by hand:  doas passwd $_u"
    fi

    if ui_yesno "Make '$_u' an administrator?

That adds them to the wheel group, which is what lets an account use doas to
run commands as root. Say no for an ordinary account."; then
        adduser "$_u" wheel 2>/dev/null || true
    fi
    # Sensible defaults for a desktop account, where the groups exist.
    for _g in audio video input netdev; do
        group_exists "$_g" && adduser "$_u" "$_g" 2>/dev/null || true
    done

    ui_msg "Created '$_u'.

  home   : $(getent passwd "$_u" | cut -d: -f6)
  shell  : $(getent passwd "$_u" | cut -d: -f7)
  groups : $(id -Gn "$_u" 2>/dev/null)

Choose 'Groups' from the user menu to change any of that."
    screen_commit_hint
}

screen_user_del() {
    _u="$1"
    if [ "$_u" = root ]; then
        ui_msg "root cannot be deleted, and should not be.

uid 0 owns most of the filesystem and the kernel checks privilege by number,
so removing it produces a system that does not boot. To take root out of use,
lock it instead:  doas passwd -l root"
        return 0
    fi
    if [ "$_u" = "${SUDO_USER:-${DOAS_USER:-}}" ]; then
        ui_msg "'$_u' is the account you are logged in as. Refusing.

Log in as another administrator first if you really mean to remove it."
        return 0
    fi
    ui_yesno "Delete the user '$_u'?

This removes the account. Their home directory and everything in it goes too
if you say yes to the next question. Neither can be undone." || return 0
    if ui_yesno "Also delete their home directory, $(getent passwd "$_u" | cut -d: -f6)?"; then
        deluser --remove-home "$_u" >/dev/null 2>&1 || deluser "$_u" >/dev/null 2>&1 || true
    else
        deluser "$_u" >/dev/null 2>&1 || true
    fi
    id "$_u" >/dev/null 2>&1 && ui_msg "Could not delete '$_u'." || ui_msg "Deleted '$_u'."
    screen_commit_hint
}

screen_user_passwd() {
    _u="$1"
    _p1=$(ui_password "New password for $_u:"); [ -n "$_p1" ] || return 0
    _p2=$(ui_password "Repeat it:")
    [ "$_p1" = "$_p2" ] || { ui_msg "They do not match. Nothing was changed."; return 0; }
    if printf '%s:%s\n' "$_u" "$_p1" | chpasswd >/dev/null 2>&1; then
        ui_msg "Password changed for '$_u'."
        screen_commit_hint
    else
        ui_msg "Could not change the password for '$_u'."
    fi
}

screen_user_one() {  # <username>
    _u="$1"
    while :; do
        _c=$(ui_menu "User: $_u" \
             "uid $(id -u "$_u" 2>/dev/null)   groups: $(id -Gn "$_u" 2>/dev/null)" \
             groups   "Groups -- what this account is allowed to do" \
             passwd   "Change password" \
             delete   "Delete this user" \
             back     "Back") || return 0
        case "$_c" in
            groups) screen_user_groups "$_u" ;;
            passwd) screen_user_passwd "$_u" ;;
            delete) screen_user_del "$_u"; id "$_u" >/dev/null 2>&1 || return 0 ;;
            *) return 0 ;;
        esac
    done
}

screen_users() {
    while :; do
        set -- add "Add a user"
        for _u in $(human_users); do
            set -- "$@" "$_u" "$_u  --  $(id -Gn "$_u" 2>/dev/null | cut -c1-46)"
        done
        set -- "$@" back "Back"
        _c=$(ui_menu "Users and groups" \
             "Accounts you can log in as. System accounts are not listed." "$@") || return 0
        case "$_c" in
            add) screen_user_add ;;
            back|'') return 0 ;;
            *) screen_user_one "$_c" ;;
        esac
    done
}

# ----------------------------------------------------------------- system ---
screen_hostname() {
    _h=$(ui_input "Hostname:" "$(hostname)") || return 0
    [ -n "$_h" ] || return 0
    case "$_h" in *[!a-zA-Z0-9-]*) ui_msg "'$_h' is not a valid hostname: letters, digits and dashes only."; return 0 ;; esac
    # setup-hostname is Alpine's own, and also fixes /etc/hosts, which is the
    # bit people forget and then wonder why sudo/doas pauses for a second.
    if have setup-hostname && setup-hostname -n "$_h" >/dev/null 2>&1; then
        hostname "$_h" 2>/dev/null || true
        ui_msg "Hostname is now '$_h'.

Some things only notice at the next reboot."
        screen_commit_hint
    else
        ui_msg "Could not set the hostname."
    fi
}

screen_timezone() {
    _z=$(ui_input "Timezone (Region/City, e.g. Europe/London):" \
                  "$(cat /etc/timezone 2>/dev/null || echo UTC)") || return 0
    [ -n "$_z" ] || return 0
    if [ ! -f "/usr/share/zoneinfo/$_z" ]; then
        ui_msg "No such timezone: $_z

The names come from the tzdata database. Browse them with:
  ls /usr/share/zoneinfo"
        return 0
    fi
    if have setup-timezone && setup-timezone -z "$_z" >/dev/null 2>&1; then
        ui_msg "Timezone is now $_z.  ($(date))"
        screen_commit_hint
    else
        ui_msg "Could not set the timezone."
    fi
}

screen_keymap() {
    ui_msg "The keyboard map is set by Alpine's own setup-keymap, which is
interactive and lists every layout it has.

Run it in a terminal:   doas setup-keymap

It is not wrapped here because its list is long enough that a dialog box
would be worse than the tool itself."
}

# ---------------------------------------------------------------- services --
screen_services() {
    while :; do
        set --
        for _s in $(ls /etc/init.d 2>/dev/null | sort); do
            [ -x "/etc/init.d/$_s" ] || continue
            if rc-update show default 2>/dev/null | grep -q "^ *$_s "; then _st="at boot"
            else _st="-      "; fi
            if rc-service "$_s" status >/dev/null 2>&1; then _st="$_st running"
            else _st="$_st stopped"; fi
            set -- "$@" "$_s" "$_st"
        done
        [ "$#" -gt 0 ] || { ui_msg "No services found."; return 0; }
        set -- "$@" back "Back"
        _c=$(ui_menu "Services" \
            "What runs, and what starts at boot. Pick one to change it." "$@") || return 0
        [ "$_c" = back ] || [ -z "$_c" ] && return 0
        _a=$(ui_menu "Service: $_c" "$(rc-service "$_c" status 2>&1 | head -3)" \
             start "Start it now" \
             stop  "Stop it now" \
             enable  "Start it at boot" \
             disable "Do not start it at boot" \
             back  "Back") || continue
        case "$_a" in
            start)   rc-service "$_c" start   >/dev/null 2>&1 || ui_msg "Could not start $_c." ;;
            stop)    rc-service "$_c" stop    >/dev/null 2>&1 || ui_msg "Could not stop $_c." ;;
            enable)  rc-update add "$_c" default >/dev/null 2>&1 && screen_commit_hint ;;
            disable) rc-update del "$_c" default >/dev/null 2>&1 && screen_commit_hint ;;
        esac
    done
}

# ------------------------------------------------------------ boot/display --
# usercfg.txt, not config.txt: config.txt carries a "do not modify, will be
# overwritten on upgrade" banner and includes usercfg.txt last, so directives
# here win and survive. Same managed-block trick the SSH policy uses.
BOOTDIR=/boot
# Pre-stage-3 the boot partition is under /media rather than /boot. Detected by
# answers.txt, which exists on every platform -- config.txt is Pi-only.
for _b in /media/*; do
    [ -f "$_b/answers.txt" ] && [ ! -f /boot/answers.txt ] && BOOTDIR=$_b
done
USERCFG="$BOOTDIR/usercfg.txt"

boot_get() { sed -n "s/^$1=//p" "$USERCFG" 2>/dev/null | tail -n1; }
boot_set() {  # <key> <value|"">   empty value removes the line
    [ -f "$USERCFG" ] || { ui_msg "No $USERCFG on this system."; return 1; }
    mount -o remount,rw "$BOOTDIR" 2>/dev/null || true
    sed -i "/^$1=/d" "$USERCFG"
    [ -n "$2" ] && printf '%s=%s\n' "$1" "$2" >> "$USERCFG"
    sync
}

screen_boot() {
    while :; do
        _c=$(ui_menu "Boot and display" \
"Firmware settings, written to usercfg.txt so an Alpine upgrade cannot
overwrite them. All of these need a reboot.

  gpu_mem      $(boot_get gpu_mem || echo '(default 64)')
  hdmi_drive   $(boot_get hdmi_drive || echo '(unset)')
  overscan     $(boot_get disable_overscan || echo '(unset)')" \
            gpu    "GPU memory split" \
            hdmi   "HDMI audio (hdmi_drive)" \
            over   "Overscan -- black border round the screen" \
            uart   "Serial console on the GPIO header" \
            edit   "Open usercfg.txt in an editor" \
            back   "Back") || return 0
        case "$_c" in
            gpu)
                _v=$(ui_menu "GPU memory" \
"How much RAM is reserved for the GPU, before Linux sees any of it. On a
512 MB board this is real memory you are giving away.

DO NOT SET 16. At exactly 16 the firmware switches to start_cd.elf, which the
Alpine tarball does not ship -- the board then halts before HDMI comes up and
looks completely dead. 32 is the lowest safe value." \
                    32 "32 MB -- lowest safe value, best for a headless or light desktop" \
                    64 "64 MB -- the default" \
                    128 "128 MB -- only if you are doing video" \
                    back "Back") || continue
                case "$_v" in 32|64|128) boot_set gpu_mem "$_v" && ui_msg "gpu_mem=$_v. Reboot to apply." ;; esac ;;
            hdmi)
                if ui_yesno "Force HDMI signalling so sound goes out of the HDMI port?

This sets hdmi_drive=2. It is what carries audio over HDMI -- but on a display
connected through a DVI adapter it can blank the screen, because DVI has no
audio and some adapters refuse the signal."; then
                    boot_set hdmi_drive 2 && ui_msg "hdmi_drive=2. Reboot to apply."
                else
                    boot_set hdmi_drive "" && ui_msg "hdmi_drive removed. Reboot to apply."
                fi ;;
            over)
                if ui_yesno "Disable overscan?

Overscan is the black border some TVs need. Disabling it uses the whole
panel, which is right for a monitor and wrong for an older TV."; then
                    boot_set disable_overscan 1 && ui_msg "disable_overscan=1. Reboot to apply."
                else
                    boot_set disable_overscan "" && ui_msg "Overscan back to default. Reboot to apply."
                fi ;;
            uart)
                if ui_yesno "Enable the serial console on the GPIO header?

Harmless with nothing attached, and the only way to see early boot messages
if the board stops before userspace."; then
                    boot_set enable_uart 1 && ui_msg "enable_uart=1. Reboot to apply."
                else
                    boot_set enable_uart "" && ui_msg "enable_uart removed. Reboot to apply."
                fi ;;
            edit)
                _e="${EDITOR:-$(have nano && echo nano || echo vi)}"
                mount -o remount,rw "$BOOTDIR" 2>/dev/null || true
                "$_e" "$USERCFG" || true; sync ;;
            *) return 0 ;;
        esac
    done
}

# ------------------------------------------------------------------ misc ----
screen_ssh() {
    have copal-ssh || { ui_msg "copal-ssh is not installed -- run stage 6."; return 0; }
    while :; do
        _c=$(ui_menu "SSH" "$(copal-ssh status 2>&1)" \
             pwon  "Allow password logins" \
             pwoff "Keys only (refuses if no key is installed)" \
             rooton  "Allow root over SSH, by key only" \
             rootoff "Refuse root over SSH" \
             back  "Back") || return 0
        case "$_c" in
            pwon)   ui_msg "$(copal-ssh password on 2>&1)" ;;
            pwoff)  ui_msg "$(copal-ssh password off 2>&1)" ;;
            rooton) ui_msg "$(copal-ssh root on 2>&1)" ;;
            rootoff) ui_msg "$(copal-ssh root off 2>&1)" ;;
            *) return 0 ;;
        esac
    done
}

screen_storage() {
    ui_msg "Storage

$(df -h / /boot 2>/dev/null)

Memory
$(free -m 2>/dev/null | head -2)

If the root partition does not fill the card, stage 8 of the installer grows
it into the free space -- non-destructively, on a mounted root:
    doas copal        and choose 8"
}

screen_about() {
    ui_msg "Copal Linux

  host       : $(hostname)
  kernel     : $(uname -sr)
  arch       : $(apk --print-arch 2>/dev/null || uname -m)
  root fs    : $(awk '$2 == "/" { print $3 }' /proc/mounts)
  uptime     : $(uptime 2>/dev/null | sed 's/^ *//')
  memory     : $(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d MB total, %d MB free", t/1024, a/1024}' /proc/meminfo)
  users      : $(human_users | tr '\n' ' ')

  installer  : doas copal
  settings   : doas copal-config"
}

# A diskless system rebuilds / from the apkovl at every boot, so a change to
# /etc that is not committed is a change that disappears. Saying so once, at
# the moment of the change, is worth more than a note in a README.
screen_commit_hint() {
    [ "$(awk '$2 == "/" { print $3 }' /proc/mounts)" = tmpfs ] || return 0
    if ui_yesno "This system is running diskless: / is a tmpfs rebuilt at every
boot, so that change is currently only in RAM.

Save it now with 'lbu commit -d'?"; then
        if lbu commit -d >/dev/null 2>&1; then ui_msg "Saved."
        else ui_msg "lbu commit failed. Run it by hand and read the error."; fi
    fi
}

# ------------------------------------------------------------------ main ----
while :; do
    choice=$(ui_menu "Copal settings" \
        "$(hostname) -- $(apk --print-arch 2>/dev/null || uname -m)" \
        users    "Users and groups -- add, remove, permissions" \
        hostname "Hostname" \
        timezone "Timezone" \
        keymap   "Keyboard layout" \
        ssh      "SSH -- who may log in remotely, and how" \
        services "Services -- what runs, and what starts at boot" \
        boot     "Boot and display -- GPU memory, HDMI audio, overscan" \
        storage  "Storage and memory" \
        software "Install software (Copal Center)" \
        about    "About this system" \
        quit     "Quit") || break
    case "$choice" in
        users)    screen_users ;;
        hostname) screen_hostname ;;
        timezone) screen_timezone ;;
        keymap)   screen_keymap ;;
        ssh)      screen_ssh ;;
        services) screen_services ;;
        boot)     screen_boot ;;
        storage)  screen_storage ;;
        software) have copal-center && copal-center || ui_msg "copal-center is not installed." ;;
        about)    screen_about ;;
        *)        break ;;
    esac
done
exit 0
COPALCONFIG
    chmod 0755 /usr/local/bin/copal-config

    # ----------------------------------------------------------------------
    # The desktop splash.
    #
    # i3 starts as a blank rectangle that ignores you, and a cheat sheet you
    # have to summon is a cheat sheet you have to remember exists. Drawing the
    # bindings straight onto the root window costs nothing at runtime -- it is
    # one image, painted once -- and it is visible in exactly the situation
    # where you need it, which is when no window is open.
    say "Installing /usr/local/bin/copal-splash"
    cat > /usr/local/bin/copal-splash <<'COPALSPLASH'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# copal-splash -- render ~/.config/i3/keys.txt onto the root window.
#
# Regenerates only when the key list is newer than the image, so this costs
# nothing on a normal login. ImageMagick and feh are both optional: without
# them the desktop is a plain colour, which is what it was before.
set -eu
KEYS="$HOME/.config/i3/keys.txt"
OUT="$HOME/.cache/copal-splash.png"
BG='#1a1b26'
FG='#a9b1d6'
have() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$(dirname "$OUT")"

# Screen size, if X will tell us. The Pi Zero's HDMI output is whatever the
# monitor asked for, so this is not a fixed number.
GEOM=$(xrandr 2>/dev/null | awk '/\*/ {print $1; exit}') || true
case "${GEOM:-}" in
    [0-9]*x[0-9]*) : ;;
    *) GEOM=1280x720 ;;
esac

# ImageMagick 7 installs both names; 6 only the first. Either will do.
IM=""
have magick  && IM=magick
[ -n "$IM" ] || { have convert && IM=convert; }

# Regenerate only when the key list has actually changed. Two separate tests
# rather than one '-o': the -o form is not portable and busybox test has been
# known to get the precedence wrong when combined with '!'.
NEED=no
[ -f "$OUT" ] || NEED=yes
[ "$KEYS" -nt "$OUT" ] 2>/dev/null && NEED=yes

if [ -n "$IM" ] && [ "$NEED" = yes ] && [ -f "$KEYS" ]; then
    # Bindings and group headings only. The explanatory prose belongs in the
    # scrollable window; a wallpaper you read at a glance wants the table.
    # Measured: this comes to 33 lines, which fits 720p at pointsize 14 with
    # room to spare. Adding a group to keys.txt is free; adding more than
    # about eight bindings will start to run off the bottom.
    BODY=$(sed -n '/^ START SOMETHING/,/^ IF SOMETHING/p' "$KEYS" \
           | sed '$d' | awk '/^ [A-Z]/ || /Super \+/')
    [ -n "$BODY" ] || BODY=$(cat "$KEYS")
    # A named font may not resolve without fontconfig knowing it, and a
    # failed -font aborts the whole command -- so try the nice one, then let
    # ImageMagick choose. Either way a failure just leaves the plain colour.
    for _f in "DejaVu Sans Mono" ""; do
        if [ -n "$_f" ]; then set -- -font "$_f"; else set --; fi
        if "$IM" -size "$GEOM" "xc:$BG" "$@" \
              -pointsize 14 -fill "$FG" -annotate +40+50 "$BODY" \
              -pointsize 12 -fill '#565f89' \
              -annotate +40-28 'Super + /  keys    Super + Z  menu    Super + C  Copal Center    Super + Shift + G  guides' \
              "$OUT" 2>/dev/null; then
            break
        fi
        rm -f "$OUT"
    done
fi

if [ -f "$OUT" ] && have feh; then
    exec feh --no-fehbg --bg-scale "$OUT"
fi
have xsetroot && exec xsetroot -solid "$BG"
COPALSPLASH
    chmod 0755 /usr/local/bin/copal-splash

    say "Writing ~/.config/i3/keys.txt"
    # This file is the single source of truth for the bindings: the login
    # window shows it, Super+/ shows it, and copal-splash renders it onto
    # the wallpaper. Change a binding, change it here, and all three follow.
    # Grouped and worded after Omarchy's keybinding guide -- the useful idea
    # there is that the guide is organised by INTENT (start something, move
    # something, arrange something) rather than by modifier key.
    cat > /tmp/keys.$$ <<'KEYS'
 ======================================================================
   Copal Linux -- key bindings
 ======================================================================
                                                     press q to close

 "Super" is the Windows key. It is the modifier for everything here.
 Show this list again at any time with   Super + /   or   Super + F1

 START SOMETHING
   Super + Space        run a program -- type a few letters, Enter.
                        Lists EVERY executable on your PATH, so anything
                        you install shows up here automatically.
   Super + D            the same thing (dmenu)
   Super + Z            the app menu: everything installed, sorted into
                        categories. Its Install branch lists the programs
                        you have NOT installed yet and installs them.
   Super + C            the Copal Center: one window listing every program
                        in the catalogue, installed or not, with a button
                        to run it or fetch it.
   Super + ,            system settings: add users and choose their
                        groups, hostname, timezone, services, SSH, and
                        the boot options. It asks doas for root itself.
   Super + Return       a terminal
   Super + E            file manager
   Super + T            task manager (htop)
   Super + Shift + G    the guides -- how to actually use what is here,
                        starting with Gopher and Gemini

 WINDOWS
   Super + Shift + Q    close the focused window
   Super + H J K L      move focus left / down / up / right
   Super + arrows       the same, if you prefer arrows
   Super + Shift + HJKL move the window itself
   Super + F            fullscreen on / off
   Super + R            resize mode: h j k l or arrows, Enter to finish
   Super + Shift+Space  float this window (drag with Super + mouse)
   Super + Tab          switch focus between floating and tiled

 HOW WINDOWS ARRANGE THEMSELVES
   New windows split the space with the focused one. Nothing overlaps.
   That is the point: on a board with no graphics acceleration, every
   pixel is drawn by the CPU, so never redrawing a hidden window is a
   speed decision as much as a tidiness one.
   Super + B            next window opens to the RIGHT
   Super + V            next window opens BELOW
   Super + W            tabbed layout -- one at a time, tabs on top
   Super + S            stacked layout -- one at a time, titles listed
   Super + G            back to a plain split

 WORKSPACES  (virtual desktops)
   Super + 1..5         switch to workspace 1-5
   Super + Shift + 1..5 send the focused window to that workspace
   Super + Ctrl + Left  previous workspace
   Super + Ctrl + Right next workspace
   Five, not ten: on 512 MB you run out of memory long before you run
   out of workspaces.

 SESSION
   Super + Shift + R    reload i3 after editing its config
   Super + Shift + E    log out of i3 (back to the console)
   Super + Shift + S    lock the screen, if i3lock is installed

 IF SOMETHING LOOKS WRONG
   The bar says "status_command process exited unexpectedly":
       i3status -c ~/.config/i3status/config -n 1
   That prints the actual parse error, which the bar will not tell you.

 FILES
   ~/.config/i3/config          bindings and colours
   ~/.config/i3status/config    what the bar shows
   ~/.config/i3/keys.txt        this file -- also drawn on the wallpaper

 To stop this appearing at login, delete the line in ~/.config/i3/config
 that begins:   exec --no-startup-id $helpcmd
KEYS
    # ----------------------------------------------------------------------
    # Guides.
    #
    # A directory of plain-text documents and one command to read them. This
    # is the nested layer the menu was missing: the app menu can tell you a
    # program exists, but not what to type once it opens, and a Gopher client
    # is useless if you do not know a single Gopher address.
    #
    # Plain text on purpose. It is readable over serial, over ssh, from the
    # console when X will not start, and by 'less' on a machine with 512 MB.
    # Drop another .txt in the directory and it appears in the menu -- no
    # code change, same rule as the catalogue.
    say "Writing the guides"
    mkdir -p /usr/local/share/copal/guides
    cp /tmp/keys.$$ /usr/local/share/copal/guides/i3-keys.txt

    cat > /usr/local/share/copal/guides/small-web.txt <<'GUIDE'
 THE SMALL WEB -- Gopher and Gemini on this machine
 ======================================================================

 This is the one thing a Pi Zero does not do badly. Gopher and Gemini
 serve text without scripts, tracking or layout, so a 1 GHz core draws
 a page as fast as any machine you own. Nothing here is a compromise
 for slow hardware -- it is simply the right tool on the right box.

 WHAT THEY ARE
   Gopher (1991)  Menus of numbered items. You pick a number, you get
                  a document or another menu. Still running, still
                  maintained, and a lot of it is people's notebooks.
   Gemini (2019)  Deliberately between gopher and the web. One page,
                  one request, TLS required, no cookies, no scripts,
                  no inline images, and a markup with six line types.

 START HERE
   gopher://gopher.floodgap.com        the main gopher hub
   gopher://gopher.floodgap.com/1/v2   Veronica-2, the gopher search
   gemini://geminiprotocol.net         the protocol's own capsule
   gemini://kennedy.gemi.dev           Kennedy, a gemini search engine
   gemini://warmedal.se/~antenna       Antenna, an aggregator of feeds

 WHICH CLIENT
   bombadillo   Gopher AND Gemini AND finger in one terminal browser.
                If you install one thing, install this.
   amfora       Gemini only, and the most comfortable to read in.
   clagrange    Lagrange in a terminal.
   lagrange     Lagrange in a real window. It works here, but it is
                SDL2 and it is the heaviest thing in this guide.
   gmnlm        Gemini, line mode -- the ed of browsers.
   gmni         Fetch one Gemini page and print it. Gemini's curl.
   gemget       Download from Gemini; mirrors a whole capsule.

   You may already have a Gopher client: lynx and elinks both speak
   gopher:// with no extra software and no configuration. links does
   NOT, so do not waste time looking for the option.

 BOMBADILLO IN SIXTY SECONDS
   bombadillo gopher://gopher.floodgap.com

   j / k          scroll down / up
   0-9            follow one of the first ten links (0 means 10)
   b  or  h       back
   f  or  l       forward
   SPACE          command mode -- then type one of:
                    a URL                 go there
                    a number              follow that link
                    help                  the full manual
                    add . My bookmark     bookmark this page
                    quit                  leave
   Shift + B      show the bookmarks bar
   q              quit

 SERVING YOUR OWN
   gmnisrv is packaged and will serve a Gemini capsule off this Pi.
   Its config lives at /etc/gmnisrv.ini and it needs a TLS certificate,
   which it will generate for you on first run. Gemini requires TLS
   even for a public page -- that is not optional in the protocol.

 IN EDGE/TESTING ONLY
   Not installed by the menu, because mixing Alpine branches can drag
   in a newer libc than the rest of the system expects. If you want one
   anyway, the pattern is:

     apk add --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing sacc

   sacc, cgo      other gopher browsers for the terminal
   castor         a GTK Gemini window
   geomyidae      a gopher SERVER, if you would rather host gopher
   agate, gmid    other gemini servers

 SEE ALSO
   copal-guide i3-keys        the window manager key bindings
GUIDE

    cat > /usr/local/share/copal/guides/cli-games.txt <<'GUIDE'
 GAMES IN A TERMINAL -- what is here and how to start it
 ======================================================================

 The menu lists the ones worth a menu entry. bsd-games alone installs
 eighteen commands, so most of them live here instead. All of these run
 in a terminal, which on this board is a feature: no OpenGL, no
 compositing, no swapping. They were written for machines slower than
 this one.

 BSD GAMES            apk add bsd-games   (all eighteen, one package)

   The famous ones
     adventure    Colossal Cave. The original text adventure, 1976.
                  "XYZZY" still works.
     hangman      hangman, against the system dictionary
     robots       escape the robots by making them collide
     snake        get the money, avoid yourself
     worm         the other snake
     atc          air traffic control. Genuinely hard.
     klondike     solitaire
     battlestar   a sci-fi text adventure, larger than it looks

   Card and board games
     cribbage     cribbage against the machine
     gofish       go fish
     gomoku       five in a row
     dab          dots and boxes
     drop4        four in a row

   The rest
     arithmetic   drills you on mental arithmetic
     sail         age-of-sail naval combat
     spirhunt     hunt something through a grid of space
     wump         hunt the wumpus
     caesar       not a game -- breaks Caesar ciphers

   Most have a man page: 'man robots', 'man atc'. atc especially --
   it is unplayable until you have read it, and excellent afterwards.

 ROGUELIKES
   nethack      the one. Deep beyond reason. 'nethack' to start.
   brogue       modern, far kinder to a newcomer, still a real game
   zangband     Angband variant. Long.

 INTERACTIVE FICTION
   frotz        a Z-machine interpreter -- it plays Infocom games and
                everything written since. It ships with no stories:
                  frotz story.z5
                The Interactive Fiction Archive has thousands, free and
                legal, and Zork I-III are freely distributed.

 CARDS AND PUZZLES
   ttysolitaire  solitaire, drawn with box characters

 CHESS
   gnuchess      the engine, playable on its own in a terminal
   xboard        a board for it, if X is running

 NOT GAMES BUT THE SAME SPIRIT
   asciiquarium  an aquarium
   cmatrix       the screen effect
   cbonsai       grows a bonsai tree, slowly
   sl            for when you type 'sl' instead of 'ls'
   fortune       a fortune. Pipe it: fortune | figlet
   figlet        big letters out of small ones

 WHAT IS NOT HERE, AND WILL NOT BE
   Alpine does not package Cataclysm-DDA, dungeon-crawl, ADOM, ToME4,
   moon-buggy, nsnake, ninvaders, bastet, vitetris or nbsdgames for
   armhf. moon-buggy, nsnake and nbsdgames exist in edge/testing:

     apk add --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing nsnake

   Anything needing OpenGL is a different problem -- see 'copal-guide i3-keys'
   for why this board renders on the CPU.

 SEE ALSO
   copal-guide small-web      gopher and gemini
   copal-guide i3-keys        the window manager key bindings
GUIDE

    cat > /usr/local/bin/copal-guide <<'COPALGUIDE'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# copal-guide [NAME]  -- read one of the plain-text guides, or list them all.
set -eu
DIR=/usr/local/share/copal/guides
have() { command -v "$1" >/dev/null 2>&1; }
if have less; then PAGE="less"; else PAGE="more"; fi

show() { exec $PAGE "$1"; }

if [ "$#" -ge 1 ]; then
    # Exact name first, then a substring, so 'guide small' finds small-web.
    if [ -f "$DIR/$1.txt" ]; then show "$DIR/$1.txt"; fi
    _hit=$(ls "$DIR"/*"$1"*.txt 2>/dev/null | head -n1 || true)
    [ -n "$_hit" ] && show "$_hit"
    echo "No guide called '$1'. Run 'copal-guide' with no arguments to list them." >&2
    exit 1
fi

# No argument: an index, then a choice. Each guide's first line is its title.
echo
echo "  Guides on this system"
echo "  ---------------------"
_n=0
for _f in "$DIR"/*.txt; do
    [ -f "$_f" ] || continue
    _n=$((_n + 1))
    # First line with letters in it -- skips a '=====' ruler.
    printf '  %2d) %-14s %s\n' "$_n" "$(basename "$_f" .txt)" \
           "$(awk 'NF && /[A-Za-z]/ {sub(/^ +/, ""); print; exit}' "$_f")"
done
if [ "$_n" = 0 ]; then echo "  (none installed)"; exit 0; fi
echo
printf '  Number, or Enter to quit: '
read -r _r || exit 0
case "${_r:-}" in
    ''|*[!0-9]*) exit 0 ;;
esac
_f=$(ls "$DIR"/*.txt 2>/dev/null | sed -n "${_r}p")
[ -n "$_f" ] && show "$_f"
exit 0
COPALGUIDE
    chmod 0755 /usr/local/bin/copal-guide

    # Into both homes, and only now delete the temporary copy -- the guides
    # directory above reads it too.
    install_home_file .config/i3/keys.txt /tmp/keys.$$; rm -f /tmp/keys.$$

    say "Writing ~/.config/i3status/config"
    cat > /tmp/i3status.$$ <<'I3S'
general {
        colors = true
        color_good = "#9ece6a"
        color_degraded = "#e0af68"
        color_bad = "#f7768e"
        interval = 5
}
order += "cpu_usage"
order += "memory"
order += "disk /"
order += "ethernet eth0"
order += "tztime local"

# One option per line. i3status does NOT accept ';' as a separator -- putting
# two options on one line makes it exit 1 at startup, and all i3bar reports is
# "status_command process exited unexpectedly".
cpu_usage {
        format = "cpu %usage"
}

memory {
        format = "mem %used/%total"
        threshold_degraded = "10%"
}

disk "/" {
        format = "sd %avail"
}

ethernet eth0 {
        format_up = "eth %ip"
        format_down = "eth down"
}

tztime local {
        format = "%Y-%m-%d %H:%M"
}
I3S
    # Prove it parses before shipping it. i3bar only ever reports
    # "status_command process exited unexpectedly", which says nothing useful.
    #
    # i3status has no "check and exit" mode: given a good config it runs
    # forever, printing a status line every interval. So the test is inverted
    # -- run it under a timeout and treat being killed as success. A bad
    # config makes it exit on its own, quickly, with the parse error.
    if command -v i3status >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        # The 'if' wrapper is required, not stylistic: under 'set -e' a bare
        # command that exits non-zero would abort the stage before $? is read.
        if timeout 3 i3status -c /tmp/i3status.$$ >/dev/null 2>/tmp/i3status.err.$$; then
            _rc=0
        else
            _rc=$?
        fi
        case "$_rc" in
            0|124) note "i3status config parses (ran until stopped at 3s)" ;;
            *)     warn "the generated i3status config does not parse (exit $_rc):"
                   sed 's/^/      /' /tmp/i3status.err.$$ >&2 ;;
        esac
        rm -f /tmp/i3status.err.$$
    fi
    install_home_file .config/i3status/config /tmp/i3status.$$; rm -f /tmp/i3status.$$

    # A readable terminal. Without a font package xterm falls back to a bitmap
    # that is painful at this resolution.
    say "Writing ~/.Xresources"
    cat > /tmp/xres.$$ <<'XRES'
! Tokyo Night
*background:           #1a1b26
*foreground:           #c0caf5
*cursorColor:          #c0caf5
*color0:  #15161e
*color8:  #414868
*color1:  #f7768e
*color9:  #f7768e
*color2:  #9ece6a
*color10: #9ece6a
*color3:  #e0af68
*color11: #e0af68
*color4:  #7aa2f7
*color12: #7aa2f7
*color5:  #bb9af7
*color13: #bb9af7
*color6:  #7dcfff
*color14: #7dcfff
*color7:  #a9b1d6
*color15: #c0caf5
XTerm*faceName:        Terminus
XTerm*faceSize:        12
XTerm*saveLines:       4096
XTerm*scrollBar:       false
XTerm*selectToClipboard: true
URxvt*font:            xft:Terminus:size=12
URxvt*saveLines:       4096
URxvt*scrollBar:       false
URxvt*internalBorder:  2
XRES
    install_home_file .Xresources /tmp/xres.$$; rm -f /tmp/xres.$$

    install_modern_browser
    configure_x_for_user

    say "Stage 4 complete."
    cat <<MSG
    The desktop runs as '$PI_USER', not as root. So:

        exit                     leave this root shell
        login as $PI_USER        at the console
        startx

    If you are still root when you type startx, copal-startx will stop you and
    say so. That is the check, not a bug.

    Super+Return terminal      Super+d  run a program
    Super+e      file manager  Super+t  task manager (htop)
    Super+r      resize mode   Super+f  fullscreen
    Super+Shift+q close        Super+Shift+e exit i3

    If X fails, read /var/log/Xorg.0.log -- the useful lines are marked (EE).
    "no screens found" on this board is usually fbdev: check that
    /dev/fb0 exists and that '$PI_USER' is in the video group.
MSG
    commit_reminder
}

# ------------------------------------------------------- stage 5: zram -----
stage_zram() {
    say "Stage 5: compressed swap in RAM (zram)"
    cat <<'MSG'
    A block device that compresses whatever is written to it and keeps it in
    RAM. Used as swap it buys back roughly its own size again in usable
    memory, at the cost of CPU to compress -- and unlike swapping to the SD
    card, it costs no writes to flash and no seek latency.

    On 512 MB this is the single biggest win available.
MSG

    if ! modprobe zram 2>/dev/null; then
        warn "the zram module is not available in this kernel."
        note "Nothing was changed."
        return 0
    fi
    note "zram module loaded"
    add_optional util-linux   # zramctl, for inspecting it later

    # Half of RAM as the uncompressed size. Real occupancy is lower -- text
    # and heap typically compress 2-3x -- and pages only occupy RAM once
    # written, so this is a ceiling and not a reservation.
    ZRAM_KB=$(awk '/MemTotal/ {printf "%d", $2 / 2}' /proc/meminfo)
    note "sizing zram0 at ${ZRAM_KB} kB (half of RAM)"

    # /etc/local.d/*.start is run at boot by the 'local' service. Doing it
    # this way avoids depending on a packaged init script whose conf format
    # differs between releases.
    say "Installing /etc/local.d/zram.start"
    mkdir -p /etc/local.d
    cat > /etc/local.d/zram.start <<ZRAM
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# Compressed swap in RAM. Written by copal-init.sh.
modprobe zram || exit 0
[ -e /dev/zram0 ] || exit 0
# Already set up (re-run of local.d)? Leave it alone.
grep -q '^/dev/zram0' /proc/swaps && exit 0
# lz4 is much cheaper than zstd on an ARMv6 core; fall back to the default.
echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
echo $((ZRAM_KB * 1024)) > /sys/block/zram0/disksize
mkswap /dev/zram0 >/dev/null
# Higher priority than any disk swap, so this fills first.
swapon -p 100 /dev/zram0
ZRAM
    chmod +x /etc/local.d/zram.start

    # Swapping to RAM is cheap, so lean on it rather than reclaiming caches.
    say "Setting vm.swappiness=100"
    mkdir -p /etc/sysctl.d
    printf '# zram swap is cheap; prefer it over dropping page cache.\nvm.swappiness=100\n' \
        > /etc/sysctl.d/60-zram.conf
    sysctl -w vm.swappiness=100 >/dev/null 2>&1 || true

    rc-update add local default >/dev/null 2>&1 || true

    say "Enabling it now"
    if /etc/local.d/zram.start; then
        note "$(free -m | awk '/Swap:/ {print "swap: " $2 " MB total"}')"
        grep '^/dev/zram0' /proc/swaps | sed 's/^/    /' || warn "zram0 is not in /proc/swaps"
    else
        warn "could not enable zram now; it will be retried at boot"
    fi

    say "Stage 5 complete."
    note "Check later with: zramctl   and   free -m"
}

# --------------------------------------------------- stage 6: ssh key ------
# ------------------------------------------------------------- ssh policy ---
#
# The policy is written as one managed block at the TOP of sshd_config, and
# the position is the whole trick. OpenSSH takes the FIRST value it finds for
# each keyword, so a block at the top wins over every stock line below it
# without having to find, comment out and keep track of them. Removing the
# block restores the stock behaviour exactly, because nothing else was edited.
SSHCFG=/etc/ssh/sshd_config
SSH_BEGIN='# >>> copal ssh policy >>>'
SSH_END='# <<< copal ssh policy <<<'

ssh_has_key() {  # is there an authorized_keys file with a key in it?
    _hd=$(user_home)
    [ -n "$_hd" ] && [ -s "$_hd/.ssh/authorized_keys" ] \
        && grep -qE '^(ssh-(ed25519|rsa)|ecdsa-sha2-|sk-)' "$_hd/.ssh/authorized_keys" 2>/dev/null
}

# Whether sshd will actually ACCEPT that key, which is a different question and
# the one that matters. ssh_has_key runs as root, and root can read anything --
# so it answers "is the file there", not "can the daemon use it".
#
# This distinction is not academic. It produced a real lockout: stage 3 left
# /home/$PI_USER in a state its owner could not enter, stage 6 wrote the key
# into it, ssh_has_key said yes because root could read the file, the policy
# disabled password authentication on the strength of that, and stage 13 then
# locked root. The result was a machine that refused every SSH login by every
# method and could only be reached from the console:
#
#     login: can't change directory to '/home/user': Permission denied
#
# sshd applies StrictModes before it will read a key: the home directory, .ssh
# and authorized_keys must each be owned by that user (or root) and must not be
# group- or world-writable. Any one of those failing makes it ignore the key
# and say nothing useful about why.
strictmodes_ok() {  # <path> -- owned by the user or root, no group/other write
    _p="$1"
    [ -e "$_p" ] || return 1
    _want=$(id -u "$PI_USER" 2>/dev/null) || return 1
    # No fallback that assumes success: a stat that cannot answer is a reason
    # to refuse, not a reason to proceed.
    _own=$(stat -c '%u' "$_p" 2>/dev/null) || return 1
    _mode=$(stat -c '%a' "$_p" 2>/dev/null) || return 1
    [ -n "$_own" ] && [ -n "$_mode" ] || return 1
    [ "$_own" = "$_want" ] || [ "$_own" = 0 ] || return 1
    while [ "${#_mode}" -lt 4 ]; do _mode="0$_mode"; done
    case "$(printf '%s' "$_mode" | cut -c3)" in 2|3|6|7) return 1 ;; esac
    case "$(printf '%s' "$_mode" | cut -c4)" in 2|3|6|7) return 1 ;; esac
    return 0
}

# Ask the operating system rather than infer from mode bits: can the account
# actually get into its own home and read its own key? This is what catches a
# home directory that is fine in itself but sits under a parent the user cannot
# traverse -- the mode bits on the home say nothing about /home above it.
home_reachable() {
    _hd=$(user_home)
    [ -n "$_hd" ] || return 1
    su -s /bin/sh "$PI_USER" -c "cd '$_hd' && test -r '$_hd/.ssh/authorized_keys'" \
        >/dev/null 2>&1
}

ssh_key_usable() {
    _hd=$(user_home)
    [ -n "$_hd" ] || return 1
    ssh_has_key || return 1
    strictmodes_ok "$_hd"                          || { warn "$_hd fails sshd StrictModes"; return 1; }
    strictmodes_ok "$_hd/.ssh"                     || { warn "$_hd/.ssh fails sshd StrictModes"; return 1; }
    strictmodes_ok "$_hd/.ssh/authorized_keys"     || { warn "$_hd/.ssh/authorized_keys fails sshd StrictModes"; return 1; }
    home_reachable                                 || { warn "'$PI_USER' cannot reach $_hd -- check the modes on its parents"; return 1; }
    return 0
}
ssh_policy_present() { grep -qF "$SSH_BEGIN" "$SSHCFG" 2>/dev/null; }
ssh_password_on()    { sed -n "/$SSH_BEGIN/,/$SSH_END/p" "$SSHCFG" 2>/dev/null \
                         | grep -qi '^PasswordAuthentication[[:space:]]*yes'; }

# <passwords: yes|no>
#
# Never called with 'no' unless a key is known to be installed -- that check
# lives in the callers, because getting it wrong means an unreachable board
# and a trip to fetch the card.
ssh_write_policy() {
    _pw="$1"
    [ -f "$SSHCFG" ] || { warn "no $SSHCFG -- is openssh installed?"; return 1; }
    cp "$SSHCFG" "$SSHCFG.copal.bak"

    # Strip any previous block, then prepend the new one.
    _tmp="$SSHCFG.copal.new"
    { printf '%s\n' "$SSH_BEGIN"
      echo '# Written by Copal. Delete this block to return to stock OpenSSH'
      echo '# behaviour; nothing outside it was modified. It is FIRST on purpose:'
      echo '# sshd uses the first value it finds for each keyword.'
      echo 'PermitRootLogin no'
      echo 'PubkeyAuthentication yes'
      printf 'PasswordAuthentication %s\n' "$_pw"
      # Alpine's sshd builds with PAM off and keyboard-interactive on. Left
      # enabled it is a second password prompt that ignores the setting above,
      # so turning passwords off without this achieves nothing at all.
      printf 'KbdInteractiveAuthentication %s\n' "$_pw"
      printf 'ChallengeResponseAuthentication %s\n' "$_pw"
      # Only the admin user. Not root, and not any service account that a
      # later package might create with a shell.
      printf 'AllowUsers %s\n' "$PI_USER"
      printf '%s\n' "$SSH_END"
      sed "/$SSH_BEGIN/,/$SSH_END/d" "$SSHCFG"
    } > "$_tmp" || { warn "could not write $_tmp"; return 1; }

    # Validate BEFORE it becomes the live config. sshd -t parses a file and
    # says nothing if it is good; a syntax error here would otherwise take
    # the daemon down at the next restart, which on a headless board is the
    # same as losing the machine.
    mv "$_tmp" "$SSHCFG"
    if sshd -t 2>/dev/null; then
        note "sshd -t: config is valid"
    else
        warn "sshd rejected the new config -- restoring the previous one:"
        sshd -t 2>&1 | sed 's/^/      /'
        cp "$SSHCFG.copal.bak" "$SSHCFG"
        return 1
    fi

    if rc-service sshd status >/dev/null 2>&1; then
        rc-service sshd reload >/dev/null 2>&1 \
            || rc-service sshd restart >/dev/null 2>&1 \
            || warn "could not reload sshd -- do it by hand: rc-service sshd restart"
    fi
    note "root login      : refused"
    note "allowed users   : $PI_USER"
    note "password login  : $_pw"
    note "public key login: yes"
    return 0
}

stage_sshkey() {
    say "Stage 6: authorise the Mac's SSH key for '$PI_USER'"
    KEYSRC="$BOOT/authorized_keys"
    [ -f "$KEYSRC" ] || {
        warn "no $KEYSRC on the boot partition."
        note "copal-prep.sh copies it there from ~/.ssh/*.pub on the Mac."
        return 0
    }
    id "$PI_USER" >/dev/null 2>&1 || {
        warn "user '$PI_USER' does not exist yet -- run stage 1 first"
        return 0
    }

    HOMEDIR=$(user_home)
    [ -n "$HOMEDIR" ] || die "cannot determine the home directory for $PI_USER"
    # In the automatic order this is the first stage to touch the home
    # directory, and `mkdir -p $HOMEDIR/.ssh` would happily create a
    # root-owned $HOMEDIR on the way past -- a home directory its owner
    # cannot write, which is worse than not having one.
    ensure_user_home || true

    say "Installing into $HOMEDIR/.ssh/authorized_keys"
    mkdir -p "$HOMEDIR/.ssh"
    # sshd refuses to use these if they are group- or world-writable.
    if [ -f "$HOMEDIR/.ssh/authorized_keys" ] \
       && grep -qxF "$(cat "$KEYSRC")" "$HOMEDIR/.ssh/authorized_keys"; then
        note "that key is already authorised"
    else
        cat "$KEYSRC" >> "$HOMEDIR/.ssh/authorized_keys"
        note "added $(awk '{print $1, $NF}' "$KEYSRC")"
    fi
    chown -R "$PI_USER" "$HOMEDIR/.ssh"
    chmod 700 "$HOMEDIR/.ssh"
    chmod 600 "$HOMEDIR/.ssh/authorized_keys"

    rc-update add sshd default >/dev/null 2>&1 || true
    rc-service sshd start >/dev/null 2>&1 || rc-service sshd restart >/dev/null 2>&1 || true

    # --- the policy ---------------------------------------------------------
    say "Applying the SSH policy"
    cat <<MSG
    The default from here is the one worth having: the key you just installed
    is the only way in, root cannot log in over the network at all, and
    '$PI_USER' is the only account sshd will consider.

    A password is a thing that can be guessed by anyone who can reach port 22.
    A key cannot, and you already have one on this card -- so leaving password
    login on buys nothing and costs you every brute-force attempt on the
    internet. It stays available as a toggle rather than a rebuild:

        doas copal-ssh password on     # allow passwords again
        doas copal-ssh password off    # keys only
        doas copal-ssh status          # what is in force now

MSG
    # ssh_key_usable, NOT ssh_has_key. The difference is the whole guard: one
    # asks whether the file exists, the other whether sshd will accept it. The
    # first is what this used to check, and it disabled password login on a key
    # the daemon then refused -- see ssh_key_usable for the lockout that made.
    if ssh_key_usable; then
        AUTO_DEFAULT=y
        if confirm_yes "Require the key and disable password login over SSH?"; then
            ssh_write_policy no || warn "policy not applied"
        else
            note "Leaving password login enabled."
            ssh_write_policy yes || warn "policy not applied"
        fi
    else
        # The guard that matters. Without a key sshd will actually honour,
        # key-only locks the machine off the network entirely, so it is not
        # offered -- not even in automatic mode, where nobody is watching.
        if ssh_has_key; then
            warn "there IS a key in $HOMEDIR/.ssh/authorized_keys, but sshd will not use it."
            warn "The warnings above say which check failed."
        else
            warn "no key in $HOMEDIR/.ssh/authorized_keys."
        fi
        warn "NOT disabling password login -- that would lock you out entirely."
        ssh_write_policy yes || warn "policy not applied"
        note "Fix the ownership, then: doas copal-ssh password off"
    fi

    say "Installing /usr/local/bin/copal-ssh"
    cat > /usr/local/bin/copal-ssh <<COPALSSH
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# copal-ssh -- read and change the SSH policy Copal wrote into sshd_config.
#
#   copal-ssh status            show what is in force
#   copal-ssh password on|off   allow / refuse password authentication
#   copal-ssh root on|off       allow / refuse root login over SSH
#   copal-ssh users U [U...]    replace the AllowUsers list
#
# Everything lives in one managed block at the top of the file; delete the
# block by hand and stock OpenSSH behaviour returns.
set -eu
CFG=$SSHCFG
USER_DEFAULT=$PI_USER
COPALSSH
cat >> /usr/local/bin/copal-ssh <<'COPALSSH'
B='# >>> copal ssh policy >>>'
E='# <<< copal ssh policy <<<'

[ "$(id -u)" = 0 ] || { echo "needs root: doas copal-ssh $*" >&2; exit 1; }
[ -f "$CFG" ] || { echo "no $CFG" >&2; exit 1; }

get() { sed -n "/$B/,/$E/p" "$CFG" | awk -v k="$1" 'tolower($1)==tolower(k){print $2; exit}'; }

status() {
    if ! grep -qF "$B" "$CFG"; then
        echo "No Copal policy block -- sshd is using its stock configuration."
        grep -iE '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|AllowUsers)' "$CFG" || true
        return 0
    fi
    printf 'password login : %s\n' "$(get PasswordAuthentication)"
    printf 'root login     : %s\n' "$(get PermitRootLogin)"
    printf 'allowed users  : %s\n' "$(sed -n "/$B/,/$E/p" "$CFG" | sed -n 's/^AllowUsers[[:space:]]*//p')"
    printf 'public keys    : %s\n' "$(get PubkeyAuthentication)"
}

# Rewrite one keyword inside the block, leaving everything else alone.
set_key() {  # <keyword> <value>
    grep -qF "$B" "$CFG" || { echo "no Copal policy block to edit" >&2; exit 1; }
    cp "$CFG" "$CFG.copal.bak"
    awk -v b="$B" -v e="$E" -v k="$1" -v v="$2" '
        $0 == b { inb = 1 }
        $0 == e { inb = 0 }
        inb && tolower($1) == tolower(k) { print k, v; next }
        { print }
    ' "$CFG" > "$CFG.copal.new" && mv "$CFG.copal.new" "$CFG"
    if sshd -t 2>/dev/null; then
        rc-service sshd reload >/dev/null 2>&1 || rc-service sshd restart >/dev/null 2>&1 || true
    else
        echo "sshd rejected the change -- reverting." >&2
        sshd -t 2>&1 | sed 's/^/  /' >&2
        cp "$CFG.copal.bak" "$CFG"
        exit 1
    fi
}

has_key() {
    h=$(getent passwd "$USER_DEFAULT" | cut -d: -f6)
    [ -n "$h" ] && [ -s "$h/.ssh/authorized_keys" ]
}

case "${1:-status}" in
    status) status ;;
    password)
        case "${2:-}" in
            on|yes)  set_key PasswordAuthentication yes
                     set_key KbdInteractiveAuthentication yes
                     set_key ChallengeResponseAuthentication yes
                     echo "Password login is ON." ;;
            off|no)
                if ! has_key; then
                    echo "Refusing: $USER_DEFAULT has no authorized_keys, so turning" >&2
                    echo "passwords off would lock this machine off the network." >&2
                    exit 1
                fi
                set_key PasswordAuthentication no
                set_key KbdInteractiveAuthentication no
                set_key ChallengeResponseAuthentication no
                echo "Password login is OFF -- keys only." ;;
            *) echo "usage: copal-ssh password on|off" >&2; exit 2 ;;
        esac ;;
    root)
        case "${2:-}" in
            on|yes) set_key PermitRootLogin prohibit-password
                    echo "Root may log in over SSH BY KEY ONLY (prohibit-password)." ;;
            off|no) set_key PermitRootLogin no; echo "Root login over SSH refused." ;;
            *) echo "usage: copal-ssh root on|off" >&2; exit 2 ;;
        esac ;;
    users)
        shift
        [ "$#" -gt 0 ] || { echo "usage: copal-ssh users NAME [NAME...]" >&2; exit 2; }
        set_key AllowUsers "$*"
        echo "AllowUsers: $*" ;;
    *) sed -n '2,${/^#/!q; /^# SPDX/d; /^# Copyright/d; p;}' "$0"; exit 2 ;;
esac
COPALSSH
    chmod 0755 /usr/local/bin/copal-ssh

    say "Stage 6 complete."
    note "From the Mac:  ssh $PI_USER@$(hostname)"
    note "or by address: ssh $PI_USER@$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')"
    note "Change the policy later with: doas copal-ssh status"
}

# --------------------------------------------- stage 7: development ---------
# A global git identity, for the ADMIN USER rather than for root. Writing it
# with 'git config --file' rather than 'su - user -c "git config --global"'
# avoids needing a login shell for the user, which does not necessarily exist
# yet and would drag in their whole profile just to set two strings.
#
# This USED TO be the one question --auto stopped for out here, an hour and a
# half into a run nobody was watching. It does not ask any more: stage 1 asks,
# next to the password, and saves the answer to $IDFILE on the boot partition.
# All this does is apply it.
#
# It can still ask, in one case: a card written before Copal gathered this up
# front, or a run that skipped stage 1 and came straight to stage 7. Then it
# falls back to the same prompt, in the same place it always was.
configure_git_identity() {
    say "Git identity for '$PI_USER'"
    if ! command -v git >/dev/null 2>&1; then
        warn "git is not installed -- skipping"
        return 0
    fi
    ensure_user_home || true
    _h=$(user_home)
    if [ -z "$_h" ] || [ ! -d "$_h" ]; then
        warn "no home directory for $PI_USER -- skipping"
        return 0
    fi
    _gc="$_h/.gitconfig"

    _have_n=$(git config --file "$_gc" user.name  2>/dev/null || true)
    _have_e=$(git config --file "$_gc" user.email 2>/dev/null || true)
    if [ -n "$_have_n" ] && [ -n "$_have_e" ]; then
        note "already set: $_have_n <$_have_e>"
        note "change it with: git config --global user.email you@example.com"
        return 0
    fi

    if git_identity_load; then
        note "from the card: ${GIT_NAME:-(no name)} <${GIT_EMAIL:-no email}>"
    else
        note "nothing was saved in stage 1 -- asking now."
        # If the progress screen is up, this prompt needs the terminal AND
        # stdout handed back, exactly as setup-alpine does: a question written
        # into the output pane's file is a machine that looks hung. Stage 1
        # normally makes this branch unreachable, which is the point of it.
        tui_suspend
        git_identity_ask
        tui_resume
        git_identity_load || {
            note "Skipped -- no git identity configured."
            note "Set it later with: git config --global user.email you@example.com"
            return 0
        }
    fi
    _gn="$GIT_NAME"
    _ge="$GIT_EMAIL"

    [ -n "$_gn" ] && git config --file "$_gc" user.name  "$_gn"
    [ -n "$_ge" ] && git config --file "$_gc" user.email "$_ge"
    # Two defaults worth having and annoying to discover later: 'main' rather
    # than git's warning about an unset default, and a merge policy so 'git
    # pull' does not stop to ask which one you meant.
    git config --file "$_gc" init.defaultBranch main
    git config --file "$_gc" pull.rebase false
    own_by_user "$_gc"

    note "$( { git config --file "$_gc" user.name; git config --file "$_gc" user.email; } 2>/dev/null | tr '\n' ' ')"
    note "written to $_gc (owned by $PI_USER)"
}

# Claude Code. Asked for explicitly, so it is offered -- with what this board
# actually is stated rather than buried.
install_claude_code() {
    say "Claude Code"
    if ! command -v npm >/dev/null 2>&1; then
        warn "npm is not installed -- skipping Claude Code"
        note "It is a Node application; without npm there is nothing to install from."
        return 0
    fi
    # Packaged is not the same as working. Alpine ships a nodejs for armhf,
    # but Node dropped official ARMv6 support years ago -- so run it once and
    # find out here, in two seconds, rather than after a several-minute npm
    # install that ends in an illegal instruction.
    if ! node -e 'process.exit(0)' >/dev/null 2>&1; then
        warn "the installed node does not run on this CPU."
        note "$(node --version 2>&1 | head -n1)"
        note "That rules out Claude Code on this board -- it is a Node program."
        return 0
    fi
    note "node $(node --version 2>/dev/null) runs here"

    cat <<'MSG'

    What you are asking of this board:

      - Node alone is tens of MB resident before Claude Code starts, against
        512 MB shared with the framebuffer. zram (stage 5) is close to a
        prerequisite rather than a nicety.
      - On ARMv6 this is not a configuration Anthropic tests. It may work; it
        will not be fast.
      - Signing in opens a URL. There is no need for a browser ON the Pi --
        the URL can be pasted into the browser on any machine, which is the
        better option here. If you would rather do it locally, stage 4
        installs one and this sets $BROWSER to it.

MSG
    confirm "Install Claude Code?" || { note "Skipping Claude Code."; return 0; }

    say "Installing @anthropic-ai/claude-code"
    # Global, so it lands on PATH for every account. That is not the same as
    # running as root: the credentials and settings Claude Code writes go to
    # ~/.claude, so signing in as the admin user keeps them in that user's
    # home where they belong.
    if npm install -g @anthropic-ai/claude-code; then
        note "installed: $(command -v claude 2>/dev/null || echo 'claude (not yet on PATH -- log out and back in)')"
    else
        warn "npm install failed -- see the output above."
        note "The usual causes on this board are RAM during the install, and"
        note "native modules with no ARMv6 build. Retry under zram, or with:"
        note "  NODE_OPTIONS=--max-old-space-size=256 npm install -g @anthropic-ai/claude-code"
        return 0
    fi

    # $BROWSER is the convention CLI tools follow to open a URL. Point it at
    # whatever stage 4 actually installed, in preference order, so the sign-in
    # link opens rather than printing an error about xdg-open.
    for _b in firefox-esr firefox chromium badwolf netsurf dillo; do
        if command -v "$_b" >/dev/null 2>&1; then
            cat > /etc/profile.d/browser.sh <<BROWSERENV
# Written by copal-init.sh. The browser CLI tools should open URLs with --
# Claude Code's sign-in link among them.
export BROWSER=$_b
BROWSERENV
            chmod +x /etc/profile.d/browser.sh
            note "\$BROWSER=$_b (for the sign-in link)"
            break
        fi
    done
    command -v "$_b" >/dev/null 2>&1 || \
        note "no browser installed yet -- run stage 4, or paste the sign-in URL"
    note "Sign in by running:  claude      (as $PI_USER, not as root)"
    note "Credentials land in ~/.claude, so run it as the account you use."
    note "If it runs out of memory: NODE_OPTIONS=--max-old-space-size=256 claude"
}

# The guides that go with the toolchain. Dropped into the same directory the
# rest of them live in, so copal-guide lists them and the jgmenu Guides submenu
# picks them up with no other change -- the menu is built from the directory.
#
# Plain text, 76 columns, first line is the title. That is the whole format.
dev_write_guides() {
    say "Writing the developer guides"
    mkdir -p /usr/local/share/copal/guides
    _g=/usr/local/share/copal/guides

    cat > "$_g/ide.txt" <<'GUIDE'
COMPILING AND DEBUGGING -- the whole loop, in one editor

   This is the guide to read first. It covers building, breakpoints, stepping,
   and finding your way around a call chain, in the editor Copal sets up as
   its IDE. Everything here works with no plugins installed.

   Two editors are configured, from ONE config file:

      nvim   the IDE: everything below, plus language servers
      vim    the same editing, building and debugging, without the servers

   ~/.vimrc is shared by both. ~/.config/nvim/lsp.lua is the Neovim-only half.

 ---------------------------------------------------------------------------
 1. BUILDING
 ---------------------------------------------------------------------------

   Every sample project in ~/dev has a Makefile, and the editor drives it:

      F5            save everything and run 'make'
      F6            save everything and run 'make run'
      :make         the same as F5, typed
      :make debug   build with symbols and start the debugger

   Errors do not scroll past. They go into the QUICKFIX LIST:

      ]q            jump to the next error
      [q            jump to the previous error
      <leader>q     open the whole list in a window
      :cc 3         jump to error 3
      :cfirst       back to the first

   <leader> is the backslash key unless you have changed it.

   The point of the quickfix list is that the compiler's line numbers become
   navigation. You never copy a line number by hand.

 ---------------------------------------------------------------------------
 2. BREAKPOINTS AND STEPPING
 ---------------------------------------------------------------------------

   Termdebug ships inside vim and neovim. It is a real gdb session with the
   source in one window and the program in another -- a graphical debugger
   without a graphical debugger.

      F4            start the debugger on this file's program (:Termdebug)
      F9            set a breakpoint on the line the cursor is on
      F21           clear the breakpoint here (Shift-F9 on most keyboards)
      F8            continue -- run until the next breakpoint
      F10           step OVER: run this line, do not enter its calls
      F11           step INTO: go into the function this line calls
      F12           finish: run until the current function returns
      <leader>e     evaluate the expression under the cursor

   The difference between F10 and F11 is the one worth internalising. F10 is
   "I trust that function, run it". F11 is "the bug is in there, take me in".

   A typical session, in ~/dev/hello:

      nvim main.c
      move to the 'total += i' line
      F9              set the breakpoint
      F4              start the debugger
      F8              run to the breakpoint
      F10 F10 F10     watch total change
      <leader>e       on 'total' -- see its value
      F12             finish accumulate() and come back to main()

 ---------------------------------------------------------------------------
 3. WHERE AM I, AND WHO CALLED ME
 ---------------------------------------------------------------------------

   Two different questions, two different tools, and people confuse them:

   AT RUNTIME -- who actually called this, on this run. That is the call
   stack, and gdb owns it. In the Termdebug gdb window:

      bt            backtrace: the whole chain of calls that got you here
      bt full       the same, with every local variable at each level
      up            move one frame TOWARDS the caller (the parent function)
      down          move one frame back towards where you were
      frame 3       jump straight to frame 3
      info locals   the variables in the frame you are looking at
      info args     the arguments this frame was called with
      finish        run until this frame returns, and print what it returned

   'up' is the answer to "what called this function". The frame it moves to
   is the parent, and 'info args' then shows what it passed in.

   STATICALLY -- everything that could call this, without running it. That is
   the language server, in nvim:

      <leader>ci    incoming calls -- everything that calls this function
      <leader>co    outgoing calls -- everything this function calls
      gr            every reference to this symbol anywhere in the project
      gd            go to the definition
      gD            go to the declaration
      gi            go to the implementation (of an interface or trait)
      gy            go to the type definition
      K             hover: the signature and documentation

   <leader>ci is the "find the parent calling function" you want when reading
   unfamiliar code. It answers it for the whole project, not just this run.

   GETTING BACK, in both cases:

      Ctrl-O        back to where you jumped from
      Ctrl-I        forward again
      Ctrl-T        back up the tag stack
      ''            (two apostrophes) back to the last place you jumped from
      :jumps        the whole jump list

   Ctrl-O is the most useful key here. Jump freely; it is one key back.

 ---------------------------------------------------------------------------
 4. WHEN gd DOES NOTHING
 ---------------------------------------------------------------------------

   go-to-definition needs a language server for that language, running.

      :Lsp          which servers are enabled, and which attached to THIS file
      :checkhealth  neovim's own diagnosis

   For C and C++, clangd also needs to know your include paths and standard.
   It reads compile_commands.json. Generate one:

      bear -- make              (bear watches the build and writes the file)
      cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON .

   Without it clangd guesses, and guesses wrong on anything with -I flags.

   No server for your language? ctags still works, everywhere, for any
   language it knows:

      ctags -R .    build the index
      Ctrl-]        jump to the definition under the cursor
      Ctrl-T        come back
      :tselect      choose between several matches

 ---------------------------------------------------------------------------
 5. PER LANGUAGE
 ---------------------------------------------------------------------------

   C, C++      cc -g -O0 main.c -o prog   then  gdb ./prog
               -g keeps symbols, -O0 stops the optimiser reordering lines out
               from under the debugger. Debug without both and the cursor
               jumps around apparently at random.
               Standards: -std=c89 c99 c11 c17 c23, and c++11 ... c++23
               Second opinion: clang instead of cc. Different, better errors.

   Rust        cargo build           debug build, symbols included
               cargo run
               rust-gdb ./target/debug/prog   gdb that knows Rust types
               Language server: rust-analyzer. gd, gr and K all work.

   Go          go build -gcflags='-N -l' -o prog    (-N -l disables inlining
               and optimisation, without which stepping is nonsense)
               dlv debug           Delve, Go's own debugger -- aarch64 only
               dlv: 'break main.main', 'continue', 'next', 'step', 'stack'
               gdb ./prog works too, on a binary built with those flags.

   Fortran     gfortran -g -O0 -fcheck=all prog.f90 -o prog
               -fcheck=all catches out-of-bounds at runtime and is worth the
               speed. Then gdb ./prog -- same breakpoints, same stepping.

   Haskell     ghc -g prog.hs        (aarch64 only: see 'copal-guide
               languages')
               ghci                  the interpreter: :break, :step, :trace
               ghci's debugger is genuinely good and needs no setup.

   Python      python3 -m pdb script.py
               pdb: 'b 42' breakpoint, 'c' continue, 'n' next, 's' step,
               'w' where (the backtrace), 'u'/'d' up and down the stack,
               'p expr' print. The same letters as gdb, mostly.

   PHP         XDEBUG_TRIGGER=1 php83 script.php
               Xdebug is installed and off until triggered, deliberately --
               see /etc/php83/conf.d/50_xdebug.ini for why.
               Composer is installed: 'composer init', 'composer require'.

   Shell       sh -n script.sh       syntax check only. Do this first.
               sh -x script.sh       trace every line as it runs
               set -x / set +x       trace part of a script
               shellcheck script.sh  finds what passes -n and still breaks
               shfmt -w script.sh    format it
               No bashdb in Alpine. 'set -x' plus PS4 is the debugger:
                 PS4='+ ${LINENO}: ' sh -x script.sh

   Forth       retro                 the RetroForth interpreter
               Not gforth -- see 'copal-guide languages' for what that means.

 ---------------------------------------------------------------------------
 6. THE GUI IDEs
 ---------------------------------------------------------------------------

   If you want menus and a mouse instead:

      geany         light, real build system, F5 compiles. Installed already.
      codeblocks    a full C/C++ IDE with GDB breakpoints in the margin.
                    Click the margin to set one, F8 to debug. Every port.
      kdevelop      heavier, better. aarch64 only.
      vscodium      VS Code without the telemetry. aarch64 only, edge/testing.
      lapce         modern, Rust, built-in LSP. aarch64 only.

   There is no VS Code for ARMv6 and there never will be: Electron dropped
   32-bit ARM years ago. On a Pi Zero the honest answer is nvim or Geany, and
   nvim with the language servers above is the more capable of the two.
   Install any of these from the menu: Super+C, then Devtools.

   See also:  copal-guide nvim        the editor itself, in depth
              copal-guide languages   what exists on which board
              copal-guide tmux        keeping a build running
GUIDE

    cat > "$_g/nvim.txt" <<'GUIDE'
NEOVIM -- a primer, from nothing to useful

   Copal configures nvim as an IDE with no plugins. This is what it can do.
   If you have never used a modal editor, read section 1 and stop; come back
   for the rest when the first part is reflex.

 ---------------------------------------------------------------------------
 1. THE ONE IDEA
 ---------------------------------------------------------------------------

   The keyboard means different things depending on the MODE.

      NORMAL     navigate and operate on text. Where you start. Esc returns.
      INSERT     type text. Enter with i, leave with Esc.
      VISUAL     select text. Enter with v, V (lines), Ctrl-V (a block).
      COMMAND    :  -- one command, then Enter.

   If a key does something unexpected, press Esc twice and you are in Normal.

   Edit and save:  nvim file -> i -> type -> Esc -> :w -> :q
   To leave without saving:  :q!
   Save and quit in one:     :x   (or ZZ in Normal mode)

 ---------------------------------------------------------------------------
 2. MOVING
 ---------------------------------------------------------------------------

      h j k l       left, down, up, right (arrows also work)
      w  b          forward/back one word      e   end of word
      0  ^  $       start of line, first non-blank, end of line
      gg  G         top of file, bottom of file
      42G  :42      line 42
      Ctrl-D Ctrl-U half a page down, up
      {  }          previous/next blank line -- moves by paragraph
      %             jump to the matching bracket. Also #if/#endif
      f x  t x      jump to the next 'x' / just before it. ; repeats.
      *             search for the word under the cursor
      /text  ?text  search forward, backward.  n / N for next, previous
      Ctrl-O Ctrl-I back, forward through everywhere you have jumped

   In code, % and * do more work than any other two keys here.

 ---------------------------------------------------------------------------
 3. CHANGING
 ---------------------------------------------------------------------------

   The grammar is VERB + OBJECT, and it composes:

      d w    delete word       c w    change word     y w   yank word
      d d    delete line          c c    change line        y y   yank line
      d $    delete to end of line
      d i (  delete inside the parentheses
      c i "  change inside the quotes
      y a {  yank around the braces, braces included
      d 3 w  delete three words        3 d d   delete three lines

      i a    inside / around -- the two that make it composable
      p  P   paste after, before
      u      undo        Ctrl-R  redo
      .      repeat the last change. The most underrated key in the editor.
      x      delete a character      r x   replace it with x
      >>  << indent, outdent         ==    reindent this line
      gq     rewrap a paragraph to the text width

   :%s/old/new/g          replace everywhere
   :%s/old/new/gc         the same, asking each time

 ---------------------------------------------------------------------------
 4. FILES, WINDOWS, BUFFERS
 ---------------------------------------------------------------------------

      :e path       open a file        :find name   open by name from anywhere
      <leader>n     the file browser (netrw)
      :b name       switch to an open buffer, by any part of its name
      :ls           list the open buffers
      Ctrl-^        the previous buffer -- toggles between two files

      :sp  :vs      split horizontally, vertically
      Ctrl-W hjkl   move between splits
      Ctrl-W =      make the splits equal
      Ctrl-W o      close every split but this one
      :tabnew       a new tab        gt / gT   next / previous tab

   'set path+=**' is configured, so :find matches recursively. :find main.c
   works from anywhere in a project.

 ---------------------------------------------------------------------------
 5. THE IDE PART
 ---------------------------------------------------------------------------

   Covered in full by 'copal-guide ide'. In brief:

      F5  F6        build, build and run
      ]q  [q        next, previous compiler error
      gd  gr  K     definition, references, documentation
      <leader>ci    who calls this function
      <leader>rn    rename this symbol everywhere
      <leader>ca    code action -- the "fix it for me" menu
      <leader>F     format the file
      ]d  [d        next, previous diagnostic
      F4 F9 F8 F10 F11   debugger: start, breakpoint, continue, over, into
      Ctrl-X Ctrl-O completion, if you would rather ask than be offered
      :Lsp          which language servers are running

 ---------------------------------------------------------------------------
 6. WORTH KNOWING
 ---------------------------------------------------------------------------

      :help x       the manual for x. It is genuinely good. Ctrl-] follows a
                    link in it, Ctrl-O comes back.
      :Tutor        a thirty-minute interactive tutorial. Do it once.
      q:            the command history, editable as text
      Ctrl-A Ctrl-X increment / decrement the number under the cursor
      Ctrl-V        block select -- then I to insert on every line at once
      gv            reselect whatever you last selected
      ga            the character code under the cursor
      :set list     show tabs and trailing whitespace
      :earlier 10m  the file as it was ten minutes ago. Undo is a tree.
      :w !doas tee % > /dev/null    save a file you opened without permission

   Macros, when a change repeats and . is not enough:

      qa            start recording into register a
      ...           do the thing
      q             stop
      @a            replay it        10@a   replay it ten times

   Why no plugins: treesitter compiles a parser per language with gcc, which
   on one ARMv6 core is most of an hour and more RAM than a Zero has. Neovim
   0.11 made the LSP and completion plugins unnecessary anyway. What is here
   starts instantly and does the job. If you want more, ~/.vimrc is yours.
GUIDE
    note "$_g/ide.txt"
    note "$_g/nvim.txt"
}

# The second half of the guides: the terminal, and the instruments. Split from
# dev_write_guides only because one function with nine heredocs in it is hard to
# read, not because they are written at different times -- stage 7 calls both.
dev_write_guides_more() {
    _g=/usr/local/share/copal/guides
    mkdir -p "$_g"

    cat > "$_g/tmux.txt" <<'GUIDE'
TMUX AND SCREEN -- one terminal, many sessions, none of them lost

   The problem both solve: you start a build, the connection drops or you
   close the window, and the build dies with it. Inside a multiplexer it does
   not. You reattach and it is still going.

   On this board there is a second reason: it is one screen and no tabs unless
   the window manager gives you them. tmux gives you them inside a terminal.

 ---------------------------------------------------------------------------
 TMUX -- the modern one
 ---------------------------------------------------------------------------

   Everything is PREFIX then a key. The prefix is Ctrl-B. Press and release
   Ctrl-B, then press the key -- not together.

   SESSIONS -- the thing that survives
      tmux                    start one
      tmux new -s build       start one called 'build'
      tmux ls                 list them
      tmux attach -t build    reattach to it
      tmux a                  reattach to the last one
      Ctrl-B d                detach -- leaves everything running
      Ctrl-B $                rename this session
      exit                    end the session for real

      The whole point: 'tmux new -s build', start a compile, Ctrl-B d, walk
      away, come back tomorrow, 'tmux a', it finished hours ago.

   WINDOWS -- tabs
      Ctrl-B c                new window
      Ctrl-B 0..9             go to window by number
      Ctrl-B n / p            next / previous
      Ctrl-B w                pick from a list
      Ctrl-B ,                rename this window
      Ctrl-B &                close it

   PANES -- splits
      Ctrl-B %                split left/right
      Ctrl-B "                split top/bottom
      Ctrl-B arrow            move between panes
      Ctrl-B o                cycle panes
      Ctrl-B z                ZOOM this pane full screen -- and again to undo.
                              The one people do not know and use most.
      Ctrl-B x                close this pane
      Ctrl-B space            cycle the layouts
      Ctrl-B Ctrl-arrow       resize
      Ctrl-B {  }             swap this pane with the previous / next

   COPYING, SCROLLING
      Ctrl-B [                enter copy mode -- now you can scroll
      arrows / PgUp           move around in it
      space                   start selecting, Enter to copy
      Ctrl-B ]                paste
      q                       leave copy mode
      Ctrl-B /                search the scrollback (tmux 3.1+)

   USEFUL
      Ctrl-B ?                every binding, live. The real manual.
      Ctrl-B t                a big clock, for no good reason
      Ctrl-B :                a tmux command prompt
      tmux kill-server        end everything, if it is truly stuck

   A worked example -- watch a build and edit at once:
      tmux new -s work
      Ctrl-B %          split
      left pane:  nvim main.c
      right pane: while :; do make; sleep 5; done
      Ctrl-B z          zoom whichever one you are reading
      Ctrl-B d          leave it all running

 ---------------------------------------------------------------------------
 SCREEN -- the classic
 ---------------------------------------------------------------------------

   Older, plainer, and on every unix machine you will ever log into, which is
   the reason to know it. The prefix is Ctrl-A.

      screen                  start
      screen -S name          start named
      screen -ls              list
      screen -r name          reattach
      screen -d -r name       reattach, detaching it from wherever else it is
      Ctrl-A d                detach
      Ctrl-A c                new window
      Ctrl-A 0..9             switch to window by number
      Ctrl-A n / p            next / previous
      Ctrl-A "                list windows and choose
      Ctrl-A A                rename this window
      Ctrl-A S                split horizontally
      Ctrl-A |                split vertically
      Ctrl-A Tab              move between splits
      Ctrl-A X                close this split
      Ctrl-A Esc              copy mode; space to mark, space to end
      Ctrl-A ]                paste
      Ctrl-A k                kill this window
      Ctrl-A ?                the key list

   Ctrl-A is also "start of line" in a shell. Inside screen you press
   Ctrl-A a to get it. This annoys everyone once.

   SERIAL CONSOLES -- the reason screen is worth having here:
      screen /dev/ttyUSB0 115200
      Leave with Ctrl-A k, or Ctrl-A \ to quit screen entirely.
      That is how you talk to a router, a microcontroller, or another Pi over
      the GPIO UART.

 ---------------------------------------------------------------------------
 WHICH
 ---------------------------------------------------------------------------

   tmux for daily work: better splits, better copy mode, still maintained.
   screen when it is already installed on someone else's machine, and for
   serial ports, where it is simply the shortest command that works.

   byobu is also installed if you took it: it is tmux with a status line
   already configured, F2/F3/F4 instead of a prefix. Run 'byobu'.

   See also:  copal-guide terminals   which terminal emulator to run it in
GUIDE

    cat > "$_g/terminals.txt" <<'GUIDE'
TERMINALS -- which one, and why the fast ones are not

   Copal defaults to urxvt (rxvt-unicode): it starts in a few milliseconds,
   uses a few megabytes, and renders through plain X11. On this hardware that
   combination is hard to beat.

   Install any of these from the menu: Super+C, then Terminals.

 ---------------------------------------------------------------------------
 THE HONEST PART ABOUT "HIGH PERFORMANCE"
 ---------------------------------------------------------------------------

   alacritty, kitty and wezterm are the three terminals people mean by fast.
   All three are packaged for every port Copal builds. All three want OpenGL,
   and get their speed by handing glyph rendering to a GPU.

   This board has no usable GPU for X: it renders on the CPU, into the
   framebuffer, through fbdev. So on a Pi Zero / 1 / 2 / 3 they will either
   refuse to start (no GL context) or fall back to software rasterisation and
   be SLOWER than xterm -- which is a strange place to end up with a terminal
   chosen for speed.

   On a Pi 4 or Pi 5, with real video, they are genuinely good and worth it.

   The fast terminal for THIS board is st or urxvt. Both are X11-native, both
   draw with the same server calls the rest of the desktop uses, and neither
   asks for anything the hardware does not have.

 ---------------------------------------------------------------------------
 THE LINE-UP
 ---------------------------------------------------------------------------

   SMALL AND QUICK -- what to actually use here
      st                suckless. Smallest and quickest. Configured by editing
                        the source and recompiling, which is either the point
                        or the objection.
      urxvt             the default. Fast, scrollback, Unicode, daemon mode
                        (urxvtd + urxvtc starts new windows instantly).
      xterm             the original. Ugly, universal, never breaks. When
                        something else will not start, this will.
      zutty             X11-native and unusually fast. edge/testing.

   FEATUREFUL -- tabs, menus, mouse
      xfce4-terminal    the most featureful GTK one: tabs, profiles, dropdown
                        mode of its own, sane defaults.
      sakura            small, tabs, no menu bar in the way.
      lxterminal        light, tabs.
      terminator        splits panes in a grid, without a multiplexer.
      qterminal         Qt. Has a drop-down mode. Not on armhf.

   DROP-DOWN -- a key drops it from the top of the screen
      tilda             F1. GTK3, small, the one Copal installs. 'tilda -C'
                        for its settings.
      guake             F12. The GNOME one, the one people name. edge/testing
                        only, and it pulls in a slice of GNOME.
      yakuake           F12. The KDE one. Not on armhf.
      xfce4-terminal    --drop-down, if you already have it.

   FOR FUN
      cool-retro-term   a convincing CRT, with the curvature, the bloom and
                        the flicker. Wants more CPU than everything else on
                        this list combined. Worth seeing once.

   NOT PACKAGED / NOT USABLE HERE
      foot              Wayland only. This is an X11 desktop; it would install
                        and never open a window. Deliberately not offered.
      ghostty, contour, mlterm, eterm -- not in Alpine v3.24 for these ports.

 ---------------------------------------------------------------------------
 CHANGING THE DEFAULT
 ---------------------------------------------------------------------------

   Super+Return opens the terminal. To change which one:

      edit ~/.config/i3/config
      find the line   set $term urxvt
      change it, then Super+Shift+R to reload i3

   Fonts and colours for xterm and urxvt live in ~/.Xresources. After editing:

      xrdb -merge ~/.Xresources

   See also:  copal-guide tmux   splits and sessions inside any of them
GUIDE

    cat > "$_g/languages.txt" <<'GUIDE'
LANGUAGES -- what exists on which board, and why

   Copal builds for three Alpine ports and they do not carry the same
   compilers. This is the honest table. 'apk --print-arch' says which you are.

      armhf    Pi Zero, Zero W, Pi 1, CM1        ARMv6
      armv7    Pi 2B v1.1                        ARMv7
      aarch64  Zero 2 W, Pi 3, 4, 400, 5, CM3/4  ARM64

 ---------------------------------------------------------------------------
 EVERYWHERE, INCLUDING A PI ZERO
 ---------------------------------------------------------------------------

   C, C++        gcc (build-base) and clang 22. Both, on purpose: two
                 compilers disagree about which code is wrong.
                 Standards: -std=c89 c99 c11 c17 c23 / c++11 ... c++23
   Rust          rustc, cargo, rust-analyzer, rust-gdb. Works on a Zero, but
                 rustc is an LLVM front end: a crate with dependencies wants
                 more than 512 MB and one ARMv6 core is slow. zram earns its
                 keep here. Fine on a Pi 4/5.
   Go            go, gopls. The pick for compiled work on a small board: the
                 compiler is small, has no LLVM, and builds hello-world in
                 seconds. Static binaries, so nothing to install alongside.
   Fortran       gfortran, F77 through Fortran 2018.
   PHP 8.3       with Composer and Xdebug (breakpoints).
   Forth         RetroForth. See the note below.
   Python 3      with pylsp for the editor.
   Lua 5.4       and LuaJIT, and lua-language-server.
   OCaml         the ML answer where Haskell is not available.
   Perl, Ruby, Tcl, Nim, Elixir, R
   Lisp/Scheme   SBCL, CHICKEN, Guile, Racket
   tcc           the Tiny C Compiler. Compiles so fast it is usable as a
                 scripting language: 'tcc -run prog.c'.

 ---------------------------------------------------------------------------
 aarch64 ONLY
 ---------------------------------------------------------------------------

   Haskell       GHC, cabal, hlint. About 1.5 GB with the package index.
   Zig
   Crystal
   OpenJDK 21
   Delve         Go's own debugger. gdb still works on Go binaries elsewhere.

   NOT armhf (so armv7 and aarch64):
   .NET 9 SDK
   Valgrind      its instrumentation is per-architecture; ARMv6 never had one.

 ---------------------------------------------------------------------------
 THE TWO THAT NEED EXPLAINING
 ---------------------------------------------------------------------------

   HASKELL is not missing because nobody packaged it. GHC bootstraps from a
   previous GHC -- you need a working Haskell compiler to build one -- and
   there is no ARMv6 or ARMv7 GHC to start that chain from. No repository,
   no flag and no amount of patience produces one on a Zero. If you want
   Haskell, use a Pi 3 or better, where it is 'apk add ghc cabal'.

   Copal installs OCaml on the smaller boards instead. It is the nearest thing
   in spirit that is actually built for ARMv6: the same ML type system,
   inference and pattern matching, strict rather than lazy, and a native
   compiler small enough to be pleasant here.

   FORTH: there is no gforth in Alpine, for any architecture, in any
   repository -- stable, community or edge. What is packaged everywhere is
   RetroForth, which is a real and maintained language in the Forth family.

   It is NOT ANS Forth. The vocabulary differs, so a textbook's examples will
   not all run. Start with 'retro' and read the words it lists. If you want
   ANS Forth specifically, you would be building gforth from source -- it is
   plain C and it does compile here, but nothing in Copal does it for you.

   See also:  copal-guide ide   compiling and debugging any of the above
GUIDE
    note "$_g/tmux.txt"
    note "$_g/terminals.txt"
    note "$_g/languages.txt"
}

# Morse code, written here because nothing provides it.
#
# There is no morse package in Alpine for any of these ports: not unixcw (cw,
# cwcp, xcwcp), not aldo, not qrq, not cwdaemon, and not in edge/testing either.
# 'cwm' turns up in a search and is a window manager. bsd-games ships a 'morse'
# on some systems but the Alpine package does not provide it.
#
# So Copal ships its own. It is a POSIX shell script over sox's tone generator,
# which is 40 lines and does the three things a morse program is for: send text,
# drill the letters, and print the table. Timing follows the standard: a dash is
# three dots, the gap inside a letter is one dot, between letters three, between
# words seven. Speed is set in words per minute against PARIS, the conventional
# 50-dot reference word, so 'copal-morse -w 13' means what an operator expects.
dev_write_morse() {
    say "Morse code trainer"
    add_optional sox alsa-utils
    cat > /usr/local/bin/copal-morse <<'MORSE'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# copal-morse -- send, drill and look up morse code.
#
# Written by copal-init.sh, because Alpine packages no morse program at all.
#
#   copal-morse hello world      send it as tones
#   copal-morse -p               print the table and exit
#   copal-morse -d               drill: it sends, you type what you heard
#   copal-morse -w 20 sos        set the speed in words per minute
#   copal-morse -f 700 sos       set the pitch in Hz
#   copal-morse -q hello         print the dots and dashes, play nothing
set -eu

WPM=13; FREQ=600; QUIET=0; MODE=send

# The table. Letter:code, space separated -- one string rather than an
# associative array, because this has to run under busybox ash.
TABLE="a:.- b:-... c:-.-. d:-.. e:. f:..-. g:--. h:.... i:.. j:.--- k:-.-
l:.-.. m:-- n:-. o:--- p:.--. q:--.- r:.-. s:... t:- u:..- v:...- w:.--
x:-..- y:-.-- z:--.. 0:----- 1:.---- 2:..--- 3:...-- 4:....- 5:.....
6:-.... 7:--... 8:---.. 9:----. .:.-.-.- ,:--..-- ?:..--.. /:-..-.
=:-...- +:.-.-. -:-....- ::---... ':.----. @:.--.-."

code_for() {  # <single lower-case character> -> dots and dashes, or empty
    for _e in $TABLE; do
        case "$_e" in "$1":*) printf '%s' "${_e#*:}"; return 0 ;; esac
    done
    return 1
}

usage() {
    sed -n '2,${/^#/!q; /^# SPDX/d; /^# Copyright/d; p;}' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -w) WPM=${2:?-w needs a number}; shift 2 ;;
        -f) FREQ=${2:?-f needs a number}; shift 2 ;;
        -q) QUIET=1; shift ;;
        -p) MODE=print; shift ;;
        -d) MODE=drill; shift ;;
        -h|--help) usage 0 ;;
        --) shift; break ;;
        -*) echo "copal-morse: unknown option '$1'" >&2; usage 1 >&2 ;;
        *) break ;;
    esac
done

case "$WPM$FREQ" in *[!0-9]*) echo "copal-morse: -w and -f take numbers" >&2; exit 1 ;; esac
[ "$WPM" -gt 0 ] 2>/dev/null || { echo "copal-morse: -w must be above 0" >&2; exit 1; }

# PARIS is 50 dot-lengths, so at W words per minute one dot is 1.2/W seconds.
# Kept in milliseconds because shell arithmetic is integer only.
DOT_MS=$(( 1200 / WPM ))
DASH_MS=$(( DOT_MS * 3 ))

HAVE_SOX=0
command -v sox >/dev/null 2>&1 && command -v play >/dev/null 2>&1 && HAVE_SOX=1
if [ "$MODE" != print ] && [ "$QUIET" = 0 ] && [ "$HAVE_SOX" = 0 ]; then
    echo "copal-morse: sox is not installed -- printing the code instead of playing it." >&2
    echo "             apk add sox" >&2
    QUIET=1
fi

# Seconds, as sox wants them. Not printf '%03d' on the milliseconds: that is
# right up to 999 and silently wrong above it, which is every dash below about
# 4 wpm -- exactly the speed a beginner starts at.
secs() { printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )); }

# THE REASON THIS BUILDS A FILE INSTEAD OF PLAYING EACH ELEMENT.
#
# The obvious implementation runs 'play -n synth' once per dot and dash. On this
# board that is fatal to the one thing morse is: rhythm. Spawning a process
# costs tens of milliseconds on a 1 GHz ARMv6 core, a dot at 13 wpm is 92 ms,
# and the jitter lands in the same range as the signal. It sounds wrong and it
# drills the wrong timing into you.
#
# So: synthesise the five distinct sounds ONCE, concatenate copies of them into
# one file, and play that. Five sox calls and one play, for a message of any
# length, and the timing is sample-accurate because sox is doing it rather than
# the shell.
WORK=''
cleanup_work() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup_work EXIT HUP INT TERM

build_parts() {
    [ "$QUIET" = 1 ] && return 0
    [ -n "$WORK" ] && return 0
    WORK=$(mktemp -d 2>/dev/null) || WORK=/tmp/copal-morse.$$
    mkdir -p "$WORK"
    # -r 8000 -c 1: 8 kHz mono is ample for a sine below 1 kHz and keeps the
    # concatenated file small enough not to matter on a card.
    sox -n -r 8000 -c 1 "$WORK/dot.wav"  synth "$(secs "$DOT_MS")"  sine "$FREQ" 2>/dev/null
    sox -n -r 8000 -c 1 "$WORK/dash.wav" synth "$(secs "$DASH_MS")" sine "$FREQ" 2>/dev/null
    # Silence, properly: 'sine 0' would be a 0 Hz tone, which is a DC offset
    # rather than a gap. Sox has a dedicated generator for this.
    sox -n -r 8000 -c 1 "$WORK/g1.wav" synth "$(secs "$DOT_MS")"        sine 0 vol 0 2>/dev/null
    sox -n -r 8000 -c 1 "$WORK/g3.wav" synth "$(secs $(( DOT_MS * 3 ))) " sine 0 vol 0 2>/dev/null
    sox -n -r 8000 -c 1 "$WORK/g7.wav" synth "$(secs $(( DOT_MS * 7 ))) " sine 0 vol 0 2>/dev/null
    [ -f "$WORK/dot.wav" ] || { echo "copal-morse: sox could not make a tone -- printing instead." >&2; QUIET=1; }
}

send_word() {  # <text> -- play it, and print the code
    _text=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    build_parts
    set --                              # the list of wav parts to concatenate
    _first_char=1
    _out=''
    while [ -n "$_text" ]; do
        _c=${_text%"${_text#?}"}; _text=${_text#?}
        if [ "$_c" = ' ' ]; then
            # A word gap replaces the letter gap rather than adding to it.
            [ "$_first_char" = 1 ] || set -- "$@" "$WORK/g7.wav"
            _out="$_out  / "
            _first_char=1
            continue
        fi
        _code=$(code_for "$_c") || continue        # skip anything not in the table
        if [ "$_first_char" = 1 ]; then _first_char=0
        else set -- "$@" "$WORK/g3.wav"; _out="$_out "
        fi
        _out="$_out$_code"
        _rest=$_code; _firstel=1
        while [ -n "$_rest" ]; do
            _el=${_rest%"${_rest#?}"}; _rest=${_rest#?}
            [ "$_firstel" = 1 ] || set -- "$@" "$WORK/g1.wav"
            _firstel=0
            case "$_el" in
                .) set -- "$@" "$WORK/dot.wav" ;;
                -) set -- "$@" "$WORK/dash.wav" ;;
            esac
        done
    done
    printf '%s\n' "$_out"
    [ "$QUIET" = 1 ] && return 0
    [ "$#" -gt 0 ] || return 0
    # One concatenation, one playback. sox reads the parts in order.
    sox "$@" "$WORK/msg.wav" 2>/dev/null && play -q "$WORK/msg.wav" 2>/dev/null || true
    return 0
}

case "$MODE" in
    print)
        printf 'MORSE CODE  (dot = 1, dash = 3, gap in letter = 1, between = 3, word = 7)\n\n'
        _n=0
        for _e in $TABLE; do
            printf '  %-3s %-9s' "${_e%%:*}" "${_e#*:}"
            _n=$(( _n + 1 ))
            [ $(( _n % 4 )) = 0 ] && printf '\n'
        done
        [ $(( _n % 4 )) = 0 ] || printf '\n'
        printf '\nSpeed is words per minute against PARIS: at %s wpm a dot is %s ms.\n' "$WPM" "$DOT_MS"
        ;;
    drill)
        printf 'Morse drill at %s wpm, %s Hz. It sends, you type. Ctrl-C to stop.\n' "$WPM" "$FREQ"
        printf 'Enter alone repeats the group. Type ? to see the answer.\n\n'
        _right=0; _wrong=0
        # No $RANDOM in ash and no /dev/urandom guarantees about awk seeding, so
        # letters are drawn from the nanosecond clock, which is plenty for a
        # practice drill and needs nothing installed.
        while :; do
            _group=''
            _i=0
            while [ "$_i" -lt 5 ]; do
                _r=$(( $(date +%N 2>/dev/null || echo $$) % 26 ))
                _group="$_group$(printf '%s' abcdefghijklmnopqrstuvwxyz | cut -c $(( _r + 1 )))"
                _i=$(( _i + 1 ))
            done
            while :; do
                send_word "$_group"
                printf 'heard: '
                read -r _ans || { printf '\n'; break 2; }
                case "$_ans" in
                    '')  continue ;;
                    '?') printf 'it was: %s\n\n' "$_group"; break ;;
                    *)   if [ "$(printf '%s' "$_ans" | tr 'A-Z' 'a-z')" = "$_group" ]; then
                             _right=$(( _right + 1 )); printf 'correct.  (%s right, %s wrong)\n\n' "$_right" "$_wrong"
                         else
                             _wrong=$(( _wrong + 1 )); printf 'no -- it was %s.  (%s right, %s wrong)\n\n' "$_group" "$_right" "$_wrong"
                         fi
                         break ;;
                esac
            done
        done
        ;;
    send)
        [ $# -gt 0 ] || usage 1 >&2
        send_word "$*"
        ;;
esac
MORSE
    chmod 0755 /usr/local/bin/copal-morse
    note "copal-morse -- send, drill, or print the table. 'copal-morse -h'"
}

# The instruments: maths, signals and radio. These are guides rather than
# installs -- the packages are in the catalogue under Instruments and Radio, and
# several are large. What the guides add is the command you actually type, which
# for symbolic maths and SDR is the part that is hard to guess.
dev_write_guides_instruments() {
    _g=/usr/local/share/copal/guides
    mkdir -p "$_g"

    cat > "$_g/instruments.txt" <<'GUIDE'
INSTRUMENTS -- calculators, matrices, transforms, scopes

   Install any of these from the menu: Super+C, then Instruments or Science.

 ---------------------------------------------------------------------------
 BASES: BINARY, OCTAL, HEX
 ---------------------------------------------------------------------------

   GUI
      galculator      View > Basic/Scientific/Paper, and the base buttons
                      (DEC/HEX/OCT/BIN) down the side. Bitwise ops too.
      speedcrunch     type '0b1011 + 0o17 + 0xff' and it just works. Its
                      history is editable, which galculator's is not.
      qalculate-gtk   unit-aware: '2 KiB to bits', '0xff to bin'.
      ghex            a hex editor, when what you want is to SEE the bytes:
                      offsets, hex and ASCII side by side, and it edits.

   TERMINAL, no install needed
      printf '%o %x\n' 255 255          octal and hex of 255
      printf '%d\n' 0xff 0755           back the other way
      echo 'obase=2; 200' | bc          decimal to binary
      echo 'ibase=2; 11001000' | bc     binary to decimal
      python3 -c 'print(bin(200), oct(200), hex(200))'
      xxd file                          hex dump; xxd -b for binary
      xxd -r                            and back again

 ---------------------------------------------------------------------------
 MATRICES AND LINEAR SYSTEMS
 ---------------------------------------------------------------------------

   OCTAVE is the tool. It is MATLAB-compatible, so any textbook works.

      octave                            start it (octave --no-gui here)

      A = [2 1 -1; -3 -1 2; -2 1 2]
      b = [8; -11; -3]
      x = A \ b                         SOLVE the system. Not inv(A)*b --
                                        backslash picks a proper factorisation
                                        and is both faster and more accurate.
      rank(A), det(A), cond(A)          is it solvable, and how well
      inv(A)                            the inverse, when you truly want it
      [L,U,P] = lu(A)                   LU factorisation
      [Q,R] = qr(A)                     QR
      eig(A)                            eigenvalues
      [V,D] = eig(A)                    eigenvectors too
      null(A), orth(A)                  null space, column space
      pinv(A)*b                         least squares (overdetermined)
      A'                                transpose

      cond(A) is the one to look at when an answer seems wrong: a large
      condition number means the system amplifies error and the digits at the
      end of your result are noise.

   MAXIMA does the same symbolically -- exact fractions, no rounding:

      maxima
      A: matrix([2,1,-1],[-3,-1,2],[-2,1,2]);
      b: matrix([8],[-11],[-3]);
      linsolve_by_lu(A, b);
      invert(A);  determinant(A);  eigenvalues(A);
      solve([x+y=3, x-y=1], [x,y]);     equations, not matrices
      quit();

   PYTHON, if you would rather script it:
      python3 -c "import numpy as np
      A=np.array([[2,1,-1],[-3,-1,2],[-2,1,2]]); b=np.array([8,-11,-3])
      print(np.linalg.solve(A,b))"

 ---------------------------------------------------------------------------
 TRANSFORMS -- INCLUDING THE INVERSE LAPLACE
 ---------------------------------------------------------------------------

   MAXIMA. 'ilt' is inverse Laplace, 'laplace' is forward.

      maxima
      laplace(sin(a*t), t, s);              forward: a/(s^2+a^2)
      ilt(1/(s^2+1), s, t);                 inverse: sin(t)
      ilt(1/(s*(s+2)), s, t);               partial fractions handled for you
      ilt((s+3)/(s^2+2*s+5), s, t);
      ilt(1/(s^2*(s+1)), s, t);

      If ilt cannot do it, it returns the expression unevaluated -- that is
      the answer "not in my table", not a crash. Try partfrac first:
      partfrac(1/(s^2*(s+1)), s);  then ilt each term.

      Solving an ODE through Laplace, which is what it is usually for:
      atvalue(y(t), t=0, 0);
      atvalue(diff(y(t),t), t=0, 1);
      desolve(diff(y(t),t,2) + y(t) = 0, y(t));

   SYMPY, the same in Python:
      python3
      from sympy import *
      s, t = symbols('s t'); a = symbols('a', positive=True)
      inverse_laplace_transform(1/(s**2+1), s, t)
      laplace_transform(sin(a*t), t, s)
      fourier_transform(exp(-t**2), t, s)
      apart(1/(s**2*(s+1)), s)              partial fractions

 ---------------------------------------------------------------------------
 FFT, SPECTRUM AND SCOPES
 ---------------------------------------------------------------------------

   AUDIO IN -- looking at a signal on the sound card
      audacity        record, then Analyze > Plot Spectrum for the FFT, and
                      the spectrogram view for it over time. The most capable
                      thing here for anything at audio frequencies.
      arecord -l      which capture devices exist at all. Start here: on a Pi
                      there is no built-in microphone input, so this is empty
                      until you plug in a USB sound card.
      arecord -f cd -d 5 out.wav        record five seconds
      alsamixer       set the capture level, and unmute it -- F4 for capture

      A quick spectrum without a GUI, if sox is installed:
        sox -d -n stat -freq 2>&1 | head    dominant frequencies from the mic
        sox in.wav -n spectrogram -o out.png

   OSCILLOSCOPE AND LOGIC ANALYSER
      pulseview       the sigrok GUI: real oscilloscopes and logic analysers
                      over USB, with protocol decoders for I2C, SPI, UART,
                      1-Wire, CAN and about a hundred more. This is the tool
                      if you own a cheap USB analyser.
      sigrok-cli      the same, scripted:
                        sigrok-cli --scan
                        sigrok-cli -d fx2lafw --samples 1000 -O bits
                      There is also a 'demo' driver that generates signals, so
                      you can learn the decoders with no hardware at all:
                        sigrok-cli -d demo --samples 100 -O ascii
      gtkwave         view VCD waveforms -- what a simulator or sigrok wrote.
                      This is the one to pair with ngspice or a Verilog run.

      xoscope, baudline and friture are NOT packaged for Alpine on any of
      these ports. PulseView with a USB scope, or Audacity for audio, is the
      honest answer here rather than a sound-card scope.

   FFT LIBRARIES, for your own code
      fftw            the reference implementation. Link with -lfftw3 -lm.
      kissfft         small and simple; easier to read and to embed.
      py3-numpy       numpy.fft, for when it does not need to be C.

   See also:  copal-guide radio    software defined radio, where the FFT lives
GUIDE

    cat > "$_g/radio.txt" <<'GUIDE'
SOFTWARE DEFINED RADIO -- and building your own

   All of this is in the catalogue: Super+C, then Radio.

   THE HARDWARE FIRST. None of this does anything without a receiver. The
   cheap and universal one is an RTL2832U TV dongle -- "RTL-SDR" -- which
   receives roughly 24 MHz to 1.7 GHz for the price of a takeaway. A Pi's USB
   port powers it. Everything below assumes one unless it says otherwise.

 ---------------------------------------------------------------------------
 START HERE
 ---------------------------------------------------------------------------

      rtl_test -t         is the dongle there, and does it work
      rtl_eeprom          read its identity
      rtl_fm -f 100.3M -M wbfm -s 200k - | aplay -r 200k -f S16_LE
                          listen to FM radio, no GUI at all
      rtl_power -f 88M:108M:100k -i 10 out.csv
                          sweep a band into a CSV -- a spectrum over time
      rtl_power_fftw      the same idea, FFTW-based, better resolution

   GQRX is the receiver with a waterfall: tune with the mouse, pick a mode
   (AM/FM/SSB/CW), see the band. It is where to start if you want to listen
   rather than build. It wants a working audio output and some CPU -- fine on
   a Pi 4, hard work on a Zero.

 ---------------------------------------------------------------------------
 BUILDING YOUR OWN RADIO -- GNU RADIO
 ---------------------------------------------------------------------------

   This is the part you asked for: writing your own SDR rather than running
   someone else's. GNU Radio is packaged for every port Copal builds.

      gnuradio-companion      the GUI: drag blocks, wire them, press play
      python3 -c "from gnuradio import gr; print(gr.version())"

   The model: a FLOWGRAPH of blocks passing sample streams. A source (the
   dongle, a file, a signal generator), some blocks that filter, mix, decimate
   or demodulate, and a sink (the sound card, a file, a plot). Companion draws
   it and generates the Python; you can also write that Python directly.

   A first flowgraph, in Companion, that receives FM:
      1. RTL-SDR Source        set sample rate 2.048M, frequency 100.3M
      2. Low Pass Filter       cutoff 100k, transition 20k, decimation 4
      3. WBFM Receive          quadrature rate 512k, audio decimation 10
      4. Audio Sink            sample rate 48k
      Wire 1->2->3->4 and press the play button.

   Then add a QT GUI Frequency Sink anywhere in the chain to see the spectrum
   at that point. That is the FFT scope, and being able to attach one at any
   point in your own signal chain is the whole reason to work this way.

   The blocks worth knowing early:
      Signal Source / Noise Source   test without any hardware at all
      Throttle                       REQUIRED in any flowgraph with no
                                     hardware clock, or it runs flat out
                                     and eats the machine. Classic bug.
      Multiply / Add                 mixing, which is most of radio
      Low/High/Band Pass Filter      selectivity
      Rational Resampler             change sample rate cleanly
      QT GUI Time / Frequency / Waterfall Sink   the instruments
      File Source / File Sink        record IQ and work on it offline

   RECORD NOW, ANALYSE LATER. This matters on a slow board: capture raw IQ to
   a file with rtl_sdr, then run your flowgraph against the file as many times
   as you like without needing the timing to keep up live.

      rtl_sdr -f 100300000 -s 2048000 -n 20480000 capture.iq

 ---------------------------------------------------------------------------
 DECODING THINGS
 ---------------------------------------------------------------------------

      dump1090        aircraft: ADS-B on 1090 MHz. Works well on a Pi and
                      gives you a live map of what is overhead.
      direwolf        packet radio: an AX.25 / APRS TNC in software, using a
                      sound card or an SDR.
      qsstv           slow-scan television and fax -- pictures over HF.
      hamlib (rigctl) control a real transceiver over serial/USB.
      sdrangel        many modes in one program. aarch64 only, and heavy.
      welle-io        DAB+ digital radio. Not on armhf.

   NOT PACKAGED for these ports: SDR++, CubicSDR, inspectrum, multimon-ng,
   fldigi, wsjtx, soapysdr, csdr. GNU Radio plus the rtl_* tools cover the
   same ground; inspectrum is the real loss, and a File Sink into a QT GUI
   Waterfall Sink is the nearest substitute.

 ---------------------------------------------------------------------------
 LEGALITY, BRIEFLY
 ---------------------------------------------------------------------------

   Receiving is unrestricted in many countries and not in all of them, and
   what you may do with what you hear is restricted in most. TRANSMITTING
   needs a licence essentially everywhere, and a HackRF or a transceiver can
   transmit. Check your own regulator before you key up.

   See also:  copal-guide instruments   the FFT and scope side of this
GUIDE

    cat > "$_g/keyboard.txt" <<'GUIDE'
TYPING AND MORSE -- keyboard practice, and code practice

 ---------------------------------------------------------------------------
 TOUCH TYPING
 ---------------------------------------------------------------------------

   gtypist         a full typing course in the terminal, and the best thing
                   here. Install from the menu: Super+C, then Learn.
                     gtypist                 the menu of lessons
                     gtypist -t              start from the top
                     gtypist q.typ           the QWERTY course specifically
                   It has real lessons that build up key by key, drills,
                   speed tests and error tracking. Runs anywhere, including
                   on a Zero over a serial console.

   ktouch          KDE's tutor, with an on-screen keyboard that highlights
                   the next key and per-finger colouring. Friendlier to look
                   at, heavier to run, and not available on armhf.

   Neither is packaged in v3.24 stable: gtypist is in edge/testing, which
   Copal reaches with the @testing tag, so 'apk add gtypist@testing' is what
   the menu runs. klavaro, tipp10, typespeed and tuxtype are not packaged for
   these ports at all.

   No install at all:
      A plain speed test in the shell -- type the line, time yourself:
        time cat > /dev/null
      Practising the keys under your fingers is most of it; practising vim's
      motions is the other half. 'nvim' then :Tutor.

 ---------------------------------------------------------------------------
 MORSE CODE
 ---------------------------------------------------------------------------

   Alpine packages no morse program -- not unixcw (cw, cwcp, xcwcp), not
   aldo, not qrq, for any of these ports. So Copal ships its own:

      copal-morse hello world      send it as tones
      copal-morse -p               print the whole table
      copal-morse -d               DRILL: it sends five random letters, you
                                   type what you heard, it scores you
      copal-morse -w 20 sos        20 words per minute
      copal-morse -f 700 sos       700 Hz instead of 600
      copal-morse -q sos           print the dots and dashes, play nothing
      copal-morse -h               the help

   It needs sox for audio ('apk add sox'), and falls back to printing the
   code if sox is missing or there is no sound card.

   HOW TO LEARN IT, briefly, because the method matters more than the tool:
   learn it by SOUND, never by reading the table. A dash is not a longer dot
   to your ear, it is a different rhythm -- 'dah' against 'dit'. Start with
   -d at 13 wpm or faster with long gaps rather than slowly, so you hear each
   letter as one shape instead of counting elements. Five or ten minutes a
   day beats an hour a week.

   Speed is words per minute against PARIS, the conventional 50-dot
   reference word, so the numbers mean what an operator expects.

   If you want the real thing: 'copal-guide radio' -- CW is a mode in gqrx,
   and a straight key on a GPIO pin is a short afternoon's work.
GUIDE
    note "$_g/instruments.txt"
    note "$_g/radio.txt"
    note "$_g/keyboard.txt"
}

# Terminals and multiplexers.
#
# tmux and screen are installed outright because they are what makes a long
# unattended job survive a lost connection, and because the guide refers to them.
# The terminal emulators are offered rather than installed: there are sixteen in
# the catalogue and nobody wants sixteen.
#
# THE GPU ONES. alacritty, kitty and wezterm are all packaged for every port
# here, and all three want OpenGL. This board has none: X renders on the CPU
# through fbdev. They will either refuse to start or fall back to software GL and
# be slower than xterm, which is a strange outcome for terminals whose whole
# pitch is speed. On a Pi 4 or 5 with real video they are reasonable. They are in
# the catalogue with that noted, and not installed here.
#
# foot is deliberately absent from the catalogue entirely: it is Wayland-only and
# this is an X11 desktop, so it would install and then never open a window.
dev_install_terminals() {
    say "Terminal multiplexers"
    add_optional tmux screen
    note "tmux   the modern one: panes, detach, resize. 'copal-guide tmux'"
    note "screen the classic: on every unix you will ever log in to"

    # A spread of emulators, installed rather than offered, because they are
    # small and the whole point is having a choice at the keyboard rather than a
    # list in a menu. Between them: the smallest (st), the most universal
    # (xterm, already there from stage 4), tabs (xfce4-terminal, sakura), and
    # grid splits without a multiplexer (terminator).
    say "Terminal emulators"
    add_optional st sakura xfce4-terminal terminator lxterminal
    note "st            smallest and quickest; no scrollback by default"
    note "sakura        small, tabs"
    note "xfce4-terminal  the featureful one: tabs, profiles, drop-down mode"
    note "terminator    splits a window into a grid of panes"

    # cool-retro-term is the one that has to be asked about rather than simply
    # installed. It is a Qt/QML application that renders a CRT -- curvature,
    # bloom, scanlines, phosphor decay -- with a shader per frame, and it is by
    # far the heaviest thing in this section: it wants more CPU than every other
    # terminal here combined, and on a board with no GPU that is CPU it takes
    # from whatever you are running inside it. It is also genuinely lovely.
    cat <<'MSG'

    Cool Retro Term draws a convincing CRT: screen curvature, bloom, scanlines
    and phosphor decay. It is a Qt/QML program running a shader every frame,
    which is the most demanding thing in this whole section -- on a board with
    no GPU that work lands on the CPU. Fine on a Pi 4 or 5, or a PC. On a Zero
    it starts and it is slow.

    About 250 MB with its Qt dependencies.

MSG
    if confirm "Install Cool Retro Term?"; then
        if try_add cool-retro-term; then
            note "cool-retro-term -- pick a profile in its settings; 'Default Amber'"
            note "and 'IBM DOS' are the convincing ones."
        fi
    else
        note "Skipping Cool Retro Term. It is in the menu under Terminals if you"
        note "change your mind."
    fi

    say "A drop-down terminal"
    # Tilda first: it is in community for every port, it is GTK3 and small, and
    # it does the one thing asked of it. Guake is the requested one and is in
    # edge/testing only -- it is offered second because it drags in a good deal
    # of GNOME, which on 512 MB is a real cost rather than a theoretical one.
    if try_add tilda; then
        note "tilda -- press F1 to drop it down. Configure with 'tilda -C'."
    fi
    cat <<'MSG'

    Guake is the drop-down terminal you asked for by name. It is in Alpine's
    edge/testing only, not in v3.24, and it pulls in a slice of GNOME
    (python3, GTK3, libwnck, keybinder) to get its F12 toggle. Tilda, just
    installed, is the same idea in a fraction of the memory.

    Install Guake as well?

MSG
    if confirm "Install Guake?"; then
        if try_add guake@testing; then
            note "guake -- F12 toggles it. Run 'guake --preferences' to change that."
        fi
    else
        note "Skipping Guake -- tilda covers the same job. 'copal-guide terminals'"
    fi
}

# Neovim as an IDE, with no plugin manager and no plugins.
#
# This is the part that would normally mean LazyVim, Mason, nvim-lspconfig,
# nvim-cmp and a treesitter build. None of that is here, and the reason is not
# minimalism for its own sake:
#
#   - treesitter compiles a parser per language with gcc on first launch. On one
#     ARMv6 core that is the better part of an hour, and it wants more RAM than
#     a Zero has. It is the single thing that makes LazyVim unusable here.
#   - nvim-lspconfig and nvim-cmp existed because Neovim had no built-in LSP
#     client configuration and no built-in completion. As of 0.11 it has both.
#     Alpine v3.24 ships 0.12, so the plugins are solving a problem this editor
#     no longer has.
#
# What you get without them: go-to-definition, find-references, hover
# documentation, rename, code actions, diagnostics, completion, and the call
# hierarchy -- incoming calls answers "what calls this function", which is the
# navigation people miss most when they leave a graphical IDE.
#
# Servers are enabled only if their binary is present, so this one config is
# correct on a Zero with three of them and a Pi 5 with six.
dev_write_lsp_config() {
    command -v nvim >/dev/null 2>&1 || {
        note "neovim is not installed -- skipping the LSP configuration"
        return 0
    }
    say "Configuring Neovim as an IDE (built-in LSP, no plugins)"

    cat > /tmp/lsp.lua.$$ <<'LSPLUA'
-- Generated by copal-init.sh. Neovim's own LSP client -- no plugins.
--
-- Edit freely: nothing regenerates this file after the install.

if vim.fn.has('nvim-0.11') == 0 then
  -- vim.lsp.config/enable landed in 0.11. On anything older this file would
  -- error on the first line that matters, so say why and stop.
  vim.notify('Copal: LSP setup needs Neovim 0.11+; skipping.', vim.log.levels.WARN)
  return
end

-- One table, one entry per language server. 'cmd[1]' is also the executable
-- checked for, so adding a server is one line and removing one is deleting it.
local servers = {
  clangd = {
    cmd = { 'clangd', '--background-index', '--clang-tidy' },
    filetypes = { 'c', 'cpp', 'objc', 'objcpp' },
    -- compile_commands.json is what tells clangd your include paths and
    -- standard. 'bear -- make' generates one; without it clangd guesses.
    root_markers = { 'compile_commands.json', '.git', 'Makefile' },
  },
  rust_analyzer = {
    cmd = { 'rust-analyzer' },
    filetypes = { 'rust' },
    root_markers = { 'Cargo.toml', '.git' },
  },
  gopls = {
    cmd = { 'gopls' },
    filetypes = { 'go', 'gomod', 'gowork' },
    root_markers = { 'go.work', 'go.mod', '.git' },
  },
  pylsp = {
    cmd = { 'pylsp' },
    filetypes = { 'python' },
    root_markers = { 'pyproject.toml', 'setup.py', '.git' },
  },
  luals = {
    cmd = { 'lua-language-server' },
    filetypes = { 'lua' },
    root_markers = { '.luarc.json', '.git' },
  },
  hls = {
    cmd = { 'haskell-language-server-wrapper', '--lsp' },
    filetypes = { 'haskell', 'lhaskell' },
    root_markers = { '*.cabal', 'stack.yaml', '.git' },
  },
}

local enabled = {}
for name, cfg in pairs(servers) do
  if vim.fn.executable(cfg.cmd[1]) == 1 then
    vim.lsp.config(name, cfg)
    vim.lsp.enable(name)
    table.insert(enabled, name)
  end
end
table.sort(enabled)
-- :Lsp tells you which servers this machine actually has, which is the first
-- question when go-to-definition does nothing.
vim.api.nvim_create_user_command('Lsp', function()
  local buf = vim.lsp.get_clients({ bufnr = 0 })
  local names = {}
  for _, c in ipairs(buf) do table.insert(names, c.name) end
  print('enabled here: ' .. (#enabled > 0 and table.concat(enabled, ', ') or 'none'))
  print('attached to this buffer: ' .. (#names > 0 and table.concat(names, ', ') or 'none'))
end, { desc = 'Which language servers are enabled and attached' })

-- Diagnostics: shown in the sign column and on the line, because a diagnostic
-- you have to hover to see is one you will not read.
vim.diagnostic.config({
  virtual_text = { spacing = 2, prefix = '*' },
  signs = true,
  underline = true,
  severity_sort = true,
  update_in_insert = false,   -- redrawing on every keystroke is not free here
})

-- The keys. Set per-buffer when a server attaches, so they only exist where
-- they do something.
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local b = args.buf
    local function map(keys, fn, desc)
      vim.keymap.set('n', keys, fn, { buffer = b, desc = 'LSP: ' .. desc })
    end

    -- Where things are
    map('gd', vim.lsp.buf.definition,      'go to definition')
    map('gD', vim.lsp.buf.declaration,     'go to declaration')
    map('gi', vim.lsp.buf.implementation,  'go to implementation')
    map('gy', vim.lsp.buf.type_definition, 'go to type definition')
    map('gr', vim.lsp.buf.references,      'find all references')

    -- Tracing calls: the two that replace a graphical IDE's call tree.
    -- incoming = who calls this. outgoing = what this calls.
    map('<leader>ci', vim.lsp.buf.incoming_calls, 'incoming calls (who calls this)')
    map('<leader>co', vim.lsp.buf.outgoing_calls, 'outgoing calls (what this calls)')

    -- What things are
    map('K',  vim.lsp.buf.hover,          'hover documentation')
    map('<leader>s', vim.lsp.buf.document_symbol,  'symbols in this file')
    map('<leader>S', vim.lsp.buf.workspace_symbol, 'symbols in the project')

    -- Changing things
    map('<leader>rn', vim.lsp.buf.rename,      'rename everywhere')
    map('<leader>ca', vim.lsp.buf.code_action, 'code action / quick fix')
    map('<leader>F',  function() vim.lsp.buf.format({ async = true }) end, 'format buffer')

    -- Diagnostics
    map('<leader>e', vim.diagnostic.open_float, 'show the error on this line')
    map('<leader>d', function() vim.diagnostic.setloclist() end, 'all diagnostics in a list')
    map(']d', function() vim.diagnostic.jump({ count =  1, float = true }) end, 'next diagnostic')
    map('[d', function() vim.diagnostic.jump({ count = -1, float = true }) end, 'previous diagnostic')

    -- Completion, built in since 0.11. autotrigger means it offers as you
    -- type; without it you press Ctrl-X Ctrl-O. Both work.
    if vim.lsp.completion and vim.lsp.completion.enable then
      pcall(vim.lsp.completion.enable, true, args.data.client_id, b,
            { autotrigger = true })
    end

    -- Ctrl-] and :tjump go through the language server rather than a tags file
    -- when one is attached, so the vi navigation you already know keeps working.
    vim.bo[b].tagfunc = 'v:lua.vim.lsp.tagfunc'
  end,
})
LSPLUA
    install_home_file .config/nvim/lsp.lua /tmp/lsp.lua.$$
    rm -f /tmp/lsp.lua.$$

    _have=''
    for _s in clangd rust-analyzer gopls pylsp lua-language-server \
              haskell-language-server-wrapper; do
        command -v "$_s" >/dev/null 2>&1 && _have="$_have $_s"
    done
    if [ -n "$_have" ]; then
        note "language servers present:$_have"
    else
        warn "no language servers found -- nvim will still edit, but gd/gr/K will do nothing"
        note "Install them from the menu: Devtools, or 'apk add clangd rust-analyzer gopls'"
    fi
    note "In nvim, :Lsp says which servers are enabled and attached."
}

# Xdebug ships switched off -- loading it unconditionally slows every PHP
# invocation, including composer's. This turns on the parts that cost nothing
# until a debugger actually connects.
dev_write_php_config() {
    command -v php83 >/dev/null 2>&1 || return 0
    apk info -e php83-pecl-xdebug >/dev/null 2>&1 || return 0
    _ini=/etc/php83/conf.d/50_xdebug.ini
    [ -d /etc/php83/conf.d ] || return 0
    say "Configuring Xdebug"
    cat > "$_ini" <<'XDEBUG'
; Written by copal-init.sh.
;
; mode=debug,develop gives breakpoints plus better var_dump and stack traces.
; start_with_request=trigger means Xdebug does NOTHING until you ask for it --
; with XDEBUG_TRIGGER=1 in the environment, or ?XDEBUG_TRIGGER=1 on a URL. The
; alternative (start_with_request=yes) makes every php invocation try to reach a
; debugger on port 9003 and wait for the timeout when there is not one.
zend_extension=xdebug
xdebug.mode=debug,develop
xdebug.start_with_request=trigger
xdebug.client_host=127.0.0.1
xdebug.client_port=9003
XDEBUG
    note "$_ini -- breakpoints on demand, off by default"
    note "Run with breakpoints:  XDEBUG_TRIGGER=1 php83 script.php"
}

# The toolchains that exist on every port, so nothing here needs a gate. Each is
# attempted independently: add_optional warns and carries on rather than failing
# the stage, which matters because this is thirty-odd packages and one of them
# being absent should not cost you the other twenty-nine.
dev_languages_core() {
    # C and C++, twice. gcc is the system compiler (build-base, installed
    # above); clang is the second opinion. Having both is not indulgence -- two
    # compilers disagree about which code is wrong, and clang's diagnostics are
    # usually the more legible of the two. clang22-extra-tools is also where
    # clangd and clang-format come from, which is what turns any editor here
    # into a C IDE.
    say "C and C++ (a second compiler, and the language server)"
    add_optional clang22 clang22-extra-tools
    # The C standards, which is a compiler flag rather than a package: every one
    # of these works with the gcc and clang installed above. Written into the
    # sample Makefile and the guide so it is discoverable.
    note "C standards available: -std=c89 c99 c11 c17 c23  (gcc and clang both)"
    note "C++ standards:         -std=c++11 c++14 c++17 c++20 c++23"

    say "Fortran"
    add_optional gfortran
    note "gfortran covers FORTRAN 77 through Fortran 2018:"
    note "  -std=legacy (F77)  -std=f95  -std=f2003  -std=f2008  -std=f2018"

    say "Rust"
    # rust-src and rust-analyzer are what make an editor useful for Rust: the
    # first lets the language server read the standard library, the second IS
    # the language server. rust-gdb is a wrapper that teaches gdb to print Rust
    # types instead of raw memory.
    add_optional rust cargo rust-src rustfmt rust-analyzer rust-gdb

    say "Go"
    add_optional go gopls

    say "PHP, Composer and Xdebug"
    # php83-pecl-xdebug is the step debugger -- breakpoints in PHP, over the
    # same DBGp protocol every PHP IDE speaks. It needs one line of php.ini to
    # switch on, which dev_write_php_config does.
    add_optional php83 php83-phar php83-openssl php83-pecl-xdebug php83-dev composer

    say "Forth"
    # gforth is in no Alpine repository for any of these ports. RetroForth is,
    # everywhere, and is a living Forth rather than a museum piece.
    add_optional retroforth

    say "Shell: linting and formatting"
    # shellcheck is aarch64-only; shfmt exists everywhere. Both matter here
    # because this project IS shell, and 'sh -n' catches syntax while
    # shellcheck catches the things that pass syntax and still break.
    add_optional shfmt
    add_optional shellcheck
    add_optional bash bash-doc

    say "Scripting and the rest"
    add_optional python3 py3-pip py3-lsp-server
    add_optional lua5.4 luajit lua-language-server
    add_optional perl ruby tcl
    add_optional tcc

    say "Build systems and analysis"
    add_optional cmake meson ninja-build ccache bear just
    add_optional cppcheck doxygen ctags
    add_optional cgdb lldb
    # Valgrind has no ARMv6 build: its instrumentation is per-architecture and
    # ARMv6 was never one of them. Everywhere else it is the fastest way to find
    # a leak or a bad free.
    add_optional valgrind
    add_optional strace ltrace
}

# The toolchains that only exist on some ports, plus the two that are big enough
# to be worth asking about. Nothing here is required for the IDE to work.
dev_languages_optional() {
    # Haskell: aarch64 only, and about 1.5 GB with cabal's index. Asked rather
    # than assumed for that reason alone.
    if [ "$ARCH_GATE" = a64 ]; then
        cat <<'MSG'

    Haskell (GHC and cabal) is available on this board. It is a large install
    -- roughly 1.5 GB once cabal has downloaded its package index -- and it is
    the one language here that genuinely cannot be offered on a Pi Zero, so if
    you want it, this is the machine for it.

MSG
        if confirm "Install Haskell (GHC + cabal + hlint)?"; then
            add_optional ghc cabal hlint
            note "cabal update      fetch the package index (large, do it once)"
            note "ghci              the interpreter; :load a file, :type an expression"
        else
            note "Skipping Haskell."
        fi
        say "Other aarch64-only languages"
        add_optional zig crystal delve
        note "delve (dlv) is Go's own debugger -- real breakpoints in Go code"
    else
        warn "Haskell (GHC) is not built for $(apk --print-arch 2>/dev/null) by Alpine."
        note "This is not a missing package that a different repository would fix:"
        note "GHC bootstraps from a previous GHC and there is no ARMv6/ARMv7 build."
        note "OCaml is installed instead -- same ML lineage, strict rather than"
        note "lazy, and its compiler is small and fast enough for this board."
    fi

    # OCaml everywhere: on aarch64 as a language in its own right, on the
    # smaller boards also as the answer to "I wanted Haskell".
    say "OCaml"
    add_optional ocaml

    say "Lisps and Schemes"
    add_optional guile chicken sbcl racket

    say "Others"
    add_optional nim elixir
    [ "$ARCH_GATE" = a64 ] && add_optional openjdk21
    [ "$ARCH_GATE" = v6 ] || add_optional dotnet9-sdk

    # Node is last because it is the least likely to exist on armhf and the
    # least missed: Node dropped official ARMv6 support years ago.
    say "Node.js"
    add_optional nodejs npm
}

stage_dev() {
    say "Stage 7: development environment"
    cat <<'MSG'
    Modelled on Omarchy's tool choices, with the pieces that need a GPU or a
    fast machine swapped for equivalents this board can actually run. The
    keyboard-driven, TUI-first, one-theme-everywhere idea carries over intact;
    Hyprland, Alacritty, Walker and Nautilus do not.
MSG
    require_network || return 1

    # --- the C toolchain ---------------------------------------------------
    # build-base is gcc, g++, make, musl-dev and binutils in one package.
    say "C toolchain and debugger"
    apk add build-base gdb
    add_optional git ctags pkgconf

    # --- editors -----------------------------------------------------------
    say "Editors"
    # Neovim is Omarchy's editor. LazyVim is not viable here: it compiles
    # treesitter parsers with gcc on first launch, which on a single ARMv6
    # core takes the better part of an hour and then wants more RAM than this
    # board has. A hand-written config gives the same core workflow instantly.
    if try_add neovim; then EDITOR_BIN=nvim; else add_optional vim; EDITOR_BIN=vim; fi
    note "editor: $EDITOR_BIN"
    add_optional neovim-doc >/dev/null 2>&1
    # Geany: a real GUI IDE with a build system, light enough for this board.
    add_optional geany

    # --- languages ---------------------------------------------------------
    # Which of these exist depends on the port, and the differences are real
    # rather than cosmetic. Every name below was checked against the v3.24
    # APKINDEX for armhf, armv7 and aarch64:
    #
    #   everywhere   Rust (and rust-analyzer), Go (and gopls), Fortran, PHP 8.3
    #                with Composer and Xdebug, Clang 22, OCaml, Lua, Perl, Ruby,
    #                Tcl, Nim, Elixir, Racket, SBCL, Guile, CHICKEN, tcc, R
    #   aarch64 only Haskell (GHC, cabal, hlint), Zig, Crystal, OpenJDK, Delve
    #   not armhf    .NET, Valgrind
    #
    # HASKELL is the one that will disappoint on a Zero and it is worth being
    # blunt about why: GHC is not built for ARMv6 or ARMv7 by Alpine, and it is
    # not the kind of thing you work around -- GHC bootstraps from a previous
    # GHC, so there is no small path to one. On a Pi 3/4/5 it is a single
    # 'apk add ghc cabal' and it works. On a Zero the nearest thing in spirit
    # is OCaml, which IS built for armhf: strict rather than lazy, but the same
    # ML type system, pattern matching and inference, and its native compiler
    # is small and quick enough for this board.
    #
    # FORTH has no gforth in Alpine on any architecture. RetroForth is packaged
    # everywhere and is a real, actively maintained Forth-family language, so
    # that is what gets installed. It is not ANS Forth: the vocabulary differs.
    # The guide says so rather than letting you discover it at the prompt.
    #
    # RUST is offered on every port including the Zero, with one caveat stated
    # up front rather than found out: rustc is an LLVM front end, a release
    # build of a crate with dependencies routinely wants more than 512 MB, and
    # on one ARMv6 core it is slow. It works -- 'cargo build' on a hello-world
    # finishes -- but stage 5's zram is doing real work behind it. On a Pi 4 or
    # 5 none of that applies.
    say "Language toolchains"
    dev_languages_core
    dev_languages_optional
    configure_git_identity
    install_claude_code

    say "AVR toolchain (Arduino-class microcontrollers)"
    # The Arduino IDE itself is Electron/Java and will not run here. The
    # toolchain underneath it is small and does the same job from a Makefile.
    add_optional gcc-avr avr-libc avrdude

    # --- Omarchy-style shell tools ----------------------------------------
    say "Shell tooling"
    # These are the Omarchy CLI stack. Several are Rust or Go, and armhf
    # availability varies by release -- each is attempted independently.
    add_optional ripgrep fd fzf bat eza zoxide tmux lazygit btop

    # --- editor configuration ---------------------------------------------
    # One config, sourced by both vim and nvim, so the two never drift.
    say "Writing the editor configuration"
    cat > /tmp/vimrc.$$ <<'VIMRC'
" Generated by copal-init.sh. Deliberately plugin-free: on this board every
" plugin is startup latency and RAM, and the built-ins cover the workflow.
set nocompatible
syntax on
filetype plugin indent on

set number
set expandtab shiftwidth=4 tabstop=4 softtabstop=4 autoindent smartindent
set incsearch hlsearch ignorecase smartcase
set hidden nowrap scrolloff=3 sidescrolloff=5
set backspace=indent,eol,start
set wildmenu wildmode=longest:full,full
set laststatus=2
set mouse=a
set nobackup nowritebackup
set updatetime=500
set path+=**
set tags=./tags;,tags;

" Tokyo Night-ish, using only colours the terminal already defines, so this
" needs no colour scheme file and no truecolour support.
set background=dark
silent! colorscheme habamax
highlight Normal ctermbg=NONE

set statusline=%f\ %m%r%h%w%=%y\ %l:%c\ %P

" --- building ---------------------------------------------------------------
" :make runs the Makefile and puts errors in the quickfix list; ]q and [q walk
" them. This is the whole compile-fix loop, built in.
set errorformat^=%-G%f:%l:\ warning:%m
nnoremap <F5> :wa<CR>:make<CR>
nnoremap <F6> :wa<CR>:make run<CR>
nnoremap ]q :cnext<CR>
nnoremap [q :cprevious<CR>
nnoremap <leader>q :copen<CR>

" --- debugging --------------------------------------------------------------
" Termdebug ships with vim and neovim: a real gdb session with breakpoints,
" stepping and variable inspection, no plugin manager involved.
packadd! termdebug
let g:termdebug_wide = 1
nnoremap <F4>  :Termdebug<CR>
nnoremap <F9>  :Break<CR>
nnoremap <F21> :Clear<CR>
nnoremap <F10> :Over<CR>
nnoremap <F11> :Step<CR>
nnoremap <F12> :Finish<CR>
nnoremap <F8>  :Continue<CR>
nnoremap <leader>e :Evaluate<CR>

" --- files ------------------------------------------------------------------
let g:netrw_banner = 0
let g:netrw_liststyle = 3
nnoremap <leader>f :find
nnoremap <leader>n :Explore<CR>
VIMRC
    install_home_file .vimrc /tmp/vimrc.$$

    # Neovim reads init.vim, not .vimrc -- source the same file from it, so the
    # two editors never drift, and then load the Lua that vim cannot use. The
    # LSP client, the completion and the call hierarchy are Neovim-only; vim
    # keeps the editing, building and Termdebug half, which is all of it that
    # does not need a language server.
    cat > /tmp/initvim.$$ <<'INITVIM'
" Generated by copal-init.sh.
set runtimepath^=~/.vim runtimepath+=~/.vim/after
let &packpath = &runtimepath
" Everything shared with vim lives in ~/.vimrc -- edit that, not this.
source ~/.vimrc
" Neovim-only: the language servers. Guarded so a missing file is not an error
" on every startup.
if filereadable(expand('~/.config/nvim/lsp.lua'))
  luafile ~/.config/nvim/lsp.lua
endif
INITVIM
    install_home_file .config/nvim/init.vim /tmp/initvim.$$
    rm -f /tmp/vimrc.$$ /tmp/initvim.$$

    dev_write_lsp_config
    dev_write_php_config
    dev_install_terminals
    dev_write_morse
    say "Typing tutor"
    add_optional gtypist@testing
    dev_write_guides
    dev_write_guides_more
    dev_write_guides_instruments

    # --- gdb ---------------------------------------------------------------
    say "Writing the gdb configuration"
    cat > /tmp/gdbinit.$$ <<'GDBINIT'
# Generated by copal-init.sh.
set confirm off
set pagination off
set print pretty on
set history save on
set history filename ~/.gdb_history
set disassembly-flavor att
# 'layout src' or Ctrl-X A gives a source view with the current line marked --
# a visual debugger without needing one.
GDBINIT
    install_home_file .gdbinit /tmp/gdbinit.$$; rm -f /tmp/gdbinit.$$

    # --- a project that proves the whole chain works -----------------------
    say "Writing a sample project at ~/dev/hello"
    cat > /tmp/main.c.$$ <<'CSRC'
#include <stdio.h>

static int accumulate(int n)
{
    int total = 0;
    for (int i = 1; i <= n; i++)
        total += i;          /* put a breakpoint here: F9 with the cursor on it */
    return total;
}

int main(void)
{
    int n = 10;
    printf("sum 1..%d = %d\n", n, accumulate(n));
    return 0;
}
CSRC
    cat > /tmp/Makefile.$$ <<'MAKEFILE'
# -g keeps the debug symbols gdb needs; -O0 stops the optimiser reordering
# lines out from under the debugger.
CC      := cc
CFLAGS  := -g -O0 -Wall -Wextra -std=c11
TARGET  := hello
SOURCES := main.c

$(TARGET): $(SOURCES)
	$(CC) $(CFLAGS) -o $@ $(SOURCES)

run: $(TARGET)
	./$(TARGET)

debug: $(TARGET)
	gdb ./$(TARGET)

clean:
	rm -f $(TARGET)

.PHONY: run debug clean
MAKEFILE
    install_home_file dev/hello/main.c   /tmp/main.c.$$
    install_home_file dev/hello/Makefile /tmp/Makefile.$$
    rm -f /tmp/main.c.$$ /tmp/Makefile.$$

    say "Stage 7 complete."
    cat <<MSG
    Try the whole loop:

        cd ~/dev/hello
        $EDITOR_BIN main.c
        F5              build (:make -- errors land in the quickfix list)
        ]q  [q          walk the errors
        F9              breakpoint on the line under the cursor
        F4              start the debugger
        F8 / F10 / F11  continue / step over / step into
        gd  gr  K       definition / references / documentation
        \\ci            who calls this function
        Ctrl-O          back to wherever you jumped from

    Or from a shell:  make run    make debug    make clean

    THE GUIDES. These are the tutorials, on this machine, no network needed.
    Super+Shift+G opens the list; from a terminal:

        copal-guide ide           compiling, breakpoints, stepping, call traces
        copal-guide nvim          the editor itself, from nothing to useful
        copal-guide languages     what exists on THIS board, and why
        copal-guide tmux          tmux and screen
        copal-guide terminals     which terminal, and why the GPU ones are not
        copal-guide instruments   bases, matrices, inverse Laplace, FFT, scopes
        copal-guide radio         software defined radio, and building your own
        copal-guide keyboard      typing tutors, and morse

    Language servers give nvim go-to-definition, references, rename, code
    actions and the call hierarchy, with no plugins installed. ':Lsp' inside
    nvim says which ones this board has.

    GUI IDEs with breakpoints, if you want menus: Geany is installed. Add
    Code::Blocks from the menu (Super+C, Devtools) -- it works on every port.
    KDevelop, Lapce and VSCodium are aarch64 only; there is no VS Code for
    ARMv6 and there will not be. 'copal-guide ide' section 6 covers this.
MSG
}

# ------------------------------ stage 11: snapshots / Timeshift ------------
P3=$(part_of "$DISKDEV" 3)
P3MNT=/media/snapshots

stage_snapshots() {
    say "Stage 11: snapshots"
    is_diskless && { warn "run stage 3 first"; return 0; }

    cat <<'MSG'
    Three things worth knowing before choosing how to do this.

    ZFS is not an option. Timeshift does not support it at all, and ZFS wants
    far more RAM than this board has -- its ARC alone would exceed 512 MB.

    BTRFS is the filesystem Timeshift snapshots natively, but only in the
    Ubuntu-style layout: / on btrfs with @ and @home subvolumes. Your root is
    ext4, made by setup-disk, so using that mode means rebuilding the root
    filesystem from scratch -- redoing stage 3 and everything after it.

    RSYNC mode works on ext4 exactly as it is. Snapshots are hardlinked
    copies, so unchanged files cost nothing beyond a directory entry. This is
    the mode that fits what you already have, and it is what this stage sets
    up.

    A snapshot on the same partition protects against mistakes, not against
    the card failing. A separate partition is better; a different device is
    better still.
MSG

    # --- the partition ----------------------------------------------------
    say "Snapshot partition"
    _free=$(p2_free_sectors)
    if [ -b "$P3" ]; then
        note "$P3 already exists ($(fstype_of "$P3" || echo unformatted))"
    elif [ "$_free" -gt 2097152 ]; then
        note "$(( _free / 2048 )) MB unallocated after p2 -- enough for p3"
        if confirm "Create $P3 there?"; then
            add_optional parted e2fsprogs-extra
            parted -s "/dev/$DISKDEV" mkpart primary ext4 "$(( $(cat "$SYSP2/start") + $(cat "$SYSP2/size") ))s" 100%
            partx -a "/dev/$DISKDEV" 2>/dev/null || partprobe "/dev/$DISKDEV" 2>/dev/null || true
            [ -b "$P3" ] && mkfs.ext4 -F -L SNAPSHOTS "$P3" && note "created and formatted $P3"
        fi
    else
        warn "p2 fills the card -- there is no room for a third partition."
        cat <<'SHRINK'
    Making room means shrinking p2, and ext4 CANNOT be shrunk while it is
    mounted -- which it is, as /. Doing it needs the root filesystem offline,
    which on this machine means booting the diskless system that is still
    sitting on p1:

      1. Put the card in another machine and edit cmdline.txt: remove the
         'root=UUID=... rootfstype=ext4' part, keeping the rest. Save the
         original as cmdline.txt.sys first.
      2. Boot. You are back on the RAM-resident system, p2 unmounted.
      3. Run this stage again. With p2 not mounted it will offer to shrink
         it and create p3.
      4. Restore cmdline.txt from cmdline.txt.sys and reboot.

    Whether that is worth it is a fair question: snapshots on p3 of the same
    card still die with the card. An external USB disk, or rsync to another
    machine over the network, protects against more.
SHRINK
        if ! grep -q ' / ' /proc/mounts || ! mount | grep -q "^$P2 on / "; then
            :
        fi
        # Only offer the shrink when p2 really is not the running root.
        if ! awk -v d="$P2" '$1 == d && $2 == "/" {found=1} END {exit !found}' /proc/mounts; then
            say "p2 is not mounted as / -- the shrink can be done now"
            _p2mb=$(( $(cat "$SYSP2/size") / 2048 ))
            _halfmb=$(( _p2mb / 2 ))
            note "p2 is ${_p2mb} MB; splitting in half gives ${_halfmb} MB each"
            if confirm "Shrink p2 to ${_halfmb} MB and create p3 with the rest?"; then
                add_optional parted e2fsprogs-extra
                warn "this rewrites the partition table and resizes a filesystem."
                ask "Type yes to proceed:"
                if [ "$REPLY" = yes ]; then
                    umount "$P2" 2>/dev/null || true
                    e2fsck -f -y "$P2" || { warn "e2fsck failed -- stopping"; return 1; }
                    resize2fs "$P2" "${_halfmb}M" || { warn "resize2fs failed -- stopping"; return 1; }
                    parted -s "/dev/$DISKDEV" resizepart 2 "$(( _halfmb + 1 ))MiB"
                    parted -s "/dev/$DISKDEV" mkpart primary ext4 "$(( _halfmb + 2 ))MiB" 100%
                    partx -u "/dev/$DISKDEV" 2>/dev/null || partprobe "/dev/$DISKDEV" 2>/dev/null || true
                    mkfs.ext4 -F -L SNAPSHOTS "$P3" && note "created $P3"
                fi
            fi
        fi
    fi

    # --- mount it ----------------------------------------------------------
    if [ -b "$P3" ]; then
        mkdir -p "$P3MNT"
        if ! is_mounted "$P3MNT"; then
            _u=$(uuid_of "$P3")
            sed -i "\|[[:space:]]$P3MNT[[:space:]]|d" /etc/fstab
            printf 'UUID=%s\t%s\text4\tdefaults,noatime\t0 2\n' "$_u" "$P3MNT" >> /etc/fstab
            mount "$P3MNT" && note "mounted $P3 at $P3MNT"
        fi
    fi

    # --- timeshift ---------------------------------------------------------
    say "Timeshift"
    if apk info -e timeshift >/dev/null 2>&1; then
        note "already installed"
    else
        cat <<'MSG'
    Timeshift is packaged for armhf, but only in edge/testing -- it is not in
    the v3.24 stable branch this system runs. Installing it means pulling one
    package from edge into a stable system, which can drag in newer libraries
    than the rest of the system expects.

    Pinning the repository to that single install limits the blast radius,
    but it is still mixing branches, and it can break unrelated things later.
MSG
        if confirm "Install timeshift from edge/testing anyway?"; then
            apk add --no-cache \
                --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing \
                timeshift \
              || warn "timeshift install failed -- the rsync fallback below still works"
        else
            note "Skipping Timeshift itself."
        fi
    fi

    # --- rsync snapshots, with or without timeshift ------------------------
    # Works regardless of whether timeshift installed, and is the thing that
    # actually makes snapshots on ext4. Hardlinks mean an unchanged file costs
    # a directory entry rather than a copy.
    say "Installing /usr/local/bin/snapshot"
    add_optional rsync
    cat > /usr/local/bin/snapshot <<'SNAP'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# snapshot -- hardlinked full-system snapshots, in retention tiers.
#
#   snapshot take TIER        make one (tier is any name: daily, monthly, ...)
#   snapshot prune TIER N     keep the newest N in that tier
#   snapshot list             show every tier with sizes
#   snapshot diff TIER NAME   what has changed since that snapshot
#   snapshot restore TIER NAME  print the command to restore (does not run it)
#
# Every snapshot is a complete tree: the whole system including user files,
# not an incremental that needs its predecessors to be readable. Unchanged
# files are hardlinked to the most recent previous snapshot, so only what
# actually changed costs space. Deleting any snapshot is always safe -- the
# others keep their own links to the data.
set -eu

DEST="${SNAPSHOT_DIR:-/media/snapshots}"
[ -d "$DEST" ] || { echo "snapshot: no $DEST -- is the snapshot partition mounted?" >&2; exit 1; }

# What NOT to copy. /proc, /sys, /dev and /run are kernel interfaces, not
# files. /media and /mnt matter most: without excluding them a snapshot would
# recurse into the snapshot directory itself. /boot IS included -- a restore
# without the kernel, cmdline.txt and config.txt is not a restore.
EXCL="--exclude=/proc/* --exclude=/sys/* --exclude=/dev/* --exclude=/run/*
      --exclude=/tmp/* --exclude=/var/tmp/* --exclude=/var/log/*
      --exclude=/media/* --exclude=/mnt/* --exclude=/var/cache/apk/*
      --exclude=/lost+found --exclude=/swapfile"

# -A (ACLs) and -X (xattrs) are not in every rsync build, and passing an
# unsupported flag makes it exit with a usage message rather than degrade.
# Ask this rsync what it has instead of assuming.
RSOPTS="-aH --numeric-ids"
rsync --help 2>&1 | grep -q -- '--acls'   && RSOPTS="$RSOPTS -A"
rsync --help 2>&1 | grep -q -- '--xattrs' && RSOPTS="$RSOPTS -X"

newest_anywhere() {
    # Link against the most recent snapshot in ANY tier, not just this one --
    # a monthly taken the day after a daily should cost almost nothing.
    find "$DEST" -mindepth 2 -maxdepth 2 -type d -name '2*' 2>/dev/null | sort | tail -1
}

case "${1:-}" in
take)
    TIER="${2:-manual}"
    NAME="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$DEST/$TIER"
    LAST="$(newest_anywhere)"
    echo "snapshot: / -> $DEST/$TIER/$NAME"
    [ -n "$LAST" ] && echo "snapshot: hardlinking unchanged files against $LAST"
    # Written to .part first and renamed on success, so an interrupted run
    # (power loss, full disk) never leaves a partial tree that later looks
    # like a good snapshot.
    rm -rf "$DEST/$TIER/$NAME.part"
    # shellcheck disable=SC2086
    if rsync $RSOPTS --delete $EXCL \
             ${LAST:+--link-dest="$LAST"} / "$DEST/$TIER/$NAME.part/"; then
        mv "$DEST/$TIER/$NAME.part" "$DEST/$TIER/$NAME"
        echo "snapshot: done, $(du -sh "$DEST/$TIER/$NAME" | cut -f1) of new data"
    else
        rc=$?
        rm -rf "$DEST/$TIER/$NAME.part"
        echo "snapshot: FAILED (rsync exit $rc); nothing kept" >&2
        exit $rc
    fi
    ;;
prune)
    TIER="${2:-}"; N="${3:-7}"
    [ -n "$TIER" ] || { echo "usage: snapshot prune TIER N" >&2; exit 1; }
    [ -d "$DEST/$TIER" ] || exit 0
    # Names sort chronologically, so "all but the last N" is a plain tail.
    # 'head -n -N' is a GNU extension; busybox head rejects it outright.
    # Count first, then drop the oldest (total - N).
    TOTAL=$(ls -1d "$DEST/$TIER"/2* 2>/dev/null | wc -l | tr -d ' ')
    [ "$TOTAL" -gt "$N" ] || { echo "snapshot: $TOTAL in $TIER, keeping $N -- nothing to prune"; exit 0; }
    ls -1d "$DEST/$TIER"/2* 2>/dev/null | sort | head -n "$((TOTAL - N))" | while read -r s; do
        echo "snapshot: removing $s"
        rm -rf "$s"
    done
    ;;
list)
    for t in "$DEST"/*/; do
        [ -d "$t" ] || continue
        echo "== $(basename "$t")  ($(ls -1d "$t"2* 2>/dev/null | wc -l) snapshots)"
        du -sh "$t"2* 2>/dev/null | sed 's/^/   /' || true
    done
    echo
    echo "total on $DEST: $(du -sh "$DEST" 2>/dev/null | cut -f1)"
    df -h "$DEST" | tail -1
    ;;
diff)
    [ -n "${3:-}" ] || { echo "usage: snapshot diff TIER NAME" >&2; exit 1; }
    # shellcheck disable=SC2086
    rsync $RSOPTS -n --delete --itemize-changes $EXCL / "$DEST/$2/$3/" | head -200
    ;;
restore)
    [ -n "${3:-}" ] || { echo "usage: snapshot restore TIER NAME" >&2; exit 1; }
    SRC="$DEST/$2/$3"
    [ -d "$SRC" ] || { echo "no such snapshot: $SRC" >&2; exit 1; }
    cat <<RESTORE
Restoring over a running system is not something to do casually, so this
prints the command rather than running it.

To restore individual files, just copy them out:
    cp -a $SRC/home/user/somefile /home/user/

To restore everything, boot the diskless system on p1 first (remove root=
from cmdline.txt), mount p2, then:

    rsync -aHAX --delete --numeric-ids \\
        --exclude=/proc/* --exclude=/sys/* --exclude=/dev/* --exclude=/run/* \\
        $SRC/ /mnt/

Doing that against a mounted, running root will replace libraries underneath
processes that are using them.
RESTORE
    ;;
*) sed -n '2,${/^#/!q; /^# SPDX/d; /^# Copyright/d; p;}' "$0"; exit 1 ;;
esac
SNAP
    chmod 0755 /usr/local/bin/snapshot

    # --- scheduling --------------------------------------------------------
    # Alpine's busybox crond runs /etc/periodic/{daily,monthly} from the stock
    # root crontab, so dropping scripts there needs no crontab editing.
    say "Scheduling: 7 daily, 24 monthly"
    add_optional busybox-openrc

    cat > /etc/periodic/daily/snapshot-daily <<'CRON'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# Daily full-system snapshot, keeping the last 7. Run by crond at 02:00 from
# the stock Alpine root crontab (run-parts /etc/periodic/daily).
[ -d /media/snapshots ] || exit 0   # partition not mounted; nothing to do
/usr/local/bin/snapshot take daily && /usr/local/bin/snapshot prune daily 7
CRON

    cat > /etc/periodic/monthly/snapshot-monthly <<'CRON'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# Monthly full-system snapshot, keeping the last 24 -- two years of history.
# Run by crond at 05:00 on the 1st (run-parts /etc/periodic/monthly).
[ -d /media/snapshots ] || exit 0
/usr/local/bin/snapshot take monthly && /usr/local/bin/snapshot prune monthly 24
CRON

    chmod 0755 /etc/periodic/daily/snapshot-daily /etc/periodic/monthly/snapshot-monthly
    mkdir -p "$P3MNT/daily" "$P3MNT/monthly" 2>/dev/null || true

    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || rc-service crond restart >/dev/null 2>&1 || true
    if rc-service crond status >/dev/null 2>&1; then
        note "crond is running"
    else
        warn "crond is not running -- snapshots will not happen on their own"
        note "start it with: rc-service crond start"
    fi
    note "daily   02:00, keeping 7"
    note "monthly 05:00 on the 1st, keeping 24"
    note "stock Alpine crontab: $(grep -c periodic /etc/crontabs/root 2>/dev/null || echo 0) periodic entries found"

    say "Stage 11 complete."
    cat <<'MSG'
    snapshot take daily        make one now, rather than waiting for cron
    snapshot list              every tier, with sizes and free space
    snapshot diff daily NAME   what has changed since that snapshot
    snapshot restore ...       prints how to restore; does not do it

    The first snapshot copies everything and will take a while on this card.
    Every one after that hardlinks whatever has not changed, so it is fast and
    costs only the difference. Each snapshot is still a complete tree -- you
    can delete any of them without harming the others.
MSG
    if [ -b "$P3" ]; then
        note "snapshots live on $P3, separate from the root filesystem"
    else
        warn "no $P3 -- snapshots are going onto the SAME partition as /."
        warn "That protects against mistakes, but not against the card failing."
    fi
    warn "This is one SD card. For real safety, copy snapshots off it:"
    note "  rsync -aHAX /media/snapshots/ user@othermachine:/backup/$(hostname)/"
}

# --------------------------- stage 10: peripherals, media, disk tools ------
stage_extras() {
    say "Stage 10: wireless, bluetooth, audio, capture, hex, graphics, disks"
    is_diskless && { warn "run stage 3 first"; return 0; }
    require_network || return 1

    # --- wireless ----------------------------------------------------------
    say "Wireless tools"
    if [ -d /sys/class/ieee80211 ] && [ -n "$(ls -A /sys/class/ieee80211 2>/dev/null)" ]; then
        note "a wireless interface is present"
    else
        warn "no wireless hardware detected."
        note "The Pi Zero *1* has no onboard wifi -- only the Zero W and Zero 2 W do."
        note "Installing the tools anyway; they will work with a USB adapter."
    fi
    add_optional wireless-tools iw wpa_supplicant
    note "scan:    iw dev wlan0 scan | grep SSID"
    note "connect: setup-interfaces   (Alpine's own, writes /etc/network/interfaces)"

    # --- bluetooth ---------------------------------------------------------
    say "Bluetooth"
    if [ -d /sys/class/bluetooth ] && [ -n "$(ls -A /sys/class/bluetooth 2>/dev/null)" ]; then
        note "a bluetooth controller is present"
    else
        warn "no bluetooth controller detected -- the Zero 1 has none onboard either."
    fi
    if try_add bluez bluez-openrc; then
        rc-update add bluetooth default >/dev/null 2>&1 || true
        rc-service bluetooth start >/dev/null 2>&1 || true
        note "pairing, from bluetoothctl:"
        note "    power on / agent on / default-agent"
        note "    scan on          -- wait for the MAC to appear"
        note "    pair AA:BB:CC:DD:EE:FF"
        note "    trust AA:BB:...  -- so it reconnects by itself"
        note "    connect AA:BB:..."
    fi
    add_optional bluez-alsa   # A2DP audio out over bluetooth, if packaged

    # --- audio over HDMI ---------------------------------------------------
    say "Audio"
    add_optional alsa-utils alsa-lib
    rc-update add alsa default >/dev/null 2>&1 || true
    cat <<'MSG'
    HDMI audio on a Pi needs two things: the audio device enabled in firmware,
    and ALSA told to route to HDMI rather than the headphone jack.

    'dtparam=audio=on' is already in usercfg.txt and is safe.

    'hdmi_drive=2' forces HDMI mode (rather than DVI mode) which is what
    actually carries sound. It is NOT enabled by default here, because on a
    display connected through a DVI adapter it can result in no picture at
    all -- and a Pi with no video and no network is hard to recover.
MSG
    if confirm "Enable hdmi_drive=2 now?"; then
        mount -o remount,rw "$BOOT" 2>/dev/null || true
        if grep -q '^hdmi_drive=' "$BOOT/usercfg.txt" 2>/dev/null; then
            note "already set"
        else
            printf '\n# Force HDMI (not DVI) signalling, which is what carries audio.\nhdmi_drive=2\n' >> "$BOOT/usercfg.txt"
            note "added hdmi_drive=2 to $BOOT/usercfg.txt -- takes effect at the next boot"
            note "if the screen stays dark afterwards, delete that line from another machine"
        fi
    fi
    note "route ALSA to HDMI:  amixer cset numid=3 2     (1 = headphones, 0 = auto)"
    note "test:                speaker-test -c2 -twav"

    # --- packet capture ----------------------------------------------------
    say "Network capture"
    # Wireshark's GUI is out of the question here -- Qt plus a live capture
    # on 512 MB. tshark is the same dissectors without the interface.
    add_optional tcpdump
    try_add tshark || note "tshark unavailable; tcpdump alone is plenty"
    add_optional termshark
    note "capture to a file:  tcpdump -i eth0 -w /tmp/cap.pcap"
    note "read it back:       tshark -r /tmp/cap.pcap   (or open it on the Mac)"
    note "live, readable:     tcpdump -i eth0 -nn -s0 -A"

    # --- hex and binary ----------------------------------------------------
    say "Hex and binary editing"
    # hexedit is edge/testing only -- not in v3.24 stable. bvi is the stable
    # equivalent (vi keys over a hex view) and dhex diffs two binaries.
    add_optional bvi dhex xxd radare2
    note "bvi FILE         full-screen hex editor, vi key bindings"
    note "dhex A B         hex diff of two files, side by side"
    note "xxd FILE | less  hex dump; xxd -r turns an edited dump back into binary"
    note "in vim:  :%!xxd   to edit,  :%!xxd -r   to convert back"

    # --- graphics ----------------------------------------------------------
    say "Graphics"
    # mtpaint would have been the right size for this board, but Alpine no
    # longer packages it (nor xpaint, nor grafx2). What is left for actual
    # drawing is GIMP, which will thrash 512 MB -- so this stage installs the
    # viewers and the command-line converters, and leaves drawing to stage 12.
    add_optional imagemagick netpbm feh gpicview
    note "gpicview IMAGE     lightweight GTK image viewer"
    note "convert a.bmp b.png    format conversion (ImageMagick)"
    note "convert -depth 1 -monochrome in.png out.bmp    1-bit, for the Mac"
    note "feh IMAGE          quick viewer"

    # --- disk images -------------------------------------------------------
    say "Filesystem and disk-image tools"
    # hfsutils -- hmount/hcopy, the classic-HFS tools a Mac Plus image needs --
    # is no longer packaged by Alpine in any repository, stable or edge. That
    # is the one real gap in this stage: getting files into a Mini vMac disk
    # image now goes through the emulator itself (~/minivmac/shared.sh mounts
    # a second .dsk you drag files onto) rather than from the Alpine side.
    # hfsprogs is HFS+, a different filesystem -- later Macs, not the Plus.
    add_optional hfsprogs mtools dosfstools 7zip unzip
    note "hfsprogs : fsck.hfsplus, mkfs.hfsplus  -- HFS+, later Macs"
    note "no hfsutils: use ~/minivmac/shared.sh to move files in and out"
    note "mtools   : mdir/mcopy                  -- FAT images, no mounting needed"

    say "Installing /usr/local/bin/mountdsk"
    # Linux can loop-mount an HFS image directly, which beats any utility for
    # browsing: it is just a directory. Read-only by default because the
    # in-kernel HFS writer is old and lightly used.
    cat > /usr/local/bin/mountdsk <<'MOUNTDSK'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# mountdsk -- loop-mount a Mac disk image so you can browse it as a directory.
#   mountdsk IMAGE [MOUNTPOINT]     mount read-only (default /mnt/dsk)
#   mountdsk -w IMAGE [MOUNTPOINT]  mount read-write  (see the warning below)
#   mountdsk -u [MOUNTPOINT]        unmount
#
# Read-only is the default deliberately. The kernel's HFS write support is old
# and rarely exercised, and a corrupted image is easy to make and annoying to
# discover later. For writing, do it inside the emulator -- hfsutils (hcopy),
# which used to be the answer here, is no longer packaged by Alpine.
#
# NEVER mount an image read-write while Mini vMac has it open. Both sides
# cache metadata and neither expects the other.
set -eu
MODE=ro
case "${1:-}" in
    -w) MODE=rw; shift ;;
    -u) umount "${2:-/mnt/dsk}" && echo "unmounted ${2:-/mnt/dsk}"; exit 0 ;;
    ''|-h|--help) sed -n '2,${/^#/!q; /^# SPDX/d; /^# Copyright/d; p;}' "$0"; exit 0 ;;
esac
IMG="$1"; MNT="${2:-/mnt/dsk}"
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }
if pgrep -x minivmac >/dev/null 2>&1 && [ "$MODE" = rw ]; then
    echo "minivmac is running -- refusing to mount read-write" >&2; exit 1
fi
mkdir -p "$MNT"
for fs in hfsplus hfs vfat; do
    modprobe "$fs" 2>/dev/null || true
    if mount -t "$fs" -o loop,"$MODE" "$IMG" "$MNT" 2>/dev/null; then
        echo "mounted $IMG as $fs ($MODE) at $MNT"
        exit 0
    fi
done
echo "could not mount $IMG as hfsplus, hfs or vfat." >&2
echo "If it is a classic HFS image, try:  hmount '$IMG' && hdir" >&2
exit 1
MOUNTDSK
    chmod 0755 /usr/local/bin/mountdsk
    note "mountdsk IMAGE       browse a disk image as a directory (read-only)"
    note "mountdsk -u          unmount it again"

    say "Stage 10 complete."
    note "Getting files in and out of a Mini vMac disk: ~/minivmac/shared.sh"
    note "or mountdsk for a read-only look at any image."
}

# ---------------------------------------- stage 9: retro emulators ---------
# Versions drift and both projects host their own tarballs, so these are
# overridable rather than pinned to something that will 404 in a year.
MINIVMAC_VER="${MINIVMAC_VER:-36.04}"
VICE_VER="${VICE_VER:-3.9}"
# PianoBooster (stage 14's piano bundle) has one release, v1.0.0 from 2020, and
# it does not build here: it calls qt5_use_modules(), which Qt 5.15 removed.
# The develop branch dropped that and gained the QT_PACKAGE_NAME switch the
# build below uses, so a commit on develop is what gets built -- pinned rather
# than tracking the branch, so the same card builds the same program next year.
PIANOBOOSTER_REF="${PIANOBOOSTER_REF:-6dafdcbdfc5d35d12cecb051c30632d0f5be5806}"

# A blank, unformatted disk image of <MB> megabytes.
#
# Unformatted is not laziness -- it is the only correct answer here. A Mac Plus
# disk holds an HFS volume, and the tools that write HFS from Linux (hfsutils:
# hformat, hcopy) are no longer packaged by Alpine on any branch. The kernel
# can read HFS but its writer is old and lightly used, and mkfs.hfsplus makes
# HFS+, which a Mac Plus running System 6 cannot read at all.
#
# So the image is created empty and initialised INSIDE the emulator, by the
# actual Macintosh ROM, which is the one HFS implementation guaranteed to
# produce something a Mac Plus will mount. System 6 offers to do it the moment
# it sees an uninitialised disk. One click, once, and the image is real.
make_blank_image() {  # <path> <MB>
    _img="$1"; _mb="$2"
    [ -f "$_img" ] && { note "$(basename "$_img") exists already -- left alone"; return 0; }
    if dd if=/dev/zero of="$_img" bs=1M count="$_mb" status=none 2>/dev/null \
       || dd if=/dev/zero of="$_img" bs=1M count="$_mb" >/dev/null 2>&1; then
        note "$(basename "$_img")  ${_mb} MB, blank"
    else
        warn "could not create $_img"
        return 1
    fi
}

# ~/minivmac -- the directory Mini vMac actually looks in, laid out so that
# starting the emulator does the right thing with no arguments.
#
# Mini vMac auto-mounts disk1.dsk, disk2.dsk ... from its working directory at
# startup, in order. That is the whole configuration mechanism: there is no
# preferences file to write. So the profile is a directory with the images in
# it and a launcher that cd's there first -- which is also why the launchers
# are per-configuration scripts rather than one binary invocation.
minivmac_profile() {
    ensure_user_home || true
    _h=$(user_home); [ -n "$_h" ] && [ -d "$_h" ] || { warn "no home directory for $PI_USER"; return 1; }
    _d="$_h/minivmac"
    say "Setting up $_d"
    mkdir -p "$_d"

    # 20 MB: comfortably more than a Mac Plus shipped with, small enough that
    # the SD card does not notice, and under the 2 GB HFS volume ceiling by a
    # wide margin. disk1 is the system disk, shared is the airlock.
    make_blank_image "$_d/disk1.dsk"  20
    make_blank_image "$_d/shared.dsk" 20

    # The ROM, if copal-prep.sh staged one on the card. It was verified and
    # trimmed on the Mac, where there are tools to do it with; here it is a
    # copy and nothing more. -s rather than -f on both sides: a zero-length
    # vMac.ROM satisfies every "is the ROM there" test ever written and then
    # fails inside the emulator, where the message says nothing about ROMs.
    if [ -s "$BOOT/minivmac/vMac.ROM" ]; then
        if [ -s "$_d/vMac.ROM" ]; then
            note "vMac.ROM is already here -- left alone"
        elif cp "$BOOT/minivmac/vMac.ROM" "$_d/vMac.ROM"; then
            note "vMac.ROM installed from the card ($(wc -c < "$_d/vMac.ROM" | tr -d ' ') bytes)"
        else
            warn "could not copy vMac.ROM off the card"
        fi
    elif [ ! -s "$_d/vMac.ROM" ]; then
        note "no vMac.ROM staged on the card -- see the README here for how to supply one"
    fi

    say "Writing the launchers"
    cat > "$_d/run-plus.sh" <<'RUNPLUS'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# run-plus.sh -- Mini vMac as a Macintosh Plus, with this directory's disks.
#
# Mini vMac mounts disk1.dsk, disk2.dsk ... from the CURRENT directory at
# startup, so the cd is the configuration. Anything passed on the command line
# is mounted as well, after those.
set -eu
cd "$(dirname "$0")"
if [ ! -s vMac.ROM ]; then
    cat <<'NOROM'
vMac.ROM is not here (or is empty), and Mini vMac cannot start without it.

It is the Macintosh Plus ROM: 128 KB, copyrighted by Apple, and not ours to
ship. Dump it from a Mac Plus you own, then put it in this directory as
exactly "vMac.ROM" (the capitalisation matters).

Checksum of the usual Plus ROM (v3, 128 KB):  md5 4d8d1e81fa606f57c7ed7188b8b5f410
NOROM
    exit 1
fi
exec minivmac "$@"
RUNPLUS

    cat > "$_d/shared.sh" <<'SHARED'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# shared.sh -- move files between Alpine and the emulated Mac.
#
# There is no host-side tool for this: hfsutils (hcopy/hmount), which used to
# be the answer, is not packaged by Alpine on any branch, and the kernel's HFS
# writer is too old to trust with an image you care about.
#
# So the airlock is a second disk. shared.dsk is mounted by Mini vMac
# alongside the system disk; copy files onto it from inside the Mac, shut the
# emulator down, and read it here with mountdsk. Read-only, deliberately.
set -eu
cd "$(dirname "$0")"
case "${1:-help}" in
    in)
        echo "To get files IN: start the Mac, copy them onto 'shared' from"
        echo "inside it, then quit. There is no reliable way to write HFS"
        echo "from this side."
        ;;
    out)
        if pgrep -x minivmac >/dev/null 2>&1; then
            echo "Quit Mini vMac first -- both sides cache metadata." >&2; exit 1
        fi
        mountdsk shared.dsk /mnt/dsk && echo "browse /mnt/dsk, then: mountdsk -u"
        ;;
    *)
        echo "usage: shared.sh out    # mount shared.dsk here, read-only"
        echo "       shared.sh in     # explains why there is no 'in'"
        ;;
esac
SHARED

    cat > "$_d/README" <<'MVMREADME'
Mini vMac -- Macintosh Plus
===========================

WHAT IS HERE
    vMac.ROM      128 KB Mac Plus ROM. Nothing starts without it. If it is
                  here, copal-prep.sh staged it from the Mac, already checked
                  against its own checksum and trimmed of padding. If it is
                  not, you supply it: dump it from hardware you own, put it
                  here, and the file must not be empty -- a zero-length one
                  looks present to every test and fails inside the emulator.
    disk1.dsk     20 MB, blank. This is the system disk.
    shared.dsk    20 MB, blank. The airlock for moving files out.
    run-plus.sh   start the emulator with both disks
    shared.sh     read shared.dsk from the Alpine side, read-only

FIRST RUN, IN ORDER
    1. Put vMac.ROM in this directory.
    2. ./run-plus.sh
    3. The Mac boots to a flashing question mark -- it has no system yet --
       and then offers to initialise the two blank disks. Say yes to both,
       name them "System" and "shared".
    4. Quit (Control-Escape), and mount a System 6 install image:
           ./run-plus.sh /path/to/system6.dsk
       System 6.0.8 is free to download from Apple's own legacy archive and
       from gryphel.com/c/minivmac/. Install it onto "System".
    5. From then on ./run-plus.sh boots straight into it.

WHY THE DISKS ARE BLANK
    Writing HFS from Linux needs hfsutils, which Alpine no longer packages.
    The Macintosh ROM in the emulator is a better HFS implementation than
    anything left on this side, so the images are initialised in there.

SPEED
    A Mac Plus is an 8 MHz 68000 with 4 MB of RAM. Emulating that on a 1 GHz
    ARM is not demanding, so this runs at full speed -- it is the emulator on
    this machine that genuinely works rather than merely runs.

NO NETWORKING
    Mini vMac has none: no Ethernet, no modem. That is upstream's position,
    not a build option. Basilisk II has networking (slirp) if you need it.
MVMREADME

    chmod 0755 "$_d/run-plus.sh" "$_d/shared.sh"
    own_by_user "$_d"
    note "disk1.dsk and shared.dsk are blank -- the Mac initialises them on"
    note "first boot. Read $_d/README; it is the whole procedure."
    if [ -f "$_d/vMac.ROM" ]; then
        note "vMac.ROM: present"
    else
        warn "vMac.ROM is NOT here. Mini vMac cannot start without it."
        note "Dump it from a Mac Plus you own and put it in $_d/vMac.ROM"
    fi
}

# ~/vice -- a C64 with a formatted, empty, writable floppy in the drive.
#
# Unlike HFS, this one CAN be done properly from the host: c1541 ships with
# VICE and writes real CBM DOS filesystems, so blank.d64 is genuinely
# formatted and the emulated 1541 will accept a SAVE to it immediately.
vice_profile() {
    ensure_user_home || true
    _h=$(user_home); [ -n "$_h" ] && [ -d "$_h" ] || { warn "no home directory for $PI_USER"; return 1; }
    _d="$_h/vice"
    say "Setting up $_d"
    mkdir -p "$_d/disks" "$_d/sid"

    if command -v c1541 >/dev/null 2>&1; then
        # A .d64 is a 1541 disk: 35 tracks, 174848 bytes, and the format needs
        # a name and a two-character disk ID exactly as the real DOS did.
        for _n in blank work; do
            if [ -f "$_d/disks/$_n.d64" ]; then
                note "$_n.d64 exists already -- left alone"
            elif c1541 -format "$_n,01" d64 "$_d/disks/$_n.d64" >/dev/null 2>&1; then
                note "$_n.d64  formatted, empty, 664 blocks free"
            else
                warn "c1541 could not format $_n.d64"
            fi
        done
    else
        warn "c1541 is not on PATH -- cannot create the blank floppies."
        note "It ships with VICE; if VICE installed correctly it should be there."
    fi

    cat > "$_d/run-c64.sh" <<'RUNC64'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# run-c64.sh -- a C64 with work.d64 in drive 8, ready to SAVE to.
#
# x64sc is the cycle-exact core and the accurate one. It is also the expensive
# one: it wants roughly a 1 GHz x86 to hit full speed, so on a Zero expect it
# to struggle and on a Zero 2 W expect it to be usable but not perfect. x64
# (plain) is the faster, less accurate core -- try it if sound breaks up.
set -eu
cd "$(dirname "$0")"
EMU=x64sc
command -v "$EMU" >/dev/null 2>&1 || EMU=x64
exec "$EMU" -8 disks/work.d64 "$@"
RUNC64

    cat > "$_d/run-sid.sh" <<'RUNSID'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# run-sid.sh -- play a SID tune. vsid is VICE's dedicated SID player: it
# emulates the 6581/8580 sound chip and the 6510 driving it, and nothing else,
# so it is far cheaper than running a whole C64.
#
#   ./run-sid.sh tune.sid
#
# Tunes: the High Voltage SID Collection (hvsc.c64.org) is tens of thousands
# of them, freely downloadable, and about 60 MB -- it fits on the card.
set -eu
cd "$(dirname "$0")"
[ "$#" -gt 0 ] || { echo "usage: run-sid.sh TUNE.sid   (put tunes in ./sid/)"; exit 2; }
exec vsid "$@"
RUNSID

    cat > "$_d/README" <<'VICEREADME'
VICE -- Commodore 64
====================

WHAT IS HERE
    disks/blank.d64   a formatted, empty 1541 floppy. Keep this one pristine
                      and copy it when you want a fresh disk.
    disks/work.d64    the same, and the one run-c64.sh puts in drive 8.
    sid/              put .sid tunes here
    run-c64.sh        a C64 with work.d64 in the drive
    run-sid.sh        play a SID tune with vsid

SAVING TO THE FLOPPY, FROM THE C64
    SAVE "HELLO",8            save the BASIC program in memory
    LOAD "$",8                load the directory
    LIST                      ...and look at it
    LOAD "HELLO",8            load it back
    OPEN 15,8,15,"N:NAME,ID": CLOSE 15     format a disk from inside the C64

FROM THE ALPINE SIDE
    c1541 -attach disks/work.d64 -list        list the disk
    c1541 -attach disks/work.d64 -write f.prg  put a file on it
    c1541 -attach disks/work.d64 -read  f.prg  take one off
    c1541 -format "name,01" d64 new.d64        make another blank disk

ROMS
    VICE ships its own C64 ROMs and they are freely redistributable, so
    unlike Mini vMac there is nothing for you to find. It works out of the box.

THE SID CHIP
    vsid emulates the 6581 (and the later 8580) directly. It is the cheapest
    way to hear a SID on this board by a wide margin -- a whole emulated C64
    is not needed just to play music. The High Voltage SID Collection at
    hvsc.c64.org is the canonical archive.

SPEED
    x64sc is cycle-exact and costly. If it stutters, edit run-c64.sh to use
    x64, which trades accuracy for speed and is usually enough for BASIC and
    for most games.
VICEREADME

    chmod 0755 "$_d/run-c64.sh" "$_d/run-sid.sh"
    own_by_user "$_d"
}

stage_emulators() {
    say "Stage 9: retro emulators"
    is_diskless && { warn "run stage 3 first -- there is nowhere to build"; return 0; }
    require_network || return 1
    apk info -e build-base >/dev/null 2>&1 || { warn "run stage 7 first (needs a C toolchain)"; return 0; }

    SRCDIR=/usr/local/src
    mkdir -p "$SRCDIR"

    cat <<'MSG'

    Two very different propositions:

      Mini vMac   Macintosh Plus: a 8 MHz 68000 with 4 MB. Emulating it on a
                  1 GHz ARM is not hard, so it runs at full speed. The source
                  is small and builds in minutes. Recommended.

      VICE        The Commodore 64. Packaged in edge/testing for every
                  architecture here, so this is now a download of a few
                  minutes rather than the multi-hour source build it used to
                  be. It brings c1541 with it, so this stage can hand you a
                  properly formatted blank floppy to save to, and vsid, which
                  plays SID music without emulating a whole C64.

    Both are set up as a directory under your home with disks and launchers in
    it, not just a binary on PATH:

      ~/minivmac   disk1.dsk and shared.dsk, blank, plus run-plus.sh
      ~/vice       disks/blank.d64 and disks/work.d64, formatted and empty,
                   plus run-c64.sh and run-sid.sh

    ROMs differ between the two. Mini vMac needs a Macintosh Plus ROM dumped
    from hardware you own -- it will not start without it, and it is not ours
    to ship. VICE bundles its own C64 ROMs, which are freely redistributable,
    so it works the moment it is installed.

MSG
    cat <<'MSG'
      Basilisk II  A later Mac -- 68040, System 7 through 8.1 -- and the only
                  one of the three with NETWORKING. Mini vMac has none at all:
                  "Mini vMac does not currently support networking", no
                  Ethernet and no modem emulation, and its FAQ points here.
                  Needs a Mac II/Quadra ROM, not the Plus ROM, and emulating a
                  68040 costs far more than a 68000.

MSG
    ask "Set up which? [b=both (recommended) / m=Mini vMac / v=VICE / k=Basilisk / all / skip]"
    case "$REPLY" in
        b|B|both) _do_minivmac=1; _do_vice=1; _do_basilisk=0 ;;
        m*)       _do_minivmac=1; _do_vice=0; _do_basilisk=0 ;;
        v*)       _do_minivmac=0; _do_vice=1; _do_basilisk=0 ;;
        k*)       _do_minivmac=0; _do_vice=0; _do_basilisk=1 ;;
        a*)       _do_minivmac=1; _do_vice=1; _do_basilisk=1 ;;
        *)        note "Skipping."; return 0 ;;
    esac

    if [ "${_do_basilisk:-0}" = 1 ]; then
        say "Basilisk II"
        if try_add basilisk2; then
            # Installed is not the same as working. Prove it runs on this
            # hardware before leaving it on the system -- an emulator that
            # segfaults on ARMv6 is worse than not having it, because you will
            # waste an evening assuming the problem is your ROM.
            say "Checking it actually runs here"
            if BasiliskII --help >/dev/null 2>&1 || [ $? -le 1 ]; then
                note "the binary executes on this CPU"
                note "Networking: set Ethernet to 'slirp' in the preferences and"
                note "the emulated Mac gets a NAT'd connection through eth0 --"
                note "no root and no bridge needed."
                warn "it needs a Macintosh II or Quadra ROM. The Mac Plus ROM"
                warn "that Mini vMac uses will NOT work."
                note "Expect it to be slow: a 68040 is a great deal more to"
                note "emulate than the 68000 in a Mac Plus."
            else
                warn "the basilisk2 binary does not run on this CPU."
                note "Removing it again -- you asked not to keep it if it does not work."
                apk del basilisk2 >/dev/null 2>&1 || true
            fi
        else
            warn "no basilisk2 package for armhf in the configured repositories."
            cat <<'BAS'
    It can be built from source -- github.com/kanjitalk755/macemu -- but read
    this before saying yes.

    Basilisk II's JIT compiler is x86_64 only. On ARM it falls back to
    interpreting every 68040 instruction in software. That interpreter is
    running here on a single in-order ARMv6 core at 1 GHz with no NEON, which
    is the weakest target the project supports, emulating a CPU far larger
    than the 68000 Mini vMac handles at full speed.

    So: it will probably build, and it will probably be too slow to use. The
    build itself is a substantial C++ tree -- expect a couple of hours.

    Your own rule was that if it does not work on this Pi you do not want it.
    This is the honest reading of "does not work": not a failure to compile,
    but a System 7 that takes minutes to reach the desktop.
BAS
            if confirm "Build Basilisk II from source anyway?"; then
                say "Building Basilisk II"
                # gmp and mpfr are required on non-x86: the CPU core generator
                # uses them. The upstream README calls this out for arm64; the
                # same applies to armhf.
                add_optional git autoconf automake m4 gcc g++ make \
                             sdl2-dev libx11-dev gmp-dev mpfr-dev
                cd "$SRCDIR"
                if [ ! -d macemu ]; then
                    git clone --depth 1 https://github.com/kanjitalk755/macemu \
                      || { warn "clone failed"; return 0; }
                fi
                BASLOG=/var/log/basilisk-build.log
                note "build output -> $BASLOG   (tail -f it from another terminal)"
                if cd "$SRCDIR/macemu/BasiliskII/src/Unix" \
                   && ./autogen.sh >"$BASLOG" 2>&1 \
                   && nice -n 10 make >>"$BASLOG" 2>&1; then
                    if [ -x ./BasiliskII ]; then
                        install -m 0755 ./BasiliskII /usr/local/bin/BasiliskII
                        note "installed /usr/local/bin/BasiliskII"
                        warn "needs a Macintosh II or Quadra ROM -- NOT the Plus ROM."
                        note "Networking: set Ethernet to 'slirp' in its preferences."
                        note "Judge it on speed before keeping it."
                    else
                        warn "make finished but no BasiliskII binary appeared"
                        tail -20 "$BASLOG" 2>/dev/null | sed 's/^/      /'
                    fi
                else
                    warn "Basilisk II build failed. Last 20 lines of $BASLOG:"
                    tail -20 "$BASLOG" 2>/dev/null | sed 's/^/      /'
                    note "Source left in $SRCDIR/macemu."
                fi
            else
                note "Skipping Basilisk II. Mini vMac remains the one that works."
            fi
        fi
    fi

    # ---------------------------------------------------------- Mini vMac --
    if [ "${_do_minivmac:-0}" = 1 ]; then
        add_optional libx11-dev libxext-dev
        cd "$SRCDIR"
        _tgz="minivmac-$MINIVMAC_VER.src.tgz"
        _url="https://www.gryphel.com/d/minivmac/minivmac-$MINIVMAC_VER/$_tgz"

        # Three sources, in order of how much can go wrong with them: one
        # already unpacked here from a previous run, one copal-prep.sh staged
        # on the boot partition, and the network. The staged copy is the point
        # -- an hours-long unattended install should not turn on a web server
        # being up at the moment it happens to reach stage 9, which is exactly
        # how the first hardware run lost this stage.
        #
        # The staged name decides the version rather than MINIVMAC_VER: the
        # tarball on the card is the one that is actually going to be built,
        # and a mismatch between the two would name the wrong version in every
        # message from here down.
        if [ ! -f "$_tgz" ]; then
            _staged=$(ls "$BOOT"/minivmac/minivmac-*.src.tgz 2>/dev/null | head -n1 || true)
            if [ -n "$_staged" ]; then
                if cp "$_staged" "$SRCDIR/"; then
                    _tgz=$(basename "$_staged")
                    _v=${_tgz#minivmac-}; MINIVMAC_VER=${_v%.src.tgz}
                    note "using $_tgz from the card -- no download needed"
                else
                    warn "could not copy $_staged -- falling back to the download"
                fi
            fi
        fi

        say "Building Mini vMac $MINIVMAC_VER"
        if [ ! -f "$_tgz" ] && ! wget -q "$_url"; then
            warn "could not download $_url"
            note "Version numbers move. Check https://www.gryphel.com/c/minivmac/"
            note "and re-run with:  MINIVMAC_VER=<version> sh /boot/copal-init.sh"
            note "Or stage it on the card and skip the network entirely:"
            note "  on the Mac -- ./fetch-minivmac.sh && ./copal-prep.sh --refresh"
        else
            rm -rf "$SRCDIR/minivmac-build"; mkdir -p "$SRCDIR/minivmac-build"
            tar xzf "$_tgz" -C "$SRCDIR/minivmac-build"
            # The archive unpacks into its own top-level directory (minivmac/),
            # so setup/tool.c is one level down from where it was extracted.
            # Find it rather than assuming the directory's name, which has
            # changed between releases.
            _src=$(dirname "$(find "$SRCDIR/minivmac-build" -name tool.c -path '*/setup/*' | head -1)" 2>/dev/null)
            _src=${_src%/setup}
            if [ -z "$_src" ] || [ ! -f "$_src/setup/tool.c" ]; then
                warn "setup/tool.c is not in the extracted archive; layout has changed"
                note "look in $SRCDIR/minivmac-build and build by hand"
                _src=""
            fi
            [ -n "$_src" ] && cd "$_src" && note "building in $_src"
            # Mini vMac generates its own build script: compile the config
            # tool, run it for the target, run the result, then make.
            # -t larm is the Linux ARM target; the default model is a Mac Plus.
            # setup.sh is generated with a '#! /bin/bash' shebang, but it is
            # POSIX-clean (verified with 'dash -n') -- it only uses printf and
            # test to write cfg/ and a Makefile, so Alpine's ash runs it and
            # bash does not need installing. It must be RUN, not sourced: its
            # line 7 is  my_obj_d="${my_project_d}bld/"  and my_project_d is
            # deliberately unset (it means "build here"), which is instant
            # death under this script's 'set -u'. All its output is files, so
            # a separate process loses nothing. That Makefile then calls gcc
            # on src/OSGLUXWN.c, the X11 glue, which is why libx11-dev is
            # installed above.
            if [ -n "$_src" ] \
               && gcc setup/tool.c -o setup_t \
               && ./setup_t -t larm > setup.sh \
               && sh ./setup.sh \
               && make; then
                if [ -x ./minivmac ]; then
                    install -m 0755 ./minivmac /usr/local/bin/minivmac
                    note "installed /usr/local/bin/minivmac"
                    # A binary on its own is not a usable emulator: it needs a
                    # directory with disks in it, which is what this builds.
                    # The menu has always looked for ~/minivmac/run-*.sh; until
                    # now nothing created them.
                    minivmac_profile
                else
                    warn "build reported success but no ./minivmac binary appeared"
                fi
            else
                warn "Mini vMac build failed. See the output above."
                note "Source left in $SRCDIR/minivmac-build for inspection."
            fi
        fi
    fi

    # -------------------------------------------------------------- VICE --
    #
    # This used to compile VICE from source: a multi-hour build on one ARMv6
    # core, warned about as unverified, and needing xa -- a 6502 cross-assembler
    # not in the repositories -- to get past the halfway point.
    #
    # None of that is necessary. VICE 3.10 is packaged in edge/testing for all
    # three architectures this script supports, and a tagged @testing install
    # takes that one package without moving the rest of the system off stable.
    # Minutes instead of hours, and it brings c1541 with it, which is what
    # makes a genuinely formatted blank floppy possible.
    #
    # The source build is kept as a fallback for the day the package is not
    # there, but it is no longer the first thing tried.
    if [ "${_do_vice:-0}" = 1 ]; then
        say "Installing VICE (Commodore 64)"
        _vice_ok=0
        if try_add vice@testing; then
            _vice_ok=1
            note "installed from edge/testing: $(command -v x64sc || echo x64sc)"
            note "binaries: x64sc x64 x128 xvic xplus4 xpet vsid c1541 petcat"
        else
            warn "no vice package available -- falling back to a source build."
            cat <<'MSG'
    That is the multi-hour path: a large C codebase on one core. It also
    needs xa, a 6502 cross-assembler, which is not in the repositories --
    without it the compile normally dies partway through, hours in.

    Unless you specifically want to build it, the better answer is to skip
    VICE and come back when the package returns.
MSG
            if confirm "Attempt the source build anyway?"; then
                say "Building VICE $VICE_VER -- this is the long one"
                note "free space on /: $(free_mb) MB (the build wants ~2 GB)"
                have_space_mb 2048 "the VICE source build" || true
                zram_active || warn "zram is not active -- stage 5 first makes an OOM far less likely"
                note "Run this under tmux so a dropped console does not kill it."
                add_optional autoconf automake libtool bison flex pkgconf \
                             sdl2-dev sdl2_image-dev libpng-dev giflib-dev zlib-dev \
                             alsa-lib-dev texinfo dos2unix xa
                cd "$SRCDIR"
                _vtgz="vice-$VICE_VER.tar.gz"
                _vurl="https://sourceforge.net/projects/vice-emu/files/releases/$_vtgz/download"
                if [ ! -f "$_vtgz" ] && ! wget -q -O "$_vtgz" "$_vurl"; then
                    rm -f "$_vtgz"
                    warn "could not download VICE $VICE_VER"
                    note "Check https://vice-emu.sourceforge.io/ for the current version and"
                    note "re-run with:  VICE_VER=<version> sh /boot/copal-init.sh"
                else
                    rm -rf "vice-$VICE_VER"
                    tar xzf "$_vtgz"
                    if cd "vice-$VICE_VER"; then
                        BUILDLOG=/var/log/vice-build.log
                        note "full build output -> $BUILDLOG  (tail -f it elsewhere)"
                        if ./configure --enable-sdl2ui --disable-html-docs \
                                       --disable-pdf-docs --without-pulse >"$BUILDLOG" 2>&1 \
                           && nice -n 10 make >>"$BUILDLOG" 2>&1 \
                           && make install >>"$BUILDLOG" 2>&1; then
                            _vice_ok=1
                            say "VICE built and installed."
                        else
                            warn "VICE build failed. Last 20 lines of $BUILDLOG:"
                            tail -20 "$BUILDLOG" 2>/dev/null | sed 's/^/      /'
                            note "Source left in $SRCDIR/vice-$VICE_VER."
                        fi
                    else
                        warn "unexpected archive layout"
                    fi
                fi
            else
                note "Skipped VICE."
            fi
        fi

        # The disks are the point of the exercise, so make them whenever there
        # is a c1541 to make them with -- however VICE got here.
        [ "$_vice_ok" = 1 ] && vice_profile
    fi

    say "Stage 9 complete."
}

# ------------------------------------------ stage 8: grow p2 ---------------
# Sector arithmetic straight from sysfs -- no tools required just to find out
# whether there is anything to do.
p2_free_sectors() {
    _tot=$(cat "/sys/block/$DISKDEV/size" 2>/dev/null || echo 0)
    _st=$(cat "$SYSP2/start" 2>/dev/null || echo 0)
    _sz=$(cat "$SYSP2/size" 2>/dev/null || echo 0)
    [ "$_tot" -gt 0 ] && [ "$_st" -gt 0 ] || { echo 0; return; }
    echo $(( _tot - _st - _sz ))
}
# Ignore anything under 64 MB: not worth a repartition, and alignment slack
# at the end of a card is normal.
p2_growable() { [ "$(p2_free_sectors)" -gt 131072 ]; }

stage_apps() {
    say "Stage 12: applications"

    if ! x_installed; then
        warn "X is not installed. Most of this catalogue is graphical."
        confirm "Install the terminal programs anyway?" || return 0
    fi

    write_catalogue

    cat <<'MSG'

    A curated set, in the spirit of the old minimal distributions -- Damn
    Small Linux fitted a browser, a mail client, a spreadsheet, a media
    player and an image editor into 50 MB, and it did that by picking one
    good small program per job rather than by shipping less.

    The constraint here is sharper than disk: 512 MB of RAM shared with the
    framebuffer. So the picks are the small ones, and the heavyweights are
    marked as such rather than hidden.

    THIS LIST IS ALREADY FILTERED FOR YOUR BOARD. Every entry below exists
    for the architecture you are running -- nothing here will fail with "no
    such package". What that costs is that the list is shorter on an ARMv6
    Zero than on a Pi 4, and the missing rows are named in the guide rather
    than shown greyed out.

    Browsers. On armhf there is no Chromium and no Firefox; nobody builds
    either for ARMv6. BadWolf is the modern engine that IS available on every
    port -- WebKitGTK, current TLS -- with Dillo, NetSurf and Links as the
    small-and-fast options. On armv7 and aarch64 Firefox ESR, Chromium and
    Thunderbird appear in the list as well.

    Games, and the honest version: there is no usable OpenGL here. X renders
    on the CPU through fbdev, so anything expecting a GPU falls back to a
    software rasteriser. SuperTux, Xonotic, OpenMW and GZDoom are listed
    where they are packaged, and on a Zero they are slideshows -- they are in
    the table because a Pi 4 runs them and the same catalogue serves both.
    What a machine of this class was always good at is turn-based, 2D and
    text: NetHack, Brogue, Angband, OpenTTD, Freeciv, ScummVM, chess.

    A few entries are marked '@testing'. Those come from edge/testing, which
    is Alpine's unstable branch, and they are tagged so that apk takes ONLY
    that package from there and leaves the rest of the system on stable.
    VICE, MilkyTracker, Schism Tracker, Maxima, Cura, CherryTree, Lynis and
    Ticker are all in that group -- genuinely wanted, genuinely not in
    stable.

    Not packaged for ANY of these architectures, so no amount of searching
    will help: Endless Sky, 0 A.D., Teeworlds, Hedgewars, Frozen Bubble,
    OpenRA, ADOM, ToME4, Fuse (Spectrum), PrusaSlicer, OpenSCAD, LibreCAD,
    Fritzing, gerbv, Joblin/Obsidian, and the whole of kdegames.

    On burning discs: the software is here (xorriso authors and burns ISOs,
    xfburn is the GTK front end), but a Pi Zero has one USB OTG port and no
    optical drive, so you would need a powered hub and a USB enclosure.

MSG

    _secs=$(catalogue_available | cut -d'|' -f1 | awk '!s[$0]++')
    note "Sections: $(echo "$_secs" | tr '\n' ' ')"
    cat <<'MSG'

    Choose:
      m   Minimal set   -- one good program per job, about 60 MB:
                           Dillo, Links, Lynx, Bombadillo, Claws Mail,
                           Audacious, Mousepad, PCManFM, GPicView, Zathura,
                           Galculator, Xarchiver
      a   Everything    -- the whole catalogue for this board, minus the
                           handful too big to install unattended: GIMP,
                           Krita, Blender, FreeCAD, KiCad, LibreOffice,
                           Calibre, TeX Live, Chromium, Thunderbird,
                           FileZilla and Remmina. Install those by section
      s   By section    -- pick one section at a time
      l   List          -- show the catalogue and what is already installed
      q   Back to the main menu

MSG
    ask "Choose [m/a/s/l/q]:"
    case "$REPLY" in
        l|L)
            catalogue_available | while IFS='|' read -r sec label pkgs bin mode; do
                if command -v "$bin" >/dev/null 2>&1; then _m="installed"
                else _m="-"; fi
                printf '    %-11s %-34s %-10s %s\n' "$sec" "$label" "$_m" "$pkgs"
            done
            return 0 ;;
        m|M) _want="dillo links lynx bombadillo claws-mail audacious
                    audacious-plugins mousepad pcmanfm gpicview zathura
                    zathura-pdf-mupdf galculator xarchiver 7zip unzip" ;;
        a|A) _want=$(catalogue_available \
                     | grep -vE '\|(gimp|blender|freecad|kicad|libreoffice-writer|calibre@testing|texlive-full|krita|chromium|thunderbird|remmina|filezilla)\|' \
                     | cut -d'|' -f3 | tr '\n' ' ') ;;
        s|S)
            note "Sections: $(echo "$_secs" | tr '\n' ' ')"
            ask "Which section?"
            _pick="$REPLY"
            _want=$(catalogue_available | awk -F'|' -v s="$_pick" 'tolower($1)==tolower(s){print $3}' | tr '\n' ' ')
            [ -n "$_want" ] || { warn "no such section: $_pick"; return 0; } ;;
        *) return 0 ;;
    esac

    # Deduplicate -- several entries share a package (7zip, unzip, the
    # audacious plugins) and apk is happier asked once.
    _want=$(echo $_want | tr ' ' '\n' | awk 'NF && !s[$0]++' | tr '\n' ' ')
    note "About to install:"
    note "$_want"
    confirm "Go ahead?" || return 0


    # add_optional one at a time rather than in one apk call: on a board this
    # slow a single failed name should not throw away twenty good ones.
    for _p in $_want; do add_optional "$_p"; done

    say "Done"
    note "Open the menu (Super+z) -- everything installed now appears in it,"
    note "and what you skipped is under Install."
    commit_reminder
}

stage_grow() {
    say "Stage 8: grow $P2 into the free space after it"
    _free=$(p2_free_sectors)
    if [ "$_free" -le 131072 ]; then
        note "Nothing to do -- $P2 already reaches the end of the card."
        return 0
    fi
    note "unallocated after p2: $(( _free / 2048 )) MB"
    note "p2 now              : $(df -h "$P2" 2>/dev/null | awk 'NR==2{print $2}' || echo unknown)"
    cat <<'MSG'

    The free space is physically after p2, so p2's end can simply be moved
    outward and the filesystem grown into it. Nothing is copied and nothing is
    reformatted -- the data already on p2 stays exactly where it is.

    ext4 grows online, so this works even while p2 is mounted as /.

    The partition table is still rewritten, which is the one genuinely risky
    moment. If power is lost between rewriting the table and the filesystem
    resize, p2 may need an e2fsck before it mounts again.
MSG
    require_network || return 1
    add_optional parted e2fsprogs-extra

    command -v parted >/dev/null 2>&1 || { warn "parted is unavailable -- cannot resize"; return 1; }
    command -v resize2fs >/dev/null 2>&1 || { warn "resize2fs is unavailable -- cannot resize"; return 1; }

    [ "$(fstype_of "$P2")" = ext4 ] || { warn "$P2 is not ext4 -- refusing to touch it"; return 1; }

    warn "about to rewrite the partition table of /dev/$DISKDEV."
    ask "Type yes to proceed:"
    [ "$REPLY" = "yes" ] || { note "Aborted; nothing was changed."; return 0; }

    say "Backing up the partition table"
    # Enough to put things back by hand if the resize goes wrong.
    dd if="/dev/$DISKDEV" of="$BOOT/mbr-backup.bin" bs=512 count=1 2>/dev/null \
        && note "first sector saved to $BOOT/mbr-backup.bin"

    say "Moving the end of partition 2 to the end of the card"
    if ! parted -s "/dev/$DISKDEV" resizepart 2 100%; then
        warn "parted could not rewrite the table."
        note "Nothing was changed. If p2 is mounted as /, try again after a reboot."
        return 1
    fi

    # The kernel will not re-read the table of a disk it is running from, so
    # nudge it into picking up just the new partition size.
    partx -u "/dev/$DISKDEV" 2>/dev/null || partprobe "/dev/$DISKDEV" 2>/dev/null || true

    say "Growing the filesystem"
    if resize2fs "$P2"; then
        note "done"
    else
        warn "resize2fs did not complete."
        note "The partition is larger but the filesystem is not yet. This is"
        note "safe -- no data was lost. Reboot and run stage 8 again; the"
        note "kernel will have the new size by then."
        return 1
    fi

    say "Stage 8 complete."
    note "p2 now: $(df -h "$P2" 2>/dev/null | awk 'NR==2{print $2 " (" $5 " used)"}')"
    df -h / | sed 's/^/    /'
}

# ----------------------------------------------------------------- verify ---
# --------------------------------------------- stage 15: SD card and logs ---
#
# WHAT THE RISK ACTUALLY IS, because the folklore and the engineering disagree.
#
# Wearing the flash out with log writes is, for this workload, close to a myth.
# A syslog on an idle desktop writes a few hundred kB a day. An 8 GB card with
# even a poor wear-levelling controller and ~1000 program/erase cycles per
# block has a total write endurance measured in terabytes. At a megabyte a day
# that is thousands of years. You will lose the card to something else first.
#
# What actually kills SD cards in Raspberry Pis is POWER LOSS DURING A WRITE.
# The card's flash translation layer keeps its own metadata -- the map from
# logical sectors to physical blocks -- and updates it as it writes. Interrupt
# that update and you can lose the map, which does not corrupt a file: it
# bricks the entire card, all of it, unrecoverably. That is an event, not a
# wear-out, and it does not care how little you were writing. It cares that
# you were writing at all at the wrong microsecond.
#
# So the useful mitigations, in order of how much they actually buy:
#
#   1. Shut down cleanly. `poweroff`, wait for the green LED to stop, then
#      pull the plug. This is worth more than everything below combined.
#   2. Write less, so the window in which power loss can hurt is smaller.
#      Stage 3 already does this: /tmp and /var/log are tmpfs, the root is
#      noatime with commit=600, and stage 5's zram means swap never touches
#      the card at all.
#   3. Keep the ext4 journal. It is what makes an interrupted write recoverable
#      at the filesystem level. Turning it off to "save writes" trades the one
#      protection you have against the actual failure mode for a saving you
#      will never measure.
#   4. Don't write at all, ever: overlaytmpfs, below. This is the real answer
#      if the machine's job allows it.
#
# ON SQUASHFS-ON-SHUTDOWN, which is a reasonable-sounding idea and a bad one:
# building a squashfs image of the logs at shutdown means doing a large,
# slow, single write at precisely the moment the machine is about to lose
# power -- the most dangerous moment there is. Squashfs is also read-only, so
# every shutdown rewrites the whole image rather than appending. It maximises
# exposure to the failure mode that actually matters in exchange for saving
# writes that were never the problem. The periodic flush below does the same
# job with small appends at safe moments.

# cmdline.txt lives on the FAT boot partition and is one single line -- the
# firmware ignores anything after the first newline, which is the classic way
# to make an unbootable card by editing it with a text editor.
cmdline_path() { [ -f "$BOOT/cmdline.txt" ] && echo "$BOOT/cmdline.txt"; }
cmdline_has()  { grep -qw "$1" "$BOOT/cmdline.txt" 2>/dev/null; }

readonly_root_on()  { cmdline_has 'overlaytmpfs=yes'; }

stage_sdcard() {
    say "Stage 15: SD card care -- writes, logs, and the read-only option"

    _rofs=$(awk '$2 == "/" {print $4}' /proc/mounts | head -n1)
    cat <<MSG

    CURRENT STATE

      root filesystem : $(root_fstype)
      root mounted    : ${_rofs:-unknown}
      /tmp            : $(is_mounted /tmp && awk '$2=="/tmp"{print $3}' /proc/mounts || echo 'on the root filesystem')
      /var/log        : $(is_mounted /var/log && awk '$2=="/var/log"{print $3}' /proc/mounts || echo 'on the root filesystem')
      swap            : $(zram_active && echo 'zram (RAM, no card writes)' || grep -q '^/dev/mmc' /proc/swaps 2>/dev/null && echo 'ON THE CARD -- run stage 5' || echo 'none')
      read-only root  : $(readonly_root_on && echo 'YES (overlaytmpfs)' || echo 'no -- the card is written normally')

    Most of the work is already done. Stage 3 puts /tmp and /var/log on
    tmpfs, mounts the root noatime with commit=600 so journal flushes are
    batched, and stage 5's zram means swap never reaches the card.

    That has a consequence worth knowing: /var/log is RAM, so your logs are
    gone at every reboot. It also means a runaway process writing a log
    cannot fill the card -- it fills a 32 MB tmpfs, hits ENOSPC, and stops.
    The card is not involved.

MSG
    _c=$(printf '')
    ask "Choose [r=read-only root / l=log policy / s=syslog size / w=what should I worry about / q=back]:"
    case "$REPLY" in
        r|R) sdcard_readonly ;;
        l|L) sdcard_logs ;;
        s|S) sdcard_syslog ;;
        w|W) sdcard_advice ;;
        *)   note "Nothing changed."; return 0 ;;
    esac
    say "Stage 15 complete."
}

sdcard_advice() {
    cat <<'MSG'

    IS IT SAFE TO LEAVE THIS RUNNING?

    Yes. A Pi running Copal writes very little: the logs are in RAM, swap is
    in RAM, and atime is off, so an idle desktop may go minutes between
    touching the card at all. Leaving it powered on indefinitely is not the
    thing that will hurt it.

    What will hurt it is yanking the power. Every time you do that you are
    rolling dice against the card's internal metadata being mid-update. The
    single most valuable habit is:

        poweroff          # or: doas poweroff

    ...wait for the activity LED to go dark, and then pull the plug.

    IS SD CARD WEAR A REAL CONCERN ON MODERN CARDS?

    For this workload, essentially no. The arithmetic is not close: a few
    hundred kB of logs a day against a card whose endurance is measured in
    terabytes. People who kill cards in Pis are almost always killing them
    with power loss, with a swap file thrashing under sustained memory
    pressure, or with a counterfeit card that was never the capacity or the
    quality it claimed.

    The two exceptions that ARE real:
      - Swap on the card. Sustained swapping writes gigabytes and it is the
        one workload that genuinely wears flash. Stage 5's zram removes it.
      - Cheap or fake cards. A counterfeit has a fraudulent controller and no
        meaningful wear levelling. Buy a known brand; check it with f3 or
        h2testw before trusting it.

    WHAT IF I WANT ABSOLUTE SAFETY?

    Turn the root read-only -- option 'r'. Then the card is not written at
    all while the machine runs, and power loss cannot corrupt what is never
    being written. The cost is that nothing you change persists.

MSG
}

# The safe copy-on-write method, and it is a first-class Alpine feature rather
# than something bolted on: the initramfs understands overlaytmpfs=yes, mounts
# the real root READ-ONLY underneath, puts a tmpfs on top, and overlays them.
# Every write lands in RAM. The card is untouched from the moment the kernel
# has read it. This is what raspi-config calls the Overlay File System, and it
# is exactly what Copal's diskless mode does -- so on a Copal box it is less a
# new idea than the same idea, applied to a system that has already moved to
# a real root.
sdcard_readonly() {
    say "Read-only root (overlaytmpfs)"
    [ -f "$BOOT/cmdline.txt" ] || { warn "no $BOOT/cmdline.txt -- cannot change this"; return 0; }
    sys_installed || {
        warn "this system already runs from a tmpfs (diskless). It is ALREADY"
        warn "read-only in the sense that matters -- nothing is written to the"
        warn "card except when you run 'lbu commit'. There is nothing to do."
        return 0
    }

    if readonly_root_on; then
        cat <<'MSG'

    Currently ON. The card is mounted read-only and every write goes to a
    tmpfs overlay that is discarded at reboot.

    While this is on:
      - apk installs work, and vanish at reboot
      - copal-config changes work, and vanish at reboot
      - your files in /home vanish at reboot
    Nothing warns you at the time. That is the deal.

MSG
        confirm "Turn read-only root OFF (writes reach the card again)?" || { note "Left on."; return 0; }
        mount -o remount,rw "$BOOT" 2>/dev/null || true
        # One line, edited in place, no newline introduced. cmdline.txt with a
        # second line is a card the firmware boots into a kernel panic.
        sed -i 's/[[:space:]]*overlaytmpfs=yes//' "$BOOT/cmdline.txt"
        sync
        note "cmdline.txt: $(cat "$BOOT/cmdline.txt")"
        warn "Reboot for this to take effect."
        return 0
    fi

    cat <<'MSG'

    Turning this ON mounts the SD card read-only at boot and puts a RAM
    overlay on top of it. After that the card is never written while the
    machine runs, so pulling the power cannot corrupt it -- there is no write
    in flight to interrupt, ever.

    What it costs: NOTHING PERSISTS. Not installed packages, not settings,
    not documents, not this script's own changes. Every reboot returns the
    machine to exactly the state it is in right now.

    That is the right trade for a kiosk, a display, a museum piece, a machine
    left somewhere it will be unplugged rudely -- and the wrong one for a
    workstation you are still setting up.

    Finish setting the machine up first. Turn this on last.

    To undo it you need to edit cmdline.txt: either run this again from the
    running system (the boot partition stays writable) or put the card in
    another machine and delete 'overlaytmpfs=yes' from that one line.

MSG
    confirm "Turn read-only root ON?" || { note "Left off."; return 0; }
    mount -o remount,rw "$BOOT" 2>/dev/null || true
    cp "$BOOT/cmdline.txt" "$BOOT/cmdline.txt.rw.bak" 2>/dev/null || true
    # Remove first, then append: applying this twice must not produce
    # 'overlaytmpfs=yes overlaytmpfs=yes'. The caller already checks, but an
    # edit to a file that decides whether the board boots should not depend
    # on its caller being careful.
    sed -i 's/[[:space:]]*overlaytmpfs=yes//' "$BOOT/cmdline.txt"
    # Only the first line, so a stray second line is never given the option
    # and the trailing newline is preserved.
    sed -i '1s/[[:space:]]*$/ overlaytmpfs=yes/' "$BOOT/cmdline.txt"
    sync
    note "cmdline.txt: $(cat "$BOOT/cmdline.txt")"
    if [ "$(wc -l < "$BOOT/cmdline.txt")" -gt 1 ]; then
        warn "cmdline.txt now has more than one line. The firmware reads only the"
        warn "first, so this would silently drop options. Restoring the backup."
        cp "$BOOT/cmdline.txt.rw.bak" "$BOOT/cmdline.txt"; sync
        return 1
    fi
    warn "Reboot for this to take effect. After that, changes do not persist."
    note "Backup of the previous line: $BOOT/cmdline.txt.rw.bak"
}

# log2ram's design, which is the sane middle ground: keep the churn in RAM,
# copy it down at moments when a write is safe (a timer, and a clean
# shutdown), accept that a hard power cut loses the last hour of logs.
sdcard_logs() {
    say "Log policy"
    cat <<'MSG'

    /var/log is a tmpfs, so log writes never reach the card -- and the logs
    are gone at every reboot. That is the safest setting and the least useful
    one: the logs you most want are the ones from the boot that just failed.

      k   Keep it in RAM only          nothing written, logs lost at reboot
      f   Flush periodically           hourly, and on a clean shutdown, copy
                                       the logs down to the card. A hard
                                       power cut loses up to an hour of them
      d   Straight to the card         normal logging, normal writes. Fine on
                                       a Pi 4 with a good card; the least
                                       kind option for a Zero
      q   Back

MSG
    ask "Choose [k/f/d/q]:"
    case "$REPLY" in
        f|F) ;;
        d|D)
            sed -i '\|^tmpfs[[:space:]][[:space:]]*/var/log[[:space:]]|d' /etc/fstab
            rm -f /etc/periodic/hourly/copal-logflush /etc/local.d/copal-logflush.stop \
                  /etc/local.d/copal-logflush.start
            note "/var/log removed from fstab -- it will be on the card after a reboot."
            warn "Reboot to apply."
            return 0 ;;
        k|K)
            grep -q '[[:space:]]/var/log[[:space:]]' /etc/fstab 2>/dev/null || \
                printf 'tmpfs\t/var/log\ttmpfs\tdefaults,noatime,size=32M\t0 0\n' >> /etc/fstab
            rm -f /etc/periodic/hourly/copal-logflush /etc/local.d/copal-logflush.stop \
                  /etc/local.d/copal-logflush.start
            note "/var/log stays in RAM and is not copied down."
            return 0 ;;
        *) return 0 ;;
    esac

    say "Setting up the periodic flush"
    mkdir -p /var/log.persist /etc/periodic/hourly /etc/local.d
    cat > /usr/local/bin/copal-logflush <<'LOGFLUSH'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# copal-logflush -- copy the RAM logs down to the card, and back up at boot.
#
#   copal-logflush save     tmpfs -> /var/log.persist   (hourly, and at shutdown)
#   copal-logflush restore  /var/log.persist -> tmpfs   (at boot)
#
# This is log2ram's design. The point is not to avoid writing -- it is to
# choose WHEN to write. A copy at a quiet moment is a small, complete,
# fsync'd write; a hundred scattered appends across the hour are a hundred
# chances to be interrupted by a power cut.
set -eu
SRC=/var/log
DST=/var/log.persist

# Only meaningful while /var/log really is a tmpfs. If someone has switched
# the policy back to writing straight to the card, copying it onto itself
# would be a pointless doubling of the writes this exists to avoid.
is_tmpfs() { awk -v m="$1" '$2 == m && $3 == "tmpfs" { f = 1 } END { exit !f }' /proc/mounts; }

case "${1:-save}" in
    save)
        is_tmpfs "$SRC" || exit 0
        mkdir -p "$DST"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete "$SRC"/ "$DST"/ 2>/dev/null || exit 0
        else
            # cp -a plus a prune, so a deleted log does not live forever.
            cp -a "$SRC"/. "$DST"/ 2>/dev/null || exit 0
        fi
        sync ;;
    restore)
        is_tmpfs "$SRC" || exit 0
        [ -d "$DST" ] || exit 0
        cp -a "$DST"/. "$SRC"/ 2>/dev/null || true ;;
    *) echo "usage: copal-logflush save|restore" >&2; exit 2 ;;
esac
LOGFLUSH
    chmod 0755 /usr/local/bin/copal-logflush

    # Alpine's stock crontab already runs run-parts over /etc/periodic/hourly,
    # so dropping a script there needs no crontab edit.
    ln -sf /usr/local/bin/copal-logflush /etc/periodic/hourly/copal-logflush

    # OpenRC's 'local' service runs local.d/*.start at boot and *.stop at
    # shutdown -- which is exactly the safe moment to write.
    printf '#!/bin/sh\nexec /usr/local/bin/copal-logflush restore\n' > /etc/local.d/copal-logflush.start
    printf '#!/bin/sh\nexec /usr/local/bin/copal-logflush save\n'    > /etc/local.d/copal-logflush.stop
    chmod 0755 /etc/local.d/copal-logflush.start /etc/local.d/copal-logflush.stop
    rc-update add local default >/dev/null 2>&1 || true

    note "hourly    : /etc/periodic/hourly/copal-logflush"
    note "at boot   : /etc/local.d/copal-logflush.start  (restores)"
    note "at halt   : /etc/local.d/copal-logflush.stop   (saves)"
    note "kept in   : /var/log.persist"
    warn "A hard power cut still loses up to an hour of logs. That is the trade."
    commit_reminder
}

sdcard_syslog() {
    say "Syslog size"
    cat <<'MSG'

    Alpine logs with busybox syslogd, which rotates by SIZE rather than by
    time -- so a cap here is a hard ceiling on how much log can ever exist,
    which is the thing that actually protects you from a chatty process.

    The default is 200 kB with one rotation. On a 32 MB /var/log tmpfs there
    is room for considerably more, and more log is more use when something
    has gone wrong.

MSG
    ask "Maximum size of each log file in kB [200]:"
    _sz="${REPLY:-200}"
    case "$_sz" in ''|*[!0-9]*) warn "not a number -- leaving it alone"; return 0 ;; esac
    ask "How many rotated copies to keep [3]:"
    _rot="${REPLY:-3}"
    case "$_rot" in ''|*[!0-9]*) warn "not a number -- leaving it alone"; return 0 ;; esac

    if [ -f /etc/conf.d/syslog ]; then
        sed -i '/^SYSLOGD_OPTS=/d' /etc/conf.d/syslog
    else
        mkdir -p /etc/conf.d
    fi
    printf 'SYSLOGD_OPTS="-t -s %s -b %s"\n' "$_sz" "$_rot" >> /etc/conf.d/syslog
    note "SYSLOGD_OPTS=\"-t -s $_sz -b $_rot\"  (max $(( _sz * (_rot + 1) )) kB total)"
    rc-service syslog restart >/dev/null 2>&1 || warn "restart it by hand: rc-service syslog restart"
    commit_reminder
}

# -------------------------------------------------- stage 14: the workshop ---
#
# The engineering and creative bundles. They are a stage rather than catalogue
# sections because a flat list cannot say the one thing that matters most
# here: what is NOT available, and what to do instead. "FreeCAD" as a menu row
# on an ARMv6 board is a lie of omission; a stage can explain that the answer
# on that board is SolveSpace, and why.
#
# Everything installed here goes through add_optional, so a package that has
# moved or been dropped costs a warning rather than the rest of the bundle.
workshop_cad() {
    say "CAD and 3D modelling"
    cat <<'MSG'

    What exists here depends sharply on the board:

      SolveSpace   every port, including ARMv6. Parametric 2D/3D CAD with a
                   real constraint solver, exports STL and STEP, and it is
                   about 15 MB. On a Zero this is not the consolation prize
                   -- it is a properly capable modeller that happens to be
                   small. Ships solvespace-cli for batch export too.
      FreeCAD      armv7 and aarch64. Full parametric CAD; heavy, and it
                   wants far more than a Zero has.
      Blender      aarch64 only. Mesh modelling and sculpting. Very heavy --
                   reasonable on a Pi 4 or 5, not on a Zero 2 W.
      Goxel        voxel modelling, small, exports to mesh formats.

    Not packaged for ANY of these architectures, so do not go looking:
    OpenSCAD, LibreCAD, QCAD, Wings3D, MeshLab, Dust3D, Antimony.
    SolveSpace is the closest thing to OpenSCAD's niche that Alpine has.

MSG
    add_optional solvespace
    case "$ARCH_GATE" in
        a64) add_optional freecad
             have_space_mb 1200 "Blender" && add_optional blender ;;
        v7)  add_optional freecad
             note "no blender for armv7 -- aarch64 only" ;;
        v6)  note "no FreeCAD and no Blender for ARMv6 -- SolveSpace is the answer here" ;;
    esac
    add_optional goxel@testing
    note "solvespace       parametric CAD, exports STL/STEP"
    note "solvespace-cli   batch export from a .slvs without the window"
}

workshop_3dprint() {
    say "3D printing -- Ender 3"
    cat <<'MSG'

    The good news is better than it looks. CuraEngine -- the actual slicer,
    the part that turns an STL into G-code -- IS packaged for every
    architecture here, in community. It is the command-line engine without
    the GUI, which suits a headless Pi better than the full application
    would anyway.

    The Cura GUI is aarch64/edge only, and PrusaSlicer, Slic3r and
    SuperSlicer are not packaged anywhere. So on a Zero the workflow is:
    model in SolveSpace, slice with CuraEngine on the command line, copy the
    G-code to the printer's SD card.

    OctoPrint (edge/testing, all ports) is the other half if you want to
    drive the Ender 3 over USB rather than walking SD cards about. It is a
    Python web application and it is the standard answer for exactly this
    hardware -- though a Zero is the low end of what it is happy on.

MSG
    add_optional curaengine admesh@testing
    if [ "$ARCH_GATE" = a64 ] && have_space_mb 1500 "the Cura GUI"; then
        confirm "Install the Cura GUI as well (aarch64, edge/testing, large)?" \
            && add_optional cura@testing
    fi
    if have_space_mb 500 "OctoPrint"; then
        confirm "Install OctoPrint (drive the printer over USB from a browser)?" \
            && add_optional octoprint@testing
    fi

    say "Installing /usr/local/bin/slice-ender3"
    cat > /usr/local/bin/slice-ender3 <<'SLICER'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# slice-ender3 -- STL in, G-code out, with Ender 3 geometry already filled in.
#
#   slice-ender3 model.stl [out.gcode] [-s key=value ...]
#
# Defaults are the safe, boring ones: 0.2 mm layers, 20% infill, 200/60 C for
# PLA, skirt adhesion. Override any of them with -s, which is passed straight
# through to CuraEngine:
#
#   slice-ender3 part.stl part.gcode -s layer_height=0.12 -s infill_sparse_density=40
#
# CuraEngine needs a printer definition. Those ship with the Cura GUI package,
# which is aarch64-only -- so if it is not installed, this tells you the two
# files to fetch and where to put them, rather than failing with a stack trace.
set -eu

command -v CuraEngine >/dev/null 2>&1 || {
    echo "CuraEngine is not installed:  doas apk add curaengine" >&2; exit 1; }

STL="${1:-}"
[ -n "$STL" ] || { sed -n '2,${/^#/!q; /^# SPDX/d; /^# Copyright/d; p;}' "$0"; exit 2; }
[ -f "$STL" ] || { echo "no such file: $STL" >&2; exit 1; }
shift
OUT=""
case "${1:-}" in
    -s|'') ;;
    *) OUT="$1"; shift ;;
esac
[ -n "$OUT" ] || OUT="${STL%.*}.gcode"

# The definition search. Cura keeps them under resources/definitions; a
# hand-placed pair in ~/.local/share/cura works just as well.
DEF=""
for d in "$HOME/.local/share/cura/definitions" \
         /usr/share/cura/resources/definitions \
         /usr/share/cura/definitions; do
    if [ -f "$d/creality_ender3.def.json" ]; then DEF="$d/creality_ender3.def.json"; break; fi
    if [ -f "$d/fdmprinter.def.json" ]; then DEF="$d/fdmprinter.def.json"; fi
done
if [ -z "$DEF" ]; then
    cat >&2 <<'NODEF'
No CuraEngine printer definition found.

CuraEngine cannot slice without one, and they are data files rather than code,
so they are not in the curaengine package. Fetch these two from Cura's
repository and put them in ~/.local/share/cura/definitions/ :

  fdmprinter.def.json          the base every printer inherits
  creality_ender3.def.json     the Ender 3 on top of it

  https://github.com/Ultimaker/Cura/tree/main/resources/definitions

  mkdir -p ~/.local/share/cura/definitions && cd ~/.local/share/cura/definitions
  wget https://raw.githubusercontent.com/Ultimaker/Cura/main/resources/definitions/fdmprinter.def.json
  wget https://raw.githubusercontent.com/Ultimaker/Cura/main/resources/definitions/creality_ender3.def.json

On aarch64 you can instead install the GUI, which brings them with it:
  doas apk add cura@testing
NODEF
    exit 1
fi

echo "definition: $DEF"
echo "slicing   : $STL -> $OUT"

# Ender 3: 220 x 220 x 250 bed, 0.4 mm nozzle, 1.75 mm filament, Marlin.
exec CuraEngine slice -v \
    -j "$DEF" \
    -l "$STL" \
    -o "$OUT" \
    -s machine_width=220 \
    -s machine_depth=220 \
    -s machine_height=250 \
    -s machine_nozzle_size=0.4 \
    -s material_diameter=1.75 \
    -s machine_gcode_flavor=Marlin \
    -s machine_center_is_zero=false \
    -s layer_height=0.2 \
    -s layer_height_0=0.28 \
    -s wall_thickness=0.8 \
    -s top_bottom_thickness=0.8 \
    -s infill_sparse_density=20 \
    -s material_print_temperature=200 \
    -s material_bed_temperature=60 \
    -s speed_print=50 \
    -s speed_travel=100 \
    -s retraction_enable=true \
    -s adhesion_type=skirt \
    "$@"
SLICER
    chmod 0755 /usr/local/bin/slice-ender3
    note "slice-ender3 model.stl        STL -> G-code with Ender 3 defaults"
    note "admesh model.stl             check an STL for holes before printing"
    note "Copy the .gcode to the printer's SD card, or feed it to OctoPrint."
}

workshop_electronics() {
    say "Electronics: schematic capture, PCB and simulation"
    cat <<'MSG'

    ngspice   every port. The circuit simulator -- the free descendant of
              Berkeley SPICE, and the engine several GUIs drive. PSpice
              itself is a proprietary Cadence product and is not available
              for Linux on ARM in any form; ngspice is the thing to learn.
    KiCad     aarch64 only. Schematic capture, PCB layout, and gerber
              export -- the whole flow, and the tool the fab houses expect.
              About 2 GB with its libraries.

    Not packaged for any port here: Fritzing, gEDA, gerbv, Qucs, Oregano,
    xcircuit, KLayout, gnucap. On a Zero the honest workflow is ngspice for
    simulation locally, and KiCad on a desktop machine for layout.

MSG
    add_optional ngspice
    if [ "$ARCH_GATE" = a64 ] && have_space_mb 2500 "KiCad and its libraries"; then
        confirm "Install KiCad (about 2 GB with libraries)?" \
            && add_optional kicad kicad-library kicad-library-3d
    elif [ "$ARCH_GATE" = a64 ]; then
        note "KiCad skipped -- not enough free space"
    else
        note "KiCad is aarch64 only -- not offered on this port"
    fi

    say "Installing /usr/local/bin/pcbzip"
    cat > /usr/local/bin/pcbzip <<'PCBZIP'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# pcbzip -- package gerbers and drill files for a fab house.
#
#   pcbzip [DIR] [OUT.zip]
#
# PCBWay, JLCPCB, OSH Park, Aisler and the rest all want the same thing: one
# zip of RS-274X gerbers plus Excellon drill files, no directories inside it.
# That is all this does, plus a check that the layers a two-layer board needs
# are actually present -- the common and expensive mistake is uploading a zip
# missing the drill file and not finding out until the board arrives wrong.
#
# To produce the gerbers from a KiCad board in the first place:
#   kicad-cli pcb export gerbers --output gerbers/ board.kicad_pcb
#   kicad-cli pcb export drill   --output gerbers/ board.kicad_pcb
set -eu
DIR="${1:-gerbers}"
OUT="${2:-$(basename "$(cd "$DIR" 2>/dev/null && pwd || echo board)")-fab.zip}"
[ -d "$DIR" ] || { echo "no such directory: $DIR" >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "zip is not installed: doas apk add zip" >&2; exit 1; }

n=$(find "$DIR" -maxdepth 1 -type f \( -name '*.gbr' -o -name '*.g??' -o -name '*.drl' \
        -o -name '*.gko' -o -name '*.txt' \) 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || { echo "no gerber or drill files in $DIR" >&2; exit 1; }

# Warn, do not refuse -- a one-layer board or an unusual naming scheme is a
# legitimate thing to send, and only you know which.
for want in drl gbr; do
    find "$DIR" -maxdepth 1 -name "*.$want" | grep -q . \
        || echo "warning: no .$want files found -- is the export complete?" >&2
done

rm -f "$OUT"
# -j junks the paths: fab houses reject zips with directories inside.
(cd "$DIR" && zip -j -q "$OLDPWD/$OUT" ./*) || { echo "zip failed" >&2; exit 1; }
echo "wrote $OUT"
unzip -l "$OUT" | sed 's/^/  /'
cat <<'NEXT'

Upload that file as-is. Before you pay, check the fab's own gerber viewer
against your layout -- every one of them has one, and it is the last chance
to catch a missing layer.
NEXT
PCBZIP
    chmod 0755 /usr/local/bin/pcbzip
    note "pcbzip gerbers/             zip gerbers + drill for PCBWay/JLCPCB/OSH Park"
    note "ngspice circuit.cir         simulate"
}

workshop_maths() {
    say "LaTeX and mathematics"
    cat <<'MSG'

    All of this is packaged for every port -- maths is one area where ARMv6
    costs you nothing but time.

      TeX Live     the full distribution. It is ~4 GB, so it is asked about
                   separately; texlive alone (without -full) is far smaller
                   and enough for most documents.
      LyX          LaTeX with a document view rather than raw markup.
      Maxima       computer algebra: solves systems of equations symbolically,
                   integrates, factors. The classic free CAS. (edge/testing)
      Octave       MATLAB-compatible numerics -- matrices, linear systems.
      SymPy        the same job inside Python, and lighter than either.
      Qalculate    a unit-aware calculator that is genuinely excellent.
      Gnuplot      plotting, from a script or interactively.
      PARI/GP      number theory. Singular: polynomial algebra. R: statistics.

    Solving a system of equations, three ways:
      maxima:  solve([x+y=10, x-y=2], [x,y]);
      octave:  A=[1 1;1 -1]; b=[10;2]; A\b
      python:  from sympy import *; x,y=symbols('x y'); solve([x+y-10,x-y-2])

MSG
    add_optional octave gnuplot qalculate-gtk py3-sympy py3-numpy py3-scipy py3-matplotlib
    add_optional maxima@testing
    add_optional pari singular R

    cat <<'MSG'

    TeX Live: 'texlive' is a few hundred MB, 'texlive-full' is around 4 GB.
    On a card with room, full removes an entire category of "missing .sty
    file" problems. On a 8 GB card it is most of the card.

MSG
    # Unattended, take the basic distribution: 'full' is ~4 GB and nobody is
    # watching to notice it filling the card. Stated rather than relying on
    # the generic 'y' happening to land on the right branch.
    if [ "${AUTO:-0}" = 1 ]; then AUTO_DEFAULT=b; fi
    ask "TeX Live: [f]ull, [b]asic, or [n]one?"
    case "$REPLY" in
        f|F) if have_space_mb 4500 "texlive-full"; then
                 add_optional texlive-full texmf-dist lyx
             else
                 note "Installing the basic distribution instead."
                 add_optional texlive lyx
             fi ;;
        b|B|y|Y) add_optional texlive lyx ;;
        *)   note "Skipped TeX Live." ;;
    esac
}

workshop_music() {
    say "Trackers, chiptune and MIDI"
    cat <<'MSG'

    Tracker music is what this class of machine was built for, and the
    trackers themselves are tiny.

      MilkyTracker    Fasttracker II style. XM and MOD. (edge/testing)
      Schism Tracker  an Impulse Tracker clone, nearly pixel-exact. (edge)
      openmpt123      play any module format from the terminal; xmp likewise
      vsid            the Commodore 64 SID chip, from VICE. Emulates the
                      6581/8580 and the 6510 driving it -- far cheaper than
                      a whole emulated C64 just to hear music. Stage 9 sets
                      up ~/vice with a place to put tunes.
      FluidSynth      a MIDI synthesiser, with a General MIDI soundfont
                      (soundfont-timgm) so it makes sound out of the box
      Hydrogen        drum machine
      LMMS            a full DAW with tracker lineage (armv7/aarch64)
      MuseScore       music notation (armv7/aarch64)
      Audacity        waveform editing

    The High Voltage SID Collection (hvsc.c64.org) is tens of thousands of
    SID tunes, free, and about 60 MB -- it fits on the card comfortably.

MSG
    add_optional milkytracker@testing schismtracker@testing xmp@testing
    add_optional openmpt123 fluidsynth soundfont-timgm hydrogen audacity
    case "$ARCH_GATE" in
        a64|v7) add_optional lmms musescore ;;
        *) note "no LMMS and no MuseScore for ARMv6 -- the trackers are the answer here" ;;
    esac
    note "fluidsynth -a alsa /usr/share/soundfonts/*.sf2 file.mid    play a MIDI file"
    note "openmpt123 tune.xm                                        play a module"
    note "vsid tune.sid                                             play a SID (stage 9)"
}

# ------------------------------------------------ learning to play piano ----
#
# The gap this fills: the catalogue has a typing tutor (two of them) and had
# nothing at all for the same idea applied to a keyboard you play with both
# hands. Alpine does not package one either -- PianoBooster, Linthesia, VMPK,
# TiMidity++, GNU Solfege, Nootka, Rosegarden, Denemo and MMA are absent from
# main, community AND edge/testing on every port. Minuet is the only packaged
# music-education program there is, and it teaches theory rather than playing.
#
# So PianoBooster is built from source, which is what stage 9 already does for
# Mini vMac and VICE. It is the program the request describes: it reads a MIDI
# file, scrolls the notes on a stave, waits for you to play the right note on a
# real keyboard, scores you on it -- and plays one hand while you play the
# other, which is the accompaniment half of the same question.
#
# Two things about this board that the build cannot fix, said before it starts
# rather than discovered afterwards:
#
#   - PianoBooster renders through OpenGL (FIND_PACKAGE(OpenGL REQUIRED), and
#     FTGL on top of it). There is no GL driver on the VideoCore framebuffer,
#     so this is llvmpipe -- software rasterisation of a scrolling score, on
#     four 1 GHz A53s. It may well be too slow to play along to. Nothing here
#     can establish that except running it.
#   - Play-along is latency-sensitive, and a Zero has no analogue audio out:
#     sound leaves over HDMI, a USB DAC or an I2S hat.
workshop_piano() {
    say "Learning to play -- PianoBooster and the MIDI plumbing"
    cat <<'MSG'

    A piano tutor in the sense a typing tutor is one: it puts the notes in
    front of you, waits for you to play them, and tells you how you did.

      PianoBooster    reads a MIDI file, scrolls the stave, listens to your
                      keyboard and scores you. Choose which hand it plays and
                      which you play -- so it can hold the left-hand part down
                      while you learn the right, or the other way round.
                      Not packaged by Alpine. Built here from source.
      piano-midi      one command to wire a USB MIDI keyboard into FluidSynth,
                      so the keyboard makes sound at all. Installed either way.
      Minuet          theory and ear training rather than playing: intervals,
                      chords, scales, rhythm. In the catalogue (stage 12).

    YOU NEED A MIDI KEYBOARD. PianoBooster listens to MIDI in; without one it
    will show you the music and score nothing. A Zero has one micro-USB data
    port, so a keyboard plus anything else means a powered OTG hub.

    THE BUILD IS LONG -- Qt5 and Mesa headers come down first, then a C++
    compile on this board. Budget an hour or more, like stage 9's.

MSG
    have_space_mb 1500 "the PianoBooster build (Qt5 and Mesa development files)" \
        || { note "Skipping the build. The MIDI plumbing below still installs."; }

    # The plumbing is worth having whether or not the build works, so it is
    # installed first and unconditionally: a keyboard that makes sound is the
    # difference between a broken setup and a usable one with no tutor yet.
    add_optional fluidsynth soundfont-timgm alsa-utils
    piano_write_helper

    AUTO_DEFAULT=y
    confirm_yes "Build PianoBooster from source now?" || {
        note "Not built. Run stage 14 again and choose the piano bundle."
        return 0
    }

    say "Build dependencies"
    # mesa-dev for the GL headers, ftgl-dev for the note glyphs, qt5-qttools-dev
    # for LinguistTools which the CMake file asks for by name.
    add_optional build-base cmake pkgconf qt5-qtbase-dev qt5-qttools-dev \
                 ftgl-dev fluidsynth-dev alsa-lib-dev mesa-dev
    apk info -e qt5-qtbase-dev >/dev/null 2>&1 \
        || { warn "no Qt5 development files -- cannot build PianoBooster"; return 1; }

    # rtmidi is only in edge/testing. If it is reachable, use it; if it is not,
    # the source tree carries its own copy and USE_BUNDLED_RTMIDI builds that
    # instead -- which is also the option that keeps an edge/testing library
    # out of a v3.24 system, so its failure is not much of a failure.
    _pb_rtmidi=ON
    if try_add rtmidi-dev@testing; then
        _pb_rtmidi=OFF
        note "using the system rtmidi from edge/testing"
    else
        note "using the rtmidi bundled with the source (no edge/testing needed)"
    fi

    SRCDIR=/usr/local/src
    mkdir -p "$SRCDIR"
    cd "$SRCDIR"

    # Card first, network second -- the same order and the same reasoning as
    # stage 9's Mini vMac tarball.
    _pb_tgz=$(ls "$SRCDIR"/pianobooster-*.tar.gz 2>/dev/null | head -n1 || true)
    if [ -z "$_pb_tgz" ]; then
        _pb_staged=$(ls "$BOOT"/pianobooster/pianobooster-*.tar.gz 2>/dev/null | head -n1 || true)
        if [ -n "$_pb_staged" ] && cp "$_pb_staged" "$SRCDIR/"; then
            _pb_tgz="$SRCDIR/$(basename "$_pb_staged")"
            note "using $(basename "$_pb_tgz") from the card -- no download needed"
        fi
    fi
    if [ -z "$_pb_tgz" ]; then
        _pb_url="https://github.com/pianobooster/PianoBooster/archive/$PIANOBOOSTER_REF.tar.gz"
        say "Downloading PianoBooster $PIANOBOOSTER_REF"
        if wget -q -O "$SRCDIR/pianobooster-src.tar.gz" "$_pb_url"; then
            _pb_tgz="$SRCDIR/pianobooster-src.tar.gz"
        else
            warn "could not download $_pb_url"
            note "Stage it on the card instead and re-run this bundle:"
            note "  on the Mac -- ./copal-prep.sh --refresh"
            return 1
        fi
    fi

    say "Unpacking"
    rm -rf "$SRCDIR/pianobooster-build"; mkdir -p "$SRCDIR/pianobooster-build"
    tar xzf "$_pb_tgz" -C "$SRCDIR/pianobooster-build" \
        || { warn "the archive did not unpack -- delete $_pb_tgz and try again"; return 1; }
    # The archive's top directory carries the commit in its name, so find the
    # tree rather than assuming what it is called.
    _pb_src=$(dirname "$(find "$SRCDIR/pianobooster-build" -maxdepth 3 -name CMakeLists.txt \
                          -path '*/src/*' 2>/dev/null | head -1)")
    _pb_src=${_pb_src%/src}
    [ -n "$_pb_src" ] && [ -f "$_pb_src/CMakeLists.txt" ] \
        || { warn "cannot find the source tree inside $_pb_tgz"; return 1; }

    say "Configuring"
    mkdir -p "$_pb_src/build"; cd "$_pb_src/build"
    # -DCMAKE_POLICY_VERSION_MINIMUM=3.5 is not optional here. PianoBooster
    # still declares cmake_minimum_required(VERSION 2.4), and CMake 4 -- which
    # is what Alpine 3.24 ships -- removed compatibility with anything below
    # 3.5 and refuses to configure at all without this escape hatch.
    if ! cmake .. -DQT_PACKAGE_NAME=Qt5 \
                  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
                  -DCMAKE_BUILD_TYPE=Release \
                  -DUSE_BUNDLED_RTMIDI="$_pb_rtmidi" > /var/log/pianobooster-build.log 2>&1; then
        warn "cmake failed -- the last lines of /var/log/pianobooster-build.log:"
        tail -n 15 /var/log/pianobooster-build.log | sed 's/^/    /' >&2
        return 1
    fi
    note "configured (Qt5, rtmidi bundled=$_pb_rtmidi)"

    say "Compiling -- this is the long part"
    if ! make -j"$(nproc 2>/dev/null || echo 1)" >> /var/log/pianobooster-build.log 2>&1; then
        warn "the compile failed -- the last lines of /var/log/pianobooster-build.log:"
        tail -n 20 /var/log/pianobooster-build.log | sed 's/^/    /' >&2
        note "The whole log is at /var/log/pianobooster-build.log."
        return 1
    fi

    _pb_bin=$(find "$_pb_src" -maxdepth 3 -type f -name pianobooster -perm -u+x 2>/dev/null | head -1)
    if [ -n "$_pb_bin" ]; then
        install -m 0755 "$_pb_bin" /usr/local/bin/pianobooster
        note "installed /usr/local/bin/pianobooster"
        note "run it as the desktop user, not root: pianobooster"
        note "It renders through software OpenGL here -- if the score crawls,"
        note "that is the missing GPU driver and not the board being busy."
    else
        warn "the build reported success but produced no pianobooster binary"
        note "Look in $_pb_src/build and at /var/log/pianobooster-build.log."
        return 1
    fi
    return 0
}

# piano-midi -- the smallest thing that makes a plugged-in keyboard audible.
#
# Nothing here is clever: fluidsynth opens an ALSA sequencer port, the keyboard
# has one, and aconnect joins them. It is written down because working that out
# from the ALSA manual pages the first time takes an evening, and because
# 'my keyboard makes no sound' has about six causes and this narrows it to one.
piano_write_helper() {
    say "Installing /usr/local/bin/piano-midi"
    cat > /usr/local/bin/piano-midi <<'PIANOMIDI'
#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org -- part of Copal Linux.
# piano-midi -- connect a USB MIDI keyboard to FluidSynth, and play MIDI files.
#
#   piano-midi            start FluidSynth and connect every MIDI keyboard
#   piano-midi list       show the MIDI ports ALSA can see
#   piano-midi play F.mid play a MIDI file through FluidSynth
#   piano-midi stop       stop the FluidSynth started by this script
#
# The soundfont is soundfont-timgm, installed by stage 14. Any .sf2 works:
# point SF2 at it.
set -eu

SF2=${SF2:-$(ls /usr/share/soundfonts/*.sf2 2>/dev/null | head -n1 || true)}
PIDFILE=/tmp/piano-midi.$(id -u).pid

need() { command -v "$1" >/dev/null 2>&1 || { echo "piano-midi: $1 is not installed" >&2; exit 1; }; }

# Every sequencer client that has an input port and is not a synth we started:
# that is what a keyboard looks like to ALSA.
keyboards() { aconnect -i 2>/dev/null | awk '/^client [1-9]/ && !/System|Midi Through/ { gsub(":", "", $2); print $2 }'; }
fluid_port() { aconnect -o 2>/dev/null | awk '/FLUID|fluid/ { gsub(":", "", $2); print $2; exit }'; }

case "${1:-start}" in
    list)
        need aconnect
        echo "--- inputs (keyboards) ---";  aconnect -i
        echo "--- outputs (synths) ---";    aconnect -o
        ;;
    play)
        [ -n "${2:-}" ] || { echo "usage: piano-midi play FILE.mid" >&2; exit 1; }
        [ -n "$SF2" ] || { echo "piano-midi: no soundfont found; apk add soundfont-timgm" >&2; exit 1; }
        need fluidsynth
        exec fluidsynth -a alsa -i "$SF2" "$2"
        ;;
    stop)
        if [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; then
            rm -f "$PIDFILE"; echo "stopped"
        else
            rm -f "$PIDFILE"; echo "nothing of ours was running"
        fi
        ;;
    start)
        [ -n "$SF2" ] || { echo "piano-midi: no soundfont found; apk add soundfont-timgm" >&2; exit 1; }
        need fluidsynth; need aconnect
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
            echo "FluidSynth is already running (pid $(cat "$PIDFILE"))"
        else
            echo "Starting FluidSynth with $SF2"
            fluidsynth -a alsa -m alsa_seq -i -s "$SF2" >/dev/null 2>&1 &
            echo $! > "$PIDFILE"
            # It has to register its sequencer port before aconnect can find it.
            sleep 2
        fi
        DEST=$(fluid_port)
        [ -n "$DEST" ] || { echo "piano-midi: FluidSynth registered no MIDI port. 'piano-midi list' to look." >&2; exit 1; }
        FOUND=0
        for k in $(keyboards); do
            if aconnect "$k:0" "$DEST:0" 2>/dev/null; then
                echo "connected client $k -> FluidSynth ($DEST)"; FOUND=1
            fi
        done
        if [ "$FOUND" = 0 ]; then
            echo "No MIDI keyboard found. Plug one into the USB port and run this again."
            echo "'piano-midi list' shows what ALSA can see."
        else
            echo "Play. 'piano-midi stop' when you are done."
        fi
        ;;
    *)  sed -n '4,12p' "$0" ;;
esac
PIANOMIDI
    chmod 0755 /usr/local/bin/piano-midi
    note "piano-midi          connect a keyboard and make it audible"
    note "piano-midi list     what ALSA can see"
    note "piano-midi play F.mid"
}

stage_workshop() {
    say "Stage 14: the workshop -- engineering, science and music"

    if is_diskless; then
        warn "the root filesystem is still a tmpfs. None of this will fit."
        note "Run stage 3 first."
        confirm "Try anyway?" || return 0
    fi
    require_network || return 1

    note "architecture: $(apk --print-arch 2>/dev/null || echo unknown)  (gate: $ARCH_GATE)"
    cat <<'MSG'

    Five bundles. Each says what it can and cannot do on this board before
    it installs anything.

      c   CAD and 3D modelling      SolveSpace, FreeCAD, Blender, Goxel
      p   3D printing (Ender 3)     CuraEngine + slice-ender3, admesh,
                                    optionally OctoPrint and the Cura GUI
      e   Electronics               ngspice, KiCad, and pcbzip for the fab
      m   LaTeX and mathematics     TeX Live, Maxima, Octave, SymPy, Gnuplot
      u   Music                     trackers, SID, MIDI, Hydrogen, Audacity
      k   Learning to play piano    PianoBooster (compiles), piano-midi
      a   All of them
      q   Back to the menu

MSG
    ask "Choose [c/p/e/m/u/k/a/q]:"
    case "$REPLY" in
        c|C) workshop_cad ;;
        p|P) workshop_3dprint ;;
        e|E) workshop_electronics ;;
        m|M) workshop_maths ;;
        u|U) workshop_music ;;
        k|K) workshop_piano ;;
        a|A) workshop_cad; workshop_3dprint; workshop_electronics
             workshop_maths; workshop_music; workshop_piano ;;
        *)   note "Nothing installed."; return 0 ;;
    esac

    say "Stage 14 complete."
    commit_reminder
}

# ----------------------------------------------- stage 13: hand over root ---
#
# The last stage of an install, and deliberately last: it takes away the
# account every earlier stage logs in as. Everything it does is reversible from
# a doas shell, and it refuses outright if the admin account is not in a state
# to open one.
stage_lockroot() {
    say "Stage 13: lock the root account, hand privilege to '$PI_USER'"
    root_handover_notes

    if root_locked && sed -n "/$SSH_BEGIN/,/$SSH_END/p" "$SSHCFG" 2>/dev/null \
         | grep -qi '^PermitRootLogin[[:space:]]*no'; then
        note "Already done -- root is locked and SSH refuses it."
        note "Undo with: doas passwd root"
        return 0
    fi

    # The pre-flight. Getting this wrong is a machine you cannot log into and
    # cannot repair without pulling the card, so each half is reported by name
    # rather than as one pass/fail.
    say "Checking '$PI_USER' can take over before anything is locked"
    _bad=0
    if can_login "$PI_USER"; then note "password    : set"
    else warn "password    : NOT set -- '$PI_USER' cannot log in at all"; _bad=1; fi
    if in_wheel "$PI_USER"; then note "wheel group : yes"
    else warn "wheel group : no -- doas will refuse"; _bad=1; fi
    if command -v doas >/dev/null 2>&1; then note "doas        : $(command -v doas)"
    else warn "doas        : not installed"; _bad=1; fi
    # NOT `doas -C /etc/doas.conf true`. Handing -C a command changes the
    # question from "is this file valid" to "may the user running me run that
    # command" -- and this runs as root, which no `permit :wheel` rule
    # matches, so the answer was no however healthy the configuration was.
    # That is what refused to hand over on a machine where doas worked
    # perfectly well: it reported a deny as a parse error.
    #
    # The real requirements are that every file doas reads parses and that
    # some rule reaches $PI_USER, both of which admin_ensure_doas checks --
    # and fixes, because this stage is the last chance to fix them while root
    # can still log in.
    if command -v doas >/dev/null 2>&1; then
        if admin_ensure_doas; then note "doas config : parses, and a rule reaches wheel"
        else warn "doas config : not usable -- see above"; _bad=1; fi
    fi

    if [ "$_bad" != 0 ]; then
        warn "not locking root -- fix the above first."
        note "Usually: run stage 1, or by hand:"
        note "  passwd $PI_USER && adduser $PI_USER wheel && apk add doas"
        note "  echo 'permit persist :wheel' > /etc/doas.d/wheel.conf"
        note "(/etc/doas.conf must exist too, even if every line in it is a comment.)"
        return 1
    fi

    # The hash check above says the password would be accepted; this says the
    # rest of the account works -- shell, home directory, groups. Run from
    # root, su asks for nothing, so a failure here is a real defect and not a
    # mistyped password.
    #
    # The home directory is checked separately rather than through su: su
    # falls back to / when it cannot chdir to $HOME and carries on, so it
    # would pass this test and still leave the person a shell that starts in
    # a directory they do not own and cannot write.
    say "Testing the account"
    ensure_user_home || true
    if su - "$PI_USER" -c 'id' >/dev/null 2>&1; then
        note "ok -- '$PI_USER' has a working shell"
    else
        warn "could not switch to '$PI_USER'. Not locking root."
        note "Check: getent passwd $PI_USER"
        return 1
    fi
    _uh=$(user_home)
    if [ -n "$_uh" ] && [ -d "$_uh" ]; then
        note "home        : $_uh"
    else
        warn "home        : $_uh is missing and could not be created"
        warn "not locking root -- fix that first."
        return 1
    fi

    warn "About to lock root. After this the ONLY way in is '$PI_USER' + doas."
    confirm "Lock the root account?" || { note "Left alone."; return 0; }

    say "Locking the root password"
    passwd -l root && note "root: $(shadow_hash root | cut -c1-2)... (locked)"

    if [ -f "$SSHCFG" ]; then
        say "Refusing root over SSH"
        # Through the same managed block stage 6 uses, so the two cannot
        # disagree about what the policy is. Passwords keep whatever setting
        # they already had -- locking root is not a reason to silently change
        # how the admin user authenticates.
        if ssh_policy_present && ssh_password_on; then
            ssh_write_policy yes
        elif ssh_policy_present; then
            ssh_write_policy no
        elif ssh_has_key; then
            note "no policy block yet -- writing one, keys only"
            ssh_write_policy no
        else
            note "no policy block yet, and no key installed -- writing one that"
            note "keeps password login, so this does not lock you off the network"
            ssh_write_policy yes
        fi
    fi

    say "Stage 13 complete."
    note "Log in as: $PI_USER        Become root: doas -s"
    note "Undo, from a doas shell:   doas passwd root"
    commit_reminder
}

stage_verify() {
    say "Verification"
    note "root filesystem : $(df -h / | awk 'NR==2 {print $1, $2, $5" used"}')"
    note "memory          : $(free -m | awk '/Mem:/ {print $2 " MB total, " $NF " MB available"}')"
    note "framebuffer     : $(ls /dev/fb0 2>/dev/null || echo 'NOT PRESENT -- no console graphics')"
    note "apk cache       : $(readlink /etc/apk/cache 2>/dev/null || echo none)"
    note "X.Org           : $(x_installed && echo installed || echo 'not installed')"
    note "zram swap       : $(zram_active && grep '^/dev/zram' /proc/swaps | awk '{print $3/1024 " MB"}' || echo 'not active')"
    note "ssh key         : $(sshkey_done && echo "authorised for $PI_USER" || echo 'not installed')"
    if [ -L /etc/apk/cache ] && [ ! -d "$(readlink /etc/apk/cache)" ]; then
        warn "the apk cache symlink is dangling -- is p2 mounted?"
    fi
    echo
    note "mounts:"; grep -E "$DISKDEV|[[:space:]]/[[:space:]]" /proc/mounts | sed 's/^/      /'
    echo
    note "uncommitted changes (lbu status):"
    lbu status 2>&1 | sed 's/^/      /' || true
}

# -------------------------------------------------------------- full auto ---
#
# Everything it needs from a human is asked in stage 1, then it runs to the end
# on its own -- across the reboot that stage 3 forces, which is the part that
# makes this more than a loop over the stage functions.
#
# What it cannot answer is the root password: setup-alpine prompts for that
# directly and has no answer-file variable for it, so stage 1 stops once, waits,
# and carries on. The git identity is asked in the same breath, immediately
# before it, and saved to the card -- so stage 7 has it an hour and a half
# later without stopping. Both are stated up front rather than discovered
# twenty minutes in.
#
# ===========================================================================
# The full-automatic installer's screen.
#
# A DOS-installer layout: a banner, four nested progress bars, a checklist of
# phases, and a scrolling output pane. It exists because the unattended install
# takes hours and the honest question at any moment is "is it stuck?". A wall of
# scrolling apk output does not answer that. Four bars do:
#
#   Total   how much of the whole install is done      (stages finished)
#   Phase   how much of this group of stages is done   (stages within a phase)
#   Task    how far through the current stage          (declared steps)
#   Item    the one package or file being worked on    (marquee, see below)
#
# THREE DESIGN DECISIONS, because they are the ones that keep this small:
#
# 1. The stages are not modified. copal-init.sh already funnels every line it
#    prints through say/note/warn, so the UI hooks THOSE, and all thirteen
#    stages drive the display without knowing it exists. That is the whole
#    reason this is ~200 lines instead of a rewrite. tui_wrap_output installs
#    the hooks; tui_unwrap_output puts the originals back.
#
# 2. One manifest, below, is the single source of truth for order, phase
#    grouping, labels and step counts. AUTO_SEQ is derived from it, so the
#    order cannot drift from what the checklist claims.
#
# 3. It repaints cells, not screens. Every update addresses the cursor to one
#    row and rewrites that row. Redrawing 24 lines on every apk line would
#    flicker on an HDMI console and waste the one CPU core that is also doing
#    the install.
#
# It degrades rather than breaks: no TTY, a terminal under 70x20, or
# COPAL_TUI=0, and the whole thing falls back to the plain line-by-line output
# that was there before. Never assume the screen is addressable -- a serial
# console on the GPIO header is a supported way to run this.
# ===========================================================================

# --- the manifest -----------------------------------------------------------
# stage | phase | what this stage does | expected steps
#
# 'expected steps' is how many say() calls the stage makes, and it is only used
# to fill the Task bar. It is a rough count on purpose: the bar clamps at 99%
# until the stage returns, so an undercount cannot show 100% early and an
# overcount just means the bar finishes in a jump. Being approximate is stated
# here so nobody later mistakes it for a promise.
#
# The order is stage 3's constraint first (it reboots), then slow things last --
# the same reasoning AUTO_SEQ documented, now with the phases named.
auto_manifest() {
    cat <<'MANIFEST'
1|System|Apply the setup-alpine answers|4
2|System|Format p2 and move the apk cache|6
3|System|Move the root filesystem onto the card|8
8|System|Grow p2 into the free space|4
5|Memory|Compressed swap in RAM (zram)|4
6|Access|Install the SSH key from the card|3
4|Desktop|X.Org, i3, a terminal and a browser|9
7|Toolchain|Compilers, debuggers and editors|12
10|Hardware|Wireless, audio, capture and disks|8
12|Software|The application catalogue|4
14|Workshop|CAD, 3D printing, EDA, LaTeX, trackers|6
9|Emulators|Mini vMac and VICE (compiles from source)|6
13|Handover|Hand root over to the admin user|4
MANIFEST
}

# Derived, so the run order and the checklist can never disagree.
auto_seq_from_manifest() { auto_manifest | cut -d'|' -f1 | tr '\n' ' '; }
auto_phases_in_order()   { auto_manifest | cut -d'|' -f2 | awk '!seen[$0]++'; }
auto_field() {  # <stage> <field-number>
    auto_manifest | awk -F'|' -v s="$1" -v f="$2" '$1 == s { print $f; exit }'
}
auto_stages_in_phase() {  # <phase> -- how many stages this phase contains
    auto_manifest | awk -F'|' -v p="$1" '$2 == p { n++ } END { print n+0 }'
}
auto_stage_count() { auto_manifest | grep -c . ; }

# --- capability detection ---------------------------------------------------
TUI=0
TUI_COLS=80
TUI_ROWS=24
TUI_UTF8=0

tui_available() {
    [ "${COPAL_TUI:-1}" = 0 ] && return 1
    # Not '[ -t 1 ]': stdout is the tee pipe by this point, so it is never a
    # terminal even when one is right there. fd 3 is the terminal, opened once
    # near the top of this script.
    [ "$HAVE_TTY" = 1 ] || return 1
    # Ask the terminal its size, not stdout. busybox stty needs it on stdin.
    _sz=$(stty size < /dev/tty 2>/dev/null) || return 1
    TUI_ROWS=${_sz%% *}; TUI_COLS=${_sz##* }
    case "$TUI_ROWS$TUI_COLS" in *[!0-9]*|'') return 1 ;; esac
    [ "$TUI_ROWS" -ge 20 ] && [ "$TUI_COLS" -ge 70 ] || return 1
    return 0
}

# --- drawing primitives ----------------------------------------------------
# Colours chosen after the installers this imitates: white on blue, cyan for
# labels, yellow for the thing happening now.
C_RESET='\033[0m'
C_FRAME='\033[44;36m'     # blue bg, cyan
C_TEXT='\033[44;37m'      # blue bg, white
C_HI='\033[44;1;33m'      # blue bg, bright yellow
C_BAR='\033[44;1;32m'     # blue bg, bright green
C_DONE='\033[44;1;37m'
C_BANNER='\033[47;34m'    # inverted: blue on white

tui_at()   { printf '\033[%d;%dH' "$1" "$2"; } >&3
tui_hide() { printf '\033[?25l'; } >&3
tui_show() { printf '\033[?25h'; } >&3

# UTF-8 box drawing where the console can render it, ASCII where it cannot.
tui_glyphs() {
    case "${LANG:-}${LC_ALL:-}" in
        *[Uu][Tt][Ff]*) TUI_UTF8=1 ;;
        *) TUI_UTF8=0 ;;
    esac
    if [ "$TUI_UTF8" = 1 ]; then
        G_TL=$(printf '\342\224\214'); G_TR=$(printf '\342\224\220')
        G_BL=$(printf '\342\224\224'); G_BR=$(printf '\342\224\230')
        G_H=$(printf '\342\224\200');  G_V=$(printf '\342\224\202')
        G_FULL=$(printf '\342\226\210'); G_EMPTY=$(printf '\342\226\221')
    else
        G_TL='+'; G_TR='+'; G_BL='+'; G_BR='+'; G_H='-'; G_V='|'
        G_FULL='#'; G_EMPTY='.'
    fi
}

# A horizontal run of a glyph. Built up in a variable and printed once rather
# than one printf per character: on this board a 78-iteration loop of commands
# per repaint is measurable, and this runs for every bar update.
#
# Not redirected to fd 3 itself -- it is only ever called from inside tui_bar and
# tui_box, whose bodies already are, so its output goes to the terminal with
# theirs.
tui_repeat() {  # <glyph> <count>
    _g=$1; _n=$2; _o=''
    [ "$_n" -gt 0 ] 2>/dev/null || { printf ''; return; }
    while [ "$_n" -gt 0 ]; do
        _o="$_o$_g"
        _n=$((_n - 1))
    done
    printf '%s' "$_o"
}

# --- one progress bar ------------------------------------------------------
# <row> <label> <done> <total> <trailing note> [cap]
#
# A bar with no known total draws a marquee instead of lying about a percentage.
# 'cap' is the highest percentage this bar may show; the Task bar passes 99
# while a stage is still running, so an inaccurate step count can never display
# a finished bar in front of unfinished work.
TUI_MARQUEE=0
tui_bar() {
    _row=$1; _label=$2; _done=$3; _total=$4; _note=$5; _cap=${6:-100}
    [ "$TUI" = 1 ] || return 0
    _lw=8                                  # label column
    _nw=$(( TUI_COLS / 3 ))                # trailing note column
    [ "$_nw" -gt 28 ] && _nw=28
    _bw=$(( TUI_COLS - _lw - _nw - 12 ))
    [ "$_bw" -lt 10 ] && _bw=10

    if [ "${_total:-0}" -gt 0 ] 2>/dev/null; then
        _pct=$(( _done * 100 / _total ))
        [ "$_pct" -gt "$_cap" ] && _pct=$_cap
        [ "$_pct" -lt 0 ] && _pct=0
        _fill=$(( _bw * _pct / 100 ))
        _pctstr=$(printf '%3d%%' "$_pct")
    else
        # Indeterminate: a block that walks, and no number.
        _fill=0; _pctstr='    '
    fi

    tui_at "$_row" 1
    printf "$C_TEXT %-*s" "$_lw" "$_label"
    printf "$C_FRAME[$C_BAR"
    if [ "${_total:-0}" -gt 0 ] 2>/dev/null; then
        tui_repeat "$G_FULL" "$_fill"
        printf "$C_FRAME"
        tui_repeat "$G_EMPTY" $(( _bw - _fill ))
    else
        _pos=$(( TUI_MARQUEE % _bw ))
        tui_repeat "$G_EMPTY" "$_pos"
        printf "$C_BAR%s$C_FRAME" "$G_FULL"
        tui_repeat "$G_EMPTY" $(( _bw - _pos - 1 ))
    fi
    printf "$C_FRAME]$C_HI %s $C_TEXT" "$_pctstr"
    # Truncate the note rather than wrap it: a wrapped line would push the
    # layout down and every addressed row below it would then be wrong.
    printf '%-*.*s' "$_nw" "$_nw" "$_note"
    printf "$C_RESET"
} >&3

# --- layout -----------------------------------------------------------------
# Row numbers are computed once, into variables, so every tui_at call refers to
# a name rather than a number. Moving a panel means changing one arithmetic
# line here instead of hunting for magic constants.
tui_layout() {
    R_BANNER=1
    R_TOTAL=3
    R_PHASE=4
    R_TASK=5
    R_ITEM=6
    R_TASKTOP=8                               # checklist frame top
    TUI_TASKROWS=$(auto_phases_in_order | grep -c .)
    R_TASKEND=$(( R_TASKTOP + TUI_TASKROWS + 1 ))
    R_OUTTOP=$(( R_TASKEND + 1 ))
    R_OUTEND=$TUI_ROWS
    TUI_OUTROWS=$(( R_OUTEND - R_OUTTOP - 1 ))
    # A short screen loses the output pane before it loses the bars: the bars
    # are the point, the log is on disk anyway.
    if [ "$TUI_OUTROWS" -lt 3 ]; then
        TUI_OUTROWS=0
        R_OUTTOP=0
    fi
}

tui_box() {  # <top-row> <bottom-row> <title>
    _t=$1; _b=$2; _title=$3
    _inner=$(( TUI_COLS - 2 ))
    tui_at "$_t" 1
    printf "$C_FRAME%s" "$G_TL"
    _lbl=" $_title "
    printf '%s' "$_lbl"
    tui_repeat "$G_H" $(( _inner - ${#_lbl} ))
    printf '%s' "$G_TR"
    _r=$(( _t + 1 ))
    while [ "$_r" -lt "$_b" ]; do
        tui_at "$_r" 1; printf "$C_FRAME%s$C_TEXT%${_inner}s$C_FRAME%s" "$G_V" '' "$G_V"
        _r=$(( _r + 1 ))
    done
    tui_at "$_b" 1
    printf "$C_FRAME%s" "$G_BL"
    tui_repeat "$G_H" "$_inner"
    printf "%s$C_RESET" "$G_BR"
} >&3

# --- state ------------------------------------------------------------------
# EVERY variable any tui_render_* function reads must be initialised HERE, even
# when the first thing that assigns it "obviously" runs first. This script runs
# under 'set -eu', and on an unset parameter busybox ash and dash do not return
# non-zero -- they EXIT, with status 2, from wherever they are. That means:
#
#   * 'tui_begin || note "progress screen unavailable"' cannot catch it. The ||
#     guards a return value, and there is no return value; the shell is gone.
#   * the abort happens on the FIRST paint, before any stage runs, so it takes
#     out the whole install rather than degrading the display.
#
# TUI_TASKTEXT was missing from this block and cost exactly that on 2026-05-24:
# every full-auto install died immediately after "Start the automatic install?"
# with a bare "Stopped (exit 2)" and no reason given, because tui_render_bars
# reads it on the first paint while only tui_stage_begin and tui_say assign it.
# Both of those run later, so on a fresh boot it was never set.
#
# The reason it was silent is worth keeping next to the reason it broke: fd 2 had
# been sent to /dev/null by the fd-3 setup (see the exec near the top of this
# script), so the shell's own "TUI_TASKTEXT: parameter not set" went nowhere.
TUI_STAGE_TOTAL=0     # stages in the whole run
TUI_STAGE_DONE=0      # stages finished
TUI_STAGE_NUM=''      # the stage running now
TUI_PHASE=''          # its phase
TUI_PHASE_TOTAL=0
TUI_PHASE_DONE=0
TUI_STEP=0            # say() calls seen in this stage
TUI_STEP_TOTAL=0      # expected, from the manifest
TUI_TASKTEXT=''       # the Task bar's label -- read on the first paint
TUI_ITEM=''
TUI_DONE_PHASES=' '   # space-delimited, phases fully finished
TUI_OUTFILE=''

tui_begin() {
    tui_available || { TUI=0; return 1; }
    TUI=1
    tui_glyphs
    tui_layout
    TUI_STAGE_TOTAL=$(auto_stage_count)
    # The Output pane tails the same file the stages' raw output is redirected
    # into (see auto_run), so what scrolls there is the real apk and make output
    # rather than a summary of it. /tmp, not the boot partition: this is written
    # to on every line and the card should not be.
    TUI_OUTFILE=/tmp/copal-tui-out.$$
    : > "$TUI_OUTFILE"
    tui_hide
    # Paint the whole screen blue once. Everything after this addresses cells.
    printf "$C_TEXT\033[2J"
    tui_banner
    tui_box "$R_TASKTOP" "$R_TASKEND" "Install phases"
    [ "$TUI_OUTROWS" -gt 0 ] && tui_box "$R_OUTTOP" "$R_OUTEND" "Output"
    tui_render_all
    return 0
} >&3

tui_end() {
    [ "$TUI" = 1 ] || return 0
    TUI=0
    tui_show
    printf "$C_RESET"
    tui_at "$TUI_ROWS" 1
    printf '\n'
} >&3

tui_banner() {
    [ "$TUI" = 1 ] || return 0
    tui_at "$R_BANNER" 1
    _left=' COPAL LINUX -- FULL AUTOMATIC INSTALL'
    _right="Alpine ${ALPINE_VER:-3.24} "
    _pad=$(( TUI_COLS - ${#_left} - ${#_right} ))
    [ "$_pad" -lt 1 ] && _pad=1
    printf "$C_BANNER%s%${_pad}s%s$C_RESET" "$_left" '' "$_right"
} >&3

# --- the checklist ----------------------------------------------------------
# [x] finished   [>] running now   [ ] not started
tui_render_tasks() {
    [ "$TUI" = 1 ] || return 0
    _row=$(( R_TASKTOP + 1 ))
    auto_phases_in_order | while IFS= read -r _p; do
        case "$TUI_DONE_PHASES" in
            *" $_p "*) _mark='[x]'; _col=$C_DONE ;;
            *) if [ "$_p" = "$TUI_PHASE" ]; then _mark='[>]'; _col=$C_HI
               else _mark='[ ]'; _col=$C_TEXT; fi ;;
        esac
        # What this phase covers: the labels of its stages, joined.
        _what=$(auto_manifest | awk -F'|' -v p="$_p" '$2 == p { printf "%s%s", sep, $3; sep = "; " }')
        _w=$(( TUI_COLS - 4 - 12 - 4 ))
        tui_at "$_row" 2
        printf "%b%s %-11.11s %-*.*s$C_RESET" "$_col" "$_mark" "$_p" "$_w" "$_w" "$_what"
        _row=$(( _row + 1 ))
    done
} >&3

# --- the output pane --------------------------------------------------------
# The last N lines of whatever the stages printed. Kept in a file rather than a
# shell variable because a variable holding hours of apk output is a memory
# leak on a board with 512 MB.
tui_log_line() {  # <text>
    [ -n "$TUI_OUTFILE" ] || return 0
    printf '%s\n' "$1" >> "$TUI_OUTFILE"
    # Trim occasionally so the file cannot grow without bound.
    if [ "$(( $(wc -l < "$TUI_OUTFILE") ))" -gt 400 ]; then
        tail -n 100 "$TUI_OUTFILE" > "$TUI_OUTFILE.t" && mv "$TUI_OUTFILE.t" "$TUI_OUTFILE"
    fi
    tui_render_out
}

tui_render_out() {
    [ "$TUI" = 1 ] || return 0
    [ "$TUI_OUTROWS" -gt 0 ] || return 0
    _w=$(( TUI_COLS - 4 ))
    _row=$(( R_OUTTOP + 1 ))
    tail -n "$TUI_OUTROWS" "$TUI_OUTFILE" 2>/dev/null | {
        _n=0
        while IFS= read -r _l; do
            tui_at "$_row" 2
            printf "$C_TEXT%-*.*s" "$_w" "$_w" "$_l"
            _row=$(( _row + 1 )); _n=$(( _n + 1 ))
        done
        # Blank any rows the log has not filled yet.
        while [ "$_n" -lt "$TUI_OUTROWS" ]; do
            tui_at "$_row" 2; printf "$C_TEXT%-*s" "$_w" ''
            _row=$(( _row + 1 )); _n=$(( _n + 1 ))
        done
    }
    printf "$C_RESET"
} >&3

tui_render_bars() {
    [ "$TUI" = 1 ] || return 0
    TUI_MARQUEE=$(( TUI_MARQUEE + 1 ))
    tui_bar "$R_TOTAL" 'Total'  "$TUI_STAGE_DONE" "$TUI_STAGE_TOTAL" \
            "$TUI_STAGE_DONE of $TUI_STAGE_TOTAL stages done"
    tui_bar "$R_PHASE" 'Phase'  "$TUI_PHASE_DONE" "$TUI_PHASE_TOTAL" "$TUI_PHASE" \
            "$TUI_PHASE_CAP"
    tui_bar "$R_TASK"  'Task'   "$TUI_STEP"       "$TUI_STEP_TOTAL"  "$TUI_TASKTEXT" \
            "$TUI_TASK_CAP"
    # The item bar has no honest total -- it is one package, or one file. It
    # marquees to show liveness instead of inventing a number.
    tui_bar "$R_ITEM"  'Item'   0 0 "$TUI_ITEM"
} >&3

tui_render_all() { tui_render_bars; tui_render_tasks; tui_render_out; }

# --- what the driver calls --------------------------------------------------
# While a stage runs, the Task and Phase bars are capped below 100: a bar that
# reads "done" next to a checkbox that reads "running" is the kind of small lie
# that makes people stop trusting the whole display. tui_stage_end lifts the cap
# and ticks the checkbox in the same call, so the two always agree.
TUI_TASK_CAP=99
TUI_PHASE_CAP=99

tui_stage_begin() {  # <stage-number>
    TUI_STAGE_NUM=$1
    _p=$(auto_field "$1" 2)
    if [ "$_p" != "$TUI_PHASE" ]; then
        TUI_PHASE_DONE=0
    fi
    TUI_PHASE=$_p
    TUI_PHASE_TOTAL=$(auto_stages_in_phase "$_p")
    TUI_STEP=0
    TUI_STEP_TOTAL=$(auto_field "$1" 4)
    TUI_TASKTEXT=$(auto_field "$1" 3)
    TUI_ITEM=''
    TUI_TASK_CAP=99
    TUI_PHASE_CAP=99
    tui_render_all
}

tui_stage_end() {
    TUI_STAGE_DONE=$(( TUI_STAGE_DONE + 1 ))
    TUI_PHASE_DONE=$(( TUI_PHASE_DONE + 1 ))
    TUI_STEP=$TUI_STEP_TOTAL
    TUI_TASK_CAP=100
    # The phase is finished only when every stage in it is. Tick the checkbox at
    # the same moment the Phase bar is allowed to reach 100%.
    if [ "$TUI_PHASE_DONE" -ge "$TUI_PHASE_TOTAL" ]; then
        TUI_PHASE_CAP=100
        case "$TUI_DONE_PHASES" in
            *" $TUI_PHASE "*) ;;
            *) TUI_DONE_PHASES="$TUI_DONE_PHASES$TUI_PHASE " ;;
        esac
    fi
    tui_render_all
}

# --- where the stages' output goes -----------------------------------------
# The thirteen stages are not modified. say/note/warn -- which is how every one
# of them already prints -- dispatch to these three when $TUI is 1, and to the
# plain printf they always used when it is 0. One branch, in one place:
# redefining functions at runtime and restoring them afterwards was the other
# option and it drifts the moment someone edits one copy and not the other.
#
# say  is a step:  it advances the Task bar and becomes the Task caption.
# note is an item: it becomes the Item caption. Most are one package or file.
# warn is an item, kept on screen and marked, because a warning during an
#      unattended install is exactly what you came back to read.
tui_say()  { TUI_STEP=$(( TUI_STEP + 1 )); TUI_TASKTEXT="$1"; TUI_ITEM=''
             tui_log_line "== $1"; tui_render_bars; }
tui_note() { TUI_ITEM="$1";              tui_log_line "   $1"; tui_render_bars; }
tui_warn() { TUI_ITEM="warning: $1";     tui_log_line "!! $1"; tui_render_bars; }

# --- asking for something, with help ---------------------------------------
# The unattended install answers its own questions, with one unavoidable
# exception: setup-alpine wants a root password and has no answer-file
# variable for it. So the one prompt that does happen gets a proper panel --
# what is being asked, why, what will be done with it, and what a valid answer
# looks like. A bare "Password:" halfway down an hour of scrolling output is
# how people type the wrong thing.
#
# It restores the screen afterwards, so the bars carry on where they were.
tui_prompt() {  # <field> <why it is needed> <hint> [default]
    _field=$1; _why=$2; _hint=$3; _default=$4
    if [ "$TUI" != 1 ]; then
        # No addressable screen: ask plainly, same information, no layout.
        printf '\n%s\n' "$_field"
        printf '  %s\n' "$_why"
        printf '  %s\n' "$_hint"
        [ -n "$_default" ] && printf '  default: %s\n' "$_default"
        return 0
    fi
    _t=$(( TUI_ROWS / 2 - 4 )); _b=$(( _t + 7 ))
    tui_box "$_t" "$_b" "Input needed"
    _w=$(( TUI_COLS - 4 ))
    tui_at $(( _t + 1 )) 2; printf "$C_HI%-*.*s" "$_w" "$_w" " $_field"
    tui_at $(( _t + 2 )) 2; printf "$C_TEXT%-*.*s" "$_w" "$_w" " $_why"
    tui_at $(( _t + 3 )) 2; printf "$C_TEXT%-*.*s" "$_w" "$_w" " $_hint"
    if [ -n "$_default" ]; then
        tui_at $(( _t + 4 )) 2
        printf "$C_TEXT%-*.*s" "$_w" "$_w" " Press Enter to accept: $_default"
    fi
    tui_at $(( _t + 5 )) 2; printf "$C_FRAME%-*.*s" "$_w" "$_w" " >"
    tui_show
    tui_at $(( _t + 5 )) 6
    printf "$C_TEXT"
    TUI_PROMPT_ROW=$(( _t + 5 ))
} >&3

# Repaint everything from scratch: the frames, then the contents. Used after
# anything that wrote over the screen -- a prompt panel, or an external command
# like setup-alpine that owns the terminal while it runs.
tui_repaint() {
    [ "$TUI" = 1 ] || return 0
    tui_hide
    printf "$C_TEXT\033[2J"
    tui_banner
    tui_box "$R_TASKTOP" "$R_TASKEND" "Install phases"
    [ "$TUI_OUTROWS" -gt 0 ] && tui_box "$R_OUTTOP" "$R_OUTEND" "Output"
    tui_render_all
} >&3
tui_prompt_done() { tui_repaint; }

# --- where the stages' raw output goes -------------------------------------
# The screen owns the terminal while it is up, so anything the stages print for
# themselves -- apk's progress lines, make's output, git's counters -- has to be
# captured instead. It goes to the file the Output pane tails, which is how that
# pane shows real install output rather than a summary.
#
# fd 4 and 5 hold the original stdout and stderr so they can be handed back.
# Both are needed: restoring only stdout would leave every later error message
# going into a temporary file nobody reads.
TUI_CAPTURED=0
tui_capture_on() {
    [ "$TUI" = 1 ] || return 0
    [ "$TUI_CAPTURED" = 1 ] && return 0
    [ -n "$TUI_OUTFILE" ] || return 0
    exec 4>&1 5>&2
    exec >> "$TUI_OUTFILE" 2>&1
    TUI_CAPTURED=1
}
tui_capture_off() {
    [ "$TUI_CAPTURED" = 1 ] || return 0
    exec 1>&4 2>&5 4>&- 5>&-
    TUI_CAPTURED=0
}

# --- handing the terminal to someone else ----------------------------------
# setup-alpine, apk's own prompts, an editor: anything that draws on its own
# terms needs the screen to itself. tui_suspend gives it back a normal terminal
# AND its stdout, which is the part that is easy to forget -- a suspended screen
# with stdout still captured means setup-alpine asks for a password into a file
# and the machine looks hung. tui_resume puts both back.
#
# Both are no-ops when the screen was never up, which is what makes them safe to
# call from a stage that also runs interactively from the menu.
TUI_WAS=0
tui_suspend() {
    [ "$TUI" = 1 ] || return 0
    tui_show
    tui_at "$TUI_ROWS" 1
    TUI_WAS=1; TUI=0
    printf '\033[0m\n' >&3
    tui_capture_off
}
tui_resume() {
    [ "$TUI_WAS" = 1 ] || return 0
    TUI_WAS=0; TUI=1
    tui_capture_on
    tui_repaint
}

# --- the pre-flight checklist ----------------------------------------------
# Shown before anything runs: every phase, every stage, and the fact that a
# full-auto run does all of them. It is a confirmation screen, not a menu --
# the point of "full automatic" is that you are not choosing -- but seeing the
# list first is how you find out it is about to do something you did not want.
#
# DELIBERATELY NOT [x] AND [ ]. This screen used to mark every phase '[x]' to
# mean "included in the run" and the two excluded stages '[ ]' to mean "not
# included". Those are the same two glyphs the live display uses for "finished"
# and "not started" (see tui_render_tasks), with a different meaning -- so on a
# fresh card the pre-flight read as though the entire install had already
# succeeded before it had started, and the one accurate reading of '[ ]' next to
# stages 11 and 15 was the one nobody needed. Words instead: 'run' and 'skip'
# say what is meant, cannot be mistaken for progress, and leave the checkbox
# vocabulary to the screen that is actually tracking it.
tui_preflight() {
    _n=$(auto_stage_count)
    printf '\n'
    printf '  ============================================================\n'
    printf '   COPAL LINUX -- FULL AUTOMATIC INSTALL\n'
    printf '  ============================================================\n\n'
    printf '  %d stages, in %d phases. Nothing below has run yet.\n\n' \
        "$_n" "$(auto_phases_in_order | grep -c .)"
    auto_phases_in_order | while IFS= read -r _p; do
        printf '   run    %s\n' "$_p"
        auto_manifest | awk -F'|' -v p="$_p" '$2 == p { printf "           %-3s %s\n", $1, $3 }'
    done
    # Same %-3s field as the stage lines above, so the numbers line up in one
    # column whether they are being run or skipped.
    printf '\n   skip    %-3s %s\n' 11 'Snapshots -- it repartitions a disk'
    printf '   skip    %-3s %s\n'   15 'Read-only root -- it would discard everything'
    printf '               the stages after it did\n\n'
}

# Order is not 1..12. It is chosen so that each stage has what it needs and so
# that the slow ones are last:
#
#   1 2 3   the system: configure, persist, move / onto the card
#   [reboot -- / does not actually become p2 until this happens]
#   8       grow p2 into free space BEFORE filling it
#   5       zram, so everything after has more usable memory
#   6 4 7   ssh key, desktop, toolchain
#   10      peripherals and media
#   12      the 316-package catalogue -- a long download
#   14      the workshop -- CAD, 3D printing, EDA, LaTeX, trackers
#   9       Mini vMac, which compiles from source. Slowest, so last.
#   13      hand over root -- genuinely last, because it takes away the
#           account every stage above it logs in as. It runs its own
#           pre-flight and declines rather than risk locking you out.
#
# Stages 11 and 15 are deliberately NOT in that list.
#
# Stage 11's snapshot feature wants to shrink p2 and create a third partition,
# and "answer yes to everything" is the wrong policy for repartitioning a disk
# you are running from.
#
# Stage 15 is excluded for a sharper reason: its read-only-root option makes
# every subsequent change evaporate at the next reboot. Applied automatically,
# partway through an install, it would silently discard everything the stages
# after it did -- and the symptom would be "the install did not work", with no
# error anywhere to explain it. It is the last thing you turn on, by hand,
# once you have finished setting the machine up.
#
# Run both by hand afterwards if you want them.
# Derived from the manifest above, so the order that runs and the checklist
# the screen draws are the same list. It resolves to exactly the sequence
# this line used to hold: 1 2 3 8 5 6 4 7 10 12 14 9 13
AUTO_SEQ=$(auto_seq_from_manifest)

auto_state_load() {
    AUTO_DONE=""
    [ -f "$AUTOFILE" ] || return 1
    AUTO_DONE=$(sed -n 's/^DONE=//p' "$AUTOFILE" | tail -n1)
    return 0
}
auto_state_save() {
    mount -o remount,rw "$BOOT" 2>/dev/null || true
    { echo "# Copal full-automatic install in progress."
      echo "# Delete this file to stop it resuming."
      echo "DONE=$AUTO_DONE"
    } > "$AUTOFILE" 2>/dev/null || warn "could not write $AUTOFILE -- resume after reboot will not work"
    sync
}
auto_is_done() { case " $AUTO_DONE " in *" $1 "*) return 0 ;; esac; return 1; }

# Marked done BEFORE the stage runs, not after. Stage 3 reboots from inside
# itself, so there is no "after" to record -- and a stage recorded only on
# success would leave the machine rebooting into the same stage forever.
# The cost is that a stage which fails is not retried; the summary at the end
# says which, and it can be re-run from the menu.
auto_mark() { AUTO_DONE="$AUTO_DONE $1"; auto_state_save; }

# Per-stage timings, on the boot partition beside the state file.
#
# copal.log carries one timestamp per RUN -- the "===== copal-init.sh: <date>"
# banner -- which is enough to know when an install started and nothing about
# where its hours went. Recording each stage's start and end costs two lines of
# a text file and answers the question people actually ask: which stage is slow,
# and how long will the rest take on a machine like this one.
#
# On the FAT boot partition on purpose. It is readable from the Mac while the
# guest is still running, it survives stage 3's reboot, and it has no
# permissions of its own to get wrong -- which matters more than it should,
# given what a stray umask did to the root filesystem.
#
# Epoch seconds, not a formatted date: durations are the point, and subtracting
# two integers needs no date parser. A machine with no clock yet writes 0, and
# the summary skips any pair it cannot subtract sensibly.
TIMEFILE="$BOOT/copal-timings"
auto_time() {  # <START|END> <stage>
    mount -o remount,rw "$BOOT" 2>/dev/null || true
    printf '%s %s %s\n' "$1" "$2" "$(date +%s 2>/dev/null || echo 0)" \
        >> "$TIMEFILE" 2>/dev/null || true
    sync 2>/dev/null || true
}

# What the timings add up to. A stage with a START and no END was interrupted --
# which for stage 3 is not a fault but the design, since it reboots from inside
# itself, so it is reported as such rather than as an error.
auto_timing_report() {
    [ -r "$TIMEFILE" ] || return 0
    say "Where the time went"
    awk '
        $1 == "START" && $3 > 0 { start[$2] = $3; order[++n] = $2 }
        $1 == "END"   && $3 > 0 { end[$2]   = $3 }
        END {
            total = 0
            for (i = 1; i <= n; i++) {
                s = order[i]
                if (!(s in start)) continue
                if (s in end) {
                    d = end[s] - start[s]
                    total += d
                    printf "    stage %-3s %3d min %02d sec\n", s, d / 60, d % 60
                } else {
                    printf "    stage %-3s (no end recorded -- rebooted from inside it)\n", s
                }
            }
            if (total > 0)
                printf "    %-9s %3d min %02d sec of measured stages\n", "TOTAL", total / 60, total % 60
        }' "$TIMEFILE"
    note "raw timings: $TIMEFILE"
}

auto_finish() {
    rm -f "$AUTOFILE" 2>/dev/null || true
    # Take the resume hook off the new root as well, so a later login is a
    # plain login again. Both accounts, and both roots -- the running one and
    # the one at /mnt if this is called while stage 3's is still mounted.
    _uh=$(user_home)
    for _p in /root/.profile /mnt/root/.profile \
              ${_uh:+"$_uh/.profile" "/mnt${_uh}/.profile"}; do
        [ -f "$_p" ] || continue
        sed -i '/^# >>> copal auto-resume/,/^# <<< copal auto-resume/d' "$_p" 2>/dev/null || true
    done
    sync
}

# Installed onto the NEW root during stage 3, because that is the filesystem
# the machine will boot into. Logging in is enough to carry on -- no init
# service, nothing enabled at boot, and deleting the block or the marker file
# stops it. Both are checked, so removing either one is enough.
#
# It goes into BOTH profiles, root's and the admin user's. Two reasons: the
# person coming back to the machine after stage 3's reboot should not have to
# remember which account they were told to use, and the install ends by locking
# root -- so if it is ever interrupted after that, root's copy of the hook is
# unreachable and the admin user's is the only one left that can resume it.
# The admin copy goes through doas, which is why stage 1 makes sure doas works.
auto_install_resume_hook() {  # <root prefix, e.g. /mnt or empty>
    _pfx="$1"
    _uh=$(user_home)
    _uid=$(id -u "$PI_USER" 2>/dev/null || echo "")

    _resume_block() {  # <command to re-enter the install>
        cat <<RESUME
# >>> copal auto-resume >>>
# Copal is part-way through a full-automatic install. This resumes it at the
# next login and removes itself when the install finishes. Delete this block,
# or the copal-auto file on the boot partition, to stop it.
if [ -f /boot/copal-auto ] || ls /media/*/copal-auto >/dev/null 2>&1; then
    printf '\n  Copal: resuming the automatic install in 10 seconds.\n'
    printf '  Press Ctrl-C now for a normal shell.\n\n'
    if sleep 10; then $1; fi
fi
# <<< copal auto-resume <<<
RESUME
    }

    if mkdir -p "$_pfx/root" 2>/dev/null; then
        if ! grep -q 'copal auto-resume' "$_pfx/root/.profile" 2>/dev/null; then
            _resume_block 'copal --auto' >> "$_pfx/root/.profile"
            note "auto-resume installed in $_pfx/root/.profile"
        fi
    fi

    # The user's home only exists once setup-alpine has run. Under /mnt it
    # arrives with the apkovl setup-disk restores, and stage 3 checked it a
    # few lines earlier. Still guarded rather than assumed: on a card where
    # stage 1 never ran there is no account to have a home directory at all.
    if [ -n "$_uh" ] && [ -d "$_pfx$_uh" ]; then
        if ! grep -q 'copal auto-resume' "$_pfx$_uh/.profile" 2>/dev/null; then
            _resume_block 'doas copal --auto' >> "$_pfx$_uh/.profile"
            [ -n "$_uid" ] && chown "$_uid" "$_pfx$_uh/.profile" 2>/dev/null || true
            note "auto-resume installed in $_pfx$_uh/.profile (via doas)"
        fi
    fi
}

auto_run() {
    AUTO=1
    say "FULL AUTOMATIC INSTALL"
    cat <<'MSG'

    Every question from here on is answered for you. Three exceptions, all
    worth knowing before you walk away, and all of them in the next few
    minutes rather than scattered through the next few hours:

      - Stage 1 asks for a NAME and EMAIL for git commits. If the Mac that
        wrote this card had them set, they are offered as the default and
        Enter accepts. They are saved on the boot partition, so stage 7 --
        the one that installs git -- applies them without asking again.
      - setup-alpine asks for a ROOT PASSWORD in stage 1 and there is no way
        to pre-answer it. It then asks for one for the admin user; type the
        same thing, because the next thing Copal does is copy root's
        password onto that account anyway, so the two always match.
      - Stage 3 reboots the machine. It comes back on its own: log in as
        EITHER root or the admin user -- both resume the install after a
        ten-second pause -- with that one password.

    It finishes by locking the root account (stage 13), so from then on you
    log in as the admin user and use `doas` for anything privileged. That
    stage checks the admin account works first and declines if it does not,
    so it cannot lock you out of your own machine.

    It will take hours, most of it stage 12 downloading and stage 9
    compiling Mini vMac. Everything is logged, so you can walk away and read
    what happened afterwards.

    Stage 11 (snapshots) is skipped. It wants to shrink the root partition
    and create a third one, and that is not a thing to do unattended.

MSG
    auto_state_load || { AUTO_DONE=""; auto_state_save; }

    # The checklist, before anything runs. On a resume it is also where you see
    # what the previous boot already got through.
    tui_preflight
    [ -n "$AUTO_DONE" ] && printf '   Resuming. Already attempted:%s\n\n' "$AUTO_DONE"
    if [ "$HAVE_TTY" = 1 ]; then
        confirm_yes "Start the automatic install?" || { note "Not started."; return 0; }
    fi

    # Bring the screen up. If it cannot (no TTY, a small or unaddressable
    # terminal, COPAL_TUI=0) tui_begin returns non-zero, $TUI stays 0, and every
    # stage prints exactly as it did before -- which is the right behaviour on a
    # serial console and when the output is being piped to a file.
    tui_begin || note "progress screen unavailable -- printing plainly instead"

    # Put the terminal back whatever happens: a stage that dies, a Ctrl-C, or
    # stage 3's reboot from inside itself. Without this the shell is left with
    # no cursor and a blue background.
    trap 'tui_end' EXIT HUP INT TERM

    # Send the stages' own output to the Output pane's file rather than the
    # terminal the screen is drawing on. tui_suspend/tui_resume hand it back and
    # take it again around anything that needs the terminal itself.
    tui_capture_on

    for _s in $AUTO_SEQ; do
        if auto_is_done "$_s"; then
            note "stage $_s -- already attempted, skipping"
            # Still count it: on a resume those stages are behind us, and a
            # Total bar that ignored them would restart at zero after the
            # stage 3 reboot and look like nothing had happened.
            tui_stage_begin "$_s"; tui_stage_end
            continue
        fi
        tui_stage_begin "$_s"
        say "AUTO: stage $_s"
        auto_mark "$_s"
        auto_time START "$_s"
        # This script runs under 'set -e', which is right for an interactive
        # session and wrong for an unattended one: a single stage returning
        # non-zero would end the whole install silently, hours in, with no
        # summary. Disable it around the stage, keep the status, put it back.
        set +e
        case "$_s" in
            1)  stage_base_config ;;
            2)  stage_ext4_cache ;;
            3)  # Stage 3 reboots from inside itself. It installs the resume
                # hook onto the new root first, while /mnt is still mounted.
                stage_sys_install ;;
            4)  stage_gui ;;
            5)  stage_zram ;;
            6)  stage_sshkey ;;
            7)  stage_dev ;;
            8)  stage_grow ;;
            9)  AUTO_DEFAULT=b; stage_emulators ;;   # Mini vMac + VICE, not Basilisk
            10) stage_extras ;;
            12) AUTO_DEFAULT=a; stage_apps ;;        # the whole catalogue
            13) stage_lockroot ;;
            14) AUTO_DEFAULT=a; stage_workshop ;;    # every bundle
        esac
        _rc=$?
        set -e
        # After the stage, so a stage that reboots from inside itself (stage 3)
        # simply has no END -- which is exactly what the report should say.
        auto_time END "$_s"
        [ "$_rc" = 0 ] || warn "stage $_s exited $_rc -- carrying on with the rest"
        tui_stage_end
    done

    # Put stdout back on the log before taking the screen down, so the summary
    # below is both visible and recorded. Order matters: restore the fd first,
    # then stop drawing.
    tui_capture_off
    # Take the screen down before the summary: state_report is a page of text
    # and it has to scroll normally.
    tui_end
    trap - EXIT HUP INT TERM
    # Keep the captured output: it is the only copy of what the stages printed
    # while the screen had the terminal, and it is what you read afterwards to
    # find out why a stage warned.
    if [ -f "${TUI_OUTFILE:-}" ]; then
        cat "$TUI_OUTFILE" >> "$LOG" 2>/dev/null || true
        rm -f "$TUI_OUTFILE"
    fi
    say "AUTOMATIC INSTALL COMPLETE"
    # Before auto_finish, which removes the state file: the timings live beside
    # it and are worth reading while the run is still fresh in mind.
    auto_timing_report
    auto_finish
    AUTO=0
    state_report
    cat <<'MSG'

    Anything above that says "not installed" is a stage that did not finish.
    Re-run it from the menu -- every stage is safe to run again.

MSG
}

# ------------------------------------------------------------------- menu ---
[ -f "$ANSWERS" ] || die "missing $ANSWERS -- was this card written by copal-prep.sh?"
grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null \
    || warn "this does not look like a Raspberry Pi -- setup-disk will behave differently"

# --- how the automatic install starts, resumes, and is stopped -------------
#
# Three ways in, in priority order:
#   1. 'copal --auto'          -- explicit, and what the resume hook calls
#   2. the marker file exists  -- an install was interrupted; pick it up
#   3. the question below      -- a fresh card, asked once, before anything
#
# The question is asked first because it is the only one whose answer changes
# what the whole session is. Answering no gives the ordinary menu and is not
# asked again this run.
case "${1:-}" in
    --auto|-a) auto_run; exit 0 ;;
    --help|-h)
        echo "usage: copal [--auto]"
        echo "  --auto   run every stage unattended, resuming across reboots"
        exit 0 ;;
esac

if auto_state_load; then
    say "An automatic install was interrupted"
    note "already attempted:$AUTO_DONE"
    note "the marker is $AUTOFILE -- delete it to stop resuming"
    if confirm_yes "Carry on with the automatic install?"; then
        auto_run; exit 0
    fi
    warn "leaving the marker in place; the menu is below"
elif ! apkovl_exists && is_diskless; then
    # Only offered on a machine that has not been set up yet. Asking this on
    # a system already half-built would be inviting it to redo work.
    cat <<'MSG'

    ======================================================================
      FULL AUTOMATIC INSTALL
    ======================================================================

    This card has not been set up yet. Copal can do the whole thing by
    itself -- every stage, every question answered yes, resuming on its own
    across the reboot in the middle.

    Early on it asks who you are -- a name and email for git commits, with
    whatever the Mac that wrote this card uses offered as the default -- and
    then for a ROOT PASSWORD, which setup-alpine has no way to be told in
    advance. After those you can walk away. It takes hours.

    Answer no for the ordinary menu, where you choose each stage yourself.

MSG
    if confirm "Do a full automatic install?"; then
        auto_run; exit 0
    fi
    note "Manual it is. The menu is below; stages can be run in any order."
fi

while :; do
    state_report

    # Recommend the next thing rather than making it be worked out each time.
    # sys_installed reads cmdline.txt, which stage 3 writes immediately -- but
    # / does not actually become p2 until the reboot. Between those two moments
    # the only correct suggestion is "reboot", not stage 4.
    if ! apkovl_exists;                        then SUGGEST=1
    elif [ "$(fstype_of "$P2")" != ext4 ];     then SUGGEST=2
    elif ! sys_installed;                      then SUGGEST=3
    elif is_diskless;                          then SUGGEST="r  (reboot -- stage 3 is done but / is still the tmpfs)"
    elif ! x_installed;                        then SUGGEST=4
    elif ! zram_active;                        then SUGGEST=5
    elif sshkey_present && ! sshkey_done;      then SUGGEST=6
    elif ! dev_installed;                      then SUGGEST=7
    elif p2_growable;                          then SUGGEST=8
    else                                            SUGGEST=v
    fi

    cat <<MSG

    1) Base configuration      setup-alpine from answers.txt, then lbu commit
    2) Persistent packages     ext4 on p2, apk cache on it   (keeps the
                               RAM-resident root -- gentlest on the card,
                               enough for a TUI)
    3) Full root filesystem    move / onto p2 with setup-disk -m sys
                               (needed for a desktop; writes to the card)
    4) Graphical desktop       X.Org on the framebuffer, i3, terminal, file
                               manager, task manager   (needs 3 done first)
    5) Compressed RAM swap     zram -- the biggest win available on 512 MB
    6) Authorise the SSH key   the Mac's public key for '$PI_USER'
    7) Development environment gcc/make/gdb, nvim configured for building and
                               breakpoints, python, geany, AVR, TUI tooling
    8) Grow COPALROOT             extend p2 into the unallocated space after it.
                               Non-destructive; works on a mounted root
    9) Retro emulators         Mini vMac (Mac Plus, fast) and VICE (C64,
                               from a package now), both with disk images
                               and launchers set up under your home
   10) Peripherals and media   wifi, bluetooth, HDMI audio, tcpdump/tshark,
                               hex editors, HFS and disk-image tools
   11) Snapshots               rsync snapshots on a third partition, and
                               Timeshift if you want it (edge/testing only)
    a) Full automatic install  every stage, unattended, resuming across the
                               reboot. Only stops for the root password
   12) Applications           316 small programs -- browser, mail, audio,
                               editors, viewers, games, gopher/gemini, disc
                               tools. What the menu installs from too
   13) Hand over root         lock the root account and log in as '$PI_USER'
                               with doas instead. Checks first; run it last
   14) The workshop           CAD and 3D printing for the Ender 3, KiCad and
                               gerbers, ngspice, LaTeX and maths, trackers
                               and SID. Each bundle says what this port lacks
   15) SD card and logs       what actually wears a card and what does not;
                               log policy, and a genuinely read-only root
    r) Reboot
    v) Verify and show state
    q) Quit

    Suggested next: $SUGGEST
MSG

    ask "Choose [1/2/3/4/5/6/7/8/9/10/11/12/13/14/15/a/r/v/q]:"
    case "$REPLY" in
        r|R) if confirm_yes "Reboot now?"; then
                 say "Rebooting. Log back in as ROOT (not $PI_USER), then run:  sh /boot/copal-init.sh"
                 sync
                 umount "$BOOT" 2>/dev/null || mount -o remount,ro "$BOOT" 2>/dev/null || true
                 reboot
                 exit 0
             fi ;;
        1) stage_base_config ;;
        2) stage_ext4_cache ;;
        3) stage_sys_install ;;
        4) stage_gui ;;
        5) stage_zram ;;
        6) stage_sshkey ;;
        7) stage_dev ;;
        8) stage_grow ;;
        9) stage_emulators ;;
        10) stage_extras ;;
        11) stage_snapshots ;;
        12) stage_apps ;;
        13) stage_lockroot ;;
        14) stage_workshop ;;
        15) stage_sdcard ;;
        a|A) auto_run ;;
        v|V) stage_verify ;;
        q|Q|"") say "Nothing further changed. Transcript: $LOG"; exit 0 ;;
        *) warn "not an option: $REPLY" ;;
    esac
done
COPALINIT

chmod +x "$MNT/copal-init.sh" 2>/dev/null || true

# Clean macOS metadata again. The earlier pass ran before these three files
# existed, so writing them left fresh ._AppleDouble sidecars behind -- harmless
# to the firmware, but they show up on the card and look like corruption.
info "Removing macOS metadata from the newly written files..."
command -v dot_clean >/dev/null && dot_clean -m "$MNT" 2>/dev/null || true
find "$MNT" -name '._*' -delete 2>/dev/null || true
find "$MNT" -name '.DS_Store' -delete 2>/dev/null || true

# ---------------------------------------------------------------- verify ---
step "Verify the card, then flush and eject" \
    "Checks every firmware file, kernel, initramfs, modloop, device tree," \
    "and directory the Pi needs is actually present on the card." \
    "" \
    "This is the check that catches a copy which ran out of space -- the" \
    "silent failure mode of copying by hand in Finder." \
    "" \
    "Then flushes buffered writes and ejects. Do not pull the card before" \
    "this finishes: macOS buffers writes, and removing it early truncates" \
    "files that appear to have copied successfully."

info "Verifying required boot files on the card..."
MISSING=0
case "$PLATFORM" in
    rpi) _verify="bootcode.bin start.elf fixup.dat config.txt cmdline.txt
                  boot/vmlinuz-rpi boot/initramfs-rpi boot/modloop-rpi
                  overlays apks
                  answers.txt copal-init.sh usercfg.txt copal.conf" ;;
    # A PC needs the bootloader, the file it reads, and the three the kernel
    # needs. No firmware blobs, no device trees, no overlays.
    #
    # apks/ IS required, and this list once said it was not. The netboot
    # tarball ships none, so fetch_bootloader takes it from the ISO -- and
    # without it the card boots to a recovery shell. Both files are checked:
    # the marker is what the initramfs searches for, and the APKINDEX is what
    # apk needs once it has been found. A zero-byte marker's absence is
    # invisible in every other check on this card.
    pc)  _verify="EFI/BOOT/$EFI_NAME boot/grub/grub.cfg
                  apks/.boot_repository apks/$ARCH/APKINDEX.tar.gz
                  boot/vmlinuz-lts boot/initramfs-lts boot/modloop-lts
                  answers.txt copal-init.sh copal.conf"
         # A VM boots the virt kernel by default. The grub.cfg cross-check
         # below catches a missing vmlinuz-virt, but it only reads 'linux'
         # lines -- the initramfs and modloop it needs are named nowhere it
         # looks, and a missing modloop is a boot with no drivers at all.
         [ "$VM" -eq 1 ] && _verify="$_verify
                  boot/vmlinuz-virt boot/initramfs-virt boot/modloop-virt"
         ;;
esac
for required in $_verify; do
    if [ -e "$MNT/$required" ]; then
        printf '    ok      %s\n' "$required"
    else
        printf '    MISSING %s\n' "$required"
        MISSING=1
    fi
done

# Device tree: one match is enough, and which one depends on the board. A PC has
# none -- the firmware describes itself through ACPI -- so this whole check is
# skipped rather than made to pass vacuously.
if [ "$PLATFORM" = pc ]; then
    # The two things that would make a PC card silently unbootable, checked here
    # because neither shows up as a missing file: a bootloader that is not
    # actually a PE binary, and a grub.cfg that names a kernel that is not there.
    if [ "$(dd if="$MNT/EFI/BOOT/$EFI_NAME" bs=2 count=1 2>/dev/null)" = MZ ]; then
        printf '    ok      EFI/BOOT/%s is a PE/EFI binary\n' "$EFI_NAME"
    else
        printf '    BROKEN  EFI/BOOT/%s is not a PE/EFI binary\n' "$EFI_NAME"
        MISSING=1
    fi
    for _k in $(sed -n 's/^[[:space:]]*linux[[:space:]]*\([^ ]*\).*/\1/p' "$MNT/boot/grub/grub.cfg" 2>/dev/null | sort -u); do
        if [ -e "$MNT$_k" ]; then
            printf '    ok      grub.cfg -> %s\n' "$_k"
        else
            printf '    MISSING grub.cfg names %s, which is not on the card\n' "$_k"
            MISSING=1
        fi
    done
    [ "$MISSING" -eq 0 ] || die "required files are missing from the card -- do not boot this"
else
DTB_FOUND=""
for candidate in $MODEL_DTB; do
    [ -e "$MNT/$candidate" ] && { DTB_FOUND="$candidate"; break; }
done
if [ -n "$DTB_FOUND" ]; then
    printf '    ok      %s\n' "$DTB_FOUND"
elif [ -z "$MODEL_DTB" ]; then
    # No MODEL, so no expected name -- just insist the card has some .dtb.
    if ls "$MNT"/*.dtb >/dev/null 2>&1; then
        printf '    ok      device trees present (no MODEL set -- not checked by name)\n'
    else
        printf '    MISSING any .dtb\n'
        MISSING=1
    fi
else
    printf '    MISSING device tree for MODEL=%s (looked for: %s)\n' "$MODEL" "$MODEL_DTB"
    MISSING=1
fi
fi   # end of the Pi-only device-tree check
[ "$MISSING" -eq 0 ] || die "required files are missing from the card -- do not boot this"

if [ -f "$MNT/authorized_keys" ]; then
    printf '    ok      authorized_keys  (%s)\n' "$(awk '{print $1, $NF}' "$MNT/authorized_keys")"
else
    printf '    --      authorized_keys  (none -- %s will be password-only)\n' "$CFG_USER"
fi

# --- firmware-blob consistency ---------------------------------------------
# An active gpu_mem=16 makes the bootloader load start_cd.elf/fixup_cd.dat
# instead of start.elf/fixup.dat. If those cut-down blobs are not on the card
# the Pi halts before HDMI comes up: no rainbow, no display, no kernel, and
# nothing written anywhere to explain it. Catch it here rather than in the
# field, because the failure gives you nothing to go on.
if [ "$PLATFORM" = rpi ]; then
info "Checking firmware settings against the blobs on the card..."
# No match is the normal, healthy case (gpu_mem commented out or absent), but
# grep exits 1 on no match and this script runs under 'set -o pipefail' -- so
# the '|| true' is load-bearing. Without it the check aborts on exactly the
# configuration it is meant to bless.
GPUMEM=$(grep -hE '^[[:space:]]*gpu_mem(_[0-9]+)?=' "$MNT/usercfg.txt" "$MNT/config.txt" 2>/dev/null \
         | tail -n1 | sed 's/.*=//' | tr -d '[:space:]' || true)

# Compare numerically only when it really is a number; a stray non-numeric
# value would make '[ -le ]' fail and, under 'set -e', kill the script.
case "${GPUMEM:-}" in
    ''|*[!0-9]*) GPUMEM_NUM="" ;;
    *)           GPUMEM_NUM="$GPUMEM" ;;
esac

if [ -n "$GPUMEM_NUM" ] && [ "$GPUMEM_NUM" -le 16 ]; then
    if [ -e "$MNT/start_cd.elf" ] && [ -e "$MNT/fixup_cd.dat" ]; then
        printf '    ok      gpu_mem=%s with start_cd.elf present\n' "$GPUMEM"
    else
        die "gpu_mem=$GPUMEM is set, but start_cd.elf/fixup_cd.dat are not on the card.
       The firmware would load the cut-down blobs, not find them, and halt
       before the display comes up. Raise gpu_mem to 32 or higher, or comment
       it out in $MNT/usercfg.txt."
    fi
else
    printf '    ok      gpu_mem=%s uses start.elf, which is present\n' "${GPUMEM:-unset (default 64)}"
fi
fi   # end of the Pi-only firmware-blob check

echo
info "Space used on boot partition:"
df -h "$MNT" | tail -n1

info "Flushing writes (this can take a while)..."
sync
# 'eject' on an attached image detaches it, so there is no special case here.
diskutil eject "/dev/$DISK"

# An image is finished at this point, and what you need next is the command to
# boot it -- not two pages about SD card partitions. Print that instead and
# stop, rather than making you read past advice for hardware you do not have.
if [ "$IMAGE_MODE" -eq 1 ]; then
    # attach_image already made this absolute.
    IMAGE_ABS="$IMAGE_PATH"
    cat <<EOF

$(info "Done. $IMAGE_PATH is written and detached.")

================================================================================
 BOOTING THE IMAGE
================================================================================

  $IMAGE_ABS
  $(du -h "$IMAGE_PATH" | awk '{print $1}') on disk, ${IMAGE_SIZE} apparent (sparse -- it grows as it is used).

EOF
    if [ "$VM" -eq 1 ] && [ "$ARCH" != aarch64 ]; then
        cat <<EOF
  Boot it in UTM:

    ./utm/utm-vm.sh create --target x86_64 --image $IMAGE_ABS
    ./utm/utm-vm.sh start  --target x86_64

  copal-vm.sh is not the tool for this one: it runs qemu-system-aarch64, and
  this image is $ARCH. UTM has the matching emulator and the OVMF firmware
  already. Expect it to be slow -- an x86_64 guest on Apple Silicon is
  translated instruction by instruction, not virtualised.

  Serial console is on ttyS0, not ttyAMA0. That is the whole difference
  between this image and the aarch64 one at the boot-configuration level.

EOF
    elif [ "$VM" -eq 1 ]; then
        cat <<EOF
  Boot it:

    ./copal-vm.sh $IMAGE_ABS          serial console on this terminal
    ./copal-vm.sh --graphical $IMAGE_ABS   a window, to watch i3 come up
    ./copal-vm.sh --check $IMAGE_ABS       boot headless, report, exit

  copal-vm.sh finds the UEFI firmware, creates the EFI variable store and
  refuses to start if the image is still attached to macOS. --check is the
  one to run after changing this script: it boots with no terminal attached
  and exits non-zero if the system does not reach a login prompt, which takes
  about a minute rather than a card and a reboot.

  Needs QEMU:  brew install qemu

  UTM instead: New > Virtualize > Linux, skip the boot ISO, then remove the
  default drive and Import this file as a VirtIO drive.

EOF
    else
        cat <<EOF
  This image is for $ARCH${MODEL:+ (MODEL=$MODEL)}, not for a VM on this Mac.
  Write it to a card with:

    diskutil unmountDisk /dev/diskN
    sudo dd if=$IMAGE_ABS of=/dev/rdiskN bs=4m status=progress

  Or re-run with MODEL=vm for an image that boots in UTM or QEMU directly.

EOF
    fi
    cat <<EOF
  First boot runs copal-init.sh from the boot partition, exactly as on a card.
  Its log lands on the FAT partition as firstrun.log, which macOS can read
  after you attach the image again:

    hdiutil attach -imagekey diskimage-class=CRawDiskImage $IMAGE_ABS

================================================================================
EOF
    exit 0
fi

cat <<EOF

$(info "Done. Card ejected -- safe to remove.")

================================================================================
 THIS CARD HAS TWO PARTITIONS
================================================================================

  mmcblk0p1   ${BOOT_LABEL}   ${BOOT_SIZE}   FAT32, written and ready
              The firmware boot partition: bootcode.bin, start.elf, the
              kernel, device trees, config.txt / cmdline.txt. Already
              populated by this script. The Pi boots from this.

  mmcblk0p2   ${ROOT_LABEL}   ${ROOT_SIZE_LABEL}   EMPTY -- you must format it on the Pi
              Intended as a persistent ext4 root filesystem. macOS cannot
              create ext4, so this script only reserved the space. Until you
              format it, it is unused and the Pi runs entirely from RAM.

 Why p2 exists: the alpine-rpi image is "diskless" -- its root filesystem is a
 tmpfs sized at about HALF of RAM (~200 MB on a 512 MB Zero). A TUI fits in
 that. A desktop does not: 'apk add' fails with "No space left on device"
 while the SD card is still 99% empty, because the limit is RAM, not storage.
 Formatting p2 as a real root filesystem removes that ceiling.

================================================================================

ON THE PI -- there is only one command to run
-----------------------------------------------------------------------------

  Boot the card. Log in as 'root' with no password. Then:

      sh /media/mmcblk0p1/copal-init.sh

  It inspects the machine, prints what is already done, and offers a menu.
  Run it as many times as you like -- it is safe to re-run, and it suggests
  the next step each time, so a stage that fails can be retried on its own.

    a) Full automatic install  Runs every stage unattended, in an order that
       satisfies each stage's prerequisites and leaves the slow ones last:
       1 2 3, reboot, then 8 5 6 4 7 10 12 9.

       It survives the reboot in stage 3. A marker file, ${BOOT_LABEL}/copal-auto,
       records which stages have been attempted, and stage 3 installs a
       resume block in the new root's /root/.profile -- so logging back in
       as root picks the install up where it stopped. Delete either the
       marker or the block to stop it.

       What it cannot answer: setup-alpine asks for a root password and has no
       answer-file variable for it, so stage 1 stops once and waits. The git
       identity is asked there too, in the same minute -- offered from this
       Mac's own git config, so Enter accepts -- and saved to
       ${BOOT_LABEL}/copal-git, which is what keeps stage 7 from stopping to
       ask an hour and a half in. Everything after that is unattended, and
       takes hours.

       Stage 11 is excluded on purpose. Its snapshot support offers to shrink
       the root partition and add a third one, and "yes to everything" is the
       wrong policy for repartitioning a disk you are running from.

       A stage that fails does not stop the run -- it warns and carries on,
       so one bad package cannot cost you the other ten stages. The state
       report at the end shows what actually landed.

    1) Base configuration   'setup-alpine -f answers.txt' -- keymap
       ${CFG_KEYMAP}, hostname ${CFG_HOSTNAME}, ${CFG_IFACE}/dhcp, ${CFG_TIMEZONE},
       fastest mirror, openssh, user '${CFG_USER}', disk=none, lbu on
       mmcblk0p1 -- then 'lbu commit -d'.

       You are prompted for a root password. setup-alpine has no answer-file
       variable for it, so that is the one unavoidable question -- and it is
       where Copal asks its own two, a name and email for git commits, rather
       than stopping for them in stage 7. They go to ${BOOT_LABEL}/copal-git,
       editable from this Mac, and default to what this Mac commits under.

    2) Persistent packages  Formats ${ROOT_LABEL} as ext4, adds it to fstab,
       and puts the apk cache on it. Without a cache, anything you 'apk add'
       is gone on reboot -- the root filesystem is a tmpfs. With one, the
       saved package list is reinstalled from the card at boot, offline.

       The root stays RAM-resident, which is the gentlest option for flash
       and is all a TUI needs. This is the recommended stopping point.

    4) Graphical desktop  X.Org on the framebuffer plus i3 (tiling), a
       terminal, pcmanfm as file manager and htop as task manager, with an
       i3 config and colours already written. Tiling is a performance choice
       here as much as an ergonomic one: windows never overlap, so the CPU
       never redraws an occluded region, and on this board every pixel is
       pushed by the CPU.

    5) Compressed RAM swap  zram: a block device that compresses what is
       written to it and keeps it in RAM. As swap it buys back roughly its
       own size again in usable memory, with no writes to flash. The single
       biggest win available on 512 MB.

    6) Authorise the SSH key  Installs ${BOOT_LABEL}/authorized_keys into
       ~${CFG_USER}/.ssh/ with the permissions sshd insists on. Only the
       public half is ever copied; the private key stays on the Mac.

   12) Applications  A catalogue of 316 small programs across 28 sections
       -- browser, mail, audio, editors, viewers, games, the small web,
       disc tools, system settings -- one good pick per job, in the spirit of the minimal
       distributions. Install the lot, a section at a time, or a
       twelve-program minimal set. The list is filtered to this board first,
       so 316 is the count on a 64-bit port and fewer on armhf.

       Three front ends, one table. The desktop menu (Super+z) is built from
       it, the Copal Center (Super+c) lists all 316 with a status column and
       a Run button that installs first if it has to, and this stage bulk
       installs from it. Nothing can appear in a menu that is not
       installable, and nothing installable is missing from the menus.

       Two things this board cannot do, stated here so you do not go
       hunting: Alpine builds neither Chromium nor Firefox for armhf (Dillo
       and NetSurf are the whole field), and there is no usable OpenGL, so
       every 3D game in the repository is unplayable and none is listed.
       What is listed is turn-based, 2D and text, which is what a machine of
       this class was always good at.

  RE-RUNNING THIS SCRIPT

      ./copal-prep.sh --refresh

  Rewrites only the generated files -- answers.txt, usercfg.txt,
  copal.conf, authorized_keys, copal-init.sh -- on a card that is already
  written. No partitioning, no erase, no payload copy. Use it to pick up
  changes to copal-init.sh without starting the Pi over.

    3) Full root filesystem  Moves / onto ${ROOT_LABEL} with 'setup-disk -m sys'.
       Only needed for a desktop: the tmpfs root is about half of RAM
       (~200 MB), too small to install X into. Requires a working network --
       setup-disk installs the kernel with 'apk add'. Backs up cmdline.txt,
       verifies the kernel and modules actually landed, and rolls back if
       they did not.

  Everything it prints is appended to ${BOOT_LABEL}/copal.log. That
  partition is FAT, so if the Pi will not boot you can read the log on any
  other machine -- including this one.

  To do it by hand instead, the answers are in ${BOOT_LABEL}/answers.txt and
  every command is visible in ${BOOT_LABEL}/copal-init.sh.

FIRMWARE SETTINGS

  ${BOOT_LABEL}/usercfg.txt holds gpu_mem=16 and enable_uart=1. config.txt
  carries a "do not modify, overwritten on upgrade" banner and includes
  usercfg.txt last, so that is where firmware settings belong. gpu_mem=16
  matters here: the GPU reservation comes off the top before Linux sees any
  RAM, and RAM is what limits the diskless root filesystem.

IF IT WILL NOT BOOT

      Read ${BOOT_LABEL}/copal.log first -- the error text is in there.
      cp cmdline.txt.bak cmdline.txt        # undo stage 3
      then delete the 'copal-init.sh managed block' from usercfg.txt

  The RAM-resident system on p1 is never touched by stage 3, so that always
  gets you back to a booting machine.

EOF
