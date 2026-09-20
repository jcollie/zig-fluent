/* SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us> */
/* SPDX-License-Identifier: MIT */

/*
 * The worked example again, in a window.
 *
 * `examples/c/greeting.c` formats every message once and exits, which is what
 * a command-line program does and is not what an application does. An
 * application holds a tree of widgets whose text has to be regenerated
 * whenever the user changes something -- and the something they change most
 * often, in a program like this one, is the language.
 *
 * So this is the same six translations and the same five messages, with two
 * controls in front of them:
 *
 *   * a language menu, which swaps the bundle every label is formatted from;
 *   * a count, which walks the plural categories live. Choose Polish and step
 *     through 0, 1, 2, 5 and 22: four different forms, and this file passes an
 *     integer and knows about none of them.
 *
 * Everything visible is translated, the window title and the labels on the
 * controls included, because in a real application they are. The button's
 * tooltip comes from the `.tooltip` attribute of the same message its label
 * comes from, which is what attributes are for: one message carrying the
 * several strings a control needs, so that a translation cannot update the
 * label and forget the explanation.
 *
 * There is no GTK below `refresh`, and no Fluent above it except through
 * `catalog.h`. That split is deliberate -- `examples/common/catalog.c` is
 * shared verbatim with `examples/win32`, which is this program written against
 * a different window system.
 *
 *     $ make run
 *     $ make run LOCALE=fi
 *     $ LANG=de_DE.UTF-8 ./greeting
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gtk/gtk.h>

#include "catalog.h"

/* Where `make` put the `.ftl` files. */
#ifndef LOCALE_DIR
#define LOCALE_DIR "../locales"
#endif

/* 2026-02-14T09:30:00Z, fixed so that running this twice says the same thing.
 * A real application would read a clock. */
#define WHEN INT64_C(1771061400000)

/* -- the window ----------------------------------------------------------- */

typedef struct {
	catalog *cat;
	size_t index; /* which translation is on screen */
	bool smoke;   /* driving ourselves for CI rather than a person */
	unsigned step;

	GtkWindow *window;
	GtkWidget *language_label;
	GtkWidget *language_menu;
	GtkWidget *count_label;
	GtkWidget *count_spin;
	GtkWidget *welcome;
	GtkWidget *new_photos;
	GtkWidget *shared;
	GtkWidget *storage;
	GtkWidget *system_button;
	GtkWidget *status;
} app;

/*
 * Put a formatted message into a label, or say plainly that it is missing.
 *
 * Missing is worth showing rather than leaving blank: a translation that has
 * fallen behind is invisible otherwise, and an empty label looks like a layout
 * bug rather than like what it is.
 */
static void set_from(app *self, GtkWidget *label, const char *id,
		     const fluent_args *args)
{
	char *text = catalog_format(self->cat, self->index, id, args);
	gtk_label_set_text(GTK_LABEL(label), text == NULL ? "—" : text);
	if (self->smoke) printf("  %-12s %s\n", id, text == NULL ? "<missing>" : text);
	fluent_string_free(text);
}

/*
 * Regenerate every string on screen from the current translation.
 *
 * One function for the whole window rather than one per control, because
 * nothing here is expensive and because a partial refresh is how half a window
 * ends up in the previous language.
 */
