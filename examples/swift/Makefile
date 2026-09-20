# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

# The macOS example, built the way a Swift project is built: `swift build`,
# with the library pointed at from the command line rather than named anywhere
# in the package. Nothing here knows about Zig except the one rule that
# produces the library, and that rule is only a convenience -- point PREFIX at
# an installed copy and it is never used.
#
#     make                     # swift build, against ../../zig-out
#     make test                # the headless assertions, which is what CI runs
#     make run                 # run it from the terminal
#     make run LOCALE=fi       # in a language named outright
#     make app                 # wrap it into Greeting.app
#     make open                # and launch that, the way a person would
#     make PREFIX=/usr/local   # against an installed copy instead
#     make clean
#
# macOS only: SwiftUI is, and so is the CoreFoundation the library reads the
# user's language from.

SWIFT ?= swift
PREFIX ?= ../../zig-out
CONFIGURATION ?= debug

# The translations, read at run time rather than embedded, so the same `.ftl`
# files serve this example and the three written in C and Zig.
LOCALE_DIR ?= ../locales

APP := Greeting.app

# `swift build` is run from this directory and the package refers to nothing
# outside it, so the library has to be named absolutely.
ABSOLUTE_PREFIX := $(abspath $(PREFIX))

# How the package finds a library it does not build.
#
#  * `-Xcc -I` is what `Sources/CFluent/shim.h` needs in order to find
#    `fluent.h`, and is the whole reason the module map points at a shim
#    rather than at the header itself.
#  * The archive is handed to the linker by path rather than as `-lfluent`,
#    so that the static one is what gets linked even when a `libfluent.dylib`
#    sits beside it.
#  * CoreFoundation because an archive cannot carry its dependencies with it,
#    and that is where `fluent_preferred_locales` reads `AppleLanguages`.
#    `pkg-config --libs --static fluent` says the same thing.
SWIFT_FLAGS := \
	-Xcc -I$(ABSOLUTE_PREFIX)/include \
	-Xlinker $(ABSOLUTE_PREFIX)/lib/libfluent.a \
	-Xlinker -framework -Xlinker CoreFoundation

STATIC_LIB := $(PREFIX)/lib/libfluent.a

.PHONY: all test run app open clean library

all: $(STATIC_LIB)
	$(SWIFT) build -c $(CONFIGURATION) $(SWIFT_FLAGS)

test: $(STATIC_LIB)
	$(SWIFT) test $(SWIFT_FLAGS)

# `../locales` is where the package's own default looks, and `swift run`
# leaves the working directory here, so this needs no environment of its own.
run: $(STATIC_LIB)
	$(SWIFT) run -c $(CONFIGURATION) $(SWIFT_FLAGS) Greeting $(LOCALE)

# An application bundle, which is what makes this worth having on macOS: a
# program launched from the Finder has no environment to read a language out
# of, so this is the shape in which `fluent_preferred_locales` has to ask
# CoreFoundation rather than getenv.
app: all
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/Info.plist
	cp "$$($(SWIFT) build -c $(CONFIGURATION) $(SWIFT_FLAGS) --show-bin-path)/Greeting" \
		$(APP)/Contents/MacOS/Greeting
	cp -R $(LOCALE_DIR) $(APP)/Contents/Resources/locales

open: app
	open $(APP)

# The one Zig rule, and the only thing in this file that knows Zig exists.
library:
	cd ../.. && zig build c --prefix zig-out -Doptimize=ReleaseSafe

# Asked for every time when the library is this repository's own, since `zig
# build` caches and a stale `libfluent.a` would otherwise sit there through
# every edit to `src/c.zig`. An installed copy is not ours to rebuild, so
# pointing PREFIX elsewhere takes the rule out of the graph entirely and this
# example needs no Zig at all.
ifeq ($(PREFIX),../../zig-out)
$(STATIC_LIB): library
.PHONY: $(STATIC_LIB)
endif

clean:
	rm -rf .build $(APP)
