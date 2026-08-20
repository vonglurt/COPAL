# COPAL LINUX -- build cards and images, and boot the VM.
#
# A thin front end over copal-prep.sh and copal-vm.sh, which remain the things
# that do the work: this only spells out the combinations worth having a name
# for, and is explicit about the state each one destroys.
#
#   make vm            build if needed, boot, serial console on this terminal
#   make fresh         delete the VM image and build it again from nothing
#   make check         boot headless, print a verdict, exit non-zero if it hung
#   make utm           register the VM with UTM and start it (utm-x86 for x86_64)
#   make sd-zero2      write a physical card for a Pi Zero 2 W
#   make img-pc        write a bootable disk image for a PC
#   make lint          syntax-check both scripts, including the generated one
#   make space         what is here, what it costs, and which target removes it
#   make clean         empties build/, keeping build/cache. Reports what it freed
#   make distclean     clean, and the download cache with it
#
# Run `make` on its own for the full list.

# Everything generated lands under one directory, so the repository root holds
# only files that are tracked. copal-prep.sh takes BUILDDIR too, so an image
# written by the script and one written by make land in the same place.
#
# The cache lives inside it, at build/cache -- but the two are not the same
# thing and the clean targets treat them differently. Build output is worthless
# to anyone else and reproduced by building again; the cache is checksum-
# verified Alpine payloads that cost bandwidth rather than CPU to replace. So
# `make clean` empties build/ while stepping around the cache, and only
# `make distclean` takes both. See the cleaning section for how, and why the
# exclusion is written as an exclusion rather than a list.
BUILDDIR ?= build
CACHEDIR ?= $(BUILDDIR)/cache

IMG      ?= $(BUILDDIR)/copal-vm.img
MODEL    ?= vm
MEM      ?= 2048
CPUS     ?= 2
LOG      ?= $(BUILDDIR)/copal-vm-check.log
AUTOLOG  ?= $(BUILDDIR)/copal-prep-auto.log

PREP     := ./copal-prep.sh
VMRUN    := ./copal-vm.sh
VARS      = $(IMG:.img=-efivars.fd)

export MEM CPUS BUILDDIR CACHEDIR

# Board names are copal-prep.sh's, not a second vocabulary invented here: the
# stem goes straight through as MODEL, so `make sd-nonsense` gets that script's
# own list of what is valid rather than a different wrong answer from make.
# The one translation is the pi-prefixed spelling of the Zeros, because
# `sd-pizero2` is what fingers type and `zero2` is what the script calls it.
model_of = $(patsubst pizero%,zero%,$(1))

.DEFAULT_GOAL := help
.PHONY: help menu flow targets boards configure require-tools vm graphical check \
        fresh auto image refresh utm utm-x86 lint space clean distclean

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
	@printf '  make utm        register the aarch64 machine with UTM and start it\n'
	@printf '  make utm-x86    the same for x86_64 -- \033[33mthe only way to boot that image\033[0m\n'
	@printf '                  Creates the VM only if there is not one already. Never replaces one.\n'
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
	@printf '  make distclean  clean, and the verified Alpine payloads in %s as well\n' '$(CACHEDIR)/'
	@printf '\n'
	@printf '  Variables: IMG MODEL MEM CPUS LOG   e.g.  make vm MEM=4096 CPUS=4\n\n'
	@printf '  \033[33mAn existing image is never rebuilt by `make vm`.\033[0m An interrupted install\n'
	@printf '  leaves copal-auto on the boot partition and resumes from there, so a\n'
	@printf '  half-finished image boots into the middle of stage 1 and skips what came\n'
	@printf '  before. Use `make fresh` whenever the result is meant to mean something.\n\n'

# The directory has to exist before script(1) can open a transcript in it, and
# an order-only prerequisite is the way to say "make sure it is there" without
# a fresh mtime on it counting as a reason to rebuild an image.
$(BUILDDIR):
	@mkdir -p $(BUILDDIR)

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

