#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 paulr@sdf.org
#
#  COPAL ALPINE LINUX -- wrap a prepared image in a UTM virtual machine.
#
# copal-prep.sh writes a disk image. copal-vm.sh boots one under plain QEMU.
# This makes one into a UTM VM instead -- a registered machine with a name, an
# icon, NAT networking, a forwarded SSH port and a shared folder, that starts
# from the UTM window or from utmctl.
#
# WHY BOTH, and which to use:
#
#   copal-vm.sh   Automated verification. Boots headless with the serial
#                 console redirected to a file, greps it for a login prompt or
#                 a known failure, and exits non-zero if the boot did not come
#                 up. That is the thing to run after changing the installer.
#
#   utm-vm.sh     Interactive use. A window to watch i3 come up in, a NAT'd
#                 network you can SSH into, and a folder shared with the Mac.
#                 That is the thing to run when you want to USE the system.
#
# UTM stores a VM as a bundle directory -- config.plist beside a Data/ holding
# the disk -- under its sandbox container. Writing that bundle is all it takes
# to register a machine; UTM notices it. Every key written here was checked
# against the UTM 4.7.4 binary rather than guessed.
#
# Usage:
#   utm/utm-vm.sh create  --target aarch64 --image copal-vm.img
#   utm/utm-vm.sh start   --target aarch64
#   utm/utm-vm.sh status  --target aarch64
#   utm/utm-vm.sh stop    --target aarch64
#   utm/utm-vm.sh refresh --target aarch64 --image copal-vm.img
#   utm/utm-vm.sh delete  --target aarch64
#   utm/utm-vm.sh config  --target x86_64        # print the plist, write nothing
#   utm/utm-vm.sh progress --target x86_64       # how far the install has got
#   utm/utm-vm.sh log     --target x86_64        # follow the install transcript
#
set -euo pipefail

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }

UTM_APP="/Applications/UTM.app"
UTMCTL="$UTM_APP/Contents/MacOS/utmctl"
# UTM is sandboxed, so its VMs live in the container rather than ~/Documents.
UTM_DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

ACTION=""
TARGET=""
IMAGE=""
NAME=""
MEM=""
CPUS=""
SSH_PORT=""
SHARE_DIR="${SHARE_DIR:-$HOME/Downloads/SharedVM}"
NET_MODE="shared"
FORCE=0

usage() { sed -n '5,33p' "$0" | sed 's/^# \{0,1\}//'; }

[ $# -gt 0 ] || { usage; exit 0; }
ACTION="$1"; shift
case "$ACTION" in
    create|start|stop|status|delete|refresh|config|ip|log|progress) : ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown action '$ACTION'. One of: create start stop status delete refresh config ip log progress" ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --target)   TARGET="${2:-}"; shift 2 ;;
        --image)    IMAGE="${2:-}";  shift 2 ;;
        --name)     NAME="${2:-}";   shift 2 ;;
        --mem)      MEM="${2:-}";    shift 2 ;;
        --cpus)     CPUS="${2:-}";   shift 2 ;;
        --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
        --share)    SHARE_DIR="${2:-}"; shift 2 ;;
        --net)      NET_MODE="${2:-}"; shift 2 ;;
        --force)    FORCE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) die "unknown option '$1'. See --help." ;;
    esac
done

case "$NET_MODE" in
    shared)   UTM_NET_MODE="Shared" ;;
    emulated) UTM_NET_MODE="Emulated" ;;
    *) die "--net must be 'shared' (vmnet NAT, guest reachable at its own IP)
       or 'emulated' (slirp NAT, guest reachable only via a forwarded port)" ;;
esac

