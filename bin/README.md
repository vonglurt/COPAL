# bin/ -- shortcuts to the make targets

Two lines of shell each. Every one of them changes directory to the top of the
checkout and hands off to `make`, so `bin/vm.sh` and `make vm` are the same
thing and there is nowhere for them to disagree.

    ./bin/ls.sh                 the index -- every shortcut and what it runs
    ./bin/menu.sh               ./copal, the front door. Start here
    ./bin/vm.sh MEM=4096        boot the VM with 4 GB
    ./bin/sd.sh zero2           write a card for a Pi Zero 2 W

## Why they exist, and what they are not

They save typing and they work from any directory -- `~/code/copal/bin/check.sh`
does the right thing from anywhere, which `make check` does not. That is the
whole of it.

They are **not** a second front door. `./copal` is the front door and `make
help` is the target list; a shortcut here that explained the build would be a
third copy of an explanation that is already in two places and would be the
first of the three to go stale. What each file carries is a header comment
about *that one target* -- what it destroys, what it keeps, and which variables
it takes -- and `bin/ls.sh` reads those headers rather than repeating them.

Variables pass straight through, because `"$@"` is on the end of every `exec`:

    bin/fresh.sh MODEL=vmx86        bin/refresh.sh MODEL=zero2
    bin/graphical.sh MEM=4096 CPUS=4

Three of them take a board name instead, since the target itself is a pattern:

    bin/sd.sh BOARD    bin/img.sh BOARD    bin/fresh-img.sh BOARD

Run any of those three with no argument and they print the board list.

## Keeping them honest

A shortcut carries no logic, but it does carry a target name, and a name goes
stale quietly. `make lint` runs `sh -n` over this folder and then checks that
every `exec make` line names a target the Makefile still defines -- so renaming
a target fails the lint, rather than leaving a shortcut that only fails when
somebody runs it.

Adding one is a copy, a new header, and nothing else. `bin/ls.sh` finds it on
its own.

## The two that destroy things

`bin/clean.sh` and `bin/distclean.sh` remove build output; `bin/fresh.sh` and
`bin/fresh-img.sh` delete an image before rebuilding it. None of them is
quieter about it than the make target is. `bin/sd.sh` still hands you to
copal-prep.sh's two typed ERASE confirmations -- nothing here skips those.

Run `bin/space.sh` first to see the bill before paying it.
