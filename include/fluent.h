/* SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us> */
/* SPDX-License-Identifier: MIT */

/*
 * zig-fluent: an implementation of Project Fluent, for C.
 *
 * Fluent is built around one idea: a translation is not a string with holes in
 * it, but a small program that the translator writes. Grammatical agreement --
 * plurals, gender, case -- belongs in the translation, where the person who
 * speaks the language can express it, rather than in the calling code, where
 * they cannot reach it.
 *
 *     fluent_bundle *bundle = fluent_bundle_new("en-US");
 *     fluent_bundle_add_resource(bundle, ftl, ftl_len, NULL);
 *
 *     fluent_args *args = fluent_args_new();
 *     fluent_args_set_number(args, "count", 5);
 *
 *     char *text = fluent_bundle_format(bundle, "unread", args, NULL);
 *     puts(text);
 *
 *     fluent_string_free(text);
 *     fluent_args_free(args);
 *     fluent_bundle_free(bundle);
 *
 * The calling code passes `count` and knows nothing about English's two plural
 * forms or Polish's four.
 *
 * ## The conventions of this API
 *
 * Every pointer parameter must be non-NULL unless it is documented as
 * optional. Handles are freed with the `_free` function of their own type, and
 * freeing NULL is allowed and does nothing.
 *
 * Text that this library returns as `char *` is heap-allocated, NUL-terminated
 * and belongs to the caller, who frees it with `fluent_string_free`. `strlen`
 * measures it, except in the one case where it cannot: an `.ftl` file is bytes,
 * so a translation may contain a NUL and the text would then stop early.
 * `fluent_string_len` gives the true length, and freeing is correct either way.
 *
 * Text that this library *takes* comes in two shapes, and the difference is
 * deliberate. A name -- a message identifier, an attribute, a locale tag, an
 * argument name -- is a NUL-terminated `const char *`, because that is what a
 * name always is. A body of text -- an FTL resource, a string argument -- is a
 * pointer and a length, because it comes out of a file and may be anything.
 * Neither is retained: this library copies whatever it keeps, so the caller
 * may free or reuse the buffer as soon as the call returns.
 *
 * Nothing here is thread-safe on its own. A bundle, an argument list and an
 * error list may each be used from one thread at a time; separate bundles in
 * separate threads are fine, since they share nothing but the allocator.
 *
 * ## What is deliberately not here
 *
 * **Locale negotiation.** Choosing which of the translations you shipped best
 * serves what the user asked for is the application's business, not this
 * library's -- how much of a mismatch to tolerate, and what to fall back to,
 * is a product decision. `fluent_preferred_locales` tells you what was asked
 * for; comparing that against what you have is a loop you write.
 *
 * **Time zones.** Dates are read in UTC. Attaching an IANA zone means holding
 * a parsed TZif, which belongs to zig-datetime rather than to Fluent, and
 * reaching it needs the Zig API.
 *
 * **Custom functions.** A translation may call `NUMBER()` and `DATETIME()`,
 * which every bundle has. Adding a function of your own is a Zig-side feature.
 */

#ifndef FLUENT_H
#define FLUENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -- version -------------------------------------------------------------- */

/*
 * The library version, such as "0.1.0". Static storage; do not free it.
 *
 * Deliberately a function rather than a macro: the version comes from
 * `build.zig.zon`, and a macro in this header would be a second copy of it to
 * keep in step.
 */
const char *fluent_version(void);

/* -- text ----------------------------------------------------------------- */

/*
 * Free a string this library returned. Passing NULL is allowed.
 *
 * The allocator is this library's own, so a string from here must not be given
 * to `free` and a string from anywhere else must not be given to this.
 */
void fluent_string_free(char *text);

/*
 * The length of a string this library returned, in bytes, not counting the
 * NUL that terminates it.
 *
 * The same as `strlen` for any text a person would recognize, and not the same
 * for text with a NUL inside it, which an `.ftl` file is entitled to contain.
 * Only for strings from this library; `text` must not be NULL.
 */
size_t fluent_string_len(const char *text);

/* -- locales -------------------------------------------------------------- */

/*
 * Room for a language tag and its NUL.
 *
 * A tag here is not a whole BCP 47 tag but the part CLDR keys its data by: a
 * language, an optional script and an optional region, so "sr-Latn-RS" at its
 * longest. Everything else -- extensions, variants, private use -- names no
 * data and is dropped by parsing.
 */
#define FLUENT_TAG_MAX 13

