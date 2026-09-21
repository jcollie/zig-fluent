/* SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us> */
/* SPDX-License-Identifier: MIT */

/*
 * The same window as `examples/gtk`, with the window itself moved out of C.
 *
 * `examples/gtk/greeting.c` builds its widget tree by calling GTK: forty-odd
 * lines of `gtk_label_new`, `gtk_grid_attach` and `gtk_widget_set_halign`.
 * That is one way and a perfectly good one. The other way -- the one a GNOME
 * application is written in -- is to declare the tree, and that is what this
 * example does: `greeting.blp` says which widgets exist, what they are called
 * and where they sit, blueprint-compiler turns it into GtkBuilder XML,
 * `glib-compile-resources` turns that into bytes inside the binary, and this
 * file is left with the half that is actually about Fluent.
 *
 * **The interesting part is what the markup does not contain.** A GtkBuilder
 * file normally carries the application's text, marked for translation:
 *
 *     <property name="label" translatable="yes">Welcome</property>
 *
 * which hands the whole user interface to gettext, and so to one string per
 * control and to translations that can do no more than substitute. This
 * template declares every label with no text at all. The text arrives at run
 * time, from a Fluent bundle, which is what lets a translator write plural
 * categories their language has and English does not, decline a product name
 * that is stored once as a term, and keep a button's label and its tooltip
 * together in one message.
 *
 * So the division of labour is: the markup owns structure, `refresh` owns
 * text, and the two meet at the widget names that
 * `gtk_widget_class_bind_template_child` turns into fields of the struct
 * below.
 *
 * Everything else -- the five messages, the six translations, the language
 * menu, the count that walks the plural categories -- is as it is in
 * `examples/gtk`, and `examples/common/catalog.c` is shared verbatim with
 * both that and `examples/win32`.
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

/* Written by `glib-compile-resources --generate-header`; it declares the one
 * function that hands the compiled-in `greeting.ui` to GIO. */
#include "greeting-resources.h"

/* Where `make` put the `.ftl` files. */
#ifndef LOCALE_DIR
#define LOCALE_DIR "../locales"
#endif

/* 2026-02-14T09:30:00Z, fixed so that running this twice says the same thing.
 * A real application would read a clock. */
#define WHEN INT64_C(1771061400000)

/* -- the window ----------------------------------------------------------- */

/*
 * A GObject subclass, which is what a template needs.
 *
 * `examples/gtk` keeps its state in a plain struct and passes a pointer to it
 * as every signal's user data. That cannot be done here, because the signals
 * are connected by GtkBuilder rather than by us -- and what GtkBuilder passes
 * a template's handlers is the template instance itself. Making the window a
 * type of its own is therefore not ceremony for its own sake: it is what
 * gives the handlers something to be handed, and it puts the state in the
 * object whose state it is.
 *
 * `G_DECLARE_FINAL_TYPE` writes the boilerplate -- the typedef, the cast
 * macros, the `_get_type` declaration -- and leaves the instance struct to be
 * defined, which is the next thing below.
 */
#define GREETING_TYPE_WINDOW (greeting_window_get_type())
G_DECLARE_FINAL_TYPE(GreetingWindow, greeting_window, GREETING, WINDOW,
		     GtkApplicationWindow)

struct _GreetingWindow {
	GtkApplicationWindow parent_instance;

	/*
	 * One field per named widget in `greeting.blp`, and the names must
	 * match: `gtk_widget_class_bind_template_child` looks the object up by
	 * the field's own name and writes it here when the window is built. A
	 * name in one file and not the other is a warning at that moment,
	 * rather than a crash the first time the field is read.
	 */
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

	/* And the half that is ours. */
	catalog *cat;
	size_t index; /* which translation is on screen */
	bool smoke;   /* driving ourselves for CI rather than a person */
	unsigned step;
};

G_DEFINE_FINAL_TYPE(GreetingWindow, greeting_window, GTK_TYPE_APPLICATION_WINDOW)

/*
 * Put a formatted message into a label, or say plainly that it is missing.
 *
 * Missing is worth showing rather than leaving blank: a translation that has
 * fallen behind is invisible otherwise, and an empty label looks like a layout
 * bug rather than like what it is.
 */
