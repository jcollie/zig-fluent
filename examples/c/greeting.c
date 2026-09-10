/* SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us> */
/* SPDX-License-Identifier: MIT */

/*
 * The worked example, in C.
 *
 * `examples/greeting.zig` is the same program written in Zig, against the same
 * `.ftl` files, and the two are worth reading side by side: what changes is
 * the spelling, and what does not is the shape. Three steps, and only the
 * middle one is really this library's business:
 *
 *  1. **What did the user ask for?** POSIX answers with `LANGUAGE`, `LC_ALL`,
 *     `LC_MESSAGES` and `LANG`, which are not language tags; Windows and macOS
 *     answer with an API instead. `fluent_preferred_locales` asks whichever is
 *     running, so this program has no environment handling of its own.
 *  2. **What do we have?** One bundle per translation, and a negotiation
 *     between what was asked for and what was shipped. That negotiation is
 *     written out below, because it is the application's decision rather than
 *     the library's -- see the comment on `negotiate`.
 *  3. **Say it.** `fluent_bundle_format`, with the arguments the message needs.
 *
 * Everything grammatical stays inside the `.ftl` files. This program passes a
 * count, a name and a moment, and never learns that Polish needs four plural
 * forms where English needs two, that Finnish counts photos in the partitive,
 * that German puts the date before the object, or that Japanese counts them
 * with 枚.
 *
 * Unlike the Zig example, which embeds its translations with `@embedFile`,
 * this one reads them from disk at run time -- which is the other ordinary
 * deployment shape, and which is why the resources are passed as a pointer and
 * a length rather than as C strings.
 *
 *     $ make && ./greeting
 *     $ LANG=de_DE.UTF-8 ./greeting
 *     $ ./greeting fi
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fluent.h>

/* Where `make` put the `.ftl` files. */
#ifndef LOCALE_DIR
#define LOCALE_DIR "../locales"
#endif

/*
 * The translations shipped with the program.
 *
 * The first entry is the source locale and is the last resort, which is why
 * its translation must be complete.
 */
static const char *const catalog[] = { "en-US", "de", "fr", "fi", "pl", "ja" };
#define CATALOG_LEN (sizeof(catalog) / sizeof(catalog[0]))

/*
 * The most locales a user can ask for. `LANGUAGE` is a list, and the rest
 * contribute one each; beyond this many nobody is being served better.
 */
#define MAX_REQUESTED 8

/* 2026-02-14T09:30:00Z, fixed so that running this twice says the same thing.
 * A real application would read a clock. */
#define WHEN INT64_C(1771061400000)

/* -- reading a translation off disk --------------------------------------- */

/*
 * The whole of `LOCALE_DIR/<tag>.ftl`, or NULL with a complaint on stderr.
 *
 * `*len` is set to the length in bytes, because that is what the library
 * wants: an `.ftl` file is text and not a C string, and nothing says it may
 * not contain a NUL.
 */
static char *read_locale(const char *tag, size_t *len)
{
	char path[256];
	int written = snprintf(path, sizeof(path), "%s/%s.ftl", LOCALE_DIR, tag);
	if (written < 0 || (size_t)written >= sizeof(path)) {
		fprintf(stderr, "path too long for %s\n", tag);
		return NULL;
	}

	FILE *file = fopen(path, "rb");
	if (file == NULL) {
		perror(path);
		return NULL;
	}

	char *source = NULL;
	if (fseek(file, 0, SEEK_END) != 0) goto fail;

	long size = ftell(file);
	if (size < 0) goto fail;
	if (fseek(file, 0, SEEK_SET) != 0) goto fail;

	source = malloc((size_t)size + 1);
	if (source == NULL) goto fail;

	if (fread(source, 1, (size_t)size, file) != (size_t)size) goto fail;
	source[size] = '\0';

	fclose(file);
	*len = (size_t)size;
	return source;

fail:
	perror(path);
	free(source);
	fclose(file);
	return NULL;
}

/* -- what we have --------------------------------------------------------- */

/*
 * Whether two canonical tags name the same language.
 *
 * A tag out of `fluent_tag_parse` is canonical -- language lowercase, script
 * title case, region uppercase, hyphens throughout -- so the language is
 * everything up to the first hyphen and a plain comparison is enough. No
 * locale library is needed to do this, which is the point: what comes back is
 * a string, and the application is free to treat it as one.
 */