typedef struct {
	char text[FLUENT_TAG_MAX];
} fluent_tag;

/*
 * Parse and canonicalize a language tag: "EN-latn-us" becomes "en-Latn-US".
 *
 * Case is normalized as BCP 47 specifies -- language lower, script title,
 * region upper -- so two spellings of one locale compare equal byte for byte.
 *
 * Returns false, leaving `out` untouched, when the text is not a language tag
 * at all. `out` may be NULL to ask whether a tag is one without keeping it.
 */
bool fluent_tag_parse(const char *text, fluent_tag *out);

/*
 * The same, for a POSIX locale name: "de_DE.UTF-8@euro" becomes "de-DE".
 *
 * The codeset says how bytes are encoded and the modifier is usually a
 * variant, and neither keys any data here, so both are dropped. A modifier
 * naming a script is the exception and is kept -- "sr_RS@latin" is Serbian in
 * Latin script, which formats differently from Serbian in Cyrillic.
 *
 * Returns false for a name that asks for no translation -- "C" and "POSIX" --
 * and for one that is not a locale at all.
 */
bool fluent_tag_from_posix_name(const char *name, fluent_tag *out);

/*
 * The locales this user would like, best first.
 *
 * Asks whichever system is running: POSIX's `LANGUAGE`, `LC_ALL`,
 * `LC_MESSAGES` and `LANG`, Windows' preferred UI languages, or macOS'
 * `AppleLanguages` -- and on macOS and Windows the environment still wins when
 * it says anything, because a shell that sets `LANG` was set up on purpose.
 *
 * Writes at most `cap` tags into `out` and returns how many were written. Zero
 * means no preference at all: nothing is set, or `LC_ALL=C` asked for no
 * translation, and the caller should use the language its own messages are
 * written in.
 *
 * Eight is more than enough room; only `LANGUAGE` is a list, and beyond a
 * handful of entries nobody is being served better.
 */
size_t fluent_preferred_locales(fluent_tag *out, size_t cap);

/*
 * The locales in a colon-separated list, as `LANGUAGE` is written: "fr:de".
 *
 * For an application with a language setting of its own, so that it can be
 * spelled the way the environment spells it. Entries that name nothing -- an
 * empty one, or `C` -- are skipped rather than ending the list.
 */
size_t fluent_locales_from_list(const char *list, fluent_tag *out, size_t cap);

/*
 * What each formatting category should be written for.
 *
 * POSIX lets a user set these apart from the language they read, and it is an
 * ordinary thing to want: English messages with a twenty-four hour clock is
 * `LANG=en_US.UTF-8 LC_TIME=en_GB.UTF-8`. Windows splits them two ways instead,
 * into a display language and a regional format governing the other three.
 *
 * A category whose `text` is empty was not set, and the application's own
 * default applies.
 */
typedef struct {
	fluent_tag messages;  /* the language to speak, and its plural rules */
	fluent_tag numeric;   /* the separators, the digits, the grouping */
	fluent_tag time;      /* the month names, the field order, the clock */
	fluent_tag monetary;  /* where the currency sign goes */
} fluent_categories;

/* Ask the running system what its user set. */
void fluent_categories_current(fluent_categories *out);

/* -- errors --------------------------------------------------------------- */

/*
 * Something that went wrong while adding a resource or formatting a message.
 *
 * None of these stop anything. A message with a bad reference in it still
 * formats, with the unresolved part printed as `{$name}` so that the sentence
 * around it survives and the gap is obvious. They are collected only for
 * whoever wants to know -- a test, a `--lint` mode, a log.
 */
typedef enum {
	/* An entry in the resource did not parse and became junk. */
	FLUENT_ERROR_PARSE = 0,
	/* A message with this name was already in the bundle. */
	FLUENT_ERROR_DUPLICATE_MESSAGE = 1,
	/* A term with this name was already in the bundle. */
	FLUENT_ERROR_DUPLICATE_TERM = 2,
	/* `$name` was not among the arguments. */
	FLUENT_ERROR_UNKNOWN_VARIABLE = 3,
	/* A message referred to one that is not in the bundle. */
	FLUENT_ERROR_UNKNOWN_MESSAGE = 4,
	/* A message referred to a term that is not in the bundle. */
	FLUENT_ERROR_UNKNOWN_TERM = 5,
	/* The message or term exists, but has no such attribute. */
	FLUENT_ERROR_UNKNOWN_ATTRIBUTE = 6,
	/* A translation called a function the bundle does not have. */
	FLUENT_ERROR_UNKNOWN_FUNCTION = 7,
	/* The message exists and has attributes, but no value to print. */
	FLUENT_ERROR_MISSING_VALUE = 8,
	/* A pattern referred to itself, directly or through others. */
	FLUENT_ERROR_CYCLIC_REFERENCE = 9,
	/* One call expanded more placeables than the budget allows. */
	FLUENT_ERROR_TOO_MANY_PLACEABLES = 10,
	/* A builtin was given something it cannot work with. */
	FLUENT_ERROR_INVALID_ARGUMENT = 11
} fluent_error_kind;

