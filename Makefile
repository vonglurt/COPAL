# COPAL LINUX -- build cards and images, and boot the VM.
#
# A thin front end over copal-prep.sh and copal-vm.sh, which remain the things
# that do the work: this only spells out the combinations worth having a name
# for, and is explicit about the state each one destroys.
#
#   make vm            build if needed, boot, serial console on this terminal
#   make fresh         delete the VM image and build it again from nothing
#   make check         boot headless, print a verdict, exit non-zero if it hung
#   make sd-zero2      write a physical card for a Pi Zero 2 W
#   make img-pc        write a bootable disk image for a PC
#   make lint          syntax-check both scripts, including the generated one
#   make clean         remove the images, EFI variable stores and boot logs
#
# Run `make` on its own for the full list.

IMG      ?= copal-vm.img
MODEL    ?= vm
MEM      ?= 2048
CPUS     ?= 2
LOG      ?= copal-vm-check.log
AUTOLOG  ?= copal-prep-auto.log

PREP     := ./copal-prep.sh
VMRUN    := ./copal-vm.sh
VARS      = $(IMG:.img=-efivars.fd)

export MEM CPUS

# Board names are copal-prep.sh's, not a second vocabulary invented here: the
# stem goes straight through as MODEL, so `make sd-nonsense` gets that script's
# own list of what is valid rather than a different wrong answer from make.
# The one translation is the pi-prefixed spelling of the Zeros, because
# `sd-pizero2` is what fingers type and `zero2` is what the script calls it.
model_of = $(patsubst pizero%,zero%,$(1))

.DEFAULT_GOAL := help
.PHONY: help vm graphical check fresh auto image refresh lint clean distclean boards

help:
	@printf '\nCopal Linux -- make targets\n\n'
	@printf '\033[1m  Booting the VM\033[0m\n'
	@printf '  make vm         boot %s, serial console on this terminal\n' '$(IMG)'
	@printf '                  builds it first if absent. Ctrl-A X quits, Ctrl-A C for the monitor.\n'
	@printf '  make graphical  the same, in a window, to watch i3 come up\n'
	@printf '  make check      boot headless, verdict, exit non-zero if no login prompt (log: %s)\n' '$(LOG)'
	@printf '\n'
	@printf '\033[1m  Building the VM image\033[0m\n'
	@printf '  make fresh      delete the image and build it from nothing.\n'
	@printf '                  \033[33mThis is the one to run after changing copal-prep.sh.\033[0m\n'
	@printf '  make auto       fresh, unattended -- answers the step gates itself (image only)\n'
	@printf '  make image      build %s only if absent. Never rebuilds.\n' '$(IMG)'
	@printf '\n'
	@printf '\033[1m  Cards and other boards\033[0m\n'
	@printf '  make sd-BOARD   write a physical card. Prompts for the disk and\n'
	@printf '                  keeps both typed ERASE confirmations.\n'
	@printf '  make img-BOARD  write copal-BOARD.img instead of a card\n'
	@printf '  make refresh    rewrite only the generated files on an existing card\n'
	@printf '                  (MODEL=%s -- set MODEL= to choose)\n' '$(MODEL)'
	@printf '\n'
	@printf '                  BOARD is any name copal-prep.sh takes:\n'
	@printf '                    \033[36mzero zero-w pi1 cm1\033[0m       armhf   (ARMv6)\n'
	@printf '                    \033[36mpi2b\033[0m                      armv7   (Pi 2B v1.1)\n'
	@printf '                    \033[36mzero2 pi3 cm3 pi2b-v12\033[0m    aarch64\n'
	@printf '                    \033[36mpi4 400 cm4 pi5\033[0m           aarch64\n'
	@printf '                    \033[36mpc pc32\033[0m                   x86_64 / x86 (UEFI)\n'
	@printf '                    \033[36mvm\033[0m                        aarch64 (QEMU/UTM)\n'
	@printf '                  pizero2 and pizero work too. e.g. \033[1mmake sd-zero2\033[0m\n'
	@printf '\n'
	@printf '\033[1m  Housekeeping\033[0m\n'
	@printf '  make lint       sh -n on copal-prep.sh and on the copal-init.sh it generates\n'
	@printf '  make clean      remove the images, EFI variable stores and boot logs\n'
	@printf '  make distclean  clean, and the downloaded Alpine payloads in work/ as well\n'
	@printf '\n'
	@printf '  Variables: IMG MODEL MEM CPUS LOG   e.g.  make vm MEM=4096 CPUS=4\n\n'
	@printf '  \033[33mAn existing image is never rebuilt by `make vm`.\033[0m An interrupted install\n'
	@printf '  leaves copal-auto on the boot partition and resumes from there, so a\n'
	@printf '  half-finished image boots into the middle of stage 1 and skips what came\n'
	@printf '  before. Use `make fresh` whenever the result is meant to mean something.\n\n'

# ---------------------------------------------------------------- booting ---

# No @ and no pipe on these: qemu takes this terminal for the serial console,
# and anything standing between it and the tty takes the keyboard away.
vm: image
	$(VMRUN) $(IMG)

graphical: image
	$(VMRUN) --graphical $(IMG)

check: image
	$(VMRUN) --check --log $(LOG) $(IMG)

# --------------------------------------------------------------- building ---