static void refresh(app *self)
{
	catalog_clear_errors(self->cat);

	if (self->smoke)
		printf("%s (%s)\n", catalog_endonym(self->cat, self->index),
		       catalog_tag(self->cat, self->index));

	double count = gtk_spin_button_get_value(
		GTK_SPIN_BUTTON(self->count_spin));

	fluent_args *args = fluent_args_new();
	if (args == NULL) return;

	/* The chrome. */
	char *title = catalog_format(self->cat, self->index, "window-title", NULL);
	if (title != NULL) gtk_window_set_title(self->window, title);
	fluent_string_free(title);

	set_from(self, self->language_label, "language-label", NULL);
	set_from(self, self->count_label, "count-label", NULL);

	/*
	 * A label and its tooltip out of one message and its attribute. The
	 * button is not a `GtkLabel`, so this is the one place the text is
	 * asked for by hand rather than through `set_from`.
	 */
	char *button = catalog_format(self->cat, self->index,
				      "use-system-language", NULL);
	if (button != NULL)
		gtk_button_set_label(GTK_BUTTON(self->system_button), button);
	fluent_string_free(button);

	char *tooltip = catalog_format_attribute(self->cat, self->index,
						 "use-system-language",
						 "tooltip", NULL);
	gtk_widget_set_tooltip_text(self->system_button, tooltip);
	fluent_string_free(tooltip);

	/* The sentences. */
	set_from(self, self->welcome, "welcome", NULL);

	fluent_args_set_number(args, "count", count);
	set_from(self, self->new_photos, "new-photos", args);

	/*
	 * `gender` is here because Polish reads it -- the past tense agrees
	 * with the sharer -- and Finnish does not, and this program cannot
	 * tell which. That is the arrangement: the application hands over what
	 * it knows, and each translation takes what its grammar needs.
	 */
	fluent_args_clear(args);
	fluent_args_set_string(args, "user", "Ada", 3);
	fluent_args_set_string(args, "gender", "female", 6);
	fluent_args_set_number(args, "count", count);
	fluent_args_set_datetime(args, "when", WHEN);
	set_from(self, self->shared, "shared-with-you", args);

	fluent_args_clear(args);
	fluent_args_set_number(args, "used", 12345.678);
	fluent_args_set_number(args, "total", 50000);
	set_from(self, self->storage, "storage", args);

	/*
	 * What the formatting complained about, which in a finished
	 * application would go to a log and is on screen here because seeing
	 * it is the point. None of it stopped anything: a message with a bad
	 * reference still formatted, with the unresolved part printed as
	 * `{$name}` so the sentence around it survived.
	 *
	 * Read before the arguments are freed. An error borrows the name it
	 * names -- from the resource that was parsed, or from the argument
	 * list -- so `fluent_args_free` below must come after this.
	 */
	size_t failures = catalog_error_count(self->cat);
	GString *joined = g_string_new(NULL);
	for (size_t i = 0; i < failures; i += 1) {
		char *message = catalog_error_message(self->cat, i);
		if (i > 0) g_string_append(joined, "\n");
		g_string_append(joined,
				message == NULL ? "(out of memory)" : message);
		fluent_string_free(message);
	}
	if (self->smoke && failures > 0) printf("  errors: %s\n", joined->str);
	gtk_label_set_text(GTK_LABEL(self->status), joined->str);
	g_string_free(joined, TRUE);

	fluent_args_free(args);
}

/* -- the controls --------------------------------------------------------- */

static void on_language_changed(GObject *menu, GParamSpec *pspec, gpointer data)
{
	(void)pspec;
	app *self = data;
	self->index = gtk_drop_down_get_selected(GTK_DROP_DOWN(menu));
	refresh(self);
}

static void on_count_changed(GtkSpinButton *spin, gpointer data)
{
	(void)spin;
	refresh(data);
}

/*
 * Go back to what the system says the user wants.
 *
 * `fluent_preferred_locales` asks whichever platform is running -- POSIX'
 * `LANGUAGE`, `LC_ALL`, `LC_MESSAGES` and `LANG`, Windows' preferred UI
 * languages, or macOS' `AppleLanguages` -- and `catalog_preferred` negotiates
 * that against what was shipped. Setting the menu emits `notify::selected`,
 * which refreshes, so there is nothing else to do here.
 */
static void on_use_system_language(GtkButton *button, gpointer data)
{
	(void)button;
	app *self = data;
	gtk_drop_down_set_selected(GTK_DROP_DOWN(self->language_menu),
				   (guint)catalog_preferred(self->cat, NULL));
}

/* -- driving it without a person ------------------------------------------ */

/*
 * What CI runs: step the count through the interesting numbers, then walk
 * every translation, then quit.
 *
 * It drives the real widgets rather than calling `refresh` directly, so what
 * is exercised is the whole program -- the signal handlers, the menu, the spin
 * button -- and not merely the formatting underneath it.
 */