# ------------------------------------------------------------- the targets ---
# Two targets, and the difference that matters is the third line: on Apple
# Silicon an aarch64 guest is VIRTUALISED through HVF and runs at native speed,
# while an x86_64 guest is EMULATED by TCG and is perhaps 5-20x slower. Both
# are useful; only one is pleasant.
#
# CPUS: 4 for aarch64 maps onto the four performance cores. x86_64 stays at 2
# deliberately -- TCG is a translation loop that contends on locks, and more
# vCPUs frequently makes it slower rather than faster.
case "${TARGET:-}" in
    aarch64|arm64|utm-aarch64)
        TARGET=aarch64
        ARCHITECTURE=aarch64
        MACHINE=virt
        CPU_MODEL=default
        HYPERVISOR=true
        DISPLAY_HW=virtio-gpu-pci
        DEFAULT_NAME="Copal-aarch64"
        DEFAULT_CPUS=4
        DEFAULT_SSH=2222
        # No i8042 exists on ARM -- the PS/2 controller is an x86 device. The
        # USB keyboard is the only option here, and it works because the
        # aarch64 guest loads usbhid out of modloop.
        PS2=false
        ;;
    x86_64|x64|amd64|utm-x86_64)
        TARGET=x86_64
        ARCHITECTURE=x86_64
        MACHINE=q35
        # qemu64 rather than host: there is no host x86 CPU to model here, and
        # 'default' under TCG picks a model missing flags Alpine's x86_64
        # baseline expects.
        CPU_MODEL=qemu64
        HYPERVISOR=false
        # virtio-vga rather than virtio-gpu-pci: the PCI-only variant has no
        # VGA compatibility mode, and x86 firmware wants one to draw on before
        # a driver is loaded.
        DISPLAY_HW=virtio-vga
        DEFAULT_NAME="Copal-x86_64"
        DEFAULT_CPUS=2
        DEFAULT_SSH=2223
        # ON, and this is not a preference -- it decides whether the graphical
        # console has a keyboard at all.
        #
        # UTM attaches a usb-kbd, and with PS2Controller off it also passes
        # i8042=off to the q35 machine, so usb-kbd is the ONLY keyboard. But
        # Alpine builds USB HID as modules and the PS/2 driver into the kernel:
        #
        #     CONFIG_USB_HID=m  CONFIG_HID_GENERIC=m  CONFIG_USB_XHCI_HCD=m
        #     CONFIG_KEYBOARD_ATKBD=y  CONFIG_SERIO_I8042=y
        #
        # So a USB keyboard needs three modules out of modloop before it types
        # anything, and a PS/2 one works from the first frame with none. Turning
        # the controller off left the graphical console mute and forced the user
        # to the serial display to log in at all. It costs nothing to leave on.
        PS2=true
        ;;
    "") die "--target is required: aarch64 or x86_64" ;;
    *)  die "unknown --target '$TARGET'. Use aarch64 or x86_64." ;;
esac

NAME="${NAME:-$DEFAULT_NAME}"
MEM="${MEM:-6144}"
CPUS="${CPUS:-$DEFAULT_CPUS}"
SSH_PORT="${SSH_PORT:-$DEFAULT_SSH}"
BUNDLE="$UTM_DOCS/${NAME}.utm"

[ -d "$UTM_APP" ] || die "UTM is not installed at $UTM_APP.
       Get it from https://mac.getutm.app"

