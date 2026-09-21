<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-fluent

An implementation of [Project Fluent](https://projectfluent.org/) for Zig 0.16,
and a C library built from the same code. It carries its own CLDR tables, so
there is no ICU to install and nothing to link against.

- **API documentation**: <https://jeff.jcollie.page/zig-fluent/>, generated from
  the doc comments, which carry most of the detail this file summarises.
- **Requires**: Zig 0.16. One dependency,
  [zig-datetime](https://git.jcollie.dev/jeff/zig-datetime).
- **Licence**: MIT.

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
nothing about English's two plural forms or Polish's four. A translation into a
language that inflects the verb for gender can do that; one into a language that
does not can ignore the argument; and neither needs a line of code changed.

If the syntax is new to you, the [Fluent Syntax
Guide](https://projectfluent.org/fluent/guide/) is the place to start. This
library implements [Fluent Syntax
1.0](https://github.com/projectfluent/fluent) in full.

## Using it from Zig

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

A `Bundle` holds the messages of one locale. An application that ships several
translations holds one bundle per translation and asks each in turn: `format`
returns null rather than failing when the message is not there.

### Nothing else can fail

Out of memory aside, no call in this library returns an error for anything a
translation does. A missing variable renders as `{$name}`, an unknown message as
`{name}`, and a select expression whose selector went wrong falls to its
default — and in every case the rest of the sentence is still built.

That is deliberate. A localization system sits between an application and
everyone using it, and a translation with one hole in it is worth far more than
a blank screen. Pass a `*fluent.Errors` where the examples above pass null to
hear about what went wrong anyway; pass null and the fallbacks are silent.

### Just the parser

```zig
var resource = try fluent.syntax.parse(gpa, source);
defer resource.deinit();
```

`fluent.syntax` is useful on its own — for a linter, an editor plugin, a
translation-memory importer — and costs nothing to leave alone: Zig only
analyses what is referenced, so a program that only parses never compiles the
resolver. Alongside the parser there is a serializer, which writes Fluent's
canonical formatting and so doubles as a formatter, and a JSON writer that emits
Fluent's interchange AST for tools written against `fluent-syntax`.

## Using it from C

`zig build` produces `libfluent.a`, `libfluent.so`, a hand-written
`include/fluent.h` and a pkg-config file. On Windows the static library is
`libfluent.lib`, and `fluent.lib` is the import library that goes with
`fluent.dll`.

```console
$ zig build --prefix /usr/local
$ pkg-config --cflags --libs fluent
-I/usr/local/include -L/usr/local/lib -lfluent
```

Ask for `--static` as well when linking the archive, since an archive cannot
carry its dependencies with it: on macOS that adds `-framework CoreFoundation`,
where the user's language is read from, and elsewhere the `-lm -lpthread` that
Zig's standard library wants underneath.

```c
#include <fluent.h>

fluent_bundle *bundle = fluent_bundle_new("en-US");
fluent_bundle_add_resource(bundle, ftl, ftl_len, NULL);

fluent_args *args = fluent_args_new();
fluent_args_set_string(args, "userName", "Ada", 3);
fluent_args_set_number(args, "photoCount", 3);
fluent_args_set_string(args, "userGender", "female", 6);

char *text = fluent_bundle_format(bundle, "shared-photos", args, NULL);
puts(text);

fluent_string_free(text);
fluent_args_free(args);
fluent_bundle_free(bundle);
```

The same shape as the Zig API, with the same guarantee: a message that is not in
the bundle formats to `NULL` rather than to an error.

Two conventions run through the header. **Names** — message identifiers,
attributes, locale tags, argument names — are C strings, because that is what a
name is. **Bodies of text** — an FTL resource, a string argument — are a pointer
and a length, because they come out of files and may contain anything, a NUL
included. Neither is retained: the library copies whatever it keeps, so a buffer
may be freed as soon as the call returns. Text the library hands back belongs to
the caller and is freed with `fluent_string_free`.

`fluent_preferred_locales` answers the question the [next
section](#finding-the-users-language) is about, on all three platforms, without
the caller needing an environment block of its own:

```c
fluent_tag wanted[8];
size_t count = fluent_preferred_locales(wanted, 8);
```

Three things are Zig-only. **Locale negotiation** — choosing which of the
translations you shipped best serves what was asked for — is the application's
decision rather than this library's, in C exactly as in Zig. **Time zones**
would mean handing C a parsed TZif, which belongs to `zig-datetime`; dates are
read in UTC. **Custom functions** need a Zig callback. `include/fluent.h` says
the same, since it is the file a C programmer will actually read.

## Examples

Six programs, all formatting the same five messages from the same six
translations in `examples/locales/`, so that they can be read against each
other.

| | language | build | shows |
|---|---|---|---|
| `examples/greeting.zig` | Zig | `zig build example` | the whole shape in one file: read the environment, negotiate, format |
| `examples/c/` | C | `make -C examples/c run` | the same again through the C API, translations read off disk |
| `examples/gtk/` | C, GTK 4 | `make -C examples/gtk run` | a window whose every label is reformatted when the language changes |
| `examples/gtk-blueprint/` | C, GTK 4, Blueprint | `make -C examples/gtk-blueprint run` | that window declared as markup instead, with no text in the markup |
| `examples/swift/` | Swift, SwiftUI | `make -C examples/swift open` | the C API wrapped in Swift, one `deinit` per `_free` |
| `examples/win32/` | C, Win32 | `cd examples\win32 && build.bat run` | the same window, and UTF-8 crossing into UTF-16 |

Start with `examples/greeting.zig` or `examples/c/greeting.c`; they are the same
program twice, and what changes is the spelling rather than the shape.

```console
$ LANG=de_DE.UTF-8 zig build example
requested: de-DE
showing:   de

  Willkommen bei Fototresor!
  Keine neuen Fotos
  Ein neues Foto
  2 neue Fotos
  5 neue Fotos
  21 neue Fotos
  Ada hat am 14. Februar 2026 3 Fotos mit dir geteilt.
  12.345,7 GB von 50.000 GB belegt
```

`zig build example -- de` names the language directly instead. The environment
still decides how numbers and dates are written, which is the split
[Finding the user's language](#finding-the-users-language) is about.

### What the translations demonstrate

```console
$ LANG=fi_FI.UTF-8 zig build example
requested: fi-FI
showing:   fi

  Tervetuloa Kuvakirjastoon!
  Ei uusia kuvia
  1 uusi kuva
  2 uutta kuvaa
  5 uutta kuvaa
  21 uutta kuvaa
  Ada jakoi kanssasi 3 kuvaa 14. helmikuuta 2026.
  Käytössä 12 345,7 Gt / 50 000 Gt
```

Those Finnish lines are the argument for Fluent in one screen. The product name
is a term, so the translator declines it — `Tervetuloa { -app-name }on!` — and
the calling code never learns that Finnish has a case system. A counted noun
goes into the partitive, so one photo and two differ in more than the numeral in
front of them. And `$gender` is passed to that third message and never read,
because Finnish has no grammatical gender: a translation may ignore an argument
the program thought was essential.

Polish makes the opposite case.

```console
$ LANG=pl_PL.UTF-8 zig build example
requested: pl-PL
showing:   pl

  Witamy w Skarbcu Zdjęć!
  Brak nowych zdjęć
  1 nowe zdjęcie
  2 nowe zdjęcia
  5 nowych zdjęć
  21 nowych zdjęć
  Ada udostępniła ci 3 zdjęcia 14 lutego 2026.
  Wykorzystano 12 345,7 GB z 50 000 GB
```

Four plural categories where English has two, and the noun changes case with the
category rather than merely taking an `-s`. `few` is 2 to 4 but not 12 to 14, so
22 takes the same form as 2, while 12 and the 21 above take the same form as 5. The past tense agrees with the sharer —
`udostępniła` for Ada, `udostępnił` for Adam — which is the argument Finnish had
no use for, read by a language that does. The term is called with an argument,
`{ -app-name(case: "locative") }`, because Polish changes the stem and not just
the ending: `Skarbiec` becomes `Skarbcu`.

All of it lives in the `.ftl` files, where the person who speaks the language can
reach it — as does Japanese counting photos with 枚.

### The GUI examples

A command-line program formats each message once and exits. An application holds
a tree of widgets whose text has to be regenerated whenever the user changes
something, and in these four that something is the language. Each has a
language menu and a count, and each shows three things the terminal examples
cannot:

- **Reformatting in place.** Choosing another language swaps the bundle every
  label is formatted from.
- **Attributes.** A button's tooltip comes from the `.tooltip` attribute of the
  message its label comes from, which keeps the two strings a control needs
  together, so that a translation cannot update one and forget the other.
- **A decision about isolation marks.** Each of them makes it, and they do not
  all make it the same way, which is the interesting part: whether to keep
  U+2068 and U+2069 is a question about the text renderer rather than about
  the application. Pango and CoreText implement the bidirectional algorithm
  and act on them, so the GTK and SwiftUI examples leave them on. Win32's
  classic controls draw through GDI, which has no bidirectional algorithm and
  hands each character to the font, so an interpolation comes out wrapped in
  two boxes — and `examples/win32` turns them off for the same reason a
  terminal example does.

`examples/common/catalog.c` is the half of such a program that has no toolkit in
it — reading the files, negotiating, formatting, collecting errors — and the two
GTK examples and the Win32 one share it verbatim, so what differs between them
is only the window system.

The two GTK examples are the same window built two ways, and reading them
against each other is the point of there being two. `examples/gtk` calls GTK to
construct its widget tree. `examples/gtk-blueprint` declares the tree in
[Blueprint](https://gnome.pages.gitlab.gnome.org/blueprint-compiler/), which
compiles to GtkBuilder XML and is embedded in the binary as a `GResource`; its
C is a `GtkApplicationWindow` subclass whose fields and signal handlers are
bound to the markup by name, and what is left of it is the formatting.

That second one is where Fluent and a declarative toolkit have to be introduced
to each other, because they both want to own the same thing. A GtkBuilder file
normally carries the application's text, marked `translatable="yes"` for
gettext — which fixes the translation at one string per control.
`examples/gtk-blueprint/greeting.blp` declares every label with no text in it
at all, and the text arrives at run time from a Fluent bundle instead. The
markup owns structure, the bundle owns words, and the two meet at the widget
names.

None of them is built by Zig: both GTK examples use `gcc` and a Makefile, Swift
uses `swift build` with the library named on the command line, and Win32 uses
`cl`, `rc` and a batch file that finds Visual C++ through `vswhere`. Each takes
a `PREFIX`, so each can be built against an installed copy with no Zig present
at all. `examples/gtk-blueprint` additionally wants `blueprint-compiler` and
the `glib-compile-resources` that comes with GLib; the devshell has both.

`examples/swift` also carries a test suite, `Tests/FluentKitTests`, which is what
asserts anything about the Swift wrapper without needing a window.

## Finding the user's language

Every platform answers two questions, and this library keeps them apart
everywhere: **which language to speak**, and **how to write numbers, dates and
money**. Somebody who reads English in Germany has answered them differently,
and that is an ordinary thing to want.

`fluent.system` asks whichever platform is running, so a program that works on
all three need not branch:

```zig
var buffer: [8]fluent.Locale = undefined;
const wanted = fluent.system.preferredLocales(&buffer, init.environ_map);
const bundle = negotiate(&bundles, wanted);

fluent.system.applyCategories(bundle, fluent.system.categories(init.environ_map));
```

Choosing among the bundles you shipped is left to the application: how much of a
mismatch to tolerate is a product decision rather than a fact about locales.
`examples/greeting.zig` writes out one reasonable answer in about forty lines —
each requested locale in turn, and for each, the closest bundle by tag, then by
language and script, then by language alone.

**The environment is asked first on every platform**, Windows and macOS
included, because a shell that sets `LANG` was set up on purpose — somebody
running under MSYS2, Cygwin or Git Bash, or in Terminal.app. It is what GNU
gettext does, and it means `LC_ALL=C` silences translation everywhere.

### In a POSIX environment

`fluent.posix` reads the variables a user expects to work.

| variable | governs | read here |
|---|---|---|
| `LANGUAGE` | a ranked list of languages to try | yes — messages only |
| `LC_ALL` | every category, overriding all others | yes |
| `LC_MESSAGES` | which language to speak | yes |
| `LC_NUMERIC` | decimal mark, grouping, digits | yes |
| `LC_TIME` | month names, field order, the clock | yes |
| `LC_MONETARY` | where the currency sign goes | yes |
| `LC_COLLATE` | sort order | no — this library does not sort |
| `LC_CTYPE` | character classification | no — nothing here classifies |
| `LANG` | the default for every category | yes |

Spelled out, rather than through `fluent.system`:

```zig
// 1. Which languages will do, best first. Only `LANGUAGE` ranks, so this is
//    the one question with a list for an answer.
var wanted: [8]fluent.Locale = undefined;
const chain = fluent.posix.fromEnviron(&wanted, init.environ_map);

// 2. Pick a bundle — yours to decide.
const bundle = negotiate(&bundles, chain);

// 3. Format the way this user writes numbers and dates.
const category = fluent.posix.categoriesFromEnviron(init.environ_map);
if (category.numeric)  |locale| bundle.setNumberLocale(locale);
if (category.monetary) |locale| bundle.setCurrencyLocale(locale);
if (category.time)     |locale| bundle.setDateLocale(locale);
```

An application that ships one translation needs only the third step, and one
that does not care about the `LC_*` split needs none of it — `Bundle.init` sets
all three categories from the locale it is given.

None of it is tied to the process. The rules apply to a `fluent.posix.Variables`
struct, so a server deciding on behalf of a user who is not the one running it
can feed in values from a config file or a request header and get the same
answers; `fromEnviron` and `categoriesFromEnviron` are the adapters for a real
environment.

**The names are not language tags.** `de_DE.UTF-8@euro` and `de-DE` are the same
locale: the codeset says how bytes are encoded and the modifier is usually a
variant, and neither keys anything here, so `fromName` drops both. The one
exception is a modifier naming a *script* — `sr_RS@latin` is Serbian written in
Latin rather than Cyrillic, a different locale that formats differently — which
becomes the script subtag it means.

Dropping the codeset has one consequence worth stating: **this library emits
UTF-8 and nothing else.** A user with `LANG=de_DE.ISO-8859-1` gets correct
German in UTF-8, and converting it is the caller's business.

**`LC_ALL=C` means do not translate.** `C` and `POSIX` are one locale under two
names, and both mean the user wants the program's own language rather than a
translation of it. `fromEnviron` returns an empty chain for them and
`Categories` returns nulls, so nothing downstream needs a special case. This is
worth honouring exactly: `LC_ALL=C` in a shell script is how somebody guarantees
that a decimal point stays a point and a month stays `Jan`, so that `awk` or
`cut` further down the pipe keeps working. For the same reason `LANGUAGE` is
ignored when `LC_ALL` or `LANG` says `C`, which is gettext's rule.

**Plural rules follow the message language**, never `LC_NUMERIC`. `[one]` and
`[few]` are variant keys the *translator* wrote, in the language the text is
written in; choosing among them by the reader's number-formatting preference
would look for variants that translation does not have. So English plurals with
Finnish punctuation is exactly what that combination gives:

```console
$ LANG=en_US.UTF-8 LC_NUMERIC=fi_FI.UTF-8 zig build example
showing:   en-US  (numbers: fi-FI)

  One new photo
  Ada shared 3 photos with you on February 14, 2026.
  12 345,7 GB of 50 000 GB used
```

`LC_MONETARY` is read but not fully served: CLDR keeps one set of separators per
locale rather than a separate monetary set, so `setCurrencyLocale` moves the
currency sign but not the decimal mark. POSIX distinguishes them
(`mon_decimal_point`), and a pair of locales that disagrees about it will not be
exact.

### On Windows

Windows has none of those variables and answers the same two questions its own
way. `fluent.windows` reads both, through
[zigwin32](https://github.com/marlersoft/zigwin32) — generated from Microsoft's
own metadata — wired in as a lazy dependency only when the target is Windows.

| | POSIX | Windows |
|---|---|---|
| which language to speak | `LANGUAGE`, `LC_MESSAGES` | `GetUserPreferredUILanguages` — a ranked list |
| how to write numbers, dates, money | `LC_NUMERIC`, `LC_TIME`, `LC_MONETARY` | `GetUserDefaultLocaleName` — one "regional format" for all three |

The answers land in the same `Categories` that `fluent.posix` produces, so
nothing above has to know which platform replied.

Windows' pseudo-locales pass through as ordinary tags — `qps` is in BCP 47's
private-use range — match no bundle, and so leave the source locale showing,
which is what somebody who set one should see from a program that ships no
pseudo-locale.

### On macOS

macOS is two systems at once. **In a terminal it is POSIX**: Terminal.app's *Set
locale environment variables on startup* is on by default and sets `LANG` from
the region preference, and iTerm2 does the same, so `fluent.system` works there
with nothing added.

**A GUI app gets nothing.** `launchd` passes no `LANG`, so a bundled `.app` sees
an empty environment however the user has their region set, and must ask the
preferences system instead. `fluent.darwin` is that, reached by `fluent.system`
in the same place it reaches Windows. `zig build` links CoreFoundation for a
Darwin target and nothing anywhere else.

| key in `NSGlobalDomain` | value | analogue |
|---|---|---|
| `AppleLanguages` | `("en-US", "de-DE")`, in preference order | `LANGUAGE`, `GetUserPreferredUILanguages` |
| `AppleLocale` | `en_US`, or `en_GB@currency=EUR` | `LC_NUMERIC`+`LC_TIME`+`LC_MONETARY` |

Both shapes go straight into functions that already exist, which is the useful
part: having read the two keys, there is nothing left to write.

```zig
// AppleLanguages entries are BCP 47 already.
const first = try fluent.Locale.parse("zh-Hans-CN");        // zh-Hans-CN

// AppleLocale is a POSIX-shaped name, and the ICU keywords after `@` are
// dropped like any other modifier.
const format = fluent.posix.fromName("en_GB@currency=EUR"); // en-GB
```

#### Format overrides

macOS lets a user override formats *independently of the locale*, under Language
& Region → Advanced, and those land in `NSGlobalDomain` as well:

| key | what it overrides |
|---|---|
| `AppleICUDateFormatStrings` | a dict keyed `"1"`–`"4"`: ICU date patterns for the four lengths |
| `AppleICUNumberSymbols` | a dict keyed by ICU's `UNumberFormatSymbol`: `0` decimal, `1` grouping, `10` monetary decimal, `17` monetary grouping |
| `AppleICUForce24HourTime`, `AppleICUForce12HourTime` | the clock, whatever the locale prefers |
| `AppleFirstWeekday`, `AppleMeasurementUnits` | week start, metric or not |

`fluent.darwin.overrides` reads all of them into a struct whose fields are null
unless the user has actually overridden that thing. It does **not** apply them:
a `Bundle` belongs to the application, so the application assigns them, and each
has somewhere to go.

```zig
var storage: fluent.darwin.OverrideStorage = .{};
const over = fluent.darwin.overrides(&storage);
if (over.date_formats) |formats| bundle.date_names.date_formats = formats;
if (over.decimal) |mark| bundle.number_symbols.decimal = mark;
if (over.first_weekday) |day| bundle.date_names.first_day = day;
```

The slices point into `storage`, which is the caller's and has to outlive them;
nothing here allocates.

**Mind the order of the date patterns.** macOS keys them `"1"` to `"4"` running
*short to long* — `"1"` is `ddMMMyy` and `"4"` is `EEEE, d MMMM y`. This library
stores them longest first, indexed by `Style`, so `date_formats[0]` is `full`
and `date_formats[3]` is `short`. They are reversed as well as offset:

```zig
// AppleICUDateFormatStrings "1".."4"  ->  date_formats[3]..[0]
bundle.date_names.date_formats[4 - index] = pattern;
```

Symbols `10` and `17` are the monetary separators — the distinction CLDR does
not keep and this library therefore cannot serve. A caller reading those from
macOS has better information than the tables do.

### Writing to a terminal

```zig
bundle.use_isolating = false;
```

Isolation is on by default and should be. It wraps every interpolation in U+2068
and U+2069 so that a right-to-left name dropped into a left-to-right sentence
does not drag the punctuation around it to the wrong end of the line.

Whether to keep them is a question about whatever will draw the text. Something
that implements the Unicode bidirectional algorithm acts on them and draws
nothing — a browser, Pango, CoreText. Something that does not draws them as
missing glyphs: a terminal, and Win32's classic controls, which put their text
on screen through GDI rather than DirectWrite. There `Ada` comes out as `⁨Ada⁩`.

So leave it on wherever the text is going into a paragraph something will lay
out properly, and turn it off for a terminal, for a renderer that will not, for
a value about to be compared or stored, and for a test asserting on exact
text.

## What it implements

Every other mature implementation delegates the locale-sensitive part to ICU:
`fluent.js` calls `Intl`, `fluent-rs` leaves number formatting to the host. This
one carries its own tables, generated from CLDR 48.2 into `src/cldr/` and
committed, so there is nothing to install and nothing to link.

Each table is a separate declaration in a separate file, so you pay for what you
reference and nothing else. Measured at `-OReleaseSmall` on x86-64 Linux: a
program that parses a resource and reads the tree is **164 KB**; one that also
formats a number and a date is **2.7 MB**, which is the CLDR data for all 766
locales.

**Plural rules** are CLDR's, cardinal and ordinal, for the 224 and 108 locales
CLDR covers. They are compiled from CLDR's rule language into tables at
generation time, so nothing parses anything at run time, and they are verified
against the 15,041 sample values CLDR publishes.

**Numbers** follow ECMA-402: digit and grouping options, significant figures,
per-locale symbols, patterns and numbering systems. German swaps the separators,
Hindi groups three digits and then two, Polish does not group four-digit numbers
at all, Egyptian Arabic writes its own digits.

**Dates** follow ECMA-402 too — `dateStyle` and `timeStyle`, or individual
fields matched against CLDR's skeletons, so that `month: "long", day: "numeric"`
comes out as "September 9" in English and "9. September" in German without the
application knowing which is which. The calendar, the IANA timezone database and
the writing of CLDR patterns come from `zig-datetime`; what is here is the part
that is Fluent's rather than a calendar's, turning `DATETIME()`'s ECMA-402
options into a CLDR skeleton.

**Flexible day periods** are CLDR's, for the 422 locales it gives rules for.
Where the meridiem knows only morning and afternoon, these divide the day as the
language does: Traditional Chinese writes 凌晨 before dawn, 中午 around noon and
晚上 in the evening, and its own short time pattern asks for them.

### How closely it agrees with ICU

ICU is the reference implementation of the specifications this follows, so
agreeing with it is the strongest claim available.

**Dates.** A matrix of 30 locales against 17 option sets and 4 instants — 2312
in all, including two either side of an ISO week-year boundary and one before
the epoch — compared against `Intl` in V8 (node 24, ICU 78.3, CLDR 48.0). 2128
are identical byte for byte, another 80 differ only by the narrow no-break space
below, and the remaining 104 are all the one divergence after it. **No case
differs on formatting.**

**Numbers.** All 400 number cases identical, and all 280 percent cases across
forty locales.

- **The narrow no-break space** — 80 cases. CLDR 48 writes English's time as
  `h:mm:ss` U+202F `a`, and Russian's year as `y` U+202F `г.`. V8 substitutes an
  ordinary space. This library follows the data, so it emits U+202F; CLDR ships
  `-alt-ascii` variants for consumers who want otherwise, and they are not used
  here.
- **Non-Gregorian calendars** — 104 cases, and the whole remainder. Thai
  defaults to the Buddhist calendar and Persian to its own, so `Intl` writes
  2568 where this writes 2025. Only the Gregorian calendar is implemented.
  Forced to `-u-ca-gregory`, those two locales agree on 132 of 136 cases,
  Persian digits and all; the four left over are Thai's `HH:mm น.`, where V8
  ships CLDR 48.0 and this pins 48.2.

### What is deliberately not implemented

- **Measurement units.** `cldr-units-full` is a further ~100 MB, and
  `NUMBER()`'s option list cannot select a unit style from FTL anyway.
- **Time zone display names.** `timeZoneNames.json` is 45 KB per locale, nearly
  all of it names. A zone is written as its offset, or as the designation the
  IANA database gives it — never wrong, only less friendly than "Central
  European Summer Time". The *wrapper* around that offset is localized, since it
  is four strings rather than a table: French writes `UTC−05:00` with a real
  minus sign and Persian `(‎−۰۵:۰۰ گرینویچ)`.
- **Compact notation** ("1.2M"). The plural rules read it, because CLDR's own
  sample data is written in it, but nothing here produces it.
- **Currency spacing.** CLDR says to insert a non-breaking space between the
  digits and a currency text that is alphabetic rather than a symbol, so ICU
  writes `EUR 1,234.50` where this writes `EUR1,234.50`. Symbols are unaffected
  — `€1,234.50` is right either way — and since currency display names are not
  shipped, an alphabetic currency text is one the application passed in itself.

## Building and testing

Everything happens inside the devshell:

```console
$ nix develop
$ zig build example                # the worked example, in your own language
$ zig build test --summary all     # unit, round-trip, fuzz seeds
$ zig build conformance            # the three external corpora, in conformance/
$ zig build c                      # just the C library, header and .pc file
$ zig build check                  # compile everything without running it
$ zig fmt --check --exclude zig-pkg --exclude cldr/zig-pkg --exclude conformance/zig-pkg .
$ zig build docs-serve             # read the API documentation at :8000
$ zig build fuzz-run -- --seconds 60
```

`zig build test` also compiles `tests/c_api.c` with a C compiler against the
installed header and links it against the static library, which is what catches
the header and the implementation drifting apart. The tests inside `src/c.zig`
run with `std.testing.allocator` in place of libc's, which is what lets them
check the ownership rules rather than merely that nothing crashed.

The examples are built by CI rather than by `zig build test`, and no two of them
can run on the same machine: the Linux runners build the plain C and the two GTK
ones, and the macOS and Windows runners build the Swift and Win32 ones.

Two things are projects of their own, in `conformance/` and `cldr/`, each with a
manifest of its own. What they depend on is heavy — two monorepos and a spec
repository in the first, 138 MB of Unicode data in the second — and none of it
is anything a consumer of this library reads. Keeping those dependencies in
their own manifests keeps them out of this one, and so out of anything
generated from it. `zig build conformance` and `zig build gen-cldr` run them
from here; each also builds on its own with `zig build` from inside its
directory.

### Conformance corpora

`zig build conformance` runs this library against three corpora it did not
write, kept by Fluent itself and by two other implementations. None is vendored
— they arrive as dependencies of `conformance/build.zig.zon`, so the exact
revision compared against is a hash in a manifest rather than a copy that could
drift, and fetching them is something only that step does.

**Fluent's own conformance fixtures**, from `projectfluent/fluent`: 39 files, the
suite every implementation is expected to agree on. They are generated with the
annotations stripped, so they say which entries are junk but not why.

**`fluent.js`'s structure fixtures**: 62 more, most of them broken on purpose,
whose trees do record why — the error code each junk entry is blamed on, the
message, and the point the parser gave up at. That corpus is what checks the
`E00NN` codes in `src/syntax/errors.zig` against the only other place they are
written down, and what checks how far a broken entry reaches. 89 annotations over
21 of the codes are compared, wording and offset included.

Four of those 62 are expected not to match, all for one reason: a broken
attribute takes the whole entry down in `fluent.js` and does not here. That is
[fluent.js#237][], and it is why `fluent.js` skips `leading_dots.ftl` when it
runs itself against the reference corpus — the reference parser keeps the
message, and so does this one. `tests/conformance_structure.zig` lists the four
and fails if one of them ever starts matching.

[fluent.js#237]: https://github.com/projectfluent/fluent.js/issues/237

**`fluent-rs`'s resolver fixtures**: 58 suites, 164 tests and 180 assertions
about the other half of the library. The two syntax corpora say what tree a file
builds and which error a broken entry is blamed on; neither says which variant a
selector picks, what a missing argument falls back to, where the isolation marks
go, or whether a cyclic reference is caught. This one does, and it is the only
runtime conformance corpus Fluent has anywhere. Its files map one-to-one onto
`fluent.js`'s own tests (`macros.yaml` against `macros_test.js`, and so on), so
what it holds is the reference implementation's behaviour in a language-neutral
form.

Eight of the 180 are expected not to match, and `tests/conformance_bundle.zig`
lists all eight with the text this library produces instead. Seven were checked
against `fluent.js`'s test for the same case, which asserts what this library
does. The eighth, a function called with arguments it cannot use, is a case
`fluent.js` skips rather than settles.

The fixtures are YAML, which Zig's standard library does not read.
`tests/yaml.zig` reads the subset they use and refuses everything else — no flow
style, no anchor, no folded scalar, no tab — since a reader that quietly
mis-parses a fixture reports a passing test that checked nothing.

### Fuzzing

Zig 0.16.0 cannot build a test executable in fuzz mode without a patched
standard library, and leaves the fuzzer's coverage table empty even then;
`flake.nix` explains both and carries the patch. `zig build fuzz-run` is a loop
of this project's own in the meantime, mutating a corpus of real inputs through
`std.testing.Smith`.

```console
$ zig build fuzz-run -- --seconds 60                  # every target in turn
$ zig build fuzz-run -- --target json --seconds 60    # one of them
$ zig build fuzz-run -- --input fuzz-findings/x.bin --target parse
```

There are ten targets:

| | |
|---|---|
| `parse` | the parser, over whole resources |
| `roundtrip` | the serializer, as both an archival round trip and a formatter |
| `resolve` | a bundle formatting messages, over eight locales, with isolation and a transform switched on and off, errors collected, and the isolation marks checked for balance |
| `numbers`, `dates` | `NUMBER()` and `DATETIME()`, options and all |
| `operands` | the plural operands derived from arbitrary text |
| `patterns` | CLDR patterns supplied by a consumer rather than by CLDR |
| `locales` | the POSIX variables, given values that disagree with each other |
| `json` | the interchange AST, plain and annotated |
| `affixes` | the prefix and suffix a number pattern wraps around its digits |

Having no coverage feedback, what a clean sweep says is that the shapes the loop
reaches are handled — and the shapes it reaches are the corpus in
`tests/fuzz.zig` and what mutation does to it. A failing input is saved under
`fuzz-findings/`; `--input` replays one, and the way to act on it is to add it
to that corpus as a test.

### Regenerating the CLDR tables

```console
$ zig build gen-cldr -Dcldr
```

The generator and the data it reads are a project of their own, in `cldr/`;
that step runs it there. `-Dcldr` fetches the three CLDR packages, which unpack
to 138 MB. Without it they are not fetched at all, and the three directories can
be named by hand instead — which is how to regenerate against a CLDR release
that manifest does not pin:

```console
$ for p in core numbers-full dates-full; do
    curl -sSL "https://registry.npmjs.org/cldr-$p/-/cldr-$p-48.2.0.tgz" |
      tar xz && mv package "cldr-$p"
  done
$ zig build gen-cldr -- cldr-core cldr-numbers-full cldr-dates-full
```

Either invocation produces byte-identical output. What the generator writes goes
under `src/cldr/` and is committed, so updating to a new CLDR is a deliberate
act with a reviewable diff.

Note that `.lazy = true` is not what makes a dependency optional. What makes it
optional is whether `b.lazyDependency` is *called*, and `build()` runs in full
during the configure phase of every `zig build`, whatever step was named on the
command line — so `-Dcldr` is what keeps `cldr/`'s own `zig build check`, which
type-checks the generator and runs nothing, from fetching all 138 MB to do it.

A declared dependency is heavier still than a called one. Anything reading a
manifest reads every entry in it, lazy or not, which is why moving these
packages into `cldr/build.zig.zon` does something an option cannot: the
library's manifest no longer names them, so neither does anything generated
from it.

### What a clean build downloads

This manifest declares two dependencies. `zig-datetime`, 1.1 MB, is the
calendar, the IANA timezone database and the writing of CLDR patterns, and is
always needed. `zigwin32` is 64 MB and is fetched only for a Windows target, so
a build for anything else neither fetches nor compiles it.

`zig-datetime` declares two of its own, `tzcode` and `tzdata`, which are the
IANA sources its `-Dembed-tzdata` compiles with zic. They are 1.1 MB each, and
they are the whole of what it adds.

So a clean Nix build of this library fetches four packages and 70 MB, of which
64 MB is `zigwin32` and is only reached for a Windows target.

`zig build conformance` adds three more, 7.4 MB for 245 KB of fixtures:

| | | |
|---|---|---|
| `fluent-spec` | 876 KB | the reference conformance fixtures |
| `fluent.js` | 2.9 MB | the structure fixtures — 193 KB of corpus inside a monorepo |
| `fluent-rs` | 3.6 MB | the resolver fixtures — 52 KB of corpus inside another |

`fluent.js` and `fluent-rs` are poor bargains by weight — two whole monorepos
for two directories of fixtures — but neither corpus has another home, and
copying them in here is the one thing that would let what this library is
measured against drift. They are in `conformance/`'s manifest rather than this
one so that the cost falls on whoever runs that step.

`zig build gen-cldr -Dcldr` adds the three CLDR packages, 138 MB unpacked, from
`cldr/`'s manifest for the same reason.

## References cited

- Project Fluent. (2019, April 17). *Fluent Syntax 1.0*.
  <https://github.com/projectfluent/fluent>
- Project Fluent. *Fluent Syntax Guide*.
  <https://projectfluent.org/fluent/guide/>
- Project Fluent. *fluent.js: JavaScript implementation of Project Fluent*.
  <https://github.com/projectfluent/fluent.js>
- Project Fluent. *fluent-rs: Rust implementation of Project Fluent*.
  <https://github.com/projectfluent/fluent-rs>
- Carr, S. F., and other CLDR committee members. *Unicode Technical Standard
  #35: Unicode Locale Data Markup Language (LDML) Part 3: Numbers* (Version
  48.2). Unicode Consortium.
  <https://www.unicode.org/reports/tr35/tr35-numbers.html>
- Edberg, P., and other CLDR committee members. *Unicode Technical Standard
  #35: Unicode Locale Data Markup Language (LDML) Part 4: Dates* (Version
  48.2). Unicode Consortium.
  <https://www.unicode.org/reports/tr35/tr35-dates.html>
- Unicode Consortium. (2025, August 4). *Unicode Common Locale Data Repository
  (CLDR)* (Release 48.2). <https://cldr.unicode.org/>
- Unicode Consortium. *ICU: International Components for Unicode* (Version
  78.3). <https://icu.unicode.org/>
- Ecma International. (2026, June). *ECMAScript 2026 Internationalization API
  Specification* (ECMA-402, 13th ed.).
  <https://ecma-international.org/publications-and-standards/standards/ecma-402/>
- Phillips, A., & Davis, M. (2009, September). *Tags for Identifying Languages*
  (RFC 5646, BCP 47). Internet Engineering Task Force.
  <https://www.rfc-editor.org/info/rfc5646>
- The Open Group. (2024). *The Open Group Base Specifications Issue 8* (IEEE
  Std 1003.1-2024). <https://pubs.opengroup.org/onlinepubs/9799919799/>
- Apple Inc. *CFPreferencesCopyAppValue(_:_:)*. Apple Developer Documentation.
  <https://developer.apple.com/documentation/corefoundation/cfpreferencescopyappvalue(_:_:)>
- Microsoft. *National Language Support*. Win32 API documentation.
  <https://learn.microsoft.com/en-us/windows/win32/intl/national-language-support>
- GNOME Project. *GTK 4 API Reference*. <https://docs.gtk.org/gtk4/>
- GNOME Project. *Blueprint Documentation*.
  <https://gnome.pages.gitlab.gnome.org/blueprint-compiler/>
- GNOME Project. *GtkBuilder*. GTK 4 API Reference.
  <https://docs.gtk.org/gtk4/class.Builder.html>
- GNOME Project. *GResource*. GIO API Reference.
  <https://docs.gtk.org/gio/struct.Resource.html>
- Apple Inc. *SwiftUI*. Apple Developer Documentation.
  <https://developer.apple.com/documentation/swiftui>
- Swift Project. *Swift Package Manager*.
  <https://www.swift.org/documentation/package-manager/>
- LLVM Project. *Clang Modules*. <https://clang.llvm.org/docs/Modules.html>
- Microsoft. *Windows Controls*. Win32 API documentation.
  <https://learn.microsoft.com/en-us/windows/win32/controls/window-controls>
- Microsoft. *MultiByteToWideChar function*. Win32 API documentation.
  <https://learn.microsoft.com/en-us/windows/win32/api/stringapiset/nf-stringapiset-multibytetowidechar>
- Microsoft. *Application Manifests*. Win32 API documentation.
  <https://learn.microsoft.com/en-us/windows/win32/sbscs/application-manifests>

The first four are Fluent itself. The grammar in `spec/fluent.ebnf` is what
`src/syntax/` implements, and the repository holding it also holds the reference
parser and the 39 conformance fixtures. The guide is the prose the syntax is
explained in. `fluent.js` is the reference implementation, and the source of the
62 structure fixtures and of the `E00NN` codes in `src/syntax/errors.zig`;
`fluent-rs` holds the 180 resolver fixtures, which are the only thing anywhere
that says what a bundle must *do* rather than what a parser must build.

The next five are the formatting. Parts 3 and 4 of UTS #35 define the pattern
vocabulary the CLDR tables are read through — the field letters, the widths, the
plural operands `n`, `i`, `v`, `w`, `f`, `t` and `e` — and CLDR 48.2 is the data
itself. ICU is the oracle the date and number matrices are compared against.
ECMA-402 is where the option names came from, because they are what `NUMBER()`
and `DATETIME()` are given in an FTL file.

The next four are how a locale is found: BCP 47 for the tag syntax and the case
normalization `Locale.parse` applies, the POSIX Base Specifications for what the
`LC_*` variables mean and which of them wins, and Apple's and Microsoft's
documentation for the two platforms that answer somewhere other than the
environment.

The last ten are what the GUI examples are written against: GTK 4's reference,
the Blueprint language and the GtkBuilder and GResource pages that say what its
output becomes, Apple's SwiftUI and Swift Package Manager documentation,
Clang's module documentation for the `module.modulemap` that makes `fluent.h`
importable from Swift, and three Win32 pages for the controls, the UTF-8 to
UTF-16 conversion and the application manifest.

All twenty-three are in the `zig-fluent` Zotero collection.

## Where this lives

The repository is hosted on Forgejo, which is where the issues and the published
documentation are:

```sh
git clone https://git.jcollie.dev/jeff/zig-fluent.git
```

It is mirrored to GitHub, and that is the copy `zig fetch` reads:

```sh
git clone https://github.com/jcollie/zig-fluent.git
```

There is a second mirror on Tangled, at
<https://tangled.org/jcollie.dev/zig-fluent>.

It is on the Radicle network as well, where the repository's identifier is

```
rad:z3qRcBG3GmL9UeB8QjNyihjnUcFTB
```

and

```sh
rad clone rad:z3qRcBG3GmL9UeB8QjNyihjnUcFTB
```

fetches it from any node that seeds it. A Radicle repository is findable by its
identifier and by nothing else, which is why that string is written out here.

Tests run in two places, because the platforms divide. The Forgejo runners are
Linux and gate the canonical repository; the GitHub mirror's matrix runs the
same suite on `ubuntu-latest`, `macos-latest` and `windows-latest`, which is
where the Win32 calls, the macOS preferences, and the Swift and Win32 examples
are exercised.

## Licence

MIT, and the project follows the [REUSE](https://reuse.software/) specification;
`reuse lint` passes. The tables under `src/cldr/` are derived from the Unicode
Common Locale Data Repository and carry its licence, Unicode-3.0.