static gboolean smoke_tick(gpointer data)
{
	static const double counts[] = { 0, 1, 2, 5, 22 };
	const unsigned count_steps = G_N_ELEMENTS(counts);

	app *self = data;
	unsigned step = self->step++;

	if (step < count_steps) {
		gtk_spin_button_set_value(GTK_SPIN_BUTTON(self->count_spin),
					  counts[step]);
		return G_SOURCE_CONTINUE;
	}

	step -= count_steps;
	if (step < catalog_len(self->cat)) {
		gtk_drop_down_set_selected(GTK_DROP_DOWN(self->language_menu),
					   step);
		return G_SOURCE_CONTINUE;
	}

	gtk_window_close(self->window);
	return G_SOURCE_REMOVE;
}

/* -- building the window -------------------------------------------------- */

/*
 * One of the sentences: a label that wraps, at a fixed width.
 *
 * **A wrapping label needs its width pinned**, and this is the whole of why
 * the two calls below are here. A `GtkLabel` with `wrap` set reports the
 * unwrapped sentence as its natural width and then answers "how tall are you?"
 * differently at every width it might be given -- so a window sized from one
 * answer and laid out at another ends up shorter than its own minimum, and GTK
 * says `Trying to measure GtkApplicationWindow ... but it needs at least` once
 * per frame for as long as it is on screen.
 *
 * Setting `width-chars` and `max-width-chars` to the same number takes the
 * width out of the negotiation: the label is that wide, the height follows from
 * the text, and nothing has to be guessed twice. Forty-six characters is what
 * suits the longest of these six translations.
 */
static GtkWidget *sentence(GtkWidget *grid, int row)
{
	GtkWidget *label = gtk_label_new(NULL);
	gtk_widget_set_halign(label, GTK_ALIGN_START);
	gtk_widget_set_valign(label, GTK_ALIGN_START);
	gtk_label_set_wrap(GTK_LABEL(label), TRUE);
	gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
	gtk_label_set_yalign(GTK_LABEL(label), 0.0f);
	gtk_label_set_width_chars(GTK_LABEL(label), 46);
	gtk_label_set_max_width_chars(GTK_LABEL(label), 46);
	gtk_grid_attach(GTK_GRID(grid), label, 0, row, 2, 1);
	return label;
}