# ------------------------------------------------------------------ plist ---
# Written as XML rather than through PlistBuddy: the whole configuration is
# visible in one place, which matters when the question is "why did it not
# boot" and the answer is one wrong key.
#
# Deliberate choices, each with a reason:
#
#   Network.Mode               Two NATs, and the difference matters more than
#       the name suggests. Verified by reading the QEMU command line UTM
#       actually builds, not from the documentation:
#
#         Shared   -> -netdev vmnet-shared    Apple's vmnet framework. The
#             guest gets a DHCP lease on 192.168.64.0/24 and is REACHABLE FROM
#             THE HOST at that address. ICMP works, so ping is a real test, and
#             throughput is far better than slirp. This is the default.
#
#         Emulated -> -netdev user,hostfwd=   slirp. The guest is unreachable
#             from outside, which is the problem host port forwarding exists to
#             work around. Slower, and ICMP is silently dropped.
#
#       PortForward is only honoured in Emulated mode. UTM accepts the key in
#       Shared mode and ignores it -- no hostfwd appears on the command line --
#       so writing one there is a config that lies about what it does. Hence
#       the block below is emitted only for Emulated, and 'utm-vm.sh ip' exists
#       to find the guest's real address in Shared mode.
#
#   Serial Mode = Terminal     Matches a VM already working on this machine.
#       A Display AND a Serial are both configured on purpose: the window
#       shows i3 when stage 4 has run, the serial shows kernel messages when
#       it has not.
#
#   UEFIBoot = true            The image has an EFI system partition with
#       GRUB on it at EFI/BOOT/BOOT{AA64,X64}.EFI. UTM supplies the matching
#       edk2 firmware and creates its own variable store on first start --
#       which is why one is NOT written here.
#
#   DirectoryShareMode=VirtFS  The 9p share. The PATH is not here: UTM keeps
#       it in its Registry as a security-scoped bookmark that only the app can
#       mint, so it is chosen once in the UI. See the note printed after
#       create.
write_config() {  # <disk uuid> <vm uuid> <mac>
    local disk_uuid="$1" vm_uuid="$2" mac="$3"
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Backend</key>
	<string>QEMU</string>
	<key>ConfigurationVersion</key>
	<integer>4</integer>
	<key>Display</key>
	<array>
		<dict>
			<key>DownscalingFilter</key>
			<string>Linear</string>
			<key>DynamicResolution</key>
			<true/>
			<key>Hardware</key>
			<string>${DISPLAY_HW}</string>
			<key>NativeResolution</key>
			<false/>
			<key>UpscalingFilter</key>
			<string>Nearest</string>
		</dict>
	</array>
	<key>Drive</key>
	<array>
		<dict>
			<key>Identifier</key>
			<string>${disk_uuid}</string>
			<key>ImageName</key>
			<string>${disk_uuid}.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>0</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
	</array>
	<key>Information</key>
	<dict>
		<key>Icon</key>
		<string>alpine</string>
		<key>IconCustom</key>
		<false/>
		<key>Name</key>
		<string>${NAME}</string>
		<key>Notes</key>
		<string>Copal Alpine Linux -- ${TARGET} target.

Built by utm-vm.sh from a copal-prep.sh image.

If the graphical console will not accept typing, switch UTM's display:
    the VM window's toolbar -&gt; Displays -&gt; Serial 1
That console is a plain UART and always works.

First boot:  login 'root', password BLANK (just Enter).
Then:        ls /media/  and  sh /media/vda1/copal-init.sh
After stage 3 the path becomes /boot/copal-init.sh.

SSH, once stage 1 has configured the network:
    utm/utm-vm.sh ip --target ${TARGET}    # find the guest address
    ssh root@192.168.64.x

Shared folder, once set in Settings &gt; Sharing:
    mount -t 9p -o trans=virtio,version=9p2000.L share /mnt/share</string>
		<key>UUID</key>
		<string>${vm_uuid}</string>
	</dict>
	<key>Input</key>
	<dict>
		<key>MaximumUsbShare</key>
		<integer>3</integer>
		<key>UsbBusSupport</key>
		<string>3.0</string>
		<key>UsbSharing</key>
		<false/>
	</dict>
	<key>Network</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>virtio-net-pci</string>
			<key>IsolateFromHost</key>
			<false/>
			<key>MacAddress</key>
			<string>${mac}</string>
			<key>Mode</key>
			<string>${UTM_NET_MODE}</string>
			<key>PortForward</key>
			<array>$(if [ "$NET_MODE" = emulated ]; then cat <<PF

				<dict>
					<key>GuestAddress</key>
					<string></string>
					<key>GuestPort</key>
					<integer>22</integer>
					<key>HostAddress</key>
					<string></string>
					<key>HostPort</key>
					<integer>${SSH_PORT}</integer>
					<key>Protocol</key>
					<string>TCP</string>
				</dict>
			
PF
fi)</array>
		</dict>
	</array>
	<key>QEMU</key>
	<dict>
		<key>AdditionalArguments</key>
		<array/>
		<key>BalloonDevice</key>
		<false/>
		<key>DebugLog</key>
		<false/>
		<key>Hypervisor</key>
		<${HYPERVISOR}/>
		<key>PS2Controller</key>
		<${PS2}/>
		<key>RNGDevice</key>
		<true/>
		<key>RTCLocalTime</key>
		<false/>
		<key>TPMDevice</key>
		<false/>
		<key>TSO</key>
		<false/>
		<key>UEFIBoot</key>
		<true/>
	</dict>
	<key>Serial</key>
	<array>
		<dict>
			<key>Mode</key>
			<string>Terminal</string>
			<key>Target</key>
			<string>Auto</string>
			<key>Terminal</key>
			<dict>
				<key>BackgroundColor</key>
				<string>#000000</string>
				<key>CursorBlink</key>
				<true/>
				<key>Font</key>
				<string>Menlo</string>
				<key>FontSize</key>
				<integer>12</integer>
				<key>ForegroundColor</key>
				<string>#ffffff</string>
			</dict>
		</dict>
	</array>
	<key>Sharing</key>
	<dict>
		<key>ClipboardSharing</key>
		<true/>
		<key>DirectoryShareMode</key>
		<string>VirtFS</string>
		<key>DirectoryShareReadOnly</key>
		<false/>
	</dict>
	<key>Sound</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>intel-hda</string>
		</dict>
	</array>
	<key>System</key>
	<dict>
		<key>Architecture</key>
		<string>${ARCHITECTURE}</string>
		<key>CPU</key>
		<string>${CPU_MODEL}</string>
		<key>CPUCount</key>
		<integer>${CPUS}</integer>
		<key>CPUFlagsAdd</key>
		<array/>
		<key>CPUFlagsRemove</key>
		<array/>
		<key>ForceMulticore</key>
		<false/>
		<key>JITCacheSize</key>
		<integer>0</integer>
		<key>MemorySize</key>
		<integer>${MEM}</integer>
		<key>Target</key>
		<string>${MACHINE}</string>
	</dict>
</dict>
</plist>
PLIST
}