typedef struct fluent_errors fluent_errors;

/* A list to collect errors in, or NULL if memory ran out. */
fluent_errors *fluent_errors_new(void);
void fluent_errors_free(fluent_errors *errors);

/*
 * How many errors have been collected.
 *
 * The list only ever grows: every call that takes one appends to it. Call
 * `fluent_errors_clear` between operations to tell one call's errors from the
 * next's, or read the count before and after.
 */
size_t fluent_errors_len(const fluent_errors *errors);
void fluent_errors_clear(fluent_errors *errors);

/* What kind the error at `index` is. Undefined if `index` is out of range. */
fluent_error_kind fluent_errors_kind(const fluent_errors *errors, size_t index);

/*
 * The error at `index` as a sentence, e.g. "unknown variable: $count".
 *
 * Freed with `fluent_string_free`. NULL if `index` is out of range or memory
 * ran out.
 *
 * **Read the list before freeing what it talks about.** An error borrows the
 * name it names -- from the resource that was parsed, or from the argument
 * list a message was formatted with -- so it must be read while the bundle and
 * the arguments it came from are still alive.
 */
char *fluent_errors_message(const fluent_errors *errors, size_t index);

/*
 * The name the error at `index` is about: a variable, message, term, function
 * or attribute, without its sigil.
 *
 * Freed with `fluent_string_free`. NULL when the error names nothing -- a
 * parse error or a cycle -- or if `index` is out of range. The same borrowing
 * rule as `fluent_errors_message` applies.
 */
char *fluent_errors_name(const fluent_errors *errors, size_t index);

/* -- number formatting options -------------------------------------------- */

typedef enum {
	FLUENT_NUMBER_DECIMAL = 0,
	FLUENT_NUMBER_PERCENT = 1,
	FLUENT_NUMBER_CURRENCY = 2
} fluent_number_style;

typedef enum {
	FLUENT_CURRENCY_SYMBOL = 0,
	FLUENT_CURRENCY_NARROW_SYMBOL = 1,
	FLUENT_CURRENCY_CODE = 2,
	FLUENT_CURRENCY_NAME = 3
} fluent_currency_display;

/*
 * Whether a select expression on a number counts it or ranks it.
 *
 * Cardinal is what counting things means, and what a translator writing `[one]`
 * almost always intends. Set ordinal when the number is a position rather than
 * a quantity, and the same `[one] [two] [few] *[other]` then means 1st, 2nd,
 * 3rd and 4th. It is deliberately not reachable from FTL: whether a number is
 * a count or a rank is a fact about the data, and the application is the one
 * that knows it.
 */
typedef enum {
	FLUENT_PLURAL_CARDINAL = 0,
	FLUENT_PLURAL_ORDINAL = 1
} fluent_plural_kind;

/*
 * How a number should be written, layered over what its locale already says.
 *
 * **Initialize with `fluent_number_options_default()`**, never by zeroing:
 * "unset" is a negative digit count and grouping is on by default, so an
 * all-zero struct asks for something quite different from the defaults.
 *
 * A digit count of -1 means unset, and the locale's own pattern decides. The
 * options a translator writes in `NUMBER()` are layered over these rather than
 * replacing them, so an amount handed in as a currency amount stays one.
 */
typedef struct {
	fluent_number_style style;

	int16_t minimum_integer_digits;
	int16_t minimum_fraction_digits;
	int16_t maximum_fraction_digits;
	int16_t minimum_significant_digits;
	int16_t maximum_significant_digits;

	bool use_grouping;

	/* The ISO 4217 code, e.g. "EUR". Required when the style is currency. */
	const char *currency;
	fluent_currency_display currency_display;

	/*
	 * The text to put where the pattern has its currency placeholder, e.g.
	 * "€". The caller resolves `currency` and `currency_display` against
	 * the locale and passes the answer, because which of a currency's
	 * several names applies is a question about the locale and not about
	 * the number. NULL prints nothing there.
	 */
	const char *currency_text;

	/*
	 * How many fraction digits this currency is normally written with: two
	 * for most, zero for the yen, three for the dinar. -1 keeps the default
	 * of two.
	 */
	int16_t currency_digits;

	fluent_plural_kind plural_kind;
} fluent_number_options;

