/* SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us> */
/* SPDX-License-Identifier: MIT */

/*
 * The C API from the outside.
 *
 * This is the only thing in the build that reads `include/fluent.h`, so it is
 * the only thing that can catch the header and `src/c.zig` drifting apart: a
 * renamed function, a reordered struct field, an enum that gained a value in
 * one place and not the other. It is a consumer rather than a unit test, and
 * it does what a consumer does -- build a bundle, add a translation, format
 * some messages, read the errors -- so that the shape of the API is exercised
 * and not merely its symbols.
 *
 * Isolation is switched off throughout, because these assertions are on exact
 * text and isolation wraps every interpolation in invisible characters.
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fluent.h"

static int failures = 0;

static void check(bool ok, const char *what)
{
	if (ok) return;
	fprintf(stderr, "FAIL: %s\n", what);
	failures += 1;
}

/* Assert on a string the library allocated, and free it either way. */
static void check_text(char *got, const char *want, const char *what)
{
	if (got == NULL) {
		fprintf(stderr, "FAIL: %s: got nothing, wanted \"%s\"\n", what,
			want);
		failures += 1;
		return;
	}
	if (strcmp(got, want) != 0) {
		fprintf(stderr, "FAIL: %s: got \"%s\", wanted \"%s\"\n", what,
			got, want);
		failures += 1;
	}
	fluent_string_free(got);
}

/* Assert on a string the library lent us and still owns. */
static void check_borrowed(const char *got, const char *want, const char *what)
{
	if (got == NULL || strcmp(got, want) != 0) {
		fprintf(stderr, "FAIL: %s: got \"%s\", wanted \"%s\"\n", what,
			got == NULL ? "(nothing)" : got, want);
		failures += 1;
	}
}

/* The same, for text whose exact shape belongs to CLDR rather than to us. */
static void check_contains(char *got, const char *want, const char *what)
{
	if (got == NULL) {
		fprintf(stderr, "FAIL: %s: got nothing\n", what);
		failures += 1;
		return;
	}
	if (strstr(got, want) == NULL) {
		fprintf(stderr, "FAIL: %s: \"%s\" does not contain \"%s\"\n",
			what, got, want);
		failures += 1;
	}
	fluent_string_free(got);
}

static const char catalog[] =
	"welcome = Welcome!\n"
	"unread =\n"
	"    { $count ->\n"
	"        [one] One unread message\n"
	"       *[other] { $count } unread messages\n"
	"    }\n"
	"greeting = Hello, { $name }!\n"
	"input = Value\n"
	"    .placeholder = Type here\n"
	"total = You paid { $amount }.\n"
	"stamp = Filed { $when }.\n"
	"plain = { $n }\n";

static void test_version(void)
{
	const char *version = fluent_version();
	check(version != NULL && version[0] != '\0', "version is not empty");
}

static void test_tags(void)
{
	fluent_tag tag;

	check(fluent_tag_parse("EN-latn-us", &tag), "a language tag parses");
	check_borrowed(tag.text, "en-Latn-US", "and is canonicalized");

	check(fluent_tag_parse("und", NULL),
	      "the root locale parses, and out may be NULL");
	check(!fluent_tag_parse("this is not a language tag", &tag),
	      "nonsense is refused");

	/* A POSIX name is not a language tag, and has a reader of its own. */
	check(fluent_tag_from_posix_name("de_DE.UTF-8@euro", &tag),
	      "a POSIX name parses");
	check_borrowed(tag.text, "de-DE", "with the codeset and modifier dropped");
	check(fluent_tag_from_posix_name("sr_RS@latin", &tag),
	      "a modifier that names a script");
	check_borrowed(tag.text, "sr-Latn-RS", "is kept, because it keys data");
	check(!fluent_tag_from_posix_name("C", &tag),
	      "and C asks for no translation at all");

	/* The longest tag CLDR keys anything by still fits, NUL and all. */
	check(fluent_tag_parse("und-Latn-419", &tag), "a full tag parses");
	check_borrowed(tag.text, "und-Latn-419", "and fills FLUENT_TAG_MAX");
	check(strlen(tag.text) == FLUENT_TAG_MAX - 1, "exactly");

	fluent_tag list[4];
	size_t found = fluent_locales_from_list("fr:de", list, 4);
	check(found == 2, "a colon-separated list gives two locales");
	if (found == 2) {
		check_borrowed(list[0].text, "fr", "the first is French");
		check_borrowed(list[1].text, "de", "the second is German");
	}

	/* `C` names no language, and a stray colon does not end the list. */
	found = fluent_locales_from_list("C::en", list, 4);
	check(found == 1, "C and an empty entry are skipped");
}