vm_uuid_of() {
    [ -f "$BUNDLE/config.plist" ] || return 1
    plutil -extract Information.UUID raw -o - "$BUNDLE/config.plist" 2>/dev/null
}

require_bundle() {
    [ -d "$BUNDLE" ] || die "no VM named '$NAME' at $BUNDLE.
       Create it first:  utm/utm-vm.sh create --target $TARGET --image <image>"
}

# ----------------------------------------------------------------- actions ---
do_config() { write_config "PREVIEW-DISK-UUID" "PREVIEW-VM-UUID" "16:00:00:00:00:00"; }

do_create() {
    [ -n "$IMAGE" ] || die "create needs --image (the .img from copal-prep.sh)"
    [ -f "$IMAGE" ] || die "no such image: $IMAGE"
    command -v qemu-img >/dev/null 2>&1 \
        || die "qemu-img not found. Install it with:  brew install qemu"

    if [ -d "$BUNDLE" ]; then
        [ "$FORCE" -eq 1 ] || die "$BUNDLE already exists.
       Pass --force to replace it, or --name to build a second machine.
       Replacing DESTROYS whatever that VM has written."
        # A running VM whose bundle is deleted underneath it corrupts the disk.
        if [ -x "$UTMCTL" ] && [ "$("$UTMCTL" status "$NAME" 2>/dev/null || echo stopped)" != stopped ]; then
            die "'$NAME' is not stopped. Stop it first:  utm/utm-vm.sh stop --target $TARGET"
        fi
        info "Replacing the existing $NAME.utm"
        rm -rf "$BUNDLE"
    fi

    # An image attached to macOS and read by qemu-img at the same time is two
    # readers over a file one of them may still be writing.
    local abs
    abs="$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")"
    if hdiutil info 2>/dev/null | grep -q "^image-path[[:space:]]*:[[:space:]]*$abs$"; then
        die "$IMAGE is still attached to macOS. Detach it first:  hdiutil detach <dev>"
    fi

    local disk_uuid vm_uuid mac
    disk_uuid=$(uuidgen)
    vm_uuid=$(uuidgen)
    # Locally administered, unicast: bit 1 of the first octet set, bit 0 clear.
    # 0x16 satisfies both, and is the prefix UTM itself uses.
    mac=$(printf '16:%02X:%02X:%02X:%02X:%02X' \
        $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) \
        $((RANDOM % 256)) $((RANDOM % 256)))

    mkdir -p "$BUNDLE/Data"
    info "Converting $IMAGE to qcow2 (sparse -- holes are preserved)..."
    qemu-img convert -p -f raw -O qcow2 -S 4k "$abs" "$BUNDLE/Data/${disk_uuid}.qcow2" \
        || { rm -rf "$BUNDLE"; die "qemu-img convert failed"; }

    write_config "$disk_uuid" "$vm_uuid" "$mac" > "$BUNDLE/config.plist"
    plutil -lint "$BUNDLE/config.plist" >/dev/null \
        || { rm -rf "$BUNDLE"; die "generated config.plist is not valid"; }

    # No efi_vars.fd is written. UTM creates its own variable store sized to
    # the firmware it supplies; a hand-made one of the wrong size is how a VM
    # ends up at the EFI shell for no visible reason.

    info "Created $BUNDLE"
    printf '\n' >&2
    printf '    %-16s %s\n' "Name"      "$NAME" >&2
    printf '    %-16s %s\n' "Target"    "$TARGET ($ARCHITECTURE / $MACHINE)" >&2
    printf '    %-16s %s\n' "CPU"       "$CPUS vCPU, $([ "$HYPERVISOR" = true ] && echo 'HVF -- native speed' || echo 'TCG emulation -- slow')" >&2
    printf '    %-16s %s\n' "Memory"    "$MEM MB" >&2
    printf '    %-16s %s\n' "Disk"      "$(du -h "$BUNDLE/Data/${disk_uuid}.qcow2" | awk '{print $1}') on disk" >&2
    if [ "$NET_MODE" = shared ]; then
        printf '    %-16s %s\n' "Network"   "Shared -- vmnet NAT, guest gets its own 192.168.64.x" >&2
    else
        printf '    %-16s %s\n' "Network"   "Emulated -- slirp NAT, ssh localhost:$SSH_PORT -> guest 22" >&2
    fi
    printf '    %-16s %s\n' "Display"   "$DISPLAY_HW" >&2
    printf '\n' >&2
    cat >&2 <<NEXT
  One thing is not scriptable. UTM keeps a shared folder's path in its own
  registry as a security-scoped bookmark, which only the app can create, so
  point it at the folder once:

      UTM -> $NAME -> Edit -> Sharing -> Directory Share Path
      -> $SHARE_DIR

  Then start it:

      utm/utm-vm.sh start --target $TARGET

  First boot: log in as 'root' with a BLANK password, then

      ls /media/                      # expect vda1
      sh /media/vda1/copal-init.sh    # the fifteen stages

  IF THE GRAPHICAL CONSOLE WILL NOT TYPE, switch UTM to the serial display:

      the VM window's toolbar  ->  Displays  ->  Serial 1

  That console is a plain UART with a driver built into the kernel, so it works
  before anything has been loaded out of modloop, and it is the one to use if
  the window takes no keystrokes. Both are wired up on purpose: the graphical
  one is for watching i3 come up, the serial one is for when it cannot.

  Stage 1 is what configures the network. Until it has run, eth0 is down and
  the guest has no address -- that is Alpine's diskless default, not a fault.