fluent_number_options fluent_number_options_default(void);

/* -- date formatting options ---------------------------------------------- */

/* Every one of these is optional, and zero means "not asked for". */

typedef enum {
	FLUENT_DATE_STYLE_UNSET = 0,
	FLUENT_DATE_STYLE_FULL = 1,
	FLUENT_DATE_STYLE_LONG = 2,
	FLUENT_DATE_STYLE_MEDIUM = 3,
	FLUENT_DATE_STYLE_SHORT = 4
} fluent_date_style;

typedef enum {
	FLUENT_WIDTH_UNSET = 0,
	FLUENT_WIDTH_NARROW = 1,
	FLUENT_WIDTH_SHORT = 2,
	FLUENT_WIDTH_LONG = 3
} fluent_width;

typedef enum {
	FLUENT_NUMERIC_UNSET = 0,
	FLUENT_NUMERIC_NUMERIC = 1,
	FLUENT_NUMERIC_2_DIGIT = 2
} fluent_numeric;

typedef enum {
	FLUENT_MONTH_UNSET = 0,
	FLUENT_MONTH_NUMERIC = 1,
	FLUENT_MONTH_2_DIGIT = 2,
	FLUENT_MONTH_NARROW = 3,
	FLUENT_MONTH_SHORT = 4,
	FLUENT_MONTH_LONG = 5
} fluent_month_width;

typedef enum {
	FLUENT_ZONE_NAME_UNSET = 0,
	FLUENT_ZONE_NAME_SHORT = 1,
	FLUENT_ZONE_NAME_LONG = 2,
	FLUENT_ZONE_NAME_SHORT_OFFSET = 3,
	FLUENT_ZONE_NAME_LONG_OFFSET = 4
} fluent_zone_name;

/*
 * How a moment should be written.
 *
 * Zeroing this struct is safe and asks for nothing, which is what
 * `fluent_datetime_options_default()` returns -- with one exception, `hour12`,
 * which is a tri-state where -1 is "let the locale decide", so use the
 * function rather than `memset` and you need not remember that.
 *
 * `date_style` and `time_style` are whole presets. When either is set the
 * individual field options are ignored, which is what ECMA-402 specifies. When
 * nothing at all is asked for, a date shows year, month and day.
 *
 * Dates are read in UTC; see the note at the top of this file.
 */
typedef struct {
	fluent_date_style date_style;
	fluent_date_style time_style;

	fluent_width weekday;
	fluent_width era;
	fluent_numeric year;
	fluent_month_width month;
	fluent_numeric day;
	fluent_numeric hour;
	fluent_numeric minute;
	fluent_numeric second;
	int16_t fractional_second_digits; /* -1 unset */
	fluent_width day_period;

	/* -1 lets the locale choose, 0 forces 24-hour, 1 forces 12-hour. */
	int8_t hour12;

	fluent_zone_name time_zone_name;
} fluent_datetime_options;

fluent_datetime_options fluent_datetime_options_default(void);

/* -- arguments ------------------------------------------------------------ */

/*
 * The values a message is formatted with.
 *
 * Fluent's type system is small on purpose: a translation can be given text, a
 * number or a moment, and that is all, because everything a translator can do
 * with a value is print it or select on it. An application with something more
 * elaborate to show formats it first and passes the text.
 *
 * Names and values are copied in, so the caller's buffers may be freed at
 * once. Setting a name that is already there replaces it.
 */
typedef struct fluent_args fluent_args;

fluent_args *fluent_args_new(void);
void fluent_args_free(fluent_args *args);

/* Forget every argument, keeping the memory for the next message. */
void fluent_args_clear(fluent_args *args);
size_t fluent_args_len(const fluent_args *args);

/* Each of these returns false only if memory ran out. */
bool fluent_args_set_string(fluent_args *args, const char *name,
			    const char *text, size_t text_len);
bool fluent_args_set_number(fluent_args *args, const char *name, double value);
bool fluent_args_set_number_with(fluent_args *args, const char *name,
				 double value,
				 const fluent_number_options *options);
/* A moment, as milliseconds since 1970-01-01T00:00:00Z. Negative is fine. */
bool fluent_args_set_datetime(fluent_args *args, const char *name,
			      int64_t epoch_ms);