static void set_from(GreetingWindow *self, GtkWidget *label, const char *id,
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
static void refresh(GreetingWindow *self)
{
	/*
	 * Nothing to format yet. A template's signals are connected before
	 * anything this program owns has been handed to the window, so the
	 * handlers fire while it is still being filled in --
	 * `greeting_window_new` says which ones and why it arranges things
	 * that way. This is the one cost of letting GtkBuilder do the
	 * connecting, and one line is what it comes to.
	 */
	if (self->cat == NULL) return;

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
	if (title != NULL) gtk_window_set_title(GTK_WINDOW(self), title);
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

/*
 * Named in `greeting.blp` and bound below, rather than connected by hand.
 *
 * Each is reached through `gtk_widget_class_bind_template_callback`, which is
 * why they have to exist before `greeting_window_class_init` and why their
 * names are part of this program's interface with its own markup.
 */
static void on_language_changed(GObject *menu, GParamSpec *pspec,
				GreetingWindow *self)
{
	(void)pspec;
	self->index = gtk_drop_down_get_selected(GTK_DROP_DOWN(menu));
	refresh(self);
}

static void on_count_changed(GtkSpinButton *spin, GreetingWindow *self)
{
	(void)spin;
	refresh(self);
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
static void on_use_system_language(GtkButton *button, GreetingWindow *self)
{
	(void)button;
	gtk_drop_down_set_selected(GTK_DROP_DOWN(self->language_menu),
				   (guint)catalog_preferred(self->cat, NULL));
}

/* -- driving it without a person ------------------------------------------ */

/*
 * What CI runs: step the count through the interesting numbers, then walk
 * every translation, then quit.
 *
 * It drives the real widgets rather than calling `refresh` directly, so what
 * is exercised is the whole program -- the template, the handlers GtkBuilder
 * connected, the menu, the spin button -- and not merely the formatting
 * underneath it.
 */
static gboolean smoke_tick(gpointer data)
{
	static const double counts[] = { 0, 1, 2, 5, 22 };
	const unsigned count_steps = G_N_ELEMENTS(counts);

	GreetingWindow *self = data;
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

	/*
	 * The line whoever ran this looks for. An exit status is not enough on
	 * its own: a program that drew nothing, or drew boxes, or stopped
	 * after the first language, exits zero just as happily as one that
	 * worked. Something only the end of the script can print, printed only
	 * once it is reached, is what cannot be faked by not running.
	 */
	printf("smoke complete: %zu translations\n", catalog_len(self->cat));
	fflush(stdout);

	gtk_window_close(GTK_WINDOW(self));
	return G_SOURCE_REMOVE;
}

/* -- the type ------------------------------------------------------------- */

/*
 * Where the markup is attached to the code, and the whole of what this file
 * has to say about the window's shape.
 *
 * `set_template_from_resource` names the path the `.ui` was compiled in
 * under; `bind_template_child` pairs each named widget with the field of the
 * same name; `bind_template_callback` makes each handler findable by the name
 * the markup calls it. Everything else about the layout is in
 * `greeting.blp`.
 */
static void greeting_window_class_init(GreetingWindowClass *klass)
{
	GtkWidgetClass *widget_class = GTK_WIDGET_CLASS(klass);

	gtk_widget_class_set_template_from_resource(
		widget_class, "/dev/jcollie/fluent/Greeting/greeting.ui");

	gtk_widget_class_bind_template_child(widget_class, GreetingWindow,
					     language_label);
	gtk_widget_class_bind_template_child(widget_class, GreetingWindow,
					     language_menu);
	gtk_widget_class_bind_template_child(widget_class, GreetingWindow,
					     count_label);
	gtk_widget_class_bind_template_child(widget_class, GreetingWindow,
					     count_spin);
	gtk_widget_class_bind_template_child(widget_class, GreetingWindow,
					     welcome);
	gtk_widget_class_bind_template_child(widget_class, GreetingWindow,
					     new_photos);
	gtk_widget_class_bind_template_child(widget_class, GreetingWindow,
					     shared);
	gtk_widget_class_bind_template_child(widget_class, GreetingWindow,
					     storage);
	gtk_widget_class_bind_template_child(widget_class, GreetingWindow,
					     system_button);
	gtk_widget_class_bind_template_child(widget_class, GreetingWindow,
					     status);

	gtk_widget_class_bind_template_callback(widget_class,
						on_language_changed);
	gtk_widget_class_bind_template_callback(widget_class, on_count_changed);
	gtk_widget_class_bind_template_callback(widget_class,
						on_use_system_language);
}

static void greeting_window_init(GreetingWindow *self)
{
	gtk_widget_init_template(GTK_WIDGET(self));
}

/*
 * Build the window and give it its translations.
 *
 * **The catalog is attached last, and deliberately.** The template's signals
 * are connected the moment `g_object_new` returns, so filling the language
 * menu below emits `notify::selected` -- twice, once when the model arrives
 * and GTK selects its first row, and again if the translation being shown is
 * not that row. Handing the catalog over afterwards means those two go
 * through the guard at the top of `refresh` and do nothing, and the window is
 * formatted exactly once, by the call at the end of this function.
 *
 * The alternative -- setting the catalog first and letting the menu's own
 * signals do the first refresh -- works, and formats every message two or
 * three times on the way up. That is invisible here and would not be in an
 * application whose strings come from somewhere slower.
 */
static GreetingWindow *greeting_window_new(GtkApplication *gtk_app,
					   catalog *cat, size_t index,
					   bool smoke)
{
	GreetingWindow *self = g_object_new(GREETING_TYPE_WINDOW,
					    "application", gtk_app, NULL);

	/*
	 * The language menu's entries: each translation's name for its own
	 * language, read out of the translation itself. A menu listing every
	 * language in the language the user cannot read yet is a small cruelty
	 * and an easy one to avoid.
	 *
	 * This is the one piece of the window that could not be declared in
	 * `greeting.blp`, because the list is not known until the `.ftl` files
	 * have been read. `gtk_string_list_new` wants a NULL-terminated array
	 * and copies it, so this one can live on the stack.
	 */
	size_t len = catalog_len(cat);
	const char *names[16];
	for (size_t i = 0; i < len && i + 1 < G_N_ELEMENTS(names); i += 1)
		names[i] = catalog_endonym(cat, i);
	names[len] = NULL;

	gtk_drop_down_set_model(GTK_DROP_DOWN(self->language_menu),
				G_LIST_MODEL(gtk_string_list_new(names)));
	gtk_drop_down_set_selected(GTK_DROP_DOWN(self->language_menu),
				   (guint)index);

	self->cat = cat;
	self->index = index;
	self->smoke = smoke;

	refresh(self);
	return self;
}

/* -- starting up ---------------------------------------------------------- */

typedef struct {
	catalog *cat;
	size_t index;
	bool smoke;
} startup;

static void on_activate(GtkApplication *gtk_app, gpointer data)
{
	startup *from = data;
	GreetingWindow *window = greeting_window_new(gtk_app, from->cat,
						     from->index, from->smoke);

	gtk_window_present(GTK_WINDOW(window));

	if (from->smoke) g_timeout_add(120, smoke_tick, window);
}

int main(int argc, char **argv)
{
	startup from = { 0 };
	const char *requested = NULL;
	for (int i = 1; i < argc; i += 1) {
		if (strcmp(argv[i], "--smoke") == 0)
			from.smoke = true;
		else
			requested = argv[i];
	}

	/*
	 * The compiled-in `greeting.ui`, handed to GIO before any window is
	 * built -- `set_template_from_resource` resolves the path at the
	 * moment the class is initialised, and a resource registered after
	 * that is too late.
	 *
	 * `glib-compile-resources` can emit a constructor that does this on
	 * its own; `--manual-register` in the Makefile turns that off, so that
	 * the registration is a line somebody reading this file can see.
	 */
	greeting_resources_register_resource();

	/* Isolation on: Pango implements the bidirectional algorithm, so it
	 * acts on U+2068 and U+2069 and draws neither of them. */
	from.cat = catalog_open(LOCALE_DIR, true);
	if (from.cat == NULL) return EXIT_FAILURE;

	/*
	 * An argument overrides the environment, so the example can be tried
	 * in a language without exporting anything. It is read with the same
	 * parser the environment goes through, so `./greeting fr:de` works.
	 */
	from.index = catalog_preferred(from.cat, requested);

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
	catalog_apply_system_formats(from.cat, from.index);

	GtkApplication *gtk_app = gtk_application_new(
		"dev.jcollie.fluent.Greeting", G_APPLICATION_DEFAULT_FLAGS);
	g_signal_connect(gtk_app, "activate", G_CALLBACK(on_activate), &from);

	/*
	 * Our own arguments are not GTK's, and `--smoke` is not an option it
	 * knows, so it is given the program name alone.
	 */
	int status = g_application_run(G_APPLICATION(gtk_app), 1, argv);

	g_object_unref(gtk_app);
	catalog_close(from.cat);
	return status;
}