NEXT
}

do_start() {
    require_bundle
    [ -x "$UTMCTL" ] || die "utmctl not found at $UTMCTL"
    info "Starting $NAME..."
    "$UTMCTL" start "$NAME" || die "utmctl could not start '$NAME'.
       If UTM has not noticed the bundle yet, open UTM once:  open -a UTM"
    if [ "$NET_MODE" = emulated ]; then
        info "Started. SSH answers on localhost:$SSH_PORT once the guest is running sshd."
    else
        info "Started. Find the guest address with:  utm/utm-vm.sh ip --target $TARGET"
    fi
}

do_stop() {
    require_bundle
    [ -x "$UTMCTL" ] || die "utmctl not found at $UTMCTL"
    info "Stopping $NAME..."
    "$UTMCTL" stop "$NAME" || warn "utmctl could not stop '$NAME' -- it may already be stopped"
}

do_status() {
    require_bundle
    printf '\n' >&2
    printf '    %-16s %s\n' "Name"   "$NAME" >&2
    printf '    %-16s %s\n' "Bundle" "$BUNDLE" >&2
    printf '    %-16s %s\n' "UUID"   "$(vm_uuid_of || echo '?')" >&2
    if [ -x "$UTMCTL" ]; then
        printf '    %-16s %s\n' "Status" "$("$UTMCTL" status "$NAME" 2>/dev/null || echo 'not registered with UTM yet')" >&2
    fi
    local d
    d=$(ls "$BUNDLE/Data"/*.qcow2 2>/dev/null | head -1 || true)
    [ -n "$d" ] && printf '    %-16s %s\n' "Disk" "$(du -h "$d" | awk '{print $1}') on disk" >&2
    [ -f "$BUNDLE/Data/efi_vars.fd" ] \
        && printf '    %-16s %s\n' "EFI vars" "present (UTM created it)" >&2 \
        || printf '    %-16s %s\n' "EFI vars" "not yet -- UTM writes it at first start" >&2
    printf '    %-16s %s\n' "SSH" "ssh -p $SSH_PORT root@localhost" >&2
    printf '\n' >&2
}

do_delete() {
    require_bundle
    if [ -x "$UTMCTL" ] && [ "$("$UTMCTL" status "$NAME" 2>/dev/null || echo stopped)" != stopped ]; then
        die "'$NAME' is running. Stop it first."
    fi
    [ "$FORCE" -eq 1 ] || die "This deletes $BUNDLE and everything the VM has written.
       Pass --force if that is what you want."
    info "Deleting $BUNDLE"
    rm -rf "$BUNDLE"
}

# copal-prep.sh --refresh rewrites only the small generated files -- answers.txt,
# copal.conf, copal-init.sh -- on a medium that is already written, so a machine
# picks up installer changes without being rebuilt. It works through hdiutil,
# which cannot attach a qcow2, so the disk is converted out and back. Both
# directions are lossless and everything the guest has written survives.
do_refresh() {
    require_bundle
    [ -n "$IMAGE" ] || die "refresh needs --image: a scratch path for the raw round-trip"
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found. brew install qemu"
    if [ -x "$UTMCTL" ] && [ "$("$UTMCTL" status "$NAME" 2>/dev/null || echo stopped)" != stopped ]; then
        die "'$NAME' is running. Stop it first -- refreshing a live disk corrupts it."
    fi
    local disk prep
    disk=$(ls "$BUNDLE/Data"/*.qcow2 2>/dev/null | head -1) || die "no disk in $BUNDLE/Data"
    prep="$(cd "$(dirname "$0")/.." && pwd)/copal-prep.sh"
    [ -x "$prep" ] || die "cannot find copal-prep.sh at $prep"

    info "qcow2 -> raw ($IMAGE)..."
    qemu-img convert -p -f qcow2 -O raw "$disk" "$IMAGE" || die "convert out failed"
    info "Running copal-prep.sh --refresh..."
    MODEL=$([ "$TARGET" = aarch64 ] && echo vm || echo vmx86) \
        "$prep" --refresh --image "$IMAGE" || die "refresh failed"
    info "raw -> qcow2..."
    qemu-img convert -p -f raw -O qcow2 -S 4k "$IMAGE" "${disk}.new" || die "convert back failed"
    mv "${disk}.new" "$disk"
    info "Refreshed. Guest data preserved."
}

# In Shared mode the guest is on Apple's vmnet subnet with an address of its
# own, so there is nothing to forward and nothing to guess: macOS's bootpd
# records the lease it handed out, keyed by MAC, and the MAC is in config.plist.
#
# The lease file stores ethernet hardware addresses with a "1," type prefix and
# in lower case, so the MAC from the plist is folded before comparing. A guest
# that has not run DHCP yet -- which is every Copal guest before stage 1, since
# Alpine's diskless boot leaves eth0 down -- simply has no entry.
do_ip() {
    require_bundle
    local mac leases ip
    mac=$(plutil -extract Network.0.MacAddress raw -o - "$BUNDLE/config.plist" 2>/dev/null | tr 'A-Z' 'a-z')
    [ -n "$mac" ] || die "no MAC address in $BUNDLE/config.plist"
    leases=/var/db/dhcpd_leases
    if [ ! -r "$leases" ]; then
        die "cannot read $leases -- no vmnet guest has taken a lease on this host yet"
    fi
    ip=$(awk -v want="$mac" '
        /^{/            { ipaddr=""; hw="" }
        /ip_address=/   { sub(/.*ip_address=/, "", $0); ipaddr=$0 }
        /hw_address=/   { sub(/.*hw_address=/, "", $0); sub(/^[0-9a-f]+,/, "", $0); hw=tolower($0) }
        /^}/            { if (hw == want) print ipaddr }
    ' "$leases" | tail -1)
    if [ -z "$ip" ]; then
        warn "no lease for $mac yet."
        note "The guest takes an address when its network comes up, which on a"
        note "Copal guest is stage 1 -- Alpine's diskless boot leaves eth0 down."
        note "In the guest, to test it before then:"
        note "    ip link set eth0 up && udhcpc -i eth0"
        return 1
    fi
    printf '%s\n' "$ip"
    info "ssh root@$ip   (or: ssh $(plutil -extract Information.Name raw -o - "$BUNDLE/config.plist" 2>/dev/null))"
}

# Watching an install that is going to take hours.
#
# copal-init.sh appends every run to copal.log on the FAT boot partition, which
# is world-readable and -- being FAT -- has no permissions of its own to get
# wrong. That makes it the one file always readable no matter what state the
# root filesystem is in, which is exactly when you most want to read it.
#
# busybox is invoked explicitly for every tool here. Once stage 12 has run, the
# GNU coreutils and grep are installed over busybox's applets, and those are
# dynamically linked against libraries the musl loader resolves through a file
# in /etc. If /etc is unreadable to the calling account -- which a leaked umask
# used to arrange -- then grep, sed and pgrep all die with "Permission denied"
# on their own libraries, and the tooling you would reach for to diagnose the
# problem is the tooling the problem breaks. busybox's applets are one static
# binary and keep working.
guest_ip() {
    _ip=$(do_ip 2>/dev/null | head -1)
    [ -n "$_ip" ] || die "no DHCP lease for this VM yet -- has stage 1 run?"
    printf '%s' "$_ip"
}

# The remote work is written as a heredoc piped into `sh -s` rather than passed
# as an argument to ssh. Quoting a script through an ssh argument means every
# quote is interpreted twice, once by the local shell and once by the remote
# one, and the first version of this got that wrong in a way that produced
# `sh: syntax error: unexpected "("` on the far side. A heredoc is passed
# through untouched.
do_log() {
    require_bundle
    _ip=$(guest_ip)
    info "Following /boot/copal.log on $_ip. Ctrl-C stops watching, not the install."
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${GUEST_USER:-user}@$_ip" \
        'busybox tail -f -n 40 /boot/copal.log'
}

# Two samples make a rate; one makes a number. The previous sample is kept on
# the HOST, keyed by VM name, because the guest is busy and should not be asked
# to remember anything -- and because a progress command that has to sleep to
# measure a rate is a progress command nobody runs twice.
#
# So each call records (epoch, count) and compares against whatever the last
# call left behind. The first call after a while shows no rate, which is honest:
# it has nothing to compare with.
_sample_file() { printf '%s/copal-progress-%s' "${TMPDIR:-/tmp}" "$NAME"; }

_rate_line() {  # <built> <total>
    _b="$1"; _t="$2"
    _now=$(date +%s)
    _f=$(_sample_file)
    if [ -r "$_f" ]; then
        read -r _pt _pb < "$_f" 2>/dev/null || { _pt=""; _pb=""; }
        if [ -n "${_pt:-}" ] && [ -n "${_pb:-}" ] && [ "$_b" -gt "$_pb" ] && [ "$_now" -gt "$_pt" ]; then
            awk -v b="$_b" -v t="$_t" -v pb="$_pb" -v dt="$((_now - _pt))" 'BEGIN{
                rate = (b - pb) / dt
                left = t - b
                if (rate > 0 && left > 0) {
                    eta = left / rate
                    printf "    rate          %.1f per minute, %d left, ETA ~%d min\n",
                           rate * 60, left, (eta + 59) / 60
                } else if (left <= 0) {
                    printf "    rate          complete\n"
                }
            }'
        fi
    fi
    printf '%s %s\n' "$_now" "$_b" > "$_f" 2>/dev/null || true
}

do_progress() {
    require_bundle
    _ip=$(guest_ip)
    _out=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
        "${GUEST_USER:-user}@$_ip" 'sh -s' <<'REMOTE'
L=/boot/copal.log
printf '\n'
# "DONE=" in copal-auto is the installer's own wording and it is misleading if
# taken at face value: auto_mark records a stage BEFORE running it, so that a
# stage which reboots from inside itself (stage 3) is not retried for ever. The
# last number in the list is therefore the stage RUNNING NOW, not the last one
# finished. Labelled accordingly, because reading it the other way makes an
# install look an entire stage further along than it is.
printf '  stages started: %s\n' "$(busybox sed -n 's/^DONE=//p' /boot/copal-auto 2>/dev/null || echo 'not an automatic run')"
printf '  (last is running, not finished)\n'
printf '  current stage : %s\n' "$(busybox grep -aoE 'Stage [0-9]+: .{0,44}' "$L" 2>/dev/null | busybox tail -1)"
printf '  disk used     : %s\n' "$(busybox df -h / | busybox awk 'NR==2 {print $3 " of " $2 " (" $5 ")"}')"
printf '  load average  : %s\n' "$(busybox cut -d' ' -f1-3 /proc/loadavg)"
printf '  transcript    : %s bytes, last written %s\n' \
    "$(busybox wc -c < "$L")" "$(busybox date -r "$L" '+%H:%M:%S' 2>/dev/null)"
printf '  time now      : %s\n' "$(busybox date '+%H:%M:%S')"
# --- artifact counts for the steps that go quiet for a long time -----------
#
# A load average of 1.00 tells you something is running. It does not tell you
# whether it is a third of the way through or will still be going at midnight.
# Some steps have a countable output and a knowable total, and for those a
# ratio is worth far more than a spinner.
#
# TeX Live is the worst offender and the first one handled. `apk add texlive`
# ends by running `fmtutil --sys --all`, which rebuilds every TeX format from
# source: pure computation, single-threaded, writing one small .fmt at the end
# of each. The transcript says nothing for the duration and the disk does not
# grow measurably. Under emulation it can run for well over an hour.
#
#   built    .fmt files under texmf-var
#   total    enabled entries in fmtutil.cnf -- lines starting with a letter;
#            the disabled ones are commented '#!' and are not built
#
# Add further cases here as they are found. The shape is the same: something
# countable on disk over something knowable from a config file.
_fmt_total=$(busybox grep -cE '^[a-zA-Z]' /usr/share/texmf-dist/web2c/fmtutil.cnf 2>/dev/null || echo 0)
if [ "$_fmt_total" -gt 0 ]; then
    _fmt_built=$(busybox find /usr/share/texmf-var -name '*.fmt' 2>/dev/null | busybox wc -l)
    printf '\n  artifacts:\n'
    printf '#SAMPLE fmt %s %s\n' "$_fmt_built" "$_fmt_total"
    printf '    TeX formats   %s / %s   %s\n' "$_fmt_built" "$_fmt_total" \
        "$(busybox awk -v b="$_fmt_built" -v t="$_fmt_total" 'BEGIN{
              n=int(b*24/t); s="["; for(i=0;i<24;i++) s=s (i<n?"=":" "); printf "%s] %d%%", s, b*100/t }')"
fi

printf '\n  working on:\n'
# The transcript goes quiet during a long package operation, because output is
# on the console until a stage ends. What is actually running is the better
# answer, and is why this looks at the process table rather than only the log.
# $8 is busybox top's %CPU and already carries its own per-cent sign; $9 is
# where COMMAND starts. Both were off by one in the first version.
busybox top -b -n1 2>/dev/null | busybox awk 'NR>4 && $8+0 > 2 {printf "    %6s  %s\n", $8, $9" "$10" "$11}' | busybox head -4
# Per-stage timings, if the installer that built this image records them.
# Written to the FAT boot partition, so they survive stage 3's reboot and are
# readable whatever state the root filesystem is in.
if [ -r /boot/copal-timings ]; then
    printf '\n  stage timings:\n'
    busybox awk '
        $1 == "START" && $3 > 0 { st[$2] = $3; if (!($2 in seen)) { seen[$2]=1; ord[++n] = $2 } }
        $1 == "END"   && $3 > 0 { en[$2] = $3 }
        END {
            now = NOW; total = 0
            for (i = 1; i <= n; i++) {
                s = ord[i]
                if (s in en)      { d = en[s] - st[s]; total += d; tag = "" }
                else              { d = now - st[s];             tag = "  <- running now" }
                printf "    stage %-3s %3d min %02d sec%s\n", s, d/60, d%60, tag
            }
            if (total > 0) printf "    %-9s %3d min %02d sec\n", "so far", total/60, total%60
        }' NOW="$(busybox date +%s)" /boot/copal-timings
fi

printf '\n  last lines of the transcript:\n'
busybox tail -5 "$L" | busybox cut -c1-96 | busybox sed 's/^/    /'
printf '\n'
REMOTE
)
    # The marker line is for this script, not for the reader: print everything
    # else verbatim, then use it to work out how fast the count is moving.
    printf '%s\n' "$_out" | grep -v '^#SAMPLE '
    _s=$(printf '%s\n' "$_out" | grep '^#SAMPLE fmt ' | head -1)
    if [ -n "$_s" ]; then
        set -- $_s
        [ $# -ge 4 ] && _rate_line "$3" "$4"
    fi
}

case "$ACTION" in
    create)  do_create  ;;
    start)   do_start   ;;
    stop)    do_stop    ;;
    status)  do_status  ;;
    delete)  do_delete  ;;
    refresh) do_refresh ;;
    config)  do_config  ;;
    ip)      do_ip      ;;
    log)     do_log     ;;
    progress) do_progress ;;
esac
