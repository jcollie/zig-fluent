# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

# The GTK example again, with the window declared in Blueprint rather than
# built by calling GTK. Two tools stand between the markup and the binary --
# blueprint-compiler, which turns `greeting.blp` into GtkBuilder XML, and
# glib-compile-resources, which turns that XML into a C file of bytes -- and
# the rest of this file is `examples/gtk/Makefile`.
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

# The two that turn markup into something the compiler can read.
# blueprint-compiler is its own project; glib-compile-resources comes with
# GLib, so anything that has GTK 4 to build against has it already.
BLUEPRINT_COMPILER ?= blueprint-compiler
GLIB_COMPILE_RESOURCES ?= glib-compile-resources

# Where the library and its header are. `zig build --prefix DIR` puts them
# there; the default is what a plain `zig build` in this repository produces.
PREFIX ?= ../../zig-out

# `static` needs no rpath and no LD_LIBRARY_PATH, which is why it is the
# default for an example. `shared` is what a distribution would do.
LINKAGE ?= static

# The translations, read at run time rather than embedded, so the same `.ftl`
# files serve this example, the other GTK one, the Win32 one, the plain C one
# and the Zig one.
#
# The *markup* is embedded, which is the difference: a `.ui` file is part of
# the program and changes when the program does, where a translation is
# somebody else's work and arrives on its own schedule.
LOCALE_DIR ?= ../locales

# `../common` is the half of this program that has no GTK in it, shared
# verbatim with `examples/gtk` and `examples/win32`. `.` is for the generated
# `greeting-resources.h`, which is written beside the sources.
CPPFLAGS += -I$(PREFIX)/include -I../common -I. -DLOCALE_DIR='"$(LOCALE_DIR)"'

GTK_CFLAGS := $(shell $(PKG_CONFIG) --cflags gtk4)
GTK_LIBS := $(shell $(PKG_CONFIG) --libs gtk4)

# `greeting-resources.c` is generated, and is a source all the same: it is the
# compiled `.ui` as an array of bytes.
SOURCES := greeting.c greeting-resources.c ../common/catalog.c
GENERATED := greeting.ui greeting-resources.c greeting-resources.h

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

# The markup, compiled. blueprint-compiler checks every property and every
# signal against GTK's own introspection data as it goes, so a misspelled
# property name is an error here rather than a warning printed once the
# window is on screen.
greeting.ui: greeting.blp
	$(BLUEPRINT_COMPILER) compile --output $@ $<

# And embedded. `--manual-register` leaves out the constructor that would
# register the resource before `main` runs, so that `greeting.c` can do it in
# a line somebody reading that file can see. `--c-name` is the prefix on the
# two functions that leaves it: without it the prefix is guessed from the file
# name, which here would make it `greeting_`, and a reader of `greeting.c`
# would have no way to tell that function from one of this program's own.
greeting-resources.c greeting-resources.h: greeting.gresource.xml greeting.ui
	$(GLIB_COMPILE_RESOURCES) --target=greeting-resources.c \
		--sourcedir=. --c-name greeting_resources \
		--generate-source --manual-register greeting.gresource.xml
	$(GLIB_COMPILE_RESOURCES) --target=greeting-resources.h \
		--sourcedir=. --c-name greeting_resources \
		--generate-header --manual-register greeting.gresource.xml

greeting: $(SOURCES) ../common/catalog.h greeting-resources.h $(LIBRARY)
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
#  3. it warned about nothing. A GTK warning is a finding, and in this example
#     more so than in the one next door: a template child bound to a name the
#     markup does not use, or a handler the markup names and this program does
#     not define, is reported as a warning while the window is being built and
#     as nothing at all afterwards.
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
	rm -f greeting smoke.out smoke.err $(GENERATED)