check: image | $(BUILDDIR)
	$(VMRUN) --check --log $(LOG) $(IMG)

# --------------------------------------------------------------- building ---

# Deliberately NOT dependent on copal-prep.sh. Editing the script does not make
# the image out of date in a way make should act on by itself: rebuilding means
# destroying a card-sized file and sitting through an install. `make fresh` is
# the explicit way to say that, and the warning in `make help` says so.
image: $(IMG)

$(IMG): | require-tools $(BUILDDIR)
	MODEL=$(MODEL) $(PREP) --image $(IMG)

fresh: | require-tools $(BUILDDIR)
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
auto: | require-tools $(BUILDDIR)
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

# --------------------------------------------------------------------- UTM ---
#
# copal-prep.sh writes an image and stops there on purpose. A UTM machine is
# not a file in this repository: it is a bundle registered inside another
# application's sandbox container, it survives clean, distclean and deleting
# this checkout entirely, and a script whose job is "write a disk image" has no
# business quietly creating one. These targets exist so the step is still a
# single command -- named and asked for, rather than a side effect of building.
#
# `create` refuses to replace an existing machine without --force, which is the
# correct behaviour and would also make `make utm` fail the second time it ran.
# So create happens only when `status` reports there is no machine, and start is
# unconditional. Running either target twice is safe and destroys nothing.
#
# utm-x86 matters more than it looks. copal-vm.sh runs qemu-system-aarch64, so
# for the x86_64 image UTM is not one of two ways to boot it -- it is the only
# way, and until now it was the only boot route with no target behind it.

UTMRUN  := ./utm/utm-vm.sh
X86IMG  ?= $(BUILDDIR)/copal-vmx86.img

# The x86_64 counterpart of $(IMG). Same rule, different MODEL: vmx86 is what
# sets ARCH=x86_64 with VM=1, and what ./copal offers as target 9.
$(X86IMG): | require-tools $(BUILDDIR)
	MODEL=vmx86 $(PREP) --image $(X86IMG)

utm: image
	@$(UTMRUN) status --target aarch64 >/dev/null 2>&1 \
	    || $(UTMRUN) create --target aarch64 --image $(IMG)
	@$(UTMRUN) start --target aarch64
	@printf '\033[36m==>\033[0m Started. Find its address with: %s ip --target aarch64\n' '$(UTMRUN)'
	@printf '    \033[2m%s\033[0m\n' 'Serial console: the VM window toolbar -> Displays -> Serial 1'

utm-x86: $(X86IMG)
	@$(UTMRUN) status --target x86_64 >/dev/null 2>&1 \
	    || $(UTMRUN) create --target x86_64 --image $(X86IMG)
	@$(UTMRUN) start --target x86_64
	@printf '\033[36m==>\033[0m Started. Emulated by TCG, so expect it to be slow.\n'
	@printf '    \033[2m%s\033[0m\n' 'Serial console is on ttyS0 here, not ttyAMA0.'

# ------------------------------------------------------- cards and boards ---

# A physical card. No --image, so copal-prep.sh picks the disk and asks for
# both typed confirmations -- which is the entire safety model for this path
# and is not bypassed here.
sd-%: | require-tools
	@printf '\033[36m==>\033[0m Card for MODEL=%s. copal-prep.sh will ask which disk.\n' '$(call model_of,$*)'
	MODEL=$(call model_of,$*) $(PREP)

# The same board, written to a file. Named for the board so several can coexist
# -- copal-zero2.img beside copal-pc.img -- rather than all colliding on IMG.
img-%: | require-tools $(BUILDDIR)
	MODEL=$(call model_of,$*) $(PREP) --image $(BUILDDIR)/copal-$(call model_of,$*).img

fresh-img-%: | require-tools $(BUILDDIR)
	MODEL=$(call model_of,$*) $(PREP) --fresh --image copal-$(call model_of,$*).img

# --------------------------------------------------------------- checking ---