# Deliberately NOT dependent on copal-prep.sh. Editing the script does not make
# the image out of date in a way make should act on by itself: rebuilding means
# destroying a card-sized file and sitting through an install. `make fresh` is
# the explicit way to say that, and the warning in `make help` says so.
image: $(IMG)

$(IMG):
	MODEL=$(MODEL) $(PREP) --image $(IMG)

fresh:
	MODEL=$(MODEL) $(PREP) --fresh --image $(IMG)
	@printf '\n\033[36m==>\033[0m Built. Boot it with: make vm   (or: make check)\n'

# Unattended. copal-prep.sh gates each step on a read from /dev/tty, so this
# supplies a tty with script(1) and answers every gate with Enter.
#
# Image only, and safe only because of that: the two typed ERASE confirmations
# exist for cards and are skipped when the target is a file. Never point this
# at a device.
#
# The transcript decides the verdict, not the exit status. The feed has to be
# unbounded -- a fixed count is consumed before the gates are reached and the
# build dies on EOF at step 1 -- and an unbounded feed still writing when the
# child exits makes script(1) report `write master: Input/output error`, which
# has nothing to do with whether the build worked. So: ignore the status, then
# insist on the line copal-prep.sh prints only when it has finished.
#
# One caveat worth knowing before reading the result. The three `sudo fdisk -e`
# calls that set the MBR type bytes get no password this way, so 0xEF and 0x83
# stay unset. The image boots regardless -- EDK2 finds BOOTAA64.EFI by scanning
# the FAT filesystem -- but it is not byte-identical to an attended build.
auto:
	@printf '\033[36m==>\033[0m Unattended build of $(IMG). Step gates answered automatically.\n'
	@printf '    Transcript: $(AUTOLOG)\n'
	@yes '' | script -q $(AUTOLOG) env MODEL=$(MODEL) $(PREP) --fresh --image $(IMG) \
	    >/dev/null 2>&1 || true
	@grep -q 'is written and detached' $(AUTOLOG) \
	    || { printf '\033[31merror:\033[0m the build did not finish. Tail of $(AUTOLOG):\n'; \
	         tail -20 $(AUTOLOG) | tr -d '\r' | sed 's/^/    /'; exit 1; }
	@printf '\033[36m==>\033[0m Built. Boot it with: make vm   (or: make check)\n'

refresh:
	MODEL=$(MODEL) $(PREP) --refresh

# ------------------------------------------------------- cards and boards ---

# A physical card. No --image, so copal-prep.sh picks the disk and asks for
# both typed confirmations -- which is the entire safety model for this path
# and is not bypassed here.
sd-%:
	@printf '\033[36m==>\033[0m Card for MODEL=%s. copal-prep.sh will ask which disk.\n' '$(call model_of,$*)'
	MODEL=$(call model_of,$*) $(PREP)

# The same board, written to a file. Named for the board so several can coexist
# -- copal-zero2.img beside copal-pc.img -- rather than all colliding on IMG.
img-%:
	MODEL=$(call model_of,$*) $(PREP) --image copal-$(call model_of,$*).img

fresh-img-%:
	MODEL=$(call model_of,$*) $(PREP) --fresh --image copal-$(call model_of,$*).img

# --------------------------------------------------------------- checking ---

# copal-init.sh only exists as a heredoc until a card is written, so a syntax
# error in it survives every check that reads copal-prep.sh alone -- and lands
# on the hardware. Extract it and check it as the file it becomes.
lint:
	@sh -n $(PREP) && printf '  ok      copal-prep.sh\n'
	@sh -n $(VMRUN) && printf '  ok      copal-vm.sh\n'
	@sh -n fetch-minivmac.sh && printf '  ok      fetch-minivmac.sh\n'
	@sed -n "/^cat > \"\$$MNT\/copal-init.sh\" <<'COPALINIT'$$/,/^COPALINIT$$/p" $(PREP) \
	    | sed '1d;$$d' > .copal-init.lint.sh
	@test -s .copal-init.lint.sh \
	    || { printf '\033[31merror:\033[0m could not extract copal-init.sh from $(PREP)\n'; \
	         rm -f .copal-init.lint.sh; exit 1; }
	@sh -n .copal-init.lint.sh \
	    && printf '  ok      copal-init.sh (generated, %s lines)\n' "$$(wc -l < .copal-init.lint.sh | xargs)"
	@rm -f .copal-init.lint.sh

# --------------------------------------------------------------- cleaning ---

# Images and variable stores are build output. work/ is not: it is the
# downloaded Alpine payload, it is checksum-verified, and deleting it costs a
# re-download on the next build -- so it belongs to distclean, not clean.
# work/alpine-rpi-* is tracked in git and is never removed by either.
clean:
	@rm -f $(IMG) $(VARS) $(LOG) $(AUTOLOG) efivars.fd .copal-init.lint.sh
	@rm -f copal-*.img copal-*-efivars.fd
	@rmdir logs 2>/dev/null || true
	@printf '\033[36m==>\033[0m Removed the images, EFI variable stores and boot logs.\n'

distclean: clean
	@rm -rf work/alpine-netboot-* work/alpine-virt-*
	@printf '\033[36m==>\033[0m Removed the downloaded netboot and virt payloads.\n'
	@printf '    work/alpine-rpi-* is tracked in git and was left alone.\n'