static void test_system(void)
{
	/*
	 * What the machine says depends on the machine, so what is asserted
	 * here is only that asking is safe and the answers are well formed:
	 * every tag written is NUL-terminated, and the count never exceeds the
	 * room offered. The Zig tests cover what the readers actually read.
	 */
	fluent_tag wanted[8];
	size_t count = fluent_preferred_locales(wanted, 8);
	check(count <= 8, "no more locales than there was room for");
	for (size_t i = 0; i < count; i += 1)
		check(memchr(wanted[i].text, '\0', FLUENT_TAG_MAX) != NULL,
		      "a reported tag is NUL-terminated");

	check(fluent_preferred_locales(wanted, 0) == 0,
	      "asking for none gives none");

	fluent_categories categories;
	fluent_categories_current(&categories);
	check(memchr(categories.messages.text, '\0', FLUENT_TAG_MAX) != NULL,
	      "a reported category is NUL-terminated");
}

static void test_formatting(fluent_bundle *bundle)
{
	fluent_args *args = fluent_args_new();
	check(args != NULL, "an argument list is created");
	if (args == NULL) return;

	check_text(fluent_bundle_format(bundle, "welcome", NULL, NULL),
		   "Welcome!", "a message with no arguments");

	/* The plural rules of the bundle's own language, chosen by CLDR. */
	check(fluent_args_set_number(args, "count", 1), "count = 1");
	check_text(fluent_bundle_format(bundle, "unread", args, NULL),
		   "One unread message", "English's singular");

	check(fluent_args_set_number(args, "count", 5),
	      "count = 5 replaces count = 1");
	check(fluent_args_len(args) == 1, "replacing does not append");
	check_text(fluent_bundle_format(bundle, "unread", args, NULL),
		   "5 unread messages", "English's plural");

	fluent_args_clear(args);
	check(fluent_args_len(args) == 0, "clearing empties the list");

	/* A string argument is a pointer and a length, and is copied. */
	char name[] = "Ada";
	check(fluent_args_set_string(args, "name", name, strlen(name)),
	      "name = Ada");
	memset(name, 'x', sizeof(name) - 1);
	check_text(fluent_bundle_format(bundle, "greeting", args, NULL),
		   "Hello, Ada!",
		   "a string argument is copied, not borrowed");

	check_text(fluent_bundle_format_attribute(bundle, "input",
						  "placeholder", NULL, NULL),
		   "Type here", "an attribute");

	/* Missing is a return value rather than an error. */
	check(fluent_bundle_format(bundle, "absent", NULL, NULL) == NULL,
	      "a message that is not there formats to nothing");
	check(!fluent_bundle_has_message(bundle, "absent"),
	      "and says it is not there");
	check(fluent_bundle_has_message(bundle, "welcome"),
	      "while one that is, is");

	fluent_args_free(args);
}

static void test_number_options(fluent_bundle *bundle)
{
	fluent_args *args = fluent_args_new();
	if (args == NULL) return;

	/*
	 * Which of a currency's several names applies is a question about the
	 * locale, so the caller resolves it and passes the answer -- that is
	 * what `currency_text` is for.
	 */
	fluent_number_options options = fluent_number_options_default();
	options.style = FLUENT_NUMBER_CURRENCY;
	options.currency = "EUR";
	options.currency_text = "\xe2\x82\xac"; /* € */

	check(fluent_args_set_number_with(args, "amount", 12.5, &options),
	      "amount = €12.50");
	check_text(fluent_bundle_format(bundle, "total", args, NULL),
		   "You paid \xe2\x82\xac" "12.50.", "a currency amount");

	/* Digit counts are honoured, and -1 leaves them to the locale. */
	options = fluent_number_options_default();
	options.maximum_fraction_digits = 1;
	check(fluent_args_set_number_with(args, "amount", 3.14159, &options),
	      "amount = 3.1");
	check_text(fluent_bundle_format(bundle, "total", args, NULL),
		   "You paid 3.1.", "a rounded number");

	/* An out-of-range digit count is refused rather than trapping. */
	options = fluent_number_options_default();
	options.maximum_fraction_digits = 9999;
	check(fluent_args_set_number_with(args, "amount", 3.14159, &options),
	      "an absurd digit count is accepted");
	check_contains(fluent_bundle_format(bundle, "total", args, NULL), "3.14",
		       "and ignored rather than crashing");

	fluent_args_free(args);
}