# copal-init.sh only exists as a heredoc until a card is written, so a syntax
# error in it survives every check that reads copal-prep.sh alone -- and lands
# on the hardware. Extract it and check it as the file it becomes.
lint: | $(BUILDDIR)
	@sh -n $(PREP) && printf '  ok      copal-prep.sh\n'
	@sh -n $(VMRUN) && printf '  ok      copal-vm.sh\n'
	@sh -n fetch-minivmac.sh && printf '  ok      fetch-minivmac.sh\n'
	@sed -n "/^cat > \"\$$MNT\/copal-init.sh\" <<'COPALINIT'$$/,/^COPALINIT$$/p" $(PREP) \
	    | sed '1d;$$d' > $(BUILDDIR)/.copal-init.lint.sh
	@test -s $(BUILDDIR)/.copal-init.lint.sh \
	    || { printf '\033[31merror:\033[0m could not extract copal-init.sh from $(PREP)\n'; \
	         rm -f $(BUILDDIR)/.copal-init.lint.sh; exit 1; }
	@sh -n $(BUILDDIR)/.copal-init.lint.sh \
	    && printf '  ok      copal-init.sh (generated, %s lines)\n' "$$(wc -l < $(BUILDDIR)/.copal-init.lint.sh | xargs)"
	@rm -f $(BUILDDIR)/.copal-init.lint.sh

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

# Everything in $(BUILDDIR) that is NOT the cache. Note what this is: an
# exclusion of one name, not a list of things to remove. Anything a future
# target drops into build/ is cleaned by default and nobody has to remember to
# add it here -- which is the property the old glob list never had, and how
# transcripts quoting a real name survived several rounds of cleaning.
#
# find, because a shell glob cannot express "except". -mindepth/-maxdepth 1 so
# it names the entries and not their contents; rm -rf does the recursion.
FIND_BUILT = find $(BUILDDIR) -mindepth 1 -maxdepth 1 ! -name cache 2>/dev/null
# The same output, in the places versions before build/ existed left it -- the
# repository root, and a top-level work/. Kept so an existing working copy gets
# genuinely cleaned rather than half-cleaned.
LEGACY   = copal-*.img copal-*-efivars.fd efivars.fd .copal-init.lint.sh \
           copal-prep-auto*.log copal-vm-check.log run-log-*.txt *.log
# Generated per-machine configuration -- the same list .gitignore carries, and
# deliberately the same list, so the two cannot drift apart.
SECRETS  = copal.conf copal-git answers.txt usercfg.txt authorized_keys \
           firstrun.log copal-auto copal-timings
# Finder droppings. Not big, but they are folder clutter and they travel.
CRUFT    = .DS_Store ._* .Spotlight-V100 .Trashes

# Set to 0 by distclean, which is about to remove the cache and should not
# first advise keeping it.
CLEAN_HINT ?= 1

# $(call) splits its arguments on commas, so a literal one has to arrive as a
# variable. Only used by the size_row labels.
comma := ,

# One row of the space report. Argument 2 is a SHELL COMMAND that prints paths,
# one per line -- not a glob -- because "everything except the cache" cannot be
# written as a glob and every row should go through the same code.
#
# du and never ls: the images are sparse, and ls reports the ceiling.
define size_row
	@_f=$$($(2)); \
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
	$(call size_row,$(BUILDDIR)/ -- images$(comma) EFI$(comma) logs,$(FIND_BUILT),make clean)
	$(call size_row,$(CACHEDIR)/ -- Alpine downloads,ls -d $(CACHEDIR) 2>/dev/null,make distclean)
	$(call size_row,Left loose by older builds,ls -d $(LEGACY) work 2>/dev/null,make clean)
	$(call size_row,Generated config -- identity,ls -d $(SECRETS) 2>/dev/null,make clean)
	$(call size_row,macOS metadata,ls -d $(CRUFT) 2>/dev/null,make clean)
	$(call size_row,minivmac/ -- emulator working set,ls -d minivmac 2>/dev/null,nothing -- see below)
	@printf '\n'
	$(call size_row,Everything above,ls -d $(BUILDDIR) $(LEGACY) work $(SECRETS) $(CRUFT) 2>/dev/null,make distclean)
	@printf '\n  \033[2m%s\033[0m\n' 'Registered UTM machines live in UTM'"'"'s own container, not here, and'
	@printf '  \033[2m%s\033[0m\n' 'no make target touches them: utm/utm-vm.sh delete --target aarch64'
	@printf '\n  \033[2m%s\033[0m\n' 'minivmac/ is left alone on purpose. fetch-minivmac.sh --rom copies in a'
	@printf '  \033[2m%s\033[0m\n' 'ROM dumped from a Macintosh Plus, and that is not re-downloadable. Remove'
	@printf '  \033[2m%s\033[0m\n\n' 'it by hand if you mean to.'