static void on_activate(GtkApplication *gtk_app, gpointer data)
{
	app *self = data;

	GtkWidget *window = gtk_application_window_new(gtk_app);
	self->window = GTK_WINDOW(window);
	/*
	 * Fixed, like the other two examples: the Win32 one lays its controls
	 * out at fixed coordinates and the SwiftUI one asks for
	 * `.windowResizability(.contentSize)`. There is nothing here that
	 * benefits from being dragged larger, and the labels have a width of
	 * their own, so the window has only to be as tall as whichever
	 * translation is showing.
	 */
	gtk_window_set_resizable(self->window, FALSE);

	GtkWidget *grid = gtk_grid_new();
	gtk_grid_set_row_spacing(GTK_GRID(grid), 8);
	gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
	gtk_widget_set_margin_top(grid, 16);
	gtk_widget_set_margin_bottom(grid, 16);
	gtk_widget_set_margin_start(grid, 16);
	gtk_widget_set_margin_end(grid, 16);
	gtk_window_set_child(self->window, grid);

	/*
	 * Every entry under its own name, read out of the translation itself.
	 * `gtk_drop_down_new_from_strings` wants a NULL-terminated array and
	 * copies it, so this one can live on the stack.
	 */
	size_t len = catalog_len(self->cat);
	const char *names[16];
	for (size_t i = 0; i < len && i + 1 < G_N_ELEMENTS(names); i += 1)
		names[i] = catalog_endonym(self->cat, i);
	names[len] = NULL;

	self->language_label = gtk_label_new(NULL);
	gtk_widget_set_halign(self->language_label, GTK_ALIGN_START);
	gtk_grid_attach(GTK_GRID(grid), self->language_label, 0, 0, 1, 1);

	self->language_menu = gtk_drop_down_new_from_strings(names);
	gtk_drop_down_set_selected(GTK_DROP_DOWN(self->language_menu),
				   (guint)self->index);
	gtk_widget_set_hexpand(self->language_menu, TRUE);
	gtk_grid_attach(GTK_GRID(grid), self->language_menu, 1, 0, 1, 1);

	self->count_label = gtk_label_new(NULL);
	gtk_widget_set_halign(self->count_label, GTK_ALIGN_START);
	gtk_grid_attach(GTK_GRID(grid), self->count_label, 0, 1, 1, 1);

	self->count_spin = gtk_spin_button_new_with_range(0, 999, 1);
	gtk_spin_button_set_value(GTK_SPIN_BUTTON(self->count_spin), 1);
	gtk_grid_attach(GTK_GRID(grid), self->count_spin, 1, 1, 1, 1);

	gtk_grid_attach(GTK_GRID(grid),
			gtk_separator_new(GTK_ORIENTATION_HORIZONTAL),
			0, 2, 2, 1);

	self->welcome = sentence(grid, 3);
	self->new_photos = sentence(grid, 4);
	/* The one that wraps: Polish and German both run to three lines at a
	 * large count, and Japanese to one. */
	self->shared = sentence(grid, 5);
	self->storage = sentence(grid, 6);

	self->system_button = gtk_button_new();
	gtk_widget_set_halign(self->system_button, GTK_ALIGN_START);
	gtk_grid_attach(GTK_GRID(grid), self->system_button, 0, 7, 2, 1);

	/* Always present, empty when there is nothing to say, so that an error
	 * appearing does not move everything above it. */
	self->status = sentence(grid, 8);
	gtk_widget_add_css_class(self->status, "dim-label");

	g_signal_connect(self->language_menu, "notify::selected",
			 G_CALLBACK(on_language_changed), self);
	g_signal_connect(self->count_spin, "value-changed",
			 G_CALLBACK(on_count_changed), self);
	g_signal_connect(self->system_button, "clicked",
			 G_CALLBACK(on_use_system_language), self);

	refresh(self);
	gtk_window_present(self->window);

	if (self->smoke) g_timeout_add(120, smoke_tick, self);
}

int main(int argc, char **argv)
{
	bool smoke = false;
	const char *requested = NULL;
	for (int i = 1; i < argc; i += 1) {
		if (strcmp(argv[i], "--smoke") == 0)
			smoke = true;
		else
			requested = argv[i];
	}

	app self = { 0 };
	self.smoke = smoke;

	/* Isolation on: Pango implements the bidirectional algorithm, so it
	 * acts on U+2068 and U+2069 and draws neither of them. */
	self.cat = catalog_open(LOCALE_DIR, true);
	if (self.cat == NULL) return EXIT_FAILURE;

	/*
	 * An argument overrides the environment, so the example can be tried
	 * in a language without exporting anything. It is read with the same
	 * parser the environment goes through, so `./greeting fr:de` works.
	 */
	self.index = catalog_preferred(self.cat, requested);

	/*
	 * POSIX lets a user set the way numbers and dates are written apart
	 * from the language they read, and it is an ordinary thing to want:
	 * English messages with a twenty-four hour clock is `LANG=en_US.UTF-8
	 * LC_TIME=en_GB.UTF-8`.
	 *
	 * Only the translation the system asked for, though, and not the
	 * others. Those settings say how *this user's own* locale should be
	 * written; a language they pick out of a menu afterwards should be
	 * written the way that language is written, and forcing en-US
	 * thousands separators onto the German and Japanese text would be a
	 * bug rather than a preference honoured.
	 */
	catalog_apply_system_formats(self.cat, self.index);

	GtkApplication *gtk_app = gtk_application_new(
		"dev.jcollie.fluent.Greeting", G_APPLICATION_DEFAULT_FLAGS);
	g_signal_connect(gtk_app, "activate", G_CALLBACK(on_activate), &self);

	/*
	 * Our own arguments are not GTK's, and `--smoke` is not an option it
	 * knows, so it is given the program name alone.
	 */
	int status = g_application_run(G_APPLICATION(gtk_app), 1, argv);

	g_object_unref(gtk_app);
	catalog_close(self.cat);
	return status;
}