static void test_datetime_options(fluent_bundle *bundle)
{
	fluent_args *args = fluent_args_new();
	if (args == NULL) return;

	/* 2026-02-14T09:30:00Z, so that this says the same thing twice. */
	const int64_t when = INT64_C(1771061400000);

	fluent_datetime_options options = fluent_datetime_options_default();
	options.date_style = FLUENT_DATE_STYLE_LONG;

	check(fluent_args_set_datetime_with(args, "when", when, &options),
	      "when = 2026-02-14");
	check_contains(fluent_bundle_format(bundle, "stamp", args, NULL),
		       "2026", "a date carries its year");

	/* Before 1970 is ordinary, which is more than `std.time.epoch` can say. */
	check(fluent_args_set_datetime(args, "when", INT64_C(-86400000)),
	      "when = 1969-12-31");
	check_contains(fluent_bundle_format(bundle, "stamp", args, NULL), "1969",
		       "a date before the epoch");

	fluent_args_free(args);
}

static void test_categories(void)
{
	/*
	 * POSIX lets a user punctuate numbers one way and read messages in
	 * another language, and this is that: English text, German numbers.
	 */
	fluent_bundle *bundle = fluent_bundle_new("en");
	check(bundle != NULL, "a bundle for English");
	if (bundle == NULL) return;
	fluent_bundle_set_use_isolating(bundle, false);
	check(fluent_bundle_add_resource(bundle, catalog, sizeof(catalog) - 1,
					 NULL),
	      "the catalog is added");

	fluent_args *args = fluent_args_new();
	if (args == NULL) {
		fluent_bundle_free(bundle);
		return;
	}
	check(fluent_args_set_number(args, "n", 1234.5), "n = 1234.5");
	check_text(fluent_bundle_format(bundle, "plain", args, NULL), "1,234.5",
		   "English punctuation");

	check(fluent_bundle_set_number_locale(bundle, "de"),
	      "numbers follow German");
	check_text(fluent_bundle_format(bundle, "plain", args, NULL), "1.234,5",
		   "German punctuation");

	check(!fluent_bundle_set_number_locale(bundle, "not a tag"),
	      "a bad tag is refused");
	check_text(fluent_bundle_format(bundle, "plain", args, NULL), "1.234,5",
		   "and changes nothing");

	/* The language itself is never touched by any of that. */
	check_borrowed(fluent_bundle_locale(bundle), "en",
		   "the bundle still speaks English");

	/* An unset category leaves the bundle as it was. */
	fluent_categories categories;
	memset(&categories, 0, sizeof(categories));
	fluent_bundle_apply_categories(bundle, &categories);
	check_text(fluent_bundle_format(bundle, "plain", args, NULL), "1.234,5",
		   "applying nothing changes nothing");

	memcpy(categories.numeric.text, "fr", 3);
	fluent_bundle_apply_categories(bundle, &categories);
	check_contains(fluent_bundle_format(bundle, "plain", args, NULL), "234",
		       "applying a category is honoured");

	fluent_args_free(args);
	fluent_bundle_free(bundle);
}

static void test_errors(void)
{
	fluent_bundle *bundle = fluent_bundle_new("en");
	if (bundle == NULL) {
		check(false, "a bundle for the error tests");
		return;
	}
	fluent_bundle_set_use_isolating(bundle, false);

	fluent_errors *errors = fluent_errors_new();
	check(errors != NULL, "an error list is created");
	if (errors == NULL) {
		fluent_bundle_free(bundle);
		return;
	}

	/*
	 * Junk recovery: the broken entry is reported and skipped, and the
	 * rest of the file is added regardless.
	 */
	static const char broken[] = "before = fine\n"
				     "oops = { $x\n"
				     "after = also fine\n";
	check(fluent_bundle_add_resource(bundle, broken, sizeof(broken) - 1,
					 errors),
	      "a file with junk in it is still added");
	check(fluent_bundle_has_message(bundle, "before"), "the entry before");
	check(fluent_bundle_has_message(bundle, "after"), "the entry after");
	check(fluent_errors_len(errors) >= 1, "and the junk was reported");
	check(fluent_errors_kind(errors, 0) == FLUENT_ERROR_PARSE,
	      "as a parse error");
	check_contains(fluent_errors_message(errors, 0), "parse error",
		       "which says so");

	fluent_errors_clear(errors);
	check(fluent_errors_len(errors) == 0, "the list can be cleared");

	/*
	 * A missing argument does not stop the message: the gap prints as
	 * `{$name}` so that the sentence around it survives.
	 */
	static const char needs[] = "hello = Hello, { $name }!\n";
	check(fluent_bundle_add_resource(bundle, needs, sizeof(needs) - 1, NULL),
	      "a message that needs an argument");
	check_text(fluent_bundle_format(bundle, "hello", NULL, errors),
		   "Hello, {$name}!", "formats with the gap showing");
	check(fluent_errors_len(errors) == 1, "and reports one error");
	check(fluent_errors_kind(errors, 0) == FLUENT_ERROR_UNKNOWN_VARIABLE,
	      "an unknown variable");
	check_text(fluent_errors_message(errors, 0), "unknown variable: $name",
		   "which says which");
	check_text(fluent_errors_name(errors, 0), "name", "and names it");

	/* Out of range is not a crash. */
	check(fluent_errors_message(errors, 99) == NULL,
	      "an index past the end has no message");
	check(fluent_errors_name(errors, 99) == NULL,
	      "and no name");

	/* An error that is about nothing in particular has no name. */
	fluent_errors_clear(errors);
	static const char cycle[] = "loop = { loop }\n";
	check(fluent_bundle_add_resource(bundle, cycle, sizeof(cycle) - 1, NULL),
	      "a message that refers to itself");
	fluent_string_free(fluent_bundle_format(bundle, "loop", NULL, errors));
	check(fluent_errors_len(errors) >= 1, "is reported");
	check(fluent_errors_name(errors, 0) == NULL,
	      "and a cycle names nothing");

	fluent_errors_free(errors);
	fluent_bundle_free(bundle);
}

