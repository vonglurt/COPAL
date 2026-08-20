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
#   make space         what is here, what it costs, and which target removes it
#   make clean         images, EFI stores, logs, and the config carrying the identity
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
.PHONY: help menu flow targets boards configure require-tools vm graphical check \
        fresh auto image refresh lint space clean distclean

help:
	@printf '\nCopal Linux -- make targets\n\n'
	@printf '\033[1m  Start here\033[0m\n'
	@printf '  make menu       ./copal -- the front door: flow chart, targets, briefings\n'
	@printf '  make flow       the flow chart alone\n'
	@printf '  make targets    the target list, one per line   \033[2m(make boards is the same)\033[0m\n'
	@printf '  make configure  what this Mac has and what it is missing. Ends in a verdict\n'
	@printf '\n'
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
	@printf '  make space      what is taking up room and which target removes it. Removes nothing\n'
	@printf '  make clean      the images, EFI stores, logs, and the generated config that\n'
	@printf '                  carries the git identity, username and SSH key. Reports what it freed\n'
	@printf '  make distclean  clean, and the verified Alpine payloads in work/ as well\n'
	@printf '\n'
	@printf '  Variables: IMG MODEL MEM CPUS LOG   e.g.  make vm MEM=4096 CPUS=4\n\n'
	@printf '  \033[33mAn existing image is never rebuilt by `make vm`.\033[0m An interrupted install\n'
	@printf '  leaves copal-auto on the boot partition and resumes from there, so a\n'
	@printf '  half-finished image boots into the middle of stage 1 and skips what came\n'
	@printf '  before. Use `make fresh` whenever the result is meant to mean something.\n\n'

# ------------------------------------------------------------- front door ---
#
# ./copal is the thing to run first, and these are one target per flag it
# takes -- so make and the script do not become two vocabularies for the same
# three questions. They call the script and nothing else: a second copy of the
# target list here would be a second copy to get wrong.

menu:
	@./copal

flow:
	@./copal --flow

# 'boards' because that is what they are called everywhere else in this file --
# sd-BOARD, img-BOARD -- and 'targets' because that is what ./copal calls them.
targets boards:
	@./copal --targets

# -------------------------------------------------------------- configure ---
#
# What has to be present before any of this works, checked rather than assumed.
# Two kinds, and the difference is whether a miss is an error:
#
#   REQUIRED   copal-prep.sh cannot run without them. All five ship with macOS,
#              so a miss means something is genuinely wrong with the host --
#              and `script`, which `make auto` needs to supply a tty.
#   OPTIONAL   needed only by the path that uses them: qemu for `make vm`, UTM
#              for utm/utm-vm.sh. Reported, never fatal, because the card and
#              PC targets do not touch either.
#
# `make configure` is the human-readable form: it hands the machine profile to
# ./copal --check, which is where that list already lives, then adds what only
# make needs and ends in a verdict -- the one thing ./copal --check does not
# do, since it reports and always exits 0.
#
# `require-tools` is the same check with no narration, and every target that
# builds something takes it as an order-only prerequisite. That way a missing
# tool stops the build on line one with a single clear message, rather than
# four hundred megabytes in when curl turns out to be the thing that is absent.

REQUIRED_TOOLS = curl shasum bsdtar diskutil hdiutil script
# QEMU's aarch64 'virt' machine has no built-in firmware the way a PC does:
# EDK2 arrives as a pflash image inside the qemu formula. copal-vm.sh looks in
# these three places, so configure looks in the same three.
QEMU_FW = $(shell for f in "$$(brew --prefix qemu 2>/dev/null)/share/qemu/edk2-aarch64-code.fd" \
                           /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
                           /usr/local/share/qemu/edk2-aarch64-code.fd; \
                  do [ -f "$$f" ] && { echo "$$f"; break; }; done)

require-tools:
	@_missing=''; \
	for _t in $(REQUIRED_TOOLS); do \
	    command -v "$$_t" >/dev/null 2>&1 || _missing="$$_missing $$_t"; \
	done; \
	[ -z "$$_missing" ] || { \
	    printf '\033[31merror:\033[0m required tool(s) not found:%s\n' "$$_missing"; \
	    printf '       All of these ship with macOS. Run \033[1mmake configure\033[0m for the report.\n'; \
	    exit 1; }

