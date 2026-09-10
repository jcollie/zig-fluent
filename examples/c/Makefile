# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

# The C example, built the way a C project would build it: a compiler, a
# linker and a Makefile. Nothing here knows about the Zig build system except
# the one rule that produces the library, and that rule is only a convenience
# -- point PREFIX at an installed copy and it is never used.
#
#     make                     # build against ../../zig-out, building it if needed
#     make run                 # and run it in whatever language this machine says
#     make run LOCALE=fi       # or in one named outright
#     make PREFIX=/usr/local   # against an installed copy instead
#     make LINKAGE=shared      # link libfluent.so rather than libfluent.a
#     make clean

CC ?= gcc
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O2

# Where the library and its header are. `zig build --prefix DIR` puts them
# there; the default is what a plain `zig build` in this repository produces.
PREFIX ?= ../../zig-out

# `static` needs no rpath and no LD_LIBRARY_PATH, which is why it is the
# default for an example. `shared` is what a distribution would do.
LINKAGE ?= static

# The translations, read at run time rather than embedded, so the same `.ftl`
# files serve this example and the Zig one.
LOCALE_DIR ?= ../locales

CPPFLAGS += -I$(PREFIX)/include -DLOCALE_DIR='"$(LOCALE_DIR)"'

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

# libfluent is Zig's standard library and a good deal of CLDR, and both want
# libm and pthreads underneath.
LDLIBS += -lm -lpthread

# Zig's object files carry no `.note.GNU-stack`, and GNU ld then warns that it
# is assuming an executable stack. Saying so explicitly is quieter and safer
# than being assumed into it. Only GNU ld has the option, and only ELF has the
# section, so this is asked for on the platform that has both.
ifeq ($(shell uname -s),Linux)
LDFLAGS += -Wl,-z,noexecstack
endif

.PHONY: all run clean library

all: greeting

greeting: greeting.c $(LIBRARY)
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ greeting.c $(LDFLAGS) $(LDLIBS)

run: greeting
	./greeting $(LOCALE)

# The one Zig rule, and the only thing in this file that knows Zig exists:
# build the library this example links against.
#
# ReleaseSafe rather than the build's Debug default. It keeps every check that
# makes a failure a failure, and it is a great deal smaller -- and it is the
# configuration in which a foreign linker most needs the archive to be
# self-contained, which is why `build.zig` bundles Zig's `compiler_rt` into it.
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
	rm -f greeting