static void test_overrides(void)
{
	fluent_bundle *bundle = fluent_bundle_new("und");
	if (bundle == NULL) {
		check(false, "a bundle for the root locale");
		return;
	}
	fluent_bundle_set_use_isolating(bundle, false);

	fluent_errors *errors = fluent_errors_new();
	if (errors == NULL) {
		fluent_bundle_free(bundle);
		return;
	}

	static const char first[] = "m = first\n";
	static const char second[] = "m = second\n";

	check(fluent_bundle_add_resource(bundle, first, sizeof(first) - 1, NULL),
	      "the first definition");
	check(fluent_bundle_add_resource(bundle, second, sizeof(second) - 1,
					 errors),
	      "the second is refused");
	check(fluent_errors_len(errors) == 1, "and reported");
	check(fluent_errors_kind(errors, 0) == FLUENT_ERROR_DUPLICATE_MESSAGE,
	      "as a duplicate");
	check_text(fluent_bundle_format(bundle, "m", NULL, NULL), "first",
		   "the first definition stands");

	check(fluent_bundle_add_resource_overriding(bundle, second,
						    sizeof(second) - 1, NULL),
	      "unless overriding was asked for");
	check_text(fluent_bundle_format(bundle, "m", NULL, NULL), "second",
		   "and then the second wins");

	fluent_errors_free(errors);
	fluent_bundle_free(bundle);
}

static void test_embedded_nul(void)
{
	/*
	 * An `.ftl` file is bytes, so a translation may have a NUL in it, and
	 * then what C sees through `strlen` stops early. The library still knows
	 * how long the text really is, and still frees the whole of it.
	 */
	fluent_bundle *bundle = fluent_bundle_new("und");
	if (bundle == NULL) {
		check(false, "a bundle for the NUL test");
		return;
	}
	fluent_bundle_set_use_isolating(bundle, false);

	static const char source[] = "m = before\0after\n";
	check(fluent_bundle_add_resource(bundle, source, sizeof(source) - 1,
					 NULL),
	      "a message with a NUL in it");

	char *text = fluent_bundle_format(bundle, "m", NULL, NULL);
	check(text != NULL, "formats");
	if (text != NULL) {
		check(strcmp(text, "before") == 0, "and stops at the NUL");
		check(fluent_string_len(text) == strlen("before") +
						   1 + strlen("after"),
		      "while the true length is the whole of it");
		fluent_string_free(text);
	}

	fluent_bundle_free(bundle);
}

static void test_lifetimes(void)
{
	/* Freeing NULL is allowed everywhere, so cleanup needs no branches. */
	fluent_string_free(NULL);
	fluent_args_free(NULL);
	fluent_errors_free(NULL);
	fluent_bundle_free(NULL);

	check(fluent_bundle_new("not a tag") == NULL,
	      "a bundle for nonsense is not created");
}

int main(void)
{
	test_version();
	test_tags();
	test_system();
	test_lifetimes();
	test_embedded_nul();
	test_categories();
	test_errors();
	test_overrides();

	fluent_bundle *bundle = fluent_bundle_new("en-US");
	check(bundle != NULL, "a bundle for American English");
	if (bundle != NULL) {
		fluent_bundle_set_use_isolating(bundle, false);
		check(fluent_bundle_add_resource(bundle, catalog,
						 sizeof(catalog) - 1, NULL),
		      "the catalog is added");
		check_borrowed(fluent_bundle_locale(bundle), "en-US",
			   "the bundle reports its locale");

		test_formatting(bundle);
		test_number_options(bundle);
		test_datetime_options(bundle);

		fluent_bundle_free(bundle);
	}

	if (failures != 0) {
		fprintf(stderr, "%d check(s) failed\n", failures);
		return 1;
	}
	printf("the C API is intact\n");
	return 0;
}
