# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

# The GTK example, built the way a C project would build it: a compiler, a
# linker and a Makefile, with GTK found through pkg-config. Nothing here knows
# about the Zig build system except the one rule that produces the library,
# and that rule is only a convenience -- point PREFIX at an installed copy and
# it is never used.
#
#     make                     # build against ../../zig-out, building it if needed
#     make run                 # and run it in whatever language this machine says
#     make run LOCALE=fi       # or in one named outright
#     make smoke               # drive it headless, which is what CI does
#     make PREFIX=/usr/local   # against an installed copy instead
#     make LINKAGE=shared      # link libfluent.so rather than libfluent.a
#     make clean

# Plain `=`, not `?=`: make predefines `CC` as `cc`, so `?=` would never take
# effect and the compiler asked for here would silently not be the one used.
# A command line still wins -- `make CC=clang` does what it says.
CC = gcc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O2

PKG_CONFIG ?= pkg-config

# Where the library and its header are. `zig build --prefix DIR` puts them
# there; the default is what a plain `zig build` in this repository produces.
PREFIX ?= ../../zig-out

# `static` needs no rpath and no LD_LIBRARY_PATH, which is why it is the
# default for an example. `shared` is what a distribution would do.
LINKAGE ?= static

# The translations, read at run time rather than embedded, so the same `.ftl`
# files serve this example, the Win32 one, the plain C one and the Zig one.
LOCALE_DIR ?= ../locales

# `../common` is the half of this program that has no GTK in it, shared
# verbatim with `examples/win32`.
CPPFLAGS += -I$(PREFIX)/include -I../common -DLOCALE_DIR='"$(LOCALE_DIR)"'

GTK_CFLAGS := $(shell $(PKG_CONFIG) --cflags gtk4)
GTK_LIBS := $(shell $(PKG_CONFIG) --libs gtk4)

SOURCES := greeting.c ../common/catalog.c
STATIC_LIB := $(PREFIX)/lib/libfluent.a

ifeq ($(LINKAGE),shared)
LDFLAGS += -L$(PREFIX)/lib -Wl,-rpath,$(abspath $(PREFIX)/lib)
LDLIBS += -lfluent
LIBRARY := $(PREFIX)/lib/libfluent.so
else
# Named as a plain input rather than with -l, so that the static one is what
# gets linked even when a shared one sits beside it.
LDLIBS += $(STATIC_LIB)
LIBRARY := $(STATIC_LIB)
endif

# What a static link needs underneath, which is what `pkg-config --libs
# --static fluent` would tell you: Zig's standard library wants libm and
# pthreads. GTK 4 does not run on macOS' native toolkit, so unlike
# `examples/c/Makefile` there is no CoreFoundation case here.
LDLIBS += -lm -lpthread

# Zig's object files carry no `.note.GNU-stack`, and GNU ld then warns that it
# is assuming an executable stack. Saying so explicitly is quieter and safer
# than being assumed into it.
LDFLAGS += -Wl,-z,noexecstack

.PHONY: all run smoke clean library

all: greeting

greeting: $(SOURCES) ../common/catalog.h $(LIBRARY)
	$(CC) $(CFLAGS) $(GTK_CFLAGS) $(CPPFLAGS) -o $@ $(SOURCES) \
		$(LDFLAGS) $(GTK_LIBS) $(LDLIBS)

run: greeting
	./greeting $(LOCALE)

# Headless, which is what CI has. GTK 4 draws through GL by default and there
# is no GL under Xvfb, so the cairo renderer is asked for by name; without it
# this dies in `gsk` before any of this example's own code runs.
#
# Three things have to be true, and this checks all three rather than trusting
# an exit status, because a program that drew nothing exits zero as happily as
# one that worked:
#
#  1. it exited zero;
#  2. it printed `smoke complete`, which is the last thing its script does, so
#     a run that stopped early or never started fails here rather than passing
#     quietly;
#  3. it warned about nothing. A GTK warning is a finding -- `Trying to measure
#     GtkApplicationWindow ... but it needs at least` means some widget answers
#     "how tall are you?" inconsistently, and it says so on a real desktop just
#     as loudly as under Xvfb.
#
# Two things are allowed through, and both are the machine rather than the
# program: Mesa's lines about DRI3 are this display having no GPU, and
# `Unable to acquire session bus` is this container having no D-Bus, which
# `GtkApplication` asks for on the way up and does without. Every desktop has
# both and no headless runner has either, which is exactly why they are named
# here rather than left to fail a build that is working.
smoke: greeting
	@rm -f smoke.out smoke.err
	@xvfb-run -a env GSK_RENDERER=cairo GDK_BACKEND=x11 ./greeting --smoke \
		>smoke.out 2>smoke.err; \
	status=$$?; \
	cat smoke.out; \
	if [ $$status -ne 0 ]; then \
		echo "smoke: the program exited $$status"; cat smoke.err; exit 1; \
	fi; \
	if ! grep -q '^smoke complete:' smoke.out; then \
		echo "smoke: it never reached the end of its own script"; \
		cat smoke.err; exit 1; \
	fi; \
	if grep -vE '^MESA-EGL: |Unable to acquire session bus' smoke.err \
		| grep -q .; then \
		echo "smoke: it warned about something:"; \
		grep -vE '^MESA-EGL: |Unable to acquire session bus' smoke.err; \
		exit 1; \
	fi; \
	echo "smoke: reached the end of its script and warned about nothing"

# The one Zig rule, and the only thing in this file that knows Zig exists:
# build the library this example links against.
library:
	cd ../.. && zig build c --prefix zig-out -Doptimize=ReleaseSafe

# Asked for every time when the library is this repository's own, since `zig
# build` caches and a stale `libfluent.a` would otherwise sit there through
# every edit to `src/c.zig`. An installed copy is not ours to rebuild, so
# pointing PREFIX elsewhere takes the rule out of the graph entirely and this
# example needs no Zig at all.
ifeq ($(PREFIX),../../zig-out)
$(LIBRARY): library
endif

clean:
	rm -f greeting smoke.out smoke.err