static size_t language_len(const char *tag)
{
	const char *hyphen = strchr(tag, '-');
	return hyphen == NULL ? strlen(tag) : (size_t)(hyphen - tag);
}

static bool same_language(const char *have, const char *want)
{
	size_t len = language_len(have);
	return len == language_len(want) && strncmp(have, want, len) == 0;
}

/* The script subtag, or NULL when the tag does not state one. */
static const char *script_of(const char *tag)
{
	const char *rest = strchr(tag, '-');
	if (rest == NULL) return NULL;
	rest += 1;

	/* A four-letter subtag in this position is a script; a two-letter or
	 * three-digit one is a region, and there is then no script. */
	size_t len = language_len(rest); /* the next subtag, by the same rule */
	return len == 4 ? rest : NULL;
}

/* Whether two tags name the same script, counting "unstated" as agreeing. */
static bool scripts_agree(const char *a, const char *b)
{
	const char *left = script_of(a);
	const char *right = script_of(b);
	if (left == NULL || right == NULL) return true;
	return strncmp(left, right, 4) == 0;
}

/* Whether `have` serves `want` at a given level of exactness. */
static bool matches(const char *have, const char *want, int pass)
{
	if (!same_language(have, want)) return false;
	switch (pass) {
	case 0: return strcmp(have, want) == 0;
	case 1: return scripts_agree(have, want);
	default: return true;
	}
}

/*
 * The bundle that best serves the locales the user asked for.
 *
 * This is the part the library deliberately does not do for you: how much of a
 * mismatch to tolerate, and what to fall back to, is a product decision rather
 * than a fact about locales. What is here is one reasonable answer, and it is
 * the same one `examples/greeting.zig` gives.
 *
 * Each requested locale is tried in turn, and for each one the bundles are
 * searched for the closest match: the same tag, then the same language and
 * script, then merely the same language. Asking in that order matters --
 * somebody who asks for `fr` before `en` should get French even though an
 * `en-US` bundle exists and is a better match for nothing they said.
 *
 * When nothing matches, the first bundle. It is the source locale, its
 * translation is by construction complete, and printing English is a better
 * outcome than printing message names.
 */
static size_t negotiate(fluent_bundle *const *bundles, const fluent_tag *requested,
			size_t requested_len)
{
	for (size_t i = 0; i < requested_len; i += 1)
		for (int pass = 0; pass < 3; pass += 1)
			for (size_t b = 0; b < CATALOG_LEN; b += 1)
				if (matches(fluent_bundle_locale(bundles[b]),
					    requested[i].text, pass))
					return b;
	return 0;
}

/* -- say it --------------------------------------------------------------- */

/*
 * Format one message and print it, or say plainly that it is missing.
 *
 * Missing is worth printing rather than skipping: a translation that has
 * fallen behind is invisible otherwise, and this is the shape a `--lint` mode
 * would grow out of.
 */
static void say(fluent_bundle *bundle, const char *id, const fluent_args *args)
{
	char *text = fluent_bundle_format(bundle, id, args, NULL);
	if (text == NULL) {
		printf("  %s: <missing>\n", id);
		return;
	}
	printf("  %s\n", text);
	fluent_string_free(text);
}

