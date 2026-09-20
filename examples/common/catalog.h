/* SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us> */
/* SPDX-License-Identifier: MIT */

/*
 * The half of a Fluent application that has nothing to do with the toolkit.
 *
 * `examples/gtk` and `examples/win32` are the same program written against two
 * window systems, and everything they share is here: reading the shipped `.ftl`
 * files off disk, deciding which translation serves the user, formatting a
 * message, and collecting what went wrong. Neither GTK nor Win32 appears below
 * this line, and neither file above it calls `fluent_*` for anything but
 * freeing a string.
 *
 * It is lifted from `examples/c/greeting.c`, which does the same work inline
 * and reads better for being one file. This exists because two GUI examples
 * needed it and a third copy of the negotiation loop would have been a third
 * thing to keep in step.
 */

#ifndef CATALOG_H
#define CATALOG_H

#include <stdbool.h>
#include <stddef.h>

#include <fluent.h>

/*
 * The most locales a user can ask for. `LANGUAGE` is a list, and the rest
 * contribute one each; beyond this many nobody is being served better.
 */
#define CATALOG_MAX_REQUESTED 8

/* The translations shipped with the program, loaded and ready. */
typedef struct catalog catalog;

/*
 * Load every shipped translation from `dir`, which holds one `<tag>.ftl` per
 * entry. NULL on failure, with a complaint on stderr: a translation that does
 * not parse is a bug in this repository rather than something to paper over at
 * run time.
 *
 * `isolating` says whether to keep the Unicode isolation marks the library
 * wraps every interpolation in, U+2068 and U+2069, which stop a right-to-left
 * name dropped into a left-to-right sentence from dragging the punctuation
 * around it to the wrong end of the line.
 *
 * **Whether to keep them is a question about the text renderer, not about the
 * application.** Something that implements the Unicode bidirectional
 * algorithm acts on them and draws nothing: Pango does, and so does CoreText,
 * so the GTK and SwiftUI examples pass true. Something that does not draws
 * them as missing glyphs: a terminal does, and so do Win32's classic controls,
 * which put their text on screen through GDI rather than through DirectWrite
 * -- so `examples/c` and `examples/win32` pass false and a Win32 window shows
 * plain text rather than a row of boxes.
 */
catalog *catalog_open(const char *dir, bool isolating);
void catalog_close(catalog *cat);

/* How many translations were loaded, and what each one is. */
size_t catalog_len(const catalog *cat);

/* The canonical tag of the nth translation, such as "en-US". */
const char *catalog_tag(const catalog *cat, size_t index);

/*
 * The nth translation's name for its own language: "Deutsch", not "German".
 *
 * It comes from the `language-name` message inside the translation itself,
 * which is the only place that knows it. A language menu listing every
 * language in the language the user cannot read yet is a small cruelty and an
 * easy one to avoid.
 */
const char *catalog_endonym(const catalog *cat, size_t index);

/*
 * The translation that best serves the locales the user asked for.
 *
 * This is the part the library deliberately does not do: how much of a
 * mismatch to tolerate, and what to fall back to, is a product decision rather
 * than a fact about locales. What is here is one reasonable answer, and it is
 * the same one `examples/greeting.zig` and `examples/c/greeting.c` give.
 *
 * Each requested locale is tried in turn, and for each one the translations
 * are searched for the closest match: the same tag, then the same language and
 * script, then merely the same language. Asking in that order matters --
 * somebody who asks for `fr` before `en` should get French even though an
 * `en-US` translation exists and is a better match for nothing they said.
 *
 * When nothing matches, the first entry. It is the source locale, its
 * translation is by construction complete, and showing English is a better
 * outcome than showing message names.
 */
size_t catalog_negotiate(const catalog *cat, const fluent_tag *requested,
			 size_t requested_len);

/*
 * The same, for whatever the running system says the user wants -- POSIX'
 * `LANGUAGE`, `LC_ALL`, `LC_MESSAGES` and `LANG`, Windows' preferred UI
 * languages, or macOS' `AppleLanguages`.
 *
 * `list`, when it is not NULL, overrides that with a colon-separated list as
 * `LANGUAGE` is written -- "fr:de" -- so that an example can be tried in a
 * language without exporting anything.
 */
size_t catalog_preferred(const catalog *cat, const char *list);

/*
 * Tell the nth translation how the user wants numbers, money and dates
 * written, which POSIX lets them set apart from the language they read.
 *
 * The message language is not touched, so plural rules stay those of the
 * language the text is written in.
 */
void catalog_apply_system_formats(catalog *cat, size_t index);

/*
 * Format `id` out of the nth translation, or one of its attributes.
 *
 * NULL means there is no such message -- a translation that has fallen behind,
 * which is an ordinary state for one to be in and not an error. The text is
 * the caller's and is freed with `fluent_string_free`.
 *
 * Whatever went wrong is appended to the catalog's error list, which is what
 * `catalog_error_count` reads. Call `catalog_clear_errors` first to tell one
 * screenful of formatting from the next.
 */
char *catalog_format(catalog *cat, size_t index, const char *id,
		     const fluent_args *args);
char *catalog_format_attribute(catalog *cat, size_t index, const char *id,
			       const char *attribute, const fluent_args *args);

void catalog_clear_errors(catalog *cat);
size_t catalog_error_count(const catalog *cat);

/*
 * The nth error as a sentence, such as "unknown variable: $count". Freed with
 * `fluent_string_free`; NULL if the index is out of range or memory ran out.
 */
char *catalog_error_message(const catalog *cat, size_t index);

#endif /* CATALOG_H */