bool fluent_args_set_datetime_with(fluent_args *args, const char *name,
				   int64_t epoch_ms,
				   const fluent_datetime_options *options);

/* -- bundles -------------------------------------------------------------- */

/*
 * The messages of one locale, ready to be formatted. The object an application
 * holds -- usually one per translation it ships.
 */
typedef struct fluent_bundle fluent_bundle;

/*
 * A bundle for `locale`, with `NUMBER()` and `DATETIME()` installed.
 *
 * The tag is parsed as `fluent_tag_parse` parses it. NULL if it is not a
 * language tag, or if memory ran out. "und" is the root locale, which is
 * always valid and formats in a neutral, ISO-like way.
 */
fluent_bundle *fluent_bundle_new(const char *locale);
void fluent_bundle_free(fluent_bundle *bundle);

/* The locale this bundle speaks, canonicalized. Owned by the bundle. */
const char *fluent_bundle_locale(const fluent_bundle *bundle);

/*
 * Whether to wrap interpolations in Unicode isolation marks. On by default, as
 * in the reference implementation.
 *
 * Isolation wraps every interpolation in U+2068 and U+2069 so that a
 * right-to-left name dropped into a left-to-right sentence does not drag the
 * punctuation around it to the wrong end of the line. A browser honours those
 * marks; a terminal prints them. Turn it off when the result is going
 * somewhere the invisible characters would be a problem -- a test asserting on
 * exact text, a command-line tool, a value about to be compared -- and leave it
 * on when it is going into a paragraph a person reads.
 */
void fluent_bundle_set_use_isolating(fluent_bundle *bundle, bool on);

/*
 * Parse `source` and add its messages and terms to the bundle.
 *
 * Returns false only if memory ran out. An entry that does not parse is
 * reported into `errors` and skipped; the rest of the file is added regardless,
 * which is the whole point of Fluent's junk recovery. A name that is already
 * defined is reported and the new definition dropped, unless
 * `fluent_bundle_add_resource_overriding` was used.
 *
 * `errors` is optional; pass NULL to ignore what went wrong.
 */
bool fluent_bundle_add_resource(fluent_bundle *bundle, const char *source,
				size_t source_len, fluent_errors *errors);

/* As above, but a name defined here replaces one an earlier resource defined. */
bool fluent_bundle_add_resource_overriding(fluent_bundle *bundle,
					   const char *source,
					   size_t source_len,
					   fluent_errors *errors);

bool fluent_bundle_has_message(const fluent_bundle *bundle, const char *id);

/*
 * Format a message. The caller owns the text and frees it with
 * `fluent_string_free`.
 *
 * NULL means the bundle has no such message -- or, far less often, that memory
 * ran out. `fluent_bundle_has_message` tells the two apart. Missing is a
 * return value rather than an error because an application falling back
 * through several bundles simply asks the next one.
 *
 * `args` and `errors` are both optional.
 */
char *fluent_bundle_format(const fluent_bundle *bundle, const char *id,
			   const fluent_args *args, fluent_errors *errors);

/* Format one attribute of a message, such as a `.placeholder`. */
char *fluent_bundle_format_attribute(const fluent_bundle *bundle,
				     const char *id, const char *attribute,
				     const fluent_args *args,
				     fluent_errors *errors);

/*
 * Punctuate numbers, write money, and write dates the way another locale does.
 *
 * For an application honouring `LC_NUMERIC`, `LC_MONETARY` and `LC_TIME`, which
 * POSIX lets a user set apart from the language they read. Plural rules are
 * not affected: `[one]` and `[few]` are keys the translator wrote in the
 * language of the text, so they follow the bundle's own locale.
 *
 * Setting the number locale sets the currency locale too, so call
 * `fluent_bundle_set_currency_locale` after it when they differ. Each returns
 * false if the tag is not a language tag, leaving the bundle alone.
 */
bool fluent_bundle_set_number_locale(fluent_bundle *bundle, const char *locale);
bool fluent_bundle_set_currency_locale(fluent_bundle *bundle,
				       const char *locale);
bool fluent_bundle_set_date_locale(fluent_bundle *bundle, const char *locale);

/*
 * Apply what `fluent_categories_current` found. A category that was not set
 * leaves the bundle as it was, and the bundle's own locale -- the language --
 * is never touched.
 */
void fluent_bundle_apply_categories(fluent_bundle *bundle,
				    const fluent_categories *categories);

#ifdef __cplusplus
}
#endif

#endif /* FLUENT_H */