configure:
	@./copal --check
	@printf '\033[1m  Additionally, for these make targets\033[0m\n\n'
	@for _t in script:'make auto -- supplies a tty to the step gates' \
	           qemu-system-aarch64:'make vm, graphical, check' \
	           qemu-img:'utm/utm-vm.sh create' ; do \
	    _n=$${_t%%:*}; _w=$${_t#*:}; \
	    if command -v "$$_n" >/dev/null 2>&1; then \
	        printf '  \033[32m[ok]\033[0m   %-22s %s\n' "$$_n" "$$_w"; \
	    else \
	        printf '  \033[33m[  ]\033[0m   %-22s %s \033[2m(brew install qemu)\033[0m\n' "$$_n" "$$_w"; \
	    fi; \
	done
	@if [ -n "$(QEMU_FW)" ]; then \
	    printf '  \033[32m[ok]\033[0m   %-22s %s\n' "edk2 firmware" "$(QEMU_FW)"; \
	else \
	    printf '  \033[33m[  ]\033[0m   %-22s %s\n' "edk2 firmware" \
	        "edk2-aarch64-code.fd not found -- ships with qemu"; \
	fi
	@if [ -x /Applications/UTM.app/Contents/MacOS/utmctl ]; then \
	    printf '  \033[32m[ok]\033[0m   %-22s %s\n' "utmctl" "utm/utm-vm.sh start and stop"; \
	else \
	    printf '  \033[33m[  ]\033[0m   %-22s %s\n' "utmctl" "absent -- only utm/utm-vm.sh needs it"; \
	fi
	@printf '\n'
	@$(MAKE) --no-print-directory require-tools \
	    && printf '\033[36m==>\033[0m \033[1mReady.\033[0m Every required tool is present.\n' \
	       && printf '    Cards and PC images need nothing else. The VM targets need qemu\n' \
	       && printf '    or UTM, and the lines above say which of those you have.\n\n'

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

$(IMG): | require-tools
	MODEL=$(MODEL) $(PREP) --image $(IMG)

fresh: | require-tools
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
auto: | require-tools
	@printf '\033[36m==>\033[0m Unattended build of $(IMG). Step gates answered automatically.\n'
	@printf '    Transcript: $(AUTOLOG)\n'
	@yes '' | script -q $(AUTOLOG) env MODEL=$(MODEL) $(PREP) --fresh --image $(IMG) \
	    >/dev/null 2>&1 || true
	@grep -q 'is written and detached' $(AUTOLOG) \
	    || { printf '\033[31merror:\033[0m the build did not finish. Tail of $(AUTOLOG):\n'; \
	         tail -20 $(AUTOLOG) | tr -d '\r' | sed 's/^/    /'; exit 1; }
	@printf '\033[36m==>\033[0m Built. Boot it with: make vm   (or: make check)\n'

refresh: | require-tools
	MODEL=$(MODEL) $(PREP) --refresh

# ------------------------------------------------------- cards and boards ---

# A physical card. No --image, so copal-prep.sh picks the disk and asks for
# both typed confirmations -- which is the entire safety model for this path
# and is not bypassed here.
sd-%: | require-tools
	@printf '\033[36m==>\033[0m Card for MODEL=%s. copal-prep.sh will ask which disk.\n' '$(call model_of,$*)'
	MODEL=$(call model_of,$*) $(PREP)

# The same board, written to a file. Named for the board so several can coexist
# -- copal-zero2.img beside copal-pc.img -- rather than all colliding on IMG.
img-%: | require-tools
	MODEL=$(call model_of,$*) $(PREP) --image copal-$(call model_of,$*).img

fresh-img-%: | require-tools
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
#
# Three levels, and what separates them is the cost of undoing them:
#
#   make space      removes nothing. Says what is here and which target takes it
#   make clean      build output, logs and generated config. Costs a rebuild
#   make distclean  clean, and the payloads too. Costs a re-download as well
#
# clean deliberately removes more than build output, and this is the reason.
# copal-prep.sh writes a handful of small files that carry the git identity it
# read from THIS Mac's git config, the admin username, and the SSH public key --
# copal.conf, copal-git, answers.txt, usercfg.txt, authorized_keys -- and the
# build transcripts quote all three back verbatim:
#
#     ==> Git identity offered: Real Name <real@address> -- stage 1 asks
#     ==> Authorised key: ssh-ed25519 real@address (from ~/.ssh/id_ed25519.pub)
#
# None of it is a password and nothing authenticates with it. It is still a real
# name and a real address belonging to whoever wrote the card, sitting in a
# working copy of a public repository. .gitignore already refuses to commit
# them; the point of removing them here is that a file nobody deleted is a file
# that gets copied somewhere else eventually -- into a tarball, an issue
# attachment, a `cp -r` of the folder onto a shared disk.
#
# Sizes are `du`, never `ls`. THE IMAGES ARE SPARSE: a 64g image reports 64 GB
# to `ls -lh` and occupies only what has been written to it -- about 550 MB
# fresh, 15-25 GB after a full fifteen-stage run. Reporting the ceiling would
# make every one of these numbers a lie by two orders of magnitude.

# Build output. Reproduced by building again.
BUILT    = $(IMG) $(VARS) copal-*.img copal-*-efivars.fd efivars.fd \
           .copal-init.lint.sh
# Transcripts. *.log covers them all; the two named ones are spelled out
# because they are the ones that quote the identity.
LOGS     = $(LOG) $(AUTOLOG) copal-prep-auto*.log copal-vm-check.log \
           run-log-*.txt *.log
# Generated per-machine configuration -- the same list .gitignore carries, and
# deliberately the same list, so the two cannot drift apart.
SECRETS  = copal.conf copal-git answers.txt usercfg.txt authorized_keys \
           firstrun.log copal-auto copal-timings
# Finder droppings. Not big, but they are folder clutter and they travel.
CRUFT    = .DS_Store ._* .Spotlight-V100 .Trashes
# The download cache: checksum-verified Alpine payloads and the GRUB ISOs.
# The only thing here that costs bandwidth rather than CPU to replace, which
# is why it is distclean's and not clean's.
CACHE    = work cache

# Set to 0 by distclean, which is about to remove work/ and should not first
# advise keeping it.
CLEAN_HINT ?= 1

# du over whatever of $(1) actually exists, or a dash. Printed, not deleted.
# `ls -d` filters the globs down to real paths first: `du` with no arguments
# would size the whole folder and report a number that is spectacularly wrong.
define size_row
	@_f=$$(ls -d $(2) 2>/dev/null); \
	if [ -n "$$_f" ]; then \
	    printf '  %-34s %9s   \033[2m%s\033[0m\n' '$(1)' \
	        "$$(du -shc $$_f 2>/dev/null | tail -n1 | cut -f1)" '$(3)'; \
	else \
	    printf '  %-34s %9s   \033[2m%s\033[0m\n' '$(1)' '--' 'nothing here'; \
	fi
endef

space:
	@printf '\n\033[1mWHAT IS IN THIS FOLDER\033[0m\n\n'
	@printf '  \033[2m%s\033[0m\n' 'Measured with du -- what is on disk, not what ls claims. The images'
	@printf '  \033[2m%s\033[0m\n\n' 'are sparse: 64 GB apparent, and only what has been written to them.'
	$(call size_row,Disk images and EFI stores,$(BUILT),make clean)
	$(call size_row,Logs and build transcripts,$(LOGS),make clean)
	$(call size_row,Generated config -- identity,$(SECRETS),make clean)
	$(call size_row,macOS metadata,$(CRUFT),make clean)
	$(call size_row,Verified Alpine downloads,$(CACHE),make distclean)
	@printf '\n'
	$(call size_row,Everything above,$(BUILT) $(LOGS) $(SECRETS) $(CRUFT) $(CACHE),make distclean)
	@printf '\n  \033[2m%s\033[0m\n' 'Registered UTM machines live in UTM'"'"'s own container, not here, and'
	@printf '  \033[2m%s\033[0m\n\n' 'no make target touches them: utm/utm-vm.sh delete --target aarch64'

clean:
	@_f=$$(ls -d $(BUILT) $(LOGS) $(SECRETS) $(CRUFT) 2>/dev/null); \
	if [ -z "$$_f" ]; then \
	    printf '\033[36m==>\033[0m Already clean -- nothing to remove.\n'; \
	else \
	    _sz=$$(du -shc $$_f 2>/dev/null | tail -n1 | cut -f1); \
	    rm -rf $$_f; \
	    rmdir logs 2>/dev/null || true; \
	    printf '\033[36m==>\033[0m Removed the images, EFI variable stores, logs and the\n'; \
	    printf '    generated config that carried the identity. \033[1m%s reclaimed.\033[0m\n' "$$_sz"; \
	fi
	@[ "$(CLEAN_HINT)" = 1 ] || exit 0; \
	if [ -d work ] || [ -d cache ]; then \
	    printf '    \033[2m%s\033[0m\n' 'work/ kept -- verified payloads, and a download to replace. make distclean'; \
	fi; \
	printf '    \033[2m%s\033[0m\n' 'UTM machines kept -- utm/utm-vm.sh delete --target aarch64'

# Recursive rather than a plain prerequisite, so clean can be told to skip the
# "work/ kept" hint -- printing it one line before removing work/ would be a
# small lie, and the hints are the reason anyone reads this output at all.
distclean:
	@$(MAKE) --no-print-directory clean CLEAN_HINT=0
	@_f=$$(ls -d $(CACHE) 2>/dev/null); \
	if [ -z "$$_f" ]; then \
	    printf '\033[36m==>\033[0m No downloaded payloads to remove.\n'; \
	else \
	    _sz=$$(du -shc $$_f 2>/dev/null | tail -n1 | cut -f1); \
	    rm -rf $$_f; \
	    printf '\033[36m==>\033[0m Removed the verified Alpine payloads and GRUB ISOs.\n'; \
	    printf '    \033[1m%s reclaimed.\033[0m The next build downloads them again.\n' "$$_sz"; \
	fi
