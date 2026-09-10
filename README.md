<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-fluent

An implementation of [Project Fluent](https://projectfluent.org/) for Zig 0.16,
with no ICU and nothing to link against.

API documentation: <https://jeff.jcollie.page/zig-fluent/>, published from main
by `.forgejo/workflows/test.yaml`. It is generated from the doc comments, which
is where most of the explanation in this project lives.

## What Fluent is

A localization system built on one idea: a translation is not a string with
holes in it, but a small program the translator writes. Grammatical agreement —
plurals, gender, case — belongs *in* the translation, where the person who
speaks the language can express it, rather than in the calling code, where they
cannot reach it and where it would have to be written to suit every language at
once.

```ftl
shared-photos =
    { $userName } { $photoCount ->
        [one] added a new photo
       *[other] added { $photoCount } new photos
    } to { $userGender ->
        [male] his stream
        [female] her stream
       *[other] their stream
    }.
```

The calling code passes `userName`, `photoCount` and `userGender`, and knows
nothing about English's two plural forms or Russian's four. A translation into a
language that inflects the verb for gender can do that; one into a language that
does not can ignore the argument; and neither of them needs a line of code
changed.

## Using it

```sh
zig fetch --save git+https://git.jcollie.dev/jeff/zig-fluent
```

```zig
const fluent = b.dependency("fluent", .{ .target = target, .optimize = optimize });
your_module.addImport("fluent", fluent.module("fluent"));
```

```zig
const fluent = @import("fluent");

var bundle: fluent.Bundle = try .init(gpa, try .parse("en-US"));
defer bundle.deinit();
try bundle.addResource(@embedFile("en-US.ftl"), .{}, null);

const text = try bundle.format(gpa, "shared-photos", &.{
    .{ .name = "userName", .value = .{ .string = "Ada" } },
    .{ .name = "photoCount", .value = .num(3) },
    .{ .name = "userGender", .value = .{ .string = "female" } },
}, null) orelse return error.NoSuchMessage;
defer gpa.free(text);
```

`format` returns null rather than failing when the message is not in the bundle,
so an application holding several bundles can ask each in turn. Pass a
`*fluent.Errors` in place of the last argument to hear about anything that went
wrong; pass null and the fallbacks are silent.

Nothing else can fail. A missing variable renders as `{$name}`, an unknown
message as `{name}`, a select expression whose selector went wrong falls to its
default — and in every case the rest of the sentence is still built. That is
deliberate: a localization system sits between an application and everyone using
it, and a translation with one hole in it is worth far more than a blank screen.

### A worked example

`examples/greeting.zig` does the whole of it: reads the user's language out of
the environment, picks the closest of five translations shipped with it, and
prints in that one.

```console
$ LANG=de_DE.UTF-8 zig build example
requested: de-DE
showing:   de

  Willkommen bei Fototresor!
  Keine neuen Fotos
  Ein neues Foto
  2 neue Fotos
  Ada hat am 14. Februar 2026 3 Fotos mit dir geteilt.
  12.345,7 GB von 50.000 GB belegt
```

```console
$ zig build example -- ru        # or say so directly, skipping the environment
  1 новая фотография
  2 новые фотографии
  5 новых фотографий
  21 новая фотография
```

Those four Russian lines are the argument for Fluent in one screen. The program
passes a number; it never learns that Russian needs four forms where English
needs two, that 21 takes the same form as 1 while 11 does not, or that Japanese
counts photos with 枚. All of that lives in the `.ftl` files, where the person
who speaks the language can reach it.

The example also shows the parts that are the application's job rather than the
library's: POSIX spreads "what language does this user read" over `LANGUAGE`,
`LC_ALL`, `LC_MESSAGES` and `LANG`, none of which are language tags, and
negotiating a ranked list of those against the translations you shipped is a
dozen lines. Both are written out and tested there.

### Just the parser

```zig
var resource = try fluent.syntax.parse(gpa, source);
defer resource.deinit();
```

`fluent.syntax` is useful on its own — a linter, an editor plugin, a
translation-memory importer — and costs nothing to leave alone: Zig only
analyses what is referenced, so a program that only parses never compiles the
resolver. There is a serializer too, which writes Fluent's canonical formatting
and so doubles as a formatter, and a JSON writer that emits Fluent's interchange
AST for tools written against `fluent-syntax`.

## Pure Zig

Every other mature implementation delegates the locale-sensitive part to ICU:
`fluent.js` calls `Intl`, `fluent-rs` leaves number formatting to the host. This
one carries its own tables, generated from CLDR into `src/cldr/` by
`zig build gen-cldr` and committed. There is nothing to install and nothing to
link.

The one dependency is [zig-datetime](https://git.jcollie.dev/jeff/zig-datetime),
which supplies the proleptic Gregorian calendar and the IANA timezone database.

Each table is a separate declaration in a separate file, so you pay for what you
reference and nothing else: a program that only parses `.ftl` links none of it.
Measured, `-OReleaseSmall`, on x86-64 Linux — a program that parses a resource
and reads the tree is **164 KB**; one that also formats a number and a date for
a locale is **2.6 MB**, which is the CLDR data for all 766 of them.

**Plural rules** are CLDR's, cardinal and ordinal, for the 224 and 108 locales
CLDR covers. They are compiled from CLDR's own rule language into tables at
generation time, so nothing parses anything at run time, and they are verified
against the 15,041 sample values CLDR publishes — every one of which CLDR itself
labels with the category it belongs to.

**Numbers** follow ECMA-402: digit and grouping options, significant figures,
per-locale symbols, patterns and numbering systems. German swaps the separators,
Hindi groups three digits and then two, Polish does not group four-digit numbers
at all, Egyptian Arabic writes its own digits.

**Dates** follow ECMA-402 too — `dateStyle` and `timeStyle`, or individual
fields matched against CLDR's skeletons, so that `month: "long", day: "numeric"`
comes out as "September 9" in English and "9. September" in German without the
application knowing which is which.

### How closely it agrees with ICU

A matrix of 30 locales against 12 date option sets and 40 number cases — 1560 in
all — was compared against `Intl` in V8 (ICU 78, CLDR 48). All 400 number cases
were identical. Of the 1160 date cases, 1134 were identical and the other 26 are
the two divergences below. There were no others.

- **The narrow no-break space.** CLDR 48 writes English's time as
  `h:mm:ss` U+202F `a`, and Russian's year as `y` U+202F `г.`. V8 substitutes an
  ordinary space. This library follows the data, so it emits U+202F; CLDR ships
  `-alt-ascii` variants for consumers who want otherwise, and they are not used
  here.
- **Non-Gregorian calendars.** Thai defaults to the Buddhist calendar, so `Intl`
  writes 2569 where this writes 2026. Only the Gregorian calendar is
  implemented.

### What is deliberately not implemented

- **Measurement units.** `cldr-units-full` is a further ~100 MB, and `NUMBER()`'s
  option list cannot select a unit style from FTL anyway.
- **Time zone display names.** `timeZoneNames.json` is 45 KB per locale. A zone
  is written as its offset, or as the designation the IANA database gives it —
  never wrong, only less friendly than "Central European Summer Time".
- **Compact notation** ("1.2M"). The plural rules read it, because CLDR's own
  sample data is written in it, but nothing here produces it.

## Building

Everything happens inside the devshell:

```console
$ nix develop
$ zig build example                # the worked example, in your own language
$ zig build test --summary all     # unit, conformance, round-trip, fuzz seeds
$ zig fmt --check --exclude zig-pkg .
$ zig build docs-serve             # read the API documentation at :8000
$ zig build fuzz-run -- --seconds 60
```

`zig build test` also runs Fluent's cross-implementation conformance suite: 39
`.ftl` files, each paired with the syntax tree it must parse to. They are not
vendored — they arrive as a lazy `build.zig.zon` dependency, so running the
tests fetches them and merely depending on this library does not.

### Regenerating the CLDR tables

```console
$ zig build gen-cldr
```

This reads `cldr-core`, `cldr-numbers-full` and `cldr-dates-full`, which are
lazy dependencies totalling 135 MB unpacked. Only this step resolves them, so an
ordinary build never sees them. What it writes goes under `src/cldr/` and is
committed, because generating on every build would make every consumer download
all of it to produce files that change only when CLDR issues a release.

Updating to a new CLDR is therefore a deliberate act with a reviewable diff:
bump the versions in `build.zig.zon`, run the generator, look at what moved.

### Fuzzing

Zig 0.16.0 cannot build a test executable in fuzz mode without a patched
standard library, and leaves the fuzzer's coverage table empty even then;
`flake.nix` explains both and carries the patch. `zig build fuzz-run` is a loop
of our own in the meantime, mutating a corpus of real inputs.

It earned its keep immediately and kept earning it: **six crashes** and three
ways the serializer could write a file that did not read back as itself. The
instructive ones:

- a float-to-integer conversion in the plural evaluator that panicked on
  exactly 2⁶⁴ — the value the largest `i64` rounds *up* to when it goes through
  an `f64`, so clamping against that largest `i64` did not save it;
- **a panic reachable straight from a translation file**: `\UFFFFFF` is six
  valid hex digits, so the parser accepts the literal, and the value it names
  overflowed the 21-bit integer the resolver parsed it into;
- `minimumSignificantDigits: 0`, which is not a legal request but is one a
  translator can type, asking the renderer for a precision of minus one;
- deriving plural operands from arbitrary text, where `carried * 10` overflows
  on a long enough run of digits and `byte - '0'` wraps below zero for any byte
  under `'0'`.

The serializer's three were all blank lines around comments and junk. A `#`
comment binds to whatever sits directly beneath it, so a blank line is not
cosmetic there: put one in the wrong place and an entry adopts a comment that
was never about it.

A seventh crash came out of reading the code afterwards, once the second one
had made the shape recognisable — `DATETIME()` given a large number clamped its
timestamp against the ends of `i64` and handed the result to `@intFromFloat`,
which is the same trap in a different place.

Every one of them carries a test. The `\UFFFFFF` one is worth pausing on:
being in range is a question about a value, not about syntax, so a well-formed
literal can name nothing at all — and this library's own documentation makes
the point that a `.ftl` file is reached by the same path a user's display name
is.

## Where this lives

The repository is hosted on Forgejo, which is where the issues, the continuous
integration and the published documentation are:

```sh
git clone https://git.jcollie.dev/jeff/zig-fluent.git
```

## Licence

MIT, and the project follows the [REUSE](https://reuse.software/) specification;
`reuse lint` passes. The tables under `src/cldr/` are derived from the Unicode
Common Locale Data Repository and carry its licence, Unicode-3.0.
