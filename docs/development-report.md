# The Construction of Copal Linux: A Development Report

*Lab Report — IEEE Format*

<!-- SPDX-License-Identifier: MIT -->
Copyright (c) 2026 paulr@sdf.org. MIT licensed — see `LICENSE`.

Companion to `lab-report.md`. That report documents the *experiment* — bringing
Alpine up on Raspberry Pi Zero hardware. This one documents the *artifact* — the
installer written to make that result reproducible — and audits it against its
own claims.

> **Read the Addendum first if you want current state.** §§ I–VIII below are the
> audit as it stood on 2026-07-29, retained unrevised so the findings can be
> checked against what was actually there. Every recommendation in § VIII was then
> applied, and the [Addendum](#addendum--remediation-applied-2026-07-29) records
> what changed and what was re-verified. Figures in the body — 316 catalogue rows,
> `aarch64`-only index validation — are audit-time values, not current ones.

---

## Abstract

Copal Linux is a two-part installer that provisions Alpine Linux onto removable
media from macOS and then builds it out, in place, into a persistent system with
a tiling desktop, a 316-entry application catalogue, a toolchain and emulators.
This report reconstructs its development from the repository's own record,
describes the architecture that emerged, and reports the results of a
verification pass performed against the shipping source and against Alpine's
live package index.

The artifact is found to be structurally sound and materially more verified than
its size would suggest. Every mechanically checkable claim examined — 300
hostname pool properties, 316 catalogue rows, five per-port row counts, all
340 package names, generated-script syntax under three shells, generated Lua,
and function definition ordering — verifies clean. Three genuine defects were
found, all of one class and all in the same field of the catalogue table. A
larger and more consequential finding is documentation drift: the README is
current, and the script's own comments and user-facing menu text are two
generations stale, including a stage count that appears in three mutually
inconsistent forms and an application count understated by a factor of three.
`lab-report.md` is separately stale, and asserts as a finding a proposition the
project subsequently disproved on hardware.

## I. Objective

1. Reconstruct the development history of Copal Linux from the repository.
2. Describe the architecture that resulted, and the constraints that produced it.
3. Verify the artifact's factual claims — internally, and against external
   sources of truth where one exists.
4. Report defects, distinguishing those that affect behaviour from those that
   affect only the account the project gives of itself.
5. Assess the development process itself: what kept failing, what was done
   about it, and where the residual risk now sits.

## II. Materials and Method

| Item | Detail |
|---|---|
| Repository | `/Users/user/code/arm-pi-zero`, branch `pi-model-select`, no remote configured |
| History | 29 commits, `8523ba1` … `ad8f287`, all by one author |
| Artifact under audit | `copal-prep.sh`, 10 245 lines (working tree) |
| Generated artifact | `copal-init.sh`, 8 875 lines, extracted from the heredoc at `copal-prep.sh:1077`–`9953` |
| Supporting documents | `README.md` (1 875 lines), `lab-report.md` (531), `LICENSE` (105) |
| External oracle | Alpine v3.24 `APKINDEX`, `aarch64`: `main` (5 983 packages), `community` (22 557), `edge/testing` (7 110) |
| Secondary oracle | `pkgs.alpinelinux.org` contents API, for package file lists |
| Tooling | `bash -n`, `sh -n`, `dash -n`, `luac -p`, and purpose-written Python for structural analysis |

Method was to treat every quantified statement in the source and documentation as
a hypothesis and test it. Where a statement could be checked against the code, it
was recomputed using the code's *own* logic rather than a reimplementation — the
per-port catalogue counts of § V-D, for example, were produced by running the
`awk` program from `catalogue_available()` over the table it filters. Where a
statement concerned the outside world, it was checked against the outside world.

Two limits are stated up front. First, `copal-prep.sh` was **not executed**: it
erases a disk, and there was no card to spend. Second, index validation was
performed for **`aarch64` only**. The other four ports were checked
arithmetically, through the gate column, but not against their own indexes. The
project's records state that stages 1–3 are proven on hardware and 4–15 are not;
nothing in this audit changes that, and nothing here should be read as hardware
confirmation.

## III. Development History

### A. Shape of the record

All 29 commits fall on three calendar days.

| Date | Commits | Window | `copal-prep.sh` at end of day |
|---|---|---|---|
| 2026-07-27 | 27 | 08:24 – 18:41 | 4 499 lines |
| 2026-07-29 | 2 | 11:45 – 12:11 | 7 221 lines |
| 2026-07-29 (uncommitted) | — | to 18:14 | 10 245 lines |

The initial commit is not a beginning. `8523ba1` lands 3 170 lines already
formed — `prep-sd.sh` at 1 900 lines, a 541-line README, a 526-line lab report
and a 192-line run transcript. Version control was introduced to a project
already in flight, which is why the earliest design decisions have no commit that
explains them and survive only as comments in the script.

Growth is 1 900 → 10 245 lines, a factor of 5.4, across three working days. The
rename from `arm-pi-zero`/`prep-sd.sh` to Copal Linux/`copal-prep.sh` occurs at
`fe82b37`, 2026-07-27 17:34, roughly two-thirds of the way through day one.

### B. Phases

Four phases are legible in the sequence:

1. **Correction of the media path** (`4d7cff2` … `1cf20ed`, 08:27–08:54). Four
   commits in 27 minutes, each fixing an assumption in the initial import:
   discover the boot partition rather than assume its mount point, prefer the CDN
   mirror, reboot after stage 3 rather than recommending it, spell out the
   post-reboot path. This is the shape of a script meeting hardware.
2. **Accretion of stages** (`b0a1d81` … `3dd9dc2`, 09:00–17:18). Stages 9, 10 and
   11 arrive, then the emulators, the snapshot scheduler, the app menu, the
   catalogue, the games, the Gopher/Gemini clients and the guide system. The
   script goes 2 160 → 4 021 lines. Six of these commits are fixes to work
   committed the same morning.
3. **Identity and automation** (`fe82b37` … `99dc82a`, 17:34–18:41). The rename,
   the resumes-across-reboot automatic install, the README rewritten around
   Copal, per-board port selection, and a fix for the defect that per-board
   selection introduced.
4. **Generalisation** (`b98ba6b` onward, plus the uncommitted work). Catalogue
   filtered by port; the workshop filled in; a settings tool; and — uncommitted —
   x86 and x86_64 support, which is the largest single body of work in the
   project.

### C. Remediation rate

Eleven of the 29 commit subjects (38%) describe correcting something the previous
state had wrong. Eight of those eleven carry no new functionality at all: they
exist only to undo an error. The defect classes named in the subjects are
consistent and narrow — a shell function called above its own definition, a
validation command with no check-and-exit mode that therefore hung a stage, a
hardcoded path invalidated by the stage that was supposed to follow it, an
archive whose top-level directory was assumed away, a `diskutil` field assumed
always present.

This is the project's dominant failure mode and it is one the author has already
diagnosed in the project's own notes: shell asserted rather than executed,
targeting a machine — busybox `ash` on ARMv6 — that the authoring machine cannot
run. § VII returns to this, because the countermeasures adopted in response are
the most interesting thing about the codebase.

## IV. Architecture

### A. The generator/target split

`copal-prep.sh` is a bash script that runs on macOS. Lines 1077–9953 are a single
quoted heredoc containing `copal-init.sh`, a POSIX-sh script that runs on the Pi
under busybox. **8 875 of the host script's 10 245 lines — 87% — are payload
rather than program.** A further 91 quoted heredocs nested inside that one
generate the artifacts the target script in turn writes: a Lua LSP configuration
for Neovim, `.vimrc`, i3 and i3status configuration, cron jobs, a Makefile,
launcher scripts, eleven plain-text guides, and a morse trainer.

The quoting is what makes this tractable. Because the outer delimiter is
`<<'COPALINIT'`, no expansion occurs at generation time, so the inner script can
use `$VAR` freely and the nested heredocs need no escaping. The cost is that the
generated script is invisible to every tool pointed at the generator — which is
precisely why the extract-and-check discipline of § V-B exists.

### B. Single-source-of-truth structures

Three places in the code deliberately derive rather than duplicate, and each one
closes a drift channel:

- **`auto_manifest()`** is a 13-row table giving each automatic stage its number,
  phase, description and weight. `auto_seq_from_manifest()` cuts field 1 to
  produce the run order; the progress display reads the same table for its
  checklist. The comment states the intent plainly — "so the run order and the
  checklist can never disagree." The derived sequence resolves to
  `1 2 3 8 5 6 4 7 10 12 14 9 13`, which matches the ordering rationale documented
  above it.
- **`catalogue()`** is a 316-row table with six pipe-separated fields, read by
  four consumers: `copal-menu`, `copal-center`, `copal-install` and stage 12.
  Nothing can appear in a menu that is not installable, because there is only one
  list.
- **`ARCH_GATE`** is resolved once from `apk --print-arch` and read as a plain
  variable thereafter. The comment explains why memoising inside the function
  would not work — every call site is a command substitution, hence a subshell,
  so a cached value would be discarded on return. That is a correct and
  non-obvious diagnosis.

The `catalogue_available()` filter strips the gate column after applying it, so
the four consumers still see the five fields they always saw. This is the
structurally strongest decision in the codebase: adding a fifth architecture
required touching one column of one table, and no consumer at all.

### C. State detection over state tracking

`copal-init.sh` is re-runnable and stateless between invocations. It determines
what has been done by interrogating the machine — `apkovl_exists()` lists the
boot partition, `is_diskless()` asks whether `/` is a tmpfs, `sys_installed()`
reads `cmdline.txt`, `x_installed()` asks `apk`, `p2_growable()` counts free
sectors — and recommends the next step from the result. Nothing depends on a
progress file that could disagree with the disk.

One consequence is handled explicitly and deserves note. Stage 3 writes
`cmdline.txt` immediately but `/` does not become the ext4 partition until the
reboot, so between those two moments `sys_installed()` is true while
`is_diskless()` is also true. The suggestion logic tests them in that order and
recommends `reboot` rather than stage 4. This is a correctly identified
intermediate state, and the comment says so.

### D. Failure policy

Optional installation is soft. `try_add()` returns success if *any* package in
its argument list installed, warns on the rest, and lets the stage continue —
because the author cannot know from macOS what every port actually carries. Under
the automatic install, `set -e` is disabled around each stage and the status
recorded, so one failing stage cannot silently end a multi-hour unattended run.

Two stages are excluded from the automatic sequence, and the reasoning given for
the second is the sharper one: stage 15's read-only-root option would cause every
subsequent change to evaporate at the next reboot, and the symptom would be "the
install did not work" with no error anywhere to explain it. That is a failure mode
identified before it happened rather than after.

## V. Verification: Method and Results

### A. Static syntax

All nine tracked shell scripts pass `bash -n`; `copal-prep.sh` also passes
`sh -n`. No syntax defects.

### B. The generated script

`copal-init.sh` was extracted from the heredoc and checked under three shells:

| Check | Result |
|---|---|
| `sh -n` (macOS sh) | pass |
| `dash -n` (closest available proxy for busybox `ash`) | pass |
| `bash -n` | pass |
| `luac -p` on the generated `lsp.lua` (126 lines) | pass |

The Lua check matters more than its size suggests: a syntax error there is loaded
by `.vimrc` at every `nvim` start, so it would break the editor on a machine whose
purpose is editing.

### C. Definition ordering

The project's records identify call-before-definition as a class that both `sh -n`
and `bash -n` accept happily, and which caused a shipped `warn: command not found`.
A purpose-written analyser was used: identify every function definition and its
line, track brace depth and heredoc bodies to isolate genuinely top-level
statements, then flag any top-level reference to a function defined later.

| Script | Functions | Top-level statements | Call-before-definition |
|---|---|---|---|
| `copal-init.sh` (generated) | 190 | 84 | none |
| `copal-prep.sh` (host) | 198 | 930 | 3 candidates, **all false positives** |

The three candidates are the words *note*, *say* and *confirm* occurring inside
quoted English strings — "see the note after you choose", "a card reader may say
this", "to confirm the target" — matched by the analyser's regex, not calls. The
class is clean in both scripts, and the fix from `99dc82a` is in place with the
reasoning recorded above the definitions.

### D. The catalogue: structure

| Property | Claimed | Measured |
|---|---|---|
| Rows | 316 (README) | **316** |
| Rows with exactly 6 fields | — | **316 of 316** |
| Sections | 28 (README) | **28** |
| Distinct package names | — | 340 |
| Duplicate rows | — | **none** |
| Duplicate label within a section | — | **none** |
| Unrecognised gate tokens | — | **none** |

Gate token distribution, against the prose in the comment above the table:

| Token | Rows | Comment claims | Verdict |
|---|---|---|---|
| `*` | 269 | "the overwhelming majority" | ✓ |
| `64` | 21 | list of 17 named examples | ✓ consistent |
| `!v6` | 16 | — | — |
| `!v6,!x32` | 6 | — | — |
| `!x32` | 3 | "nine entries" (3 + 6) | ✓ exact |
| `!v7` | 1 | "exactly one entry: abcde" | ✓ exact |

The armhf exclusion arithmetic also closes: 316 − 273 = 43 = 22 `!v6` rows +
21 `64` rows.

### E. The catalogue: per-port row counts

The README publishes a table of how many rows each port sees. Recomputed by
running the `awk` program from `catalogue_available()` over the table:

| Port | README claims | Measured |
|---|---|---|
| `aarch64` | 316 | **316** |
| `x86_64` | 316 | **316** |
| `armv7` | 294 | **294** |
| `x86` | 286 | **286** |
| `armhf` | 273 | **273** |

Five for five, exact.

### F. The catalogue: against Alpine's live index

Every package name and every `bin` field was checked against Alpine v3.24
`aarch64`, using `main` and `community` for untagged names and `edge/testing` for
`@testing`-tagged ones, with binaries resolved through the `cmd:` provides the
index records.

| Check | Result |
|---|---|
| Package names resolving (340 names, 316 rows) | **340 of 340** |
| `@testing` tags correct (tagged ⟺ absent from stable) | **all correct** |
| `bin` fields with a `cmd:` provider | 313 of 316 — **3 failures** |

Zero package-name errors across 340 names is a strong result, and it corroborates
the project's stated practice of checking names against the real index rather
than from memory. The three `bin` failures are analysed in § VI-A.

### G. The hostname pool

`hostname_pool()` carries an unusually specific set of claims in its comment. All
were tested:

| Claim | Verdict |
|---|---|
| 300 names | **exactly 300** |
| No duplicates | **300 unique** |
| Lowercase ASCII, valid DNS label as-is | **all match `[a-z0-9]{5,15}`**; no accents, spaces or hyphens |
| 5 to 15 characters | **no violations** |
| All 26 letters represented | **all 26** |
| 10 to 13 names each | **min 10, max 13** |
| "q and x are the thin ones" | **q = 10, x = 10** — the only two at the minimum |

Every claim exact, including the two incidental ones. This is the most thoroughly
true comment in the repository.

## VI. Defects

### A. Behavioural: three unreachable `bin` fields

All three are the same defect. `rows()` decides whether a catalogue entry is
installed with `have "$_bin"`, which is `command -v` — so the `bin` field must
name a command resolvable on `PATH`. In these three rows it does not. The
packages install correctly; what fails is status detection and, for the two in
mode `x`, launching.

**D1 — `copal-prep.sh:1712`, Cataclysm DDA.**
```
Games|Cataclysm DDA (survival roguelike)|cataclysm-dda-tiles@testing|cataclysm-dda-tiles|x|64
```
The package provides `cmd:cataclysm-tiles`, not `cataclysm-dda-tiles`. The row
takes the package name for the binary name. Effect: the entry reads
"not installed" permanently, remains in the Install branch of the menu after
being installed, and clicking it in `copal-menu` or the Center executes a command
that does not exist. Gated `64`, so it is live on `aarch64` and `x86_64` — every
Pi 3/4/5, Zero 2 W and PC. Fix: `cataclysm-tiles`.

**D2 — `copal-prep.sh:1785`, SFTP server.**
```
Sharing|SFTP server (comes with sshd)|openssh-sftp-server|sftp-server|h|*
```
`openssh-sftp-server` declares no `cmd:` provides at all; it ships
`/usr/lib/ssh/sftp-server`, deliberately not on `PATH`, because `sshd` invokes it
by absolute path. There is no command for `have` to find, so the row reads
"not installed" on every port forever. This one is not a typo — the entry is
informational and the catalogue has no convention for a row without a runnable
binary. Either give it one, or drop the row and mention SFTP in the SSH guide.

**D3 — `copal-prep.sh:1814`, git-gui.**
```
System|git-gui + gitk|git-gui|git-gui|x|*
```
Three problems in one row, confirmed against the package's file list:
`git-gui` installs only `/usr/libexec/git-core/git-gui`, `git-citool` and
`git-gui--askpass` — nothing on `PATH`, and no `cmd:` provides. So detection
fails, and mode `x` means the Center would try to execute `git-gui` directly when
the correct invocation is `git gui`. Separately, the label promises `gitk`, but
`gitk` lives in a *different* package — `git-gitk`, which does provide `cmd:gitk`
— and the row does not install it. Fix: packages `git-gui git-gitk`, binary
`gitk`.

Note on why these survived earlier validation: the project's notes describe a
validator built on `cmd:` provides and the dependency closure. That oracle can
catch D1, but it cannot catch D2 or D3 — for those, the truth is in the package's
*file list*, which `APKINDEX` does not carry. Confirming D3 required the contents
API. The oracle was the limit, not the diligence.

### B. Documentation drift

The README is current. The script's own comments and its user-facing menu text
are not, by two generations. Every instance below is in a comment or a printed
string; none is in code, and none affects behaviour. They do affect what a user
reads on the machine.

**Stage count, three values in one file.** The menu dispatches fifteen numbered
stages and the README says "fifteen". The script says:

| Location | Says | Verdict |
|---|---|---|
| `copal-prep.sh:20` (banner) | "twelve stages" | **stale** |
| `copal-prep.sh:334` (x86 section) | "all thirteen stages … work the same" | **stale**, should be fifteen |
| `copal-prep.sh:9036`, `:9425` (TUI) | "all thirteen" / "the thirteen stages" | **correct** — these refer to the 13-stage automatic sequence |

**Application count, understated threefold.** The catalogue holds 316 rows. The
script says 105 in five places, two of which a user reads on screen:

| Location | Text |
|---|---|
| `copal-prep.sh:22` | "105 curated applications" |
| `copal-prep.sh:9570` | "the 105-package catalogue" |
| `copal-prep.sh:9906` | menu item 12: "105 small programs" |
| `copal-prep.sh:10186` | "A catalogue of 105 small programs across twelve sections" |
| `copal-prep.sh:10193` | "the Copal Center (Super+c) lists all 105" |
| `README.md:198` | "Of Copal's 105 catalogued applications" |

`copal-prep.sh:10186` also says "twelve sections" against an actual 28.

**Banner contradicts its own configuration block.** Lines 29–33 state that the
script "leaves the remainder of the card unallocated, so an ext4 partition can be
created later on the Pi itself (macOS cannot make ext4)." Lines 66–70, thirty-odd
lines later, define `ROOT_SIZE="${ROOT_SIZE:-R}"` and explain that the fixed-size
approach "stranded most of a large card for no benefit." The banner describes an
abandoned design, and the code that replaced it sits immediately below.

**Banner scope is narrower than the code.** Lines 27–28 scope the script to
"Raspberry Pi Zero 1 / Zero W / Zero 2 W". `MODEL` accepts `zero`, `zero-w`,
`pi1`, `cm1`, `pi2b`, `zero2`, `pi3`, `cm3`, `pi4`, `400`, `cm4`, `pi5`, `pc` and
`pc32` — two architectures and an entire platform beyond what the banner admits.

**The one drift with legal weight.** `README.md:15` reads:

> A Deravative work of Alpine Linux, SD formatter, Install script, for a Raspberry Pi Zero, or Raspberry Pi 2w.

It is misspelled, and it asserts exactly what three other documents in the same
repository take pains to deny. `LICENSE:41` — "Copal is an AGGREGATION of Alpine
Linux, not a derivative work of it. The distinction is the whole reason this
section exists". `README.md:1829` — the same, as a section heading.
`lab-report.md:7` — the same. Twenty-five lines below the offending sentence, the
README itself says Copal "is not a fork of Alpine Linux". Of all the stale prose
in the repository this is the line to fix first: it is the fifteenth line of the
front page, and it concedes the precise claim the licence was written to
forestall.

**Dangling cross-reference.** `.gitignore` says "See README 'Repository contents'
for what that means before adding a remote." No such section existed at audit time; none of the README's
30 second-level headings matched.

**Correction to this finding.** The audit first recorded that the pointer led to
advice "that was never written." That overstated it. The advice does exist, and it
is explicit — `README.md`, under *License* → *The third-party material stored
alongside*, states that the Apple ROM and disk images are not redistributable and
that the repository must not be pushed without removing them from the working tree
*and* from history. What was wrong was the **pointer**, not the guidance. The
defect was therefore a broken cross-reference to real advice under a different
heading, which is a considerably milder finding than the one first written here.
§ VI-D's substance stands; its framing did not.

### C. `lab-report.md` is stale, and one finding is inverted

The experimental report has not kept pace with either the code or the project's
own hardware results.

**The inverted finding.** § IV-B Step 1 records, under the heading "Observation —
one image covers both targets", that a single `armhf` image serves both the Zero 1
and the Zero 2 W, reasoning from the presence of `bcm2710-rpi-zero-2-w.dtb` in the
tarball and ARMv6 user-mode compatibility on Cortex-A53. It concludes that the
second download "is not required. This supersedes the note recorded there."

The project's records show this was **falsified on hardware on 2026-07-27**,
at the cost of a card and a boot. The reasoning was right about userland and wrong
about the kernel: the `armhf` rpi kernel is built `CONFIG_CPU_V6K` with no
`CONFIG_CPU_V7`, so `__lookup_processor_type` in `head.S` matches the A53's MIDR
against the compiled-in `proc_info_list`, finds no entry, branches to `__error_p`
and spins — before the MMU, before any console, and before the device tree is ever
read. The DTB's presence is irrelevant because nothing gets far enough to read it.

`copal-prep.sh` now encodes the opposite conclusion, in code: a `MODEL`→`ARCH`
map, a refusal when `ARCH` disagrees with `MODEL`, and a cross-check of the
payload's own `boot/config-*` before anything is written. The lab report's
central architectural claim is inverted relative to the shipping installer, and
it is stated as a confirmed observation that supersedes an earlier correct doubt.
This is the highest-priority correction in the repository.

**Consequent staleness.** § III-B still assigns Target B the `armv7` port; the
code maps `zero2` to `aarch64`. § IV-B Step 2b records a 2.0 GB boot partition
with 126.2 GB left unallocated; § V-B records `COPALROOT` at 16 GB. Current
defaults are `BOOT_SIZE=4G` and `ROOT_SIZE=R`, the rest of the card — and the
comment at lines 66–70 explains that the 16 GB design was abandoned precisely
because it stranded capacity.

**Incompleteness.** § VI Discussion and § VII Conclusion are both
"*(To be recorded.)*". Two further placeholders remain in § IV — the pending boot
of the scripted card, and the `lsusb`/DHCP/`free -m` observations of Step 5. The
scope omits the Pi 2, 3, 4 and 5, omits x86 and x86_64 entirely, and never
mentions the fifteen-stage installer that is now the project's main artifact.
The § V-B negative result — that the diskless model cannot host a graphical
install because the tmpfs root fills before the card does — remains the report's
strongest contribution and is unaffected by any of the above.

### D. Repository hygiene and one prospective risk

**Uncommitted work.** Twelve tracked files are modified, including a 3 426-line
change to `copal-prep.sh` — the x86/x86_64 support and the settings tool. The
largest single body of work in the project is unversioned, alongside an untracked
`aarch64` payload (tarball, checksum and extracted tree) in `work/`.

**Size.** `.git` is 1.0 GB against a 2.3 GB working tree. Largest tracked
objects: `minivmac/macOS755.dsk.zip` at 894 MB, `minivmac/disk1.dsk` at 100 MB,
the `armhf` tarball at 66 MB. This is a deliberate choice — `.gitignore` says so
in a comment — and it is workable for a local repository. It would make a push
awkward and a shallow clone the only practical one.

**The prospective risk.** `work/vMac.ROM` is tracked, 138 576 bytes: a Macintosh
Plus ROM. `minivmac/vMac.ROM` was emptied at `b8658e8`, but the 131 072-byte blob
remains reachable in history at `20ac6f9` — emptying a file does not remove it
from a repository. With `System_7.0.1.smi.bin` (4.9 MB) and `macOS755.dsk.zip`
(894 MB), the repository tracks a substantial quantity of Apple-copyrighted
material, in history as well as in the working tree.

The project's own notes are clear on the principle: Gryphel does not distribute
the Plus ROM and directs users to dump their own, and copies found on GitHub and
abandonware sites are unlicensed redistributions. Tracking a personal dump in a
local repository is consistent with that. Publishing it would not be, and
`.gitignore` anticipates exactly this by directing the reader to a README section
that turns out not to exist.

No remote is configured, so nothing has been published and no line has been
crossed. But the safeguard against crossing it is a pointer to a document that
was never written, and removing those blobs after a push is materially harder
than before one. Writing the missing section — or filtering the ROM out of
history now — is cheap today and expensive later.

## VII. Discussion

### A. The failure mode, and the response to it

The project's defining constraint is that it is a **generator, for a machine the
author cannot execute on**. `copal-prep.sh` runs on bash under macOS and emits
8 875 lines of POSIX shell for busybox `ash` on ARMv6. Plausible-looking shell is
not working shell, and 38% of the commit history is the bill for that gap.

What makes the codebase interesting is that the response was structural rather
than exhortative. Each recurring defect produced a design change that made the
class harder to reintroduce:

| Recurring defect | Structural response |
|---|---|
| Two lists that must agree, and drifted | `auto_manifest` — derive the run order and the checklist from one table |
| A menu listing what the installer cannot install | One catalogue, four consumers, filter applied once |
| Package names remembered rather than checked | Validate every name and binary against the real `APKINDEX` |
| A helper called above its own definition | Definitions hoisted above the first top-level caller, with the reason written above them |
| A validation command with no check-and-exit mode that hung a stage | Run under `timeout`, treat exit 124 as success |
| A GNU-only construct rejected by busybox | Comment at the site naming the constraint |
| A firmware setting that removed every diagnostic channel at once | Change `usercfg.txt` one line at a time and boot between changes |

The comments are unusually load-bearing. They routinely record what was tried,
what broke, and why the current form was chosen — the `ARCH_GATE` memoisation
note, the `gpu_mem` history, the `a64`→`64` rename explained so "the next person
to add a row has to be able to guess right from the name." For a single-author
project with no test suite, this is the mechanism that carries hard-won facts
forward, and it works. Nearly every non-obvious decision this audit examined had
its rationale attached.

### B. Where the residual risk went

The verification pass produced an asymmetry worth stating plainly.

**Everything load-bearing verifies.** Syntax under three shells. Generated Lua.
Definition ordering across 388 functions. 316 rows, 6 fields each, no duplicates.
340 package names against the live index. Five per-port counts, exact. Gate
arithmetic, exact. Seven separate claims about a 300-name pool, all exact
including the incidental ones. Not one arithmetic or structural error was found in
any of it.

**Everything decorative is wrong.** The stage count appears as twelve, thirteen
and fifteen. The application count is understated by a factor of three, in five
places, two of them on screen. The banner describes a partition layout the code
below it abandoned, and a board list two architectures short. The front page of
the README concedes a legal characterisation the licence spends fifty lines
refuting.

The distribution is not random, and it is not carelessness. Effort went exactly
where a mistake would break a boot or hide an application, and drift accumulated
exactly where a mistake breaks nothing. As a triage under time pressure that is
defensible. But the cost is not zero, because the stale numbers are concentrated
in the menu — the one place a user is *invited* to check a claim. A user who
counts fifteen options beside the words "twelve stages", or installs the
catalogue and finds three times the 105 promised, learns that Copal's numbers are
decoration. That is a poor lesson to teach on a system whose real numbers —
`gpu_mem=32` not 16, `armhf` not `armv7`, 273 rows not 316 — are the difference
between a working card and a dead one.

The two defect groups have the same root, seen from opposite sides. The three
`bin` errors survived because the available oracle (`cmd:` provides) was weaker
than the claim (a command on `PATH`). The stale prose survived because there was
no oracle at all. Both are answered the same way: make the claim checkable, then
check it.

### C. What deserves imitating

Three decisions in this codebase are better than the median for work of this
kind, and are worth naming because they are portable:

1. **Filter once, consume many.** The gate column meant adding a fifth
   architecture touched one column of one table and no consumer. That is the
   difference between four architectures being four times the work and being
   almost none of it.
2. **Derive the second list.** `auto_seq_from_manifest` is one line and it makes
   a whole category of drift impossible rather than merely unlikely.
3. **Comment the wrong turn, not just the right one.** The `gpu_mem=16` note, the
   memoisation note and the `a64`→`64` rename each stop the next reader — or the
   same author in a month — from re-deriving a fact that cost a debug cycle. Most
   codebases record only the destination.

## VIII. Conclusion

Copal Linux is a 10 245-line generator that emits an 8 875-line installer for a
platform its author cannot execute, built in three working days, and it holds up
under audit better than those figures predict. Its structure is sound: one
catalogue behind four consumers, one manifest behind both the run order and the
progress display, one architecture gate resolved once, and state detected from the
machine rather than tracked in a file. Every mechanically checkable claim
examined in § V — and there were a great many, some of them unusually specific —
verified clean.

Three real defects were found, all in the `bin` column of the catalogue, all
affecting status detection rather than installation, and two of them invisible to
the oracle the project had been using. They are small and the fixes are one line
each.

The substantive finding is not a code defect. It is that the project's *account*
of itself has fallen two generations behind its code, in ways ranging from
cosmetic (a stage count in three flavours) to consequential (a front-page
sentence conceding the derivative-work characterisation the licence exists to
deny) to genuinely misleading (a lab report asserting, as a confirmed observation
that supersedes an earlier doubt, a proposition the project later disproved at the
cost of a card). The code learned that one `armhf` image does not serve both
boards. The report still teaches the opposite.

### Recommended actions, in priority order

1. **Correct `lab-report.md` § IV-B Step 1.** Replace the "one image covers both
   targets" observation with the kernel-configuration finding that falsified it,
   and reinstate the § III-B note it wrongly superseded. Fix § III-B's `armv7`
   assignment for Target B, and the 2 GB/16 GB/unallocated figures in § IV-B
   Step 2b and § V-B.
2. **Fix `README.md:15`.** Delete the derivative-work sentence, or restate it as
   aggregation, to agree with `LICENSE:41`, `README.md:1829` and
   `lab-report.md:7`. Fix the spelling of *derivative* while there.
3. **Fix the three `bin` fields.** `copal-prep.sh:1712` →
   `cataclysm-tiles`; `copal-prep.sh:1814` → packages `git-gui git-gitk`, binary
   `gitk`; `copal-prep.sh:1785` → give SFTP a resolvable command or drop the row.
4. **Reconcile the counts.** 105 → 316 at lines 22, 9570, 9906, 10186, 10193 and
   `README.md:198`; twelve sections → 28 at line 10186; twelve/thirteen stages →
   fifteen at lines 20 and 334, leaving 9036 and 9425 alone as they are correct.
   Rewrite the banner at lines 27–33 to match the `ROOT_SIZE=R` layout and the
   full `MODEL` list.
5. **Commit the x86 work.** 3 426 lines of the project's largest change are
   unversioned.
6. **Write the missing README "Repository contents" section**, or filter the ROM
   blobs from history — before a remote is added, while both are still cheap.
7. **Extend index validation to the other four ports**, and to a file-list oracle
   rather than `cmd:` provides alone. § VI-A shows that `APKINDEX` cannot see two
   of the three defects it was used to look for.
8. **Complete `lab-report.md` §§ VI–VII**, and widen its scope to the platforms
   the installer now covers.

## Appendix — Reproducing this audit

```sh
# A. Syntax, all scripts
for f in copal-prep.sh fetch-minivmac.sh work/firstrun.sh \
         work/card-backup/firstrun.sh minivmac/*.sh; do bash -n "$f" || echo "FAIL $f"; done
sh -n copal-prep.sh

# B. Extract and check the generated installer
S=$(grep -n "<<'COPALINIT'" copal-prep.sh | cut -d: -f1)
E=$(grep -n '^COPALINIT$'   copal-prep.sh | cut -d: -f1)
awk -v s=$S -v e=$E 'NR>s && NR<e' copal-prep.sh > copal-init.sh
sh -n copal-init.sh && dash -n copal-init.sh && bash -n copal-init.sh

# C. Extract and check the generated Lua
S=$(grep -n "<<'LSPLUA'" copal-prep.sh | cut -d: -f1)
E=$(grep -n '^LSPLUA$'   copal-prep.sh | cut -d: -f1)
awk -v s=$S -v e=$E 'NR>s && NR<e' copal-prep.sh > lsp.lua && luac -p lsp.lua

# D. Extract the catalogue
S=$(grep -n "cat <<'CATALOGUE'" copal-prep.sh | cut -d: -f1)
E=$(grep -n '^CATALOGUE$'       copal-prep.sh | cut -d: -f1)
awk -v s=$S -v e=$E 'NR>s && NR<e' copal-prep.sh > cat.txt
awk -F'|' 'NF!=6 {print NR": "NF" fields"}' cat.txt      # expect no output
cut -d'|' -f1 cat.txt | sort -u | wc -l                  # expect 28
sort cat.txt | uniq -d                                   # expect no output

# E. Per-port row counts, using the script's own gate logic
for a in a64 x64 v7 x32 v6; do
  printf '%-4s ' "$a"
  awk -F'|' -v a="$a" 'NF<6{next}
    { keep=1; n=split($6,g,",")
      for(i=1;i<=n;i++){
        if(g[i]=="*") continue
        if(g[i]=="64"){ if(a!="a64"&&a!="x64") keep=0 }
        else if(substr(g[i],1,1)=="!"){ if(a==substr(g[i],2)) keep=0 } }
      if(keep) c++ } END{print c+0}' cat.txt
done
# expect 316 316 294 286 273

# F. Hostname pool properties
awk "NR>=103 && NR<=200" copal-prep.sh | awk "/<<.WATERS.\$/{f=1;next} /^WATERS\$/{f=0} f" \
  | tr -s ' \n' '\n' | grep . > names.txt
wc -l < names.txt; sort -u names.txt | wc -l               # expect 300, 300
awk 'length<5||length>15' names.txt                        # expect no output
grep -v '^[a-z0-9]*$' names.txt                            # expect no output
cut -c1 names.txt | sort | uniq -c | sort -n | head -2     # expect q=10, x=10

# G. Catalogue against the live index (aarch64)
for r in main community; do
  curl -fsSO "https://dl-cdn.alpinelinux.org/alpine/v3.24/$r/aarch64/APKINDEX.tar.gz"
done
curl -fsS -o APKINDEX-testing.tar.gz \
  "https://dl-cdn.alpinelinux.org/alpine/edge/testing/aarch64/APKINDEX.tar.gz"
# then compare field 3 against ^P: names and field 4 against ^p:cmd: provides
```

## References

[1] Alpine Linux, "Alpine Linux 3.24.1 release," 13 Jun. 2026.
    Available: https://alpinelinux.org/

[2] Alpine Linux package index, v3.24 `main`/`community` and `edge/testing`,
    `aarch64`. Available: https://dl-cdn.alpinelinux.org/alpine/

[3] Alpine Linux package contents browser.
    Available: https://pkgs.alpinelinux.org/contents

[4] This repository: `lab-report.md`, `README.md`, `LICENSE`, and the commit
    range `8523ba1`…`ad8f287`.

---

## Addendum — Remediation applied, 2026-07-29

The recommendations of § VIII were applied in the same session as the audit. This
addendum records what changed and what was re-verified; the body above is left as
the audit found things.

### A. Behavioural fixes (§ VI-A)

| Row | Before | After |
|---|---|---|
| Cataclysm DDA | `bin` = `cataclysm-dda-tiles` | `bin` = `cataclysm-tiles` |
| git-gui | pkgs `git-gui`, `bin` `git-gui` | pkgs `git-gui git-gitk`, `bin` `gitk` |
| SFTP server | `openssh-sftp-server` / `sftp-server` | **row removed** |

The SFTP row was removed rather than repaired because no repair exists:
`openssh-sftp-server` ships one file, `/usr/lib/ssh/sftp-server`, which `sshd`
invokes by absolute path. It declares no `cmd:` provides on any of the five ports,
so there is no command for `have()` to detect and nothing for mode `h` to open.
Enabling SFTP is an `sshd_config` matter, not an application to install.

A comment block was added above `catalogue()` stating the `bin` field's contract —
a command on `$PATH`, not a package name and not a file path — naming all three
defects, and recording that `cmd:` provides are a *weaker* oracle than the truth
because they describe `/usr/bin` and say nothing about `/usr/libexec`.

The catalogue is now **315 rows across 28 sections**.

### B. Count reconciliation (§ VI-B)

`copal-prep.sh`: "twelve stages" → fifteen (line 20); "all thirteen stages" →
fifteen (line 334); 105 → 315 in all five places; "twelve sections" → 28; and a
stale "nine-program minimal set" → twelve, which the audit had not caught — the
`m` branch installs sixteen package names covering twelve named programs.

The two occurrences of "thirteen" in the TUI code were **left alone**: they refer
to the 13-stage automatic sequence and are correct. So is `README.md`'s "the other
twelve stages," which counts the remainder of that same 13-stage run.

The banner at lines 27–37 was rewritten. It had described leaving the card
remainder unallocated for an ext4 partition to be made on the Pi — a design
abandoned two generations earlier — and scoped the script to three Pi Zero
variants. It now describes the two-partition `COPALBOOT`/`COPALROOT` layout, states
why the root slot is created on the host, and names the full `MODEL` range
including the PC path.

`README.md` counts were moved to 315/315/293/285/272, matching § C below.

### C. Re-verification

Every check from § V was re-run after the edits.

| Check | Result |
|---|---|
| `bash -n`, `sh -n` on `copal-prep.sh` | pass |
| Generated `copal-init.sh` (8 900 lines) under `sh -n`, `dash -n`, `bash -n` | pass |
| Catalogue structure | 315 rows, all 6 fields, 28 sections, no duplicates |
| Per-port counts vs. README table | 315 / 315 / 293 / 285 / 272 — match |

Index validation was extended to **all five ports** (§ VIII item 7), against v3.24
`main` + `community` + `edge/testing` for each:

| Port | Rows shown | Package errors | Binary errors |
|---|---|---|---|
| `aarch64` | 315 | 0 | 0 |
| `x86_64` | 315 | 0 | 0 |
| `armv7` | 293 | 0 | 0 |
| `armhf` | 272 | 0 | 0 |
| `x86` | 285 | 0 | 0 |

1 480 row-instances checked, clean. The pre-fix run over the same five ports found
exactly the three defects of § VI-A and no others, which is the useful control: the
fixes introduced nothing, and the four ports not originally audited were never
carrying a fourth defect.

### D. Documentation fixes

**`README.md:15`** — the "Deravative work of Alpine Linux" sentence was replaced
with one that states the aggregation relationship and links to *License*. It had
contradicted `LICENSE:41`, `README.md`'s own *aggregation* subsection and
`lab-report.md:7`.

**`README.md`** — a *Repository contents* section was added: what is tracked and
at what size, that none of it is required because both payloads are fetched and
verified by script, and a warning against pushing to a public remote while the
Apple ROM and disk images are present in the working tree *and* history, citing
`minivmac/vMac.ROM` as the worked example. `.gitignore`'s pointer was rewritten to
reach it. The blobs were **not** removed from history — that is a rewrite, and it
is the owner's call, not a cleanup to perform unasked.

### E. `lab-report.md`

The inverted finding was corrected in the manner a lab report requires — by
recording the falsification, not by deleting the error.

- § IV-B Step 1's "Observation — one image covers both targets" is relabelled
  **Hypothesis (subsequently falsified)**, with a note explaining that its two
  premises are *both still true* and that neither concerns the kernel.
- § III-B's note is reinstated as having been correct and wrongly set aside, and
  Target B is reassigned from `armv7` to `aarch64`.
- A new **§ IV-C** records Attempt 3: the `armhf` payload booted on Target B,
  producing no output at all, and the mechanism — `__lookup_processor_type` in
  `head.S` failing to match the A53's MIDR `0x410fd034` against an ARMv6-only
  `proc_info_list`, before the MMU or any console exists. It gives the board→port
  table, the kernel-config identification method adopted in response, and a
  premise-by-premise account of why the inference failed.
- § IV-B Step 2a's partition description and § V-B's 16 GB figure are marked
  superseded in place, with the reason the intermediate design was abandoned.
  **The measured values in § IV-B Step 2b were left untouched** — they are the
  record of an actual run, and revising a measurement to match a later default
  would be falsifying data.
- §§ VI and VII, previously "*(To be recorded.)*", are written from findings
  already in the report: the inverted difficulty of the objective, the two
  misidentified constraints, the cost of Alpine's central virtue, the three
  failure modes that destroy their own evidence, and the pattern of labelling
  inference as observation. Seven numbered conclusions.

Nothing was invented to fill them. The two uncollected measurements — the
X-versus-`tmux` `free -m` comparison and the § IV-B Step 5 observations — are named
as outstanding, because only hardware can supply them.

### F. Not done, and why

- **ROM blobs remain in git history.** Removing them means `git filter-repo`, which
  rewrites every commit. That is the owner's decision. The README now says so, and
  no remote is configured.
- **Stages 4–15 remain unexercised on hardware.** Outside the reach of a static
  audit.
- **The `armv7`, `armhf`, `x86` and `x86_64` boot paths** are validated only at the
  package-index level. No card was written and nothing was booted; `copal-prep.sh`
  was never executed, because it erases a disk.

---

## Addendum — Four defects found in the first full-automatic hardware log, 2026-07-30

§ F above closes by naming stages 4–15 as unexercised on hardware. They have now
been exercised: a full-automatic install ran to completion on a Zero 2 W across
two sessions (2026-05-24, resumed 2026-06-14), and its log is the first evidence
this project has that was not produced by reading the script. It found four
defects, three of which no static audit could have found because each one is a
piece of code that *runs and reports success*.

### A. The admin user has no home directory after stage 3

**Observed.** `/home/user` missing on the installed system, reported from the
machine. The log is consistent with a weaker statement: nothing in it ever
*creates* the directory deliberately. The only thing that brought one into
existence during that run was stage 6's `mkdir -p $HOMEDIR/.ssh`, which makes it
root-owned, and stage 9 then wrote `~/vice` into it on that basis. So the run
ended with either no home directory or a root-owned one, depending on how far it
got; both are the same defect and the fix addresses both.

**Cause.** `setup-disk -m sys` builds the new root from packages plus the apkovl,
and the apkovl is `/etc`. `/etc/passwd` crosses onto p2; `/home` does not.
`adduser` made the home directory once, in RAM, during stage 1, and nothing
recreates it. The account arrives on the new root complete in every respect
except the directory it names.

**Why nothing complained.** `install_home_file` guards each destination with
`[ -d "$_h" ] || continue`, so every dotfile it writes for the admin user — the
`.xinitrc`, the i3 config and keybinding sheet, `.Xresources`, `.vimrc`, the
Neovim LSP config, `.gdbinit`, the `~/dev/hello` sample project — was written to
`/root` and silently skipped for `user`. `configure_git_identity` skipped for the
same reason. `stage_sshkey` did the opposite and worse: `mkdir -p $HOME/.ssh`
created `/home/user` as a side effect, owned by root, so later stages found a
directory that existed and wrote into it a home its owner cannot write. A comment
in `auto_install_resume_hook` recorded the wrong model explicitly — that the home
directory exists under `/mnt` "after setup-disk has copied it across."

**Fixed.** A new `ensure_user_home [prefix]` creates it with the mode, ownership
and `/etc/skel` contents `adduser` would have given it; where one already exists
but is owned by root — the state stage 6's `mkdir` leaves behind — it takes
ownership instead. It is silent when there is nothing to do. Stage 3 calls it on
`/mnt` while the new root is still mounted,
which is the repair at the point of loss; `install_home_file`, `admin_sync_password`
(stage 1), `stage_sshkey`, `configure_git_identity`, both emulator profiles and
stage 13 call it as a guard. `state_report` now prints the home directory and its
owner as a line of its own, because the account can be perfect and the directory
absent. The stale comment was corrected.

### B. Stage 13 refused to hand over root, on a machine where `doas` worked

**Observed.** `!! doas config : /etc/doas.conf does not parse` — then `!! not
locking root -- fix the above first.` The remedy it printed (`passwd user &&
adduser user wheel && apk add doas`) addressed none of it; the log's own state
report says the account was already in `wheel` with a password set.

**Cause.** The check was `doas -C /etc/doas.conf true`. Handing `-C` a command
changes the question from *is this file valid* to *may the user running me run
that command*, and stage 13 runs as root, whom no `permit :wheel` rule matches.
The answer is no however healthy the configuration is, and the exit status is
indistinguishable from a parse error. It also read the wrong file: Alpine's
`doas` (6.8.2-r8, confirmed against the `.apk` in `work/`) ships an `/etc/doas.conf`
whose every line is a comment, `# permit persist :wheel` among them, plus an
empty `/etc/doas.d/`; since 6.8.2-r5 it reads both, in that order, and requires
the first to exist. Copal's own rule goes into `/etc/doas.d/wheel.conf`, which
the check never looked at.

**Fixed.** `admin_ensure_doas` checks the three facts separately — the binary is
installed, `/etc/doas.conf` exists, some `permit` rule reaches the admin user —
repairs each, and validates with `doas -C <file>` and *no* command, which is the
syntax check and nothing else. It reports doas's own message rather than a flat
"does not parse". Stage 1 and stage 13 now share it, so the stage that refuses to
hand over is the stage that can fix the reason. Stage 13's "working shell and home
directory" test was also split: `su` falls back to `/` when it cannot `chdir` to
`$HOME` and carries on, so that test passed on a machine with no home directory.

### C. `!! skipped X -- not in the configured repositories`, said 100 times, wrongly

**Observed.** From part-way through stage 12, almost every package that needed an
actual `apk add` was reported missing from the repositories — including `rsync`,
`zip`, `samba`, `tig`, `sshfs`, `xorriso` and `xarchiver`, all of which are in
Alpine `main` or `community` for `aarch64` and were verified as present by this
report's own § V index checks. Packages already installed continued to report
correctly, which is the tell: the `apk info -e` path needs no network and the
`apk add` path does.

**Cause.** `try_add` ran `apk add "$_p" >/dev/null 2>&1` and attributed every
non-zero exit to one cause. Whatever actually happened — the log is consistent
with the mirror becoming unreachable mid-stage — went to `/dev/null`. Stage 9's
Mini vMac download failed in the same window; the URL it reported is live and the
tarball is 500 kB (`minivmac/minivmac-36.04.src.tgz`, already fetched on the Mac),
so that failure was almost certainly the same outage rather than the moved version
number its message suggests.

**Fixed.** `try_add` captures apk's stderr and classifies it: unreachable
repositories, a full filesystem, a genuinely absent package, or apk's own text
verbatim. Network symptoms are tested *first*, because apk reports a package it
cannot fetch an index for as "no such package" too — which is exactly how a
hundred packages that exist came to be logged as ones that do not. An unattended
install is read from its log afterwards or not at all.

### D. `add_optional` was not safe bare, which is its entire purpose

**Found while reading the failure path in § C, not in the log.** The comment
above `try_add` states the contract: `add_optional` installs what it can, reports
what it cannot, and *always succeeds* — "Safe bare" — and records that the split
exists because sixteen bare calls used to abort their stage. The implementation
was `add_optional() { try_add "$@"; }`, which returns `try_add`'s status. Under
`set -e` a bare call whose every package was unavailable took the whole script
down.

The automatic install hid this: `auto_run` turns `set -e` off around each stage,
which is why the log shows six consecutive Small Web skips and then carries on.
The menu path has no such protection, so this could only ever have bitten someone
driving stages by hand — the one case nobody is reading a log for. Fixed by adding
the `|| true` the documentation had always claimed was there.

### E. Verification

| Check | Result |
|---|---|
| `bash -n copal-prep.sh` | pass |
| Generated `copal-init.sh` under `sh -n` | pass |
| `ensure_user_home`: missing home, skel copied, mode/owner | pass |
| `ensure_user_home`: existing home, correctly owned, is a silent no-op | pass |
| `ensure_user_home`: existing home owned by root | chowned to the user |
| `ensure_user_home`: existing home, `stat` unavailable | left alone, silent |
| `ensure_user_home`: no such account, empty home field | returns non-zero, prints nothing |
| Every `ensure_user_home` call site guarded against `set -e` | pass |
| `doas` helpers vs. stock Alpine layout (comments only, empty `doas.d`) | rule added, config valid |
| `doas` helpers: missing `doas.conf`, broken file in `doas.d` | created; rejected with doas's message |
| `doas_rule_present`: `:wheel`, the user by name, another user, a commented rule | present, present, absent, absent |
| `try_add` classification: ok / absent / outage / ENOSPC / silent | five for five |
| `add_optional` bare under `set -e`, all packages failing | continues (aborted before the fix) |

The `doas` behaviour was established from the 6.8.2-r8 `.apk` in `work/` — its
`/etc/doas.conf`, its empty `/etc/doas.d/`, and the `.post-upgrade` script that
states the two-file contract — not from memory of what Alpine ships. The helper
tests ran against a stand-in `doas -C` with that same contract, since the real
one is `aarch64`.

**Not verified on hardware.** None of this has been run on the Pi. The four fixes
are argued from the log, from Alpine's packaging, and from tests of the shell
logic in isolation; the next card written is what would confirm them.

### F. Falsification: § A's stated mechanism was wrong

§ A above claimed that "`/etc/passwd` crosses onto p2 and `/home` does not",
because "the apkovl is `/etc`". That is false, and the card falsified it within
the hour.

`/Volumes/COPALBOOT/ucayali.apkovl.tar.gz` **contains** `home/user/` — an empty
directory, `drwxr-sr-x user user`. `/etc/apk/protected_paths.d/lbu.list` in the
same overlay reads `+home/user`, `+media/mmcblk0p2`, `-media/mmcblk0p2/cache`:
the second and third are stage 2's, and the first is not Copal's at all.
`alpine-conf` 3.22.0, `setup-alpine` lines 321–326, immediately after
`setup-user`:

```sh
for i in "$ROOT"home/*; do
    if [ -d "$i" ]; then
        lbu add $i
    fi
done
```

So `/home/$user` is in lbu's include list from the moment the account exists,
it is in every apkovl written afterwards, and `setup-disk` unpacks it onto the
new root. The directory does cross stage 3.

**What survives of § A.** The apkovl is a snapshot, not a mirror: it is only as
new as the last `lbu commit -d`, and Copal commits in stages 1 and 2, when the
home is empty. So the home that arrives on p2 is an empty one, and everything
written into it between that commit and the reboot is gone — which is the same
practical outcome by a different route, and is what the empty `home/user/` in
this card's overlay actually shows. Stage 6's root-owned `mkdir` (§ A) is
untouched by any of this and remains exactly as described.

**What this changes.** The fix does not change: `ensure_user_home` creates a
missing home, takes ownership of a root-owned one, and is silent otherwise, all
of which remain correct and necessary. The explanation changes, and it is the
explanation that tells the next reader where to look — so the comments in
`ensure_user_home`, stage 3 and `auto_install_resume_hook` were corrected to
state the snapshot mechanism and to cite the `setup-alpine` lines rather than an
assumption about what an apkovl contains.

**Method note.** The claim was made from reading `setup-disk`'s behaviour and
never checked against an actual overlay, then written into a commit message as
though established. The overlay was sitting on a mounted card the whole time.

### G. Mini vMac now travels on the card (§ C, closed)

§ C left the Mini vMac download as "offered, not done". It is done: `copal-prep.sh`
stages `minivmac-*.src.tgz` and a verified `vMac.ROM` into `COPALBOOT/minivmac/`,
in both full-write and `--refresh` mode, and stage 9 prefers what is on the card
over the network. The download remains as the fallback, so a card without staged
files behaves exactly as before.

The version comes from the staged filename rather than from `MINIVMAC_VER`, since
the tarball on the card is the one that will actually be built and a disagreement
between the two would misname the version in every message downstream.

The ROM is verified rather than trusted, reusing `fetch-minivmac.sh`'s method: the
first four bytes of a Mac ROM are a big-endian checksum over the 16-bit words that
follow, so a dump is self-verifying. The staging function looks for a *window* that
verifies (128 KiB, then 64 KiB), trims trailing padding, and refuses anything that
does not check out.

That last part is not hypothetical. This repository holds two files called
`vMac.ROM`: `work/vMac.ROM`, a genuine Macintosh Plus v1 dump (`4d1f8172`) with
7 504 bytes of trailing padding, and `minivmac/vMac.ROM`, **zero bytes**. An empty
file satisfies `[ -f "$ROM" ]` — the guard used by the Pi's `run-plus.sh` and by
`minivmac/lib-profile.sh:25` — and then fails inside the emulator with a message
that says nothing about ROMs. The generated `run-plus.sh` now tests `-s`;
`lib-profile.sh` is host-side and was left alone.

**Staged and verified on the card**, which is a stronger claim than anything else
in this addendum: `COPALBOOT/minivmac/` holds `minivmac-36.04.src.tgz` (500 742
bytes, 140 entries, containing the `minivmac/setup/tool.c` that stage 9's `find`
looks for) and `vMac.ROM` (exactly 131 072 bytes, first four bytes `4d1f8172`),
with macOS AppleDouble sidecars cleaned off. What has *not* been verified is stage
9 consuming them, which needs the Pi.

### H. A piano tutor, and what the index says about music education

The catalogue carried two typing tutors (`gtypist`, KTouch) and nothing that did
the same job for a piano keyboard: no tutor, no MIDI play-along, no accompaniment.
Before adding anything, the question "does Alpine package one" was answered
against the index rather than from memory — 35 650 packages, `aarch64`, v3.24
`main` (5 983) + `community` (22 557) + `edge/testing` (7 110).

**Absent from all three:** PianoBooster, Linthesia, VMPK, TiMidity++, GNU Solfege,
Nootka, Rosegarden, Denemo, TuxGuitar, MMA, kmetronome, GrandOrgue, LinuxSampler.
A fuzzy search on `piano|midi|solfege|chord` returned `pianobar` (a Pandora
client) and the `portmidi`/`rtmidi` libraries — nothing else.

**Present:** `minuet` (community, KDE music education — theory and ear training,
28.8 MB packaged, but Qt6 + KF6 + QML), `lilypond`, `frescobaldi`, `qsynth`,
`yoshimi`, `muse`, `jack`, `qjackctl`, `a2jmidid`. None of them is a tutor.

So Minuet was added to the catalogue as one row — checked across all five ports,
present on four, absent on `armhf`, hence gate `!v6`, and `cmd:minuet` confirmed
as the binary — and **PianoBooster is built from source**, which is what stage 9
already does for Mini vMac and VICE.

#### Why a commit and not the release

PianoBooster's only release is v1.0.0, December 2020. It does not build on
Alpine 3.24, for two independent reasons found by reading the source rather than
by trying:

| | v1.0.0 | develop (`6dafdcb`) |
|---|---|---|
| Qt linkage | `qt5_use_modules()`, removed in Qt 5.15 — Alpine ships 5.15 | uses `target_link_libraries` only |
| Qt version switch | none | `QT_PACKAGE_NAME`, default Qt5 |

Both declare `cmake_minimum_required(VERSION 2.4)`, and Alpine 3.24 ships **CMake
4.2.3**, which removed compatibility with anything below 3.5 and refuses to
configure. The build passes `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`, which is CMake
4's documented escape hatch; without it the stage would fail at configure time on
every card. So the pinned ref is a develop commit, and `PIANOBOOSTER_REF`
overrides it.

Every build dependency was confirmed present for `aarch64`: `build-base`,
`cmake`, `pkgconf`, `qt5-qtbase-dev`, `qt5-qttools-dev` (the CMake file asks for
LinguistTools by name), `ftgl-dev`, `fluidsynth-dev`, `alsa-lib-dev`, `mesa-dev`.
`rtmidi-dev` is only in `edge/testing`, so the stage tries it and falls back to
`-DUSE_BUNDLED_RTMIDI=ON` — which is also the outcome that keeps an edge library
out of a v3.24 system, making the fallback the safer branch rather than the
degraded one.

#### What is not established

`FIND_PACKAGE(OpenGL REQUIRED)`: PianoBooster renders its scrolling score through
OpenGL, with FTGL on top. There is no GL driver on the VideoCore framebuffer, so
this is llvmpipe — software rasterisation on four 1 GHz A53s. **It may be too slow
to play along to, and nothing short of running it can settle that.** The stage
says so before it starts, and again after it installs the binary. Play-along is
also latency-sensitive, and a Zero has no analogue audio out.

#### Verification

| Check | Result |
|---|---|
| `bash -n copal-prep.sh`; generated `copal-init.sh` under `sh`, `dash`, `bash` | pass |
| `piano-midi` under `sh`, `dash`, `bash` | pass |
| `piano-midi` against stubbed `aconnect`/`fluidsynth` | `list`, `play`, `start`, `stop`, `help` all correct; skips `System` and `Midi Through`, connects only the keyboard |
| `piano-midi` failure paths | no keyboard, no soundfont, synth registers no port — each exits with an actionable message |
| Catalogue structure | 316 rows, all 6 fields, 28 sections, no duplicate descriptions |
| Per-port counts, by the script's own gate logic | 316 / 316 / 294 / 286 / 272 |
| Minuet row vs. live index, five ports | package and `cmd:` provide confirmed; absent on `armhf` only |
| Staged tarball, pinned | `pianobooster-develop-6dafdcb.tar.gz`, 3 086 387 bytes, sha256 `e868b3cb…10c04f`, 303 entries |

Counts in `copal-prep.sh` and `README.md` were moved from 315/315/293/285/272 to
316/316/294/286/272. § VI-B's earlier reconciliation is left as it was written.

**Not verified:** the compile itself. It cannot be run here — it is an `aarch64`
musl build against Alpine's Qt5 — so what is established is that every dependency
exists, that the two known blockers are handled, and that the stage reports
failure with the tail of `/var/log/pianobooster-build.log` rather than claiming
success. Whether PianoBooster compiles, and whether it is usable once it does,
needs the Pi.