int main(int argc, char **argv)
{
	/* -- 1. what the user asked for ---------------------------------- */

	/*
	 * An argument overrides the environment, so the example can be tried
	 * without exporting anything. It is read with the same parser the
	 * environment goes through, so `./greeting fr:de` works too.
	 */
	fluent_tag requested[MAX_REQUESTED];
	size_t requested_len =
		argc > 1 ? fluent_locales_from_list(argv[1], requested,
						    MAX_REQUESTED)
			 : fluent_preferred_locales(requested, MAX_REQUESTED);

	/* -- 2. what we have ---------------------------------------------- */

	fluent_bundle *bundles[CATALOG_LEN] = { 0 };
	int status = EXIT_FAILURE;

	for (size_t i = 0; i < CATALOG_LEN; i += 1) {
		bundles[i] = fluent_bundle_new(catalog[i]);
		if (bundles[i] == NULL) {
			fprintf(stderr, "no bundle for %s\n", catalog[i]);
			goto done;
		}

		/*
		 * Off, because this is a terminal. Isolation wraps every
		 * interpolation in U+2068 and U+2069 so that a right-to-left
		 * name dropped into a left-to-right sentence does not drag the
		 * punctuation around it to the wrong end of the line. A browser
		 * honours those marks; a terminal prints them. Leave it on
		 * wherever the text is going into a paragraph a person reads,
		 * which is most places.
		 */
		fluent_bundle_set_use_isolating(bundles[i], false);

		size_t len;
		char *source = read_locale(catalog[i], &len);
		if (source == NULL) goto done;

		/*
		 * A translation that does not parse is a bug in this
		 * repository, not something to paper over at run time -- so
		 * the errors are collected and complained about rather than
		 * passed as NULL.
		 */
		fluent_errors *errors = fluent_errors_new();
		bool added = fluent_bundle_add_resource(bundles[i], source, len,
							errors);
		/* The bundle copied what it needed, so this can go now. */
		free(source);

		for (size_t e = 0; errors != NULL && e < fluent_errors_len(errors);
		     e += 1) {
			char *message = fluent_errors_message(errors, e);
			fprintf(stderr, "%s.ftl: %s\n", catalog[i],
				message == NULL ? "(out of memory)" : message);
			fluent_string_free(message);
			added = false;
		}
		fluent_errors_free(errors);

		if (!added) goto done;
	}

	size_t chosen = negotiate(bundles, requested, requested_len);

	/*
	 * POSIX lets a user set the language apart from the way numbers and
	 * dates are written, and it is an ordinary thing to want: English
	 * messages with a twenty-four hour clock is `LANG=en_US.UTF-8
	 * LC_TIME=en_GB.UTF-8`. Without this, that user is shown "2:03 PM".
	 *
	 * The message language is not touched, so the plural rules stay those
	 * of the language the text is written in.
	 */
	fluent_categories categories;
	fluent_categories_current(&categories);
	fluent_bundle_apply_categories(bundles[chosen], &categories);

	/* -- 3. say it ---------------------------------------------------- */

	printf("requested:");
	if (requested_len == 0)
		printf(" (nothing; the environment is unset or C)");
	for (size_t i = 0; i < requested_len; i += 1)
		printf(" %s", requested[i].text);
	printf("\nshowing:   %s", fluent_bundle_locale(bundles[chosen]));

	/*
	 * Only worth reporting when the user actually asked for a category to
	 * differ. `LANG` alone sets every category to the same thing, and
	 * saying so three times is noise rather than information.
	 */
	if (categories.messages.text[0] != '\0') {
		const char *said = categories.messages.text;
		if (strcmp(categories.numeric.text, said) != 0 &&
		    categories.numeric.text[0] != '\0')
			printf("  (numbers: %s)", categories.numeric.text);
		if (strcmp(categories.monetary.text, said) != 0 &&
		    categories.monetary.text[0] != '\0')
			printf("  (money: %s)", categories.monetary.text);
		if (strcmp(categories.time.text, said) != 0 &&
		    categories.time.text[0] != '\0')
			printf("  (dates: %s)", categories.time.text);
	}
	printf("\n\n");

	fluent_args *args = fluent_args_new();
	if (args == NULL) {
		fprintf(stderr, "out of memory\n");
		goto done;
	}

	say(bundles[chosen], "welcome", NULL);

	static const double counts[] = { 0, 1, 2, 5, 21 };
	for (size_t i = 0; i < sizeof(counts) / sizeof(counts[0]); i += 1) {
		fluent_args_set_number(args, "count", counts[i]);
		say(bundles[chosen], "new-photos", args);
	}

	fluent_args_clear(args);
	fluent_args_set_string(args, "user", "Ada", 3);
	fluent_args_set_number(args, "count", 3);
	fluent_args_set_datetime(args, "when", WHEN);
	say(bundles[chosen], "shared-with-you", args);

	fluent_args_clear(args);
	fluent_args_set_number(args, "used", 12345.678);
	fluent_args_set_number(args, "total", 50000);
	say(bundles[chosen], "storage", args);

	fluent_args_free(args);
	status = EXIT_SUCCESS;

done:
	for (size_t i = 0; i < CATALOG_LEN; i += 1)
		fluent_bundle_free(bundles[i]);
	return status;
}