# work/ is in the removal list because that is where the cache used to live,
# at the top level. A working copy from before the move keeps it, and leaving
# it behind would mean two caches and a confusing space report.
clean:
	@_f=$$($(FIND_BUILT); ls -d $(LEGACY) work $(SECRETS) $(CRUFT) 2>/dev/null); \
	if [ -z "$$_f" ]; then \
	    printf '\033[36m==>\033[0m Already clean -- nothing to remove.\n'; \
	else \
	    _sz=$$(du -shc $$_f 2>/dev/null | tail -n1 | cut -f1); \
	    rm -rf $$_f; \
	    rmdir logs 2>/dev/null || true; \
	    printf '\033[36m==>\033[0m Purged \033[1m%s/\033[0m -- images, EFI variable stores and\n' '$(BUILDDIR)'; \
	    printf '    transcripts -- along with any generated config that carried the\n'; \
	    printf '    identity. \033[1m%s reclaimed.\033[0m\n' "$$_sz"; \
	fi
	@[ "$(CLEAN_HINT)" = 1 ] || exit 0; \
	if [ -d $(CACHEDIR) ]; then \
	    printf '    \033[2m%s\033[0m\n' '$(CACHEDIR)/ kept -- verified payloads, and a download to replace.'; \
	    printf '    \033[2m%s\033[0m\n' 'make distclean takes it too.'; \
	fi; \
	printf '    \033[2m%s\033[0m\n' 'UTM machines kept -- utm/utm-vm.sh delete --target aarch64'

# Recursive rather than a plain prerequisite, so clean can be told to skip the
# "cache kept" hint -- printing it one line before removing the cache would be
# a small lie, and the hints are the reason anyone reads this output at all.
#
# The case is a de-duplication, not a formality. By default CACHEDIR sits
# INSIDE BUILDDIR, and naming both to `du -shc` counts the cache twice: the
# first run of this reported 50M for a 25M cache. Since clean has already
# emptied everything else, the size of BUILDDIR alone is the size of the cache
# -- and CACHEDIR is only named separately when someone has moved it out.
#
# The patterns are written (build/*) rather than build/*) on purpose: make
# collapses this recipe onto one line, and a bare case pattern's unbalanced ')'
# inside $( ) is a syntax error in bash. The leading paren is POSIX and it
# balances.
distclean:
	@$(MAKE) --no-print-directory clean CLEAN_HINT=0
	@_f=$$(ls -d $(BUILDDIR) 2>/dev/null; \
	       case "$(CACHEDIR)/" in ($(BUILDDIR)/*) ;; (*) ls -d $(CACHEDIR) 2>/dev/null ;; esac); \
	if [ -z "$$_f" ]; then \
	    printf '\033[36m==>\033[0m No downloaded payloads to remove.\n'; \
	else \
	    _sz=$$(du -shc $$_f 2>/dev/null | tail -n1 | cut -f1); \
	    rm -rf $$_f; \
	    printf '\033[36m==>\033[0m Removed the verified Alpine payloads and GRUB ISOs.\n'; \
	    printf '    \033[1m%s reclaimed.\033[0m The next build downloads them again.\n' "$$_sz"; \
	fi
