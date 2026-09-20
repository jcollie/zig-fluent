/* SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us> */
/* SPDX-License-Identifier: MIT */

#include "catalog.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * The translations shipped with the program.
 *
 * The first entry is the source locale and is the last resort, which is why
 * its translation must be complete.
 */
static const char *const shipped[] = { "en-US", "de", "fr", "fi", "pl", "ja" };
#define SHIPPED_LEN (sizeof(shipped) / sizeof(shipped[0]))

struct catalog {
	fluent_bundle *bundles[SHIPPED_LEN];
	/* The name each translation gives its own language, formatted once at
	 * load time because a menu asks for it on every redraw. */
	char *endonyms[SHIPPED_LEN];
	/* One list, cleared by the caller between screenfuls. Held here rather
	 * than made per call so that a window can format a dozen messages and
	 * then ask once what went wrong. */
	fluent_errors *errors;
};

/* -- reading a translation off disk --------------------------------------- */

/*
 * The whole of `dir/<tag>.ftl`, or NULL with a complaint on stderr.
 *
 * `*len` is set to the length in bytes, because that is what the library
 * wants: an `.ftl` file is text and not a C string, and nothing says it may
 * not contain a NUL.
 */
static char *read_locale(const char *dir, const char *tag, size_t *len)
{
	char path[512];
	int written = snprintf(path, sizeof(path), "%s/%s.ftl", dir, tag);
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

/* -- loading -------------------------------------------------------------- */

catalog *catalog_open(const char *dir, bool isolating)
{
	catalog *cat = calloc(1, sizeof(*cat));
	if (cat == NULL) {
		fprintf(stderr, "out of memory\n");
		return NULL;
	}

	cat->errors = fluent_errors_new();
	if (cat->errors == NULL) {
		fprintf(stderr, "out of memory\n");
		goto fail;
	}

	for (size_t i = 0; i < SHIPPED_LEN; i += 1) {
		cat->bundles[i] = fluent_bundle_new(shipped[i]);
		if (cat->bundles[i] == NULL) {
			fprintf(stderr, "no bundle for %s\n", shipped[i]);
			goto fail;
		}

		/* The caller's choice, and it is a question about what will draw
		 * the text rather than about what the text is -- see catalog.h. */
		fluent_bundle_set_use_isolating(cat->bundles[i], isolating);

		size_t len;
		char *source = read_locale(dir, shipped[i], &len);
		if (source == NULL) goto fail;

		fluent_errors *parse_errors = fluent_errors_new();
		bool added = fluent_bundle_add_resource(cat->bundles[i], source,
							len, parse_errors);
		/* The bundle copied what it needed, so this can go now. */
		free(source);

		/*
		 * A translation that does not parse is a bug in this
		 * repository, not something to paper over at run time -- so
		 * these are complained about and fatal, where a *formatting*
		 * error later on is merely shown.
		 */
		for (size_t e = 0;
		     parse_errors != NULL && e < fluent_errors_len(parse_errors);
		     e += 1) {
			char *message = fluent_errors_message(parse_errors, e);
			fprintf(stderr, "%s.ftl: %s\n", shipped[i],
				message == NULL ? "(out of memory)" : message);
			fluent_string_free(message);
			added = false;
		}
		fluent_errors_free(parse_errors);

		if (!added) goto fail;

		/* Formatted now, while nothing can have gone wrong yet, and
		 * kept: a language menu asks for it on every redraw. */
		cat->endonyms[i] = fluent_bundle_format(
			cat->bundles[i], "language-name", NULL, NULL);
	}

	return cat;

fail:
	catalog_close(cat);
	return NULL;
}

void catalog_close(catalog *cat)
{
	if (cat == NULL) return;
	for (size_t i = 0; i < SHIPPED_LEN; i += 1) {
		fluent_string_free(cat->endonyms[i]);
		fluent_bundle_free(cat->bundles[i]);
	}
	fluent_errors_free(cat->errors);
	free(cat);
}

/* -- what we have --------------------------------------------------------- */

size_t catalog_len(const catalog *cat)
{
	(void)cat;
	return SHIPPED_LEN;
}

const char *catalog_tag(const catalog *cat, size_t index)
{
	if (index >= SHIPPED_LEN) return "";
	return fluent_bundle_locale(cat->bundles[index]);
}

const char *catalog_endonym(const catalog *cat, size_t index)
{
	if (index >= SHIPPED_LEN) return "";
	/* A translation that has not got round to `language-name` yet still
	 * belongs in the menu, under the only name we have for it. */
	if (cat->endonyms[index] == NULL)
		return fluent_bundle_locale(cat->bundles[index]);
	return cat->endonyms[index];
}

/* -- negotiation ---------------------------------------------------------- */

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

size_t catalog_negotiate(const catalog *cat, const fluent_tag *requested,
			 size_t requested_len)
{
	for (size_t i = 0; i < requested_len; i += 1)
		for (int pass = 0; pass < 3; pass += 1)
			for (size_t b = 0; b < SHIPPED_LEN; b += 1)
				if (matches(catalog_tag(cat, b),
					    requested[i].text, pass))
					return b;
	return 0;
}

size_t catalog_preferred(const catalog *cat, const char *list)
{
	fluent_tag requested[CATALOG_MAX_REQUESTED];
	size_t len = list != NULL
			     ? fluent_locales_from_list(list, requested,
							CATALOG_MAX_REQUESTED)
			     : fluent_preferred_locales(requested,
							CATALOG_MAX_REQUESTED);
	return catalog_negotiate(cat, requested, len);
}

void catalog_apply_system_formats(catalog *cat, size_t index)
{
	if (index >= SHIPPED_LEN) return;
	fluent_categories categories;
	fluent_categories_current(&categories);
	fluent_bundle_apply_categories(cat->bundles[index], &categories);
}

/* -- saying it ------------------------------------------------------------ */

char *catalog_format(catalog *cat, size_t index, const char *id,
		     const fluent_args *args)
{
	if (index >= SHIPPED_LEN) return NULL;
	return fluent_bundle_format(cat->bundles[index], id, args, cat->errors);
}

char *catalog_format_attribute(catalog *cat, size_t index, const char *id,
			       const char *attribute, const fluent_args *args)
{
	if (index >= SHIPPED_LEN) return NULL;
	return fluent_bundle_format_attribute(cat->bundles[index], id, attribute,
					      args, cat->errors);
}

void catalog_clear_errors(catalog *cat)
{
	fluent_errors_clear(cat->errors);
}

size_t catalog_error_count(const catalog *cat)
{
	return fluent_errors_len(cat->errors);
}

char *catalog_error_message(const catalog *cat, size_t index)
{
	return fluent_errors_message(cat->errors, index);
}
