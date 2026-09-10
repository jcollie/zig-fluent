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
zig fetch --save git+https://github.com/jcollie/zig-fluent
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

Reading the environment, and honouring the `LC_*` variables a user expects to
work, is [its own section below](#in-a-posix-environment). Choosing among the
bundles you shipped is left to the application, and the example writes that out
too: each requested locale in turn, and for each, the closest bundle by tag,
then by language and script, then by language.

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

## In a POSIX environment

Somebody running a command-line program on a Unix expects `LANG` and the `LC_*`
variables to work. They are not decoration: `LC_ALL=C` in a script is a promise
that the output will not move, and a user who set `LC_TIME=en_GB.UTF-8` did it
because they want a twenty-four hour clock. `fluent.posix` reads them.

| variable | governs | read here |
|---|---|---|
| `LANGUAGE` | a ranked list of languages to try | yes — messages only |
| `LC_ALL` | every category, overriding all others | yes |
| `LC_MESSAGES` | which language to speak | yes |
| `LC_NUMERIC` | decimal mark, grouping, digits | yes |
| `LC_TIME` | month names, field order, the clock | yes |
| `LC_MONETARY` | where the currency sign goes | yes |
| `LC_COLLATE` | sort order | no — see below |
| `LC_CTYPE` | character classification | no — see below |
| `LANG` | the default for every category | yes |

The whole of it, in an application that ships several translations:

```zig
// 1. Which languages will do, best first. Only `LANGUAGE` ranks, so this is
//    the one question with a list for an answer.
var wanted: [8]fluent.Locale = undefined;
const chain = fluent.posix.fromEnviron(&wanted, init.environ_map);

// 2. Pick a bundle. Matching a ranked request against what you shipped is
//    yours to decide; `examples/greeting.zig` writes out a dozen lines of it.
const bundle = negotiate(&bundles, chain);

// 3. Format the way this user writes numbers and dates, which POSIX lets
//    them answer separately from the language they read.
const category = fluent.posix.categoriesFromEnviron(init.environ_map);
if (category.numeric)  |locale| bundle.setNumberLocale(locale);
if (category.monetary) |locale| bundle.setCurrencyLocale(locale);
if (category.time)     |locale| bundle.setDateLocale(locale);
```

An application that ships one translation needs only the third step, and one
that does not care about the `LC_*` split needs none of it — `Bundle.init` sets
all three categories from the locale it is given.

None of it is tied to the process, either. The rules apply to a
`fluent.posix.Variables` struct, so a server deciding on behalf of a user who is
not the one running it can feed in values from a config file or a request header
and get the same answers; `fromEnviron` and `categoriesFromEnviron` are the
adapters for a real environment.

### The names are not language tags

`de_DE.UTF-8@euro` and `de-DE` are the same locale. The codeset says how bytes
are encoded and the modifier is usually a variant, and neither keys anything
here, so both are dropped. `fromName` handles that, along with the one
exception worth making: a few modifiers name a *script*, and `sr_RS@latin` is
Serbian written in Latin rather than Cyrillic — a different locale that formats
differently — so those become the script subtag they mean.

The codeset being dropped has one consequence worth saying out loud: **this
library emits UTF-8 and nothing else.** A user with `LANG=de_DE.ISO-8859-1`
gets correct German in UTF-8, and converting it is the caller's business.

### `LC_ALL=C` means do not translate

`C` and `POSIX` are one locale under two names, and both mean the user wants
the program's own language rather than a translation of it. `fromEnviron`
returns an **empty chain** for them and `Categories` returns nulls, so nothing
downstream needs a special case: a negotiation that falls back to your source
locale when it can satisfy nothing already does the right thing, and the three
`if (category.x) |locale|` lines above already leave the formatting alone.

This is worth honouring carefully rather than approximately. `LC_ALL=C` in a
shell script is how somebody guarantees that the output of a command will not
move under them — that a decimal point stays a point and a month stays
`Jan` — so that `awk` or `cut` further down the pipe keeps working. A program
that translates anyway has broken their pipeline.

For the same reason `LANGUAGE` is ignored when `LC_ALL` or `LANG` says `C`,
which is gettext's rule: a ranked list left over in a shell profile must not
quietly undo it.

### Plural rules follow the message language

They follow `LC_MESSAGES`, never `LC_NUMERIC`, and the distinction matters.
`[one]` and `[few]` are variant keys the *translator* wrote, in the language
the text is written in. Choosing among them by the reader's number-formatting
preference would look for variants that translation does not have, and fall to
the default every time.

So English plurals with Russian punctuation is exactly what that combination
should give, and does:

```console
$ LANG=en_US.UTF-8 LC_NUMERIC=ru_RU.UTF-8 zig build example
showing:   en-US  (numbers: ru-RU)

  One new photo
  Ada shared 3 photos with you on February 14, 2026.
  12 345,7 GB of 50 000 GB used
```

All three categories at once, which is the setting the whole feature exists
for:

```console
$ LANG=en_US.UTF-8 LC_TIME=en_GB.UTF-8 LC_NUMERIC=de_DE.UTF-8 zig build example
showing:   en-US  (numbers: de-DE)  (dates: en-GB)

  One new photo
  Ada shared 3 photos with you on 14 February 2026.
  12.345,7 GB of 50.000 GB used
```

### Writing to a terminal

Turn isolation off:

```zig
bundle.use_isolating = false;
```

It is on by default and should be. It wraps every interpolation in U+2068 and
U+2069 so that a right-to-left name dropped into a left-to-right sentence does
not drag the punctuation around it to the wrong end of the line. A browser
honours those marks; a terminal prints them, and `Ada` comes out as `⁨Ada⁩`.

Leave it on wherever the text is going into a paragraph a person reads, and
turn it off for a terminal, for a value about to be compared or stored, and for
a test asserting on exact text.

### What is not read, and why

`LC_COLLATE` and `LC_CTYPE` govern sort order and character classification.
This library does neither, so there is nothing here for them to change; an
application that sorts a list of translated strings should read `LC_COLLATE`
itself.

`LC_MONETARY` is read but not fully served. CLDR keeps one set of separators
per locale rather than a separate monetary set, so `setCurrencyLocale` moves
the currency sign but not the decimal mark. POSIX distinguishes them
(`mon_decimal_point`), and a pair of locales that disagrees about it will not
be exact.

## On Windows

Windows has none of those variables and answers two questions of its own —
which happen to make the same split:

| | POSIX | Windows |
|---|---|---|
| which language to speak | `LANGUAGE`, `LC_MESSAGES` | `GetUserPreferredUILanguages` — a ranked list |
| how to write numbers, dates, money | `LC_NUMERIC`, `LC_TIME`, `LC_MONETARY` | `GetUserDefaultLocaleName` — one "regional format" for all three |

Somebody in Germany reading an English interface is an ordinary Windows
setting, and it is the same shape as `LANG=en_US.UTF-8 LC_NUMERIC=de_DE.UTF-8`.
`fluent.windows` reads both, and answers in the same `Categories` that
`fluent.posix` does.

### Write it once

`fluent.system` asks whichever system is running, so a program that works on
both need not branch:

```zig
var buffer: [8]fluent.Locale = undefined;
const wanted = fluent.system.preferredLocales(&buffer, init.environ_map);
const bundle = negotiate(&bundles, wanted);

fluent.system.applyCategories(bundle, fluent.system.categories(init.environ_map));
```

**The environment is asked first, on Windows too.** Not because Windows uses
it — it does not — but because somebody running under MSYS2, Cygwin or Git Bash
has a shell that sets `LANG`, and somebody who exported `LC_ALL` did it on
purpose. It is what GNU gettext does there, and it means `LC_ALL=C` silences
translation on Windows as well, which is the setting it would be worst to
ignore.

### Testing what cannot be run here

The Win32 calls come from [zigwin32](https://github.com/marlersoft/zigwin32),
which is generated from Microsoft's own metadata, as a lazy dependency wired in
only when the target is Windows. Two hand-written `extern` declarations would
have been less machinery and worse: nothing checks them, and a wrong parameter
width is memory corruption on the one platform that cannot be tested from a
Linux machine. `GetUserDefaultLocaleName` takes a `[*:0]u16`, not the `[*]u16`
that is easy to write.

Everything that parses is separated from everything that calls, so the parsing
is tested here on the byte sequences Windows would have produced — the
NUL-separated, double-NUL-terminated UTF-16 multi-string, the invariant locale,
a name that is not ASCII. The calling half is checked by compiling the whole
test suite for `x86_64-windows-gnu`, which type-checks it against the real
signatures even though there is no Windows here to run it on.

Windows' pseudo-locales pass through as ordinary tags — `qps` is in BCP 47's
private-use range — match no bundle, and so leave the source locale showing,
which is what somebody who set one should see from a program that ships no
pseudo-locale.

## On macOS

macOS is two systems at once, and which one you are in decides everything.

**In a terminal it is POSIX**, and already served. Terminal.app's *Set locale
environment variables on startup* is on by default and sets `LANG` from the
region preference, so `fluent.system` works there with nothing added. iTerm2
does the same. A command-line program needs to read no further than this.

**A GUI app gets nothing.** `launchd` passes no `LANG`, so a bundled `.app`
sees an empty environment however the user has their region set, and must ask
the preferences system instead.

### What to ask for

The answers live in `NSGlobalDomain`, and macOS makes the same two-way split
Windows does — a ranked list of languages, and one locale for formatting — so
they land in the same `Categories`:

| key | value | analogue |
|---|---|---|
| `AppleLanguages` | `("en-US", "de-DE")`, in preference order | `LANGUAGE`, `GetUserPreferredUILanguages` |
| `AppleLocale` | `en_US`, or `en_GB@currency=EUR` | `LC_NUMERIC`+`LC_TIME`+`LC_MONETARY`, the Windows regional format |

Both shapes go straight into functions that are already here, which is the
useful part: having read the two keys, there is nothing left to write.

```zig
// AppleLanguages entries are BCP 47 already.
const first = try fluent.Locale.parse("zh-Hans-CN");        // zh-Hans-CN

// AppleLocale is a POSIX-shaped name, and the ICU keywords after `@` are
// dropped like any other modifier.
const format = fluent.posix.fromName("en_GB@currency=EUR"); // en-GB
```

Reading them is two CoreFoundation calls —
`CFPreferencesCopyAppValue(CFSTR("AppleLanguages"), kCFPreferencesCurrentApplication)`
and the same for `AppleLocale` — which a GUI app already links for.

### Format overrides

macOS lets a user override formats *independently of the locale*, under
Language & Region → Advanced, and those land in `NSGlobalDomain` as well:

| key | what it overrides |
|---|---|
| `AppleICUDateFormatStrings` | a dict keyed `"1"`–`"4"`: ICU date patterns for the four lengths |
| `AppleICUNumberSymbols` | a dict keyed by ICU's `UNumberFormatSymbol`: `0` decimal, `1` grouping, `10` monetary decimal, `17` monetary grouping |
| `AppleICUForce24HourTime`, `AppleICUForce12HourTime` | the clock, whatever the locale prefers |
| `AppleFirstWeekday`, `AppleMeasurementUnits` | week start, metric or not |

These are not read either, and an application that wants them can apply them
itself, because each has somewhere to go: `Bundle.date_names.date_formats` holds
the same four patterns, `Bundle.number_symbols` the same symbols, and
`datetime_format.Options.hour12` is the same switch.

**Mind the order of the date patterns.** macOS keys them `"1"` to `"4"` running
*short to long* — `"1"` is `ddMMMyy` and `"4"` is `EEEE, d MMMM y`. This library
stores them longest first, indexed by `Style`, so `date_formats[0]` is `full`
and `date_formats[3]` is `short`. They are reversed as well as offset:

```zig
// AppleICUDateFormatStrings "1".."4"  ->  date_formats[3]..[0]
bundle.date_names.date_formats[4 - index] = pattern;
```

And note that symbols `10` and `17` are the monetary separators — the
distinction described above as one CLDR does not keep and this library
therefore cannot serve. A caller reading those from macOS has better
information than the tables do.

### Why there is no `fluent.darwin`

Because it could not be verified from here. Reading any of this needs
`CFPreferencesCopyAppValue`, which needs `-framework CoreFoundation`, which
needs the macOS SDK; without it the linker gets as far as `unable to find
framework 'CoreFoundation'`. The Windows half is the way it is precisely
because [zigwin32](https://github.com/marlersoft/zigwin32) let every signature
be type-checked against Microsoft's own metadata — and it caught a wrong
parameter width the first time it was compiled. There is no equivalent here,
and code that ships looking as tested as the rest of the library while being
neither built nor run is worse than a section of a README that tells you
exactly which two keys to read.

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
- **Currency spacing.** CLDR says to insert a non-breaking space between the
  digits and a currency text that is alphabetic rather than a symbol, so ICU
  writes `EUR 1,234.50` where this writes `EUR1,234.50`. Symbols are unaffected
  — `€1,234.50` is right either way — and since currency display names are not
  shipped, an alphabetic currency text is one the application passed in itself.

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
vendored — they arrive as a `build.zig.zon` dependency, so the exact revision
compared against is a hash in the manifest rather than a copy in this repository
that could drift. At 876 KB they are worth a manifest entry; see below for what
a manifest entry costs.

### Regenerating the CLDR tables

```console
$ zig build gen-cldr -- cldr-core cldr-numbers-full cldr-dates-full
```

The three directories are the unpacked CLDR packages:

```console
$ for p in core numbers-full dates-full; do
    curl -sSL "https://registry.npmjs.org/cldr-$p/-/cldr-$p-48.2.0.tgz" |
      tar xz && mv package "cldr-$p"
  done
$ zig build gen-cldr -- cldr-core cldr-numbers-full cldr-dates-full
```

They are passed as arguments rather than declared as dependencies, and that is
a deliberate retreat from the obvious design. **A lazy dependency in
`build.zig.zon` is fetched by `zig build` whether or not any step asks for it**
— measured on Zig 0.16.0, with the `lazyDependency` calls behind a `-D` flag
that was switched off, and confirmed from the other side by building a throwaway
project that merely depended on this one. Those three packages are 138 MB, so
every consumer was paying for them in order to regenerate files that change only
when CLDR issues a release. Out of the manifest, a dependent project's tree
drops from 211 MB to 73 MB.

What the generator writes goes under `src/cldr/` and is committed, so updating
to a new CLDR is a deliberate act with a reviewable diff: fetch the new
packages, run the generator, look at what moved.

### What a clean build actually downloads

73 MB, and it is worth knowing where it goes, because none of it is lazy in the
sense the name suggests:

| | | |
|---|---|---|
| `zigwin32` | 64 MB | the two Win32 calls; fetched on every platform, not only Windows |
| `moment`, `tzdata`, `tzcode` | 8 MB | `zig-datetime`'s, for its own generators |
| `fluent-spec` | 876 KB | the conformance fixtures, used by `zig build test` |
| `zig-datetime` | 868 KB | the calendar and the timezone database |

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

A later pass added targets for date formatting, for CLDR patterns supplied by a
consumer rather than by CLDR, for the interchange JSON and for pattern affixes,
and those found four more: a pattern asking for more than nine fractional
second digits divided by zero looking for a tenth; a date-and-time connector
ending in `{` read past the end of itself; and the affix walker searched for the
currency placeholder with a byte-wise `indexOfAny`, so it also matched the first
byte of every character in U+0080..U+00BF — a non-breaking space among them,
which German, French, Russian and Czech all put before their percent sign. That
last one was not a crash at all. It was **wrong output in shipped code**, in
every one of those languages, and the reason it survived a 1,560-case comparison
against `Intl` is that `NUMBER()` cannot ask for a percentage from FTL, so the
matrix never exercised the path. The comparison now covers percent and currency
across forty locales too; all 280 percent cases agree.

A fifth came from the fuzzer directly, and is the subtlest of the lot: the
serializer tracks its output by the last two bytes written, and used a zero
byte to mean "nothing written yet". No byte can mean that — a NUL inside a
comment is a NUL inside a comment — so a comment containing one was read as the
start of the file, the blank line after it was suppressed, and reparsing handed
that comment to the message below. Nobody was going to write that input by
hand.

Two more crashes came out of reading the code afterwards, once the shape had
become recognisable: `DATETIME()` given a large number clamped its timestamp
against the ends of `i64` and handed the result to `@intFromFloat`, which is the
same trap as the plural one in a different place; and a year before the common
era was computed with arithmetic that both said the wrong thing and overflowed
at the bottom of an `i32`.

Every one of them carries a test. The `\UFFFFFF` one is worth pausing on:
being in range is a question about a value, not about syntax, so a well-formed
literal can name nothing at all — and this library's own documentation makes
the point that a `.ftl` file is reached by the same path a user's display name
is.

## Where this lives

The repository is hosted on Forgejo, which is where the issues and the
published documentation are:

```sh
git clone https://git.jcollie.dev/jeff/zig-fluent.git
```

It is mirrored to GitHub, and that is the copy Zig fetches from, since a
`zig fetch` URL is read by whoever depends on this and GitHub is the more
reachable of the two:

```sh
git clone https://github.com/jcollie/zig-fluent.git
```

The mirror also earns its keep: the Forgejo runners are Linux, and
`.github/workflows/test.yaml` runs the same tests on macOS and Windows as well,
which is the only way the Win32 calls and the macOS locale conventions get
exercised at all.

## Licence

MIT, and the project follows the [REUSE](https://reuse.software/) specification;
`reuse lint` passes. The tables under `src/cldr/` are derived from the Unicode
Common Locale Data Repository and carry its licence, Unicode-3.0.
