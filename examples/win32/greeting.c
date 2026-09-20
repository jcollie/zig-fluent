/* SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us> */
/* SPDX-License-Identifier: MIT */

/*
 * The worked example again, in a Win32 window.
 *
 * This is `examples/gtk/greeting.c` written against a different window system.
 * The same six translations, the same five messages, the same two controls --
 * a language menu that swaps the bundle every label is formatted from, and a
 * count that walks the plural categories live -- and the same
 * `examples/common/catalog.c` underneath, shared between the two verbatim.
 * What differs is everything above that line, which is the point of having
 * both.
 *
 * Two things are Windows' alone and are the reason this file is worth reading:
 *
 *  1. **UTF-8 meets UTF-16.** Everything the library returns is UTF-8, because
 *     that is what an `.ftl` file is and what C libraries speak. Every `W`
 *     entry point here wants UTF-16. So a string crosses `widen` on its way to
 *     a control, and `widen` measures its input with `fluent_string_len`
 *     rather than `wcslen`'s cousin, because a translation is entitled to
 *     contain a NUL and `strlen` would stop early. That is the whole reason
 *     the header offers that function.
 *
 *  2. **The user's language does not come from the environment.** A program
 *     started from Explorer has no `LANG`. `fluent_preferred_locales` asks
 *     `GetUserPreferredUILanguages` instead, and the "use system language"
 *     button is that call with a window in front of it.
 *
 *     $ build.bat
 *     $ greeting.exe
 *     $ greeting.exe fi
 */

/*
 * `UNICODE` before <windows.h> is not decoration. Without it the generic
 * macros resolve to their ANSI halves, so `IDC_ARROW` becomes a `char *` that
 * `LoadCursorW` will not take -- and where a call is generic rather than
 * explicitly `W`, it is the byte-oriented one that gets compiled, quietly, on
 * a program whose every string is UTF-16.
 *
 * `0x0A00` is Windows 10, which is what `GetDpiForSystem` and
 * `SystemParametersInfoForDpi` want to be declared. Guarded because a
 * toolchain may have set them on the command line already.
 */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WINVER
#define WINVER 0x0A00
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <commctrl.h>

#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "catalog.h"

/* Where `build.bat` put the `.ftl` files. */
#ifndef LOCALE_DIR
#define LOCALE_DIR "../locales"
#endif

/* 2026-02-14T09:30:00Z, fixed so that running this twice says the same thing.
 * A real application would read a clock. */
#define WHEN INT64_C(1771061400000)

#define ID_LANGUAGE 1001
#define ID_COUNT 1002
#define ID_UPDOWN 1003
#define ID_SYSTEM 1004
#define ID_SMOKE_TIMER 1

typedef struct {
	catalog *cat;
	size_t index; /* which translation is on screen */
	int count;    /* what the up-down last settled on */
	bool smoke;   /* driving ourselves for CI rather than a person */
	unsigned step;

	int dpi;
	HFONT font;

	HWND window;
	HWND language_label;
	HWND language_menu;
	HWND count_label;
	HWND count_edit;
	HWND count_updown;
	HWND welcome;
	HWND new_photos;
	HWND shared;
	HWND storage;
	HWND system_button;
	HWND tooltip;
	HWND status;
} app;

/* -- UTF-8 meets UTF-16 --------------------------------------------------- */

/*
 * A UTF-8 string of `len` bytes as a freshly allocated, NUL-terminated UTF-16
 * one. NULL if it does not convert or memory ran out.
 *
 * Twice through `MultiByteToWideChar`, which is the shape every use of it
 * takes: once with a NULL destination to be told how much room is wanted, once
 * to fill it. The length is passed explicitly rather than as -1, so that what
 * is converted is exactly the bytes asked for -- with -1 the terminating NUL
 * would be counted and copied, and a string with a NUL inside it would be cut
 * short at it.
 */
static WCHAR *widen(const char *utf8, size_t len)
{
	if (utf8 == NULL) return NULL;
	if (len > (size_t)INT_MAX) return NULL;

	int wanted = MultiByteToWideChar(CP_UTF8, 0, utf8, (int)len, NULL, 0);
	if (wanted < 0) return NULL;

	WCHAR *wide = malloc(((size_t)wanted + 1) * sizeof(WCHAR));
	if (wide == NULL) return NULL;

	if (wanted > 0 &&
	    MultiByteToWideChar(CP_UTF8, 0, utf8, (int)len, wide, wanted) == 0) {
		free(wide);
		return NULL;
	}
	wide[wanted] = L'\0';
	return wide;
}

/* The other direction, for the one argument this program takes. */
static char *narrow(const WCHAR *wide)
{
	int wanted = WideCharToMultiByte(CP_UTF8, 0, wide, -1, NULL, 0, NULL,
					 NULL);
	if (wanted <= 0) return NULL;

	char *utf8 = malloc((size_t)wanted);
	if (utf8 == NULL) return NULL;

	if (WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8, wanted, NULL,
				NULL) == 0) {
		free(utf8);
		return NULL;
	}
	return utf8;
}

/*
 * Put a string the library returned into a control, and free it.
 *
 * `text` is owned by us and is freed here however the conversion goes, which
 * is what makes every call site below a single line with no cleanup in it.
 */
static void set_text(HWND control, char *text)
{
	if (text == NULL) {
		/* A translation that has fallen behind. Worth showing rather
		 * than leaving blank, where an empty control would look like a
		 * layout bug instead of like what it is. */
		SetWindowTextW(control, L"\x2014");
		return;
	}

	WCHAR *wide = widen(text, fluent_string_len(text));
	SetWindowTextW(control, wide == NULL ? L"" : wide);
	free(wide);
	fluent_string_free(text);
}

/* -- the window ----------------------------------------------------------- */

static void say(app *self, HWND control, const char *id, const fluent_args *args)
{
	char *text = catalog_format(self->cat, self->index, id, args);
	if (self->smoke)
		printf("  %-12s %s\n", id, text == NULL ? "<missing>" : text);
	set_text(control, text);
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

	double count = (double)self->count;

	fluent_args *args = fluent_args_new();
	if (args == NULL) return;

	/* The chrome. */
	say(self, self->window, "window-title", NULL);
	say(self, self->language_label, "language-label", NULL);
	say(self, self->count_label, "count-label", NULL);

	/*
	 * A label and its tooltip out of one message and its attribute --
	 * which is what attributes are for: the several strings a control
	 * needs kept together, so that a translation cannot update the label
	 * and forget the explanation.
	 */
	say(self, self->system_button, "use-system-language", NULL);

	char *tip = catalog_format_attribute(self->cat, self->index,
					     "use-system-language", "tooltip",
					     NULL);
	WCHAR *wide_tip = tip == NULL ? NULL : widen(tip, fluent_string_len(tip));
	fluent_string_free(tip);
	if (wide_tip != NULL) {
		TTTOOLINFOW info = { 0 };
		info.cbSize = sizeof(info);
		info.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
		info.hwnd = self->window;
		info.uId = (UINT_PTR)self->system_button;
		info.lpszText = wide_tip;
		SendMessageW(self->tooltip, TTM_UPDATETIPTEXTW, 0,
			     (LPARAM)&info);
		free(wide_tip);
	}

	/* The sentences. */
	say(self, self->welcome, "welcome", NULL);

	fluent_args_set_number(args, "count", count);
	say(self, self->new_photos, "new-photos", args);

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
	say(self, self->shared, "shared-with-you", args);

	fluent_args_clear(args);
	fluent_args_set_number(args, "used", 12345.678);
	fluent_args_set_number(args, "total", 50000);
	say(self, self->storage, "storage", args);

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
	if (failures == 0) {
		SetWindowTextW(self->status, L"");
	} else {
		char *first = catalog_error_message(self->cat, 0);
		if (self->smoke)
			printf("  errors: %zu, first: %s\n", failures,
			       first == NULL ? "(out of memory)" : first);
		set_text(self->status, first);
	}

	fluent_args_free(args);
}

/* -- driving it without a person ------------------------------------------ */

/*
 * What CI runs: step the count through the interesting numbers, then walk
 * every translation, then quit.
 *
 * It drives the real controls rather than calling `refresh` directly, so what
 * is exercised is the whole program -- the window procedure, the notifications
 * the controls send -- and not merely the formatting underneath it.
 */
static void smoke_tick(app *self)
{
	static const int counts[] = { 0, 1, 2, 5, 22 };
	const unsigned count_steps = ARRAYSIZE(counts);

	unsigned step = self->step++;

	if (step < count_steps) {
		/* No refresh here: moving the up-down rewrites its buddy edit,
		 * which sends `EN_CHANGE`, which is what a person typing would
		 * have sent. Driving the controls rather than the model is the
		 * whole point of doing it this way. */
		SendMessageW(self->count_updown, UDM_SETPOS32, 0,
			     counts[step]);
		return;
	}

	step -= count_steps;
	if (step < catalog_len(self->cat)) {
		/* A combo box, on the other hand, deliberately does *not*
		 * notify when the selection is set programmatically -- only a
		 * person choosing sends `CBN_SELCHANGE` -- so this one has to
		 * do by hand what the handler would have done. */
		SendMessageW(self->language_menu, CB_SETCURSEL, step, 0);
		self->index = step;
		refresh(self);
		return;
	}

	KillTimer(self->window, ID_SMOKE_TIMER);

	/*
	 * The line whoever ran this looks for. An exit status is not enough on
	 * its own: a window program that fails to start -- a manifest the
	 * loader will not have, a DLL that is not there -- is reported by the
	 * loader rather than by us, and `start /wait` does not always carry
	 * that back. Something only the script itself can print, printed only
	 * at the end of it, is the thing that cannot be faked by not running.
	 */
	printf("smoke complete: %zu translations\n", catalog_len(self->cat));
	fflush(stdout);

	PostMessageW(self->window, WM_CLOSE, 0, 0);
}

/* -- building the window -------------------------------------------------- */

/* Laid out in the 96-dpi units everything below is written in. */
static int scaled(const app *self, int units)
{
	return MulDiv(units, self->dpi, USER_DEFAULT_SCREEN_DPI);
}

static HWND child(app *self, const WCHAR *class_name, DWORD style, int x, int y,
		  int w, int h, int id)
{
	HWND control = CreateWindowExW(0, class_name, NULL,
				       WS_CHILD | WS_VISIBLE | style,
				       scaled(self, x), scaled(self, y),
				       scaled(self, w), scaled(self, h),
				       self->window, (HMENU)(UINT_PTR)id,
				       NULL, NULL);
	if (control != NULL)
		SendMessageW(control, WM_SETFONT, (WPARAM)self->font, TRUE);
	return control;
}

/*
 * The font the rest of Windows is written in.
 *
 * `DEFAULT_GUI_FONT` is a stock object and is the wrong answer: it is a
 * bitmap font from 1995 that no other window uses. The message font out of
 * the non-client metrics is what a dialog would be drawn with.
 */
static HFONT ui_font(int dpi)
{
	NONCLIENTMETRICSW metrics;
	metrics.cbSize = sizeof(metrics);
	if (!SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS,
					sizeof(metrics), &metrics, 0,
					(UINT)dpi))
		return (HFONT)GetStockObject(DEFAULT_GUI_FONT);
	return CreateFontIndirectW(&metrics.lfMessageFont);
}

static void create_children(app *self)
{
	self->font = ui_font(self->dpi);

	self->language_label = child(self, L"STATIC", SS_LEFT, 12, 15, 96, 20,
				     0);

	/*
	 * `CBS_DROPDOWNLIST` rather than `CBS_DROPDOWN`: a language menu is a
	 * choice among what was shipped, not a text field with suggestions.
	 * The height given to a combo box is the height of the dropped list,
	 * not of the closed control.
	 */
	self->language_menu = child(self, L"COMBOBOX",
				    CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP,
				    112, 12, 232, 240, ID_LANGUAGE);

	/*
	 * Every entry under its own name, read out of the translation itself,
	 * so that nobody has to recognize their language written in one they
	 * cannot read yet.
	 */
	for (size_t i = 0; i < catalog_len(self->cat); i += 1) {
		const char *name = catalog_endonym(self->cat, i);
		WCHAR *wide = widen(name, strlen(name));
		if (wide == NULL) continue;
		SendMessageW(self->language_menu, CB_ADDSTRING, 0,
			     (LPARAM)wide);
		free(wide);
	}
	SendMessageW(self->language_menu, CB_SETCURSEL, (WPARAM)self->index, 0);

	self->count_label = child(self, L"STATIC", SS_LEFT, 12, 49, 96, 20, 0);
	self->count_edit = child(self, L"EDIT",
				 ES_NUMBER | ES_RIGHT | WS_BORDER | WS_TABSTOP,
				 112, 46, 72, 22, ID_COUNT);

	/*
	 * An up-down with a buddy edit is Win32's spin button. `UDS_SETBUDDYINT`
	 * makes the up-down write the number into the edit, and
	 * `UDS_ALIGNRIGHT` parks it inside the edit's right-hand side, which is
	 * why the edit is created first and no position is given here.
	 */
	self->count_updown = CreateWindowExW(
		0, UPDOWN_CLASSW, NULL,
		WS_CHILD | WS_VISIBLE | UDS_SETBUDDYINT | UDS_ALIGNRIGHT |
			UDS_ARROWKEYS | UDS_NOTHOUSANDS,
		0, 0, 0, 0, self->window, (HMENU)(UINT_PTR)ID_UPDOWN, NULL,
		NULL);
	SendMessageW(self->count_updown, UDM_SETBUDDY,
		     (WPARAM)self->count_edit, 0);
	SendMessageW(self->count_updown, UDM_SETRANGE32, 0, 999);
	/* Before the control is told, not after: setting the position writes
	 * the buddy edit, which sends `EN_CHANGE` straight back here, and a
	 * handler that found `count` still zero would redraw a window that has
	 * not been built yet. */
	self->count = 1;
	SendMessageW(self->count_updown, UDM_SETPOS32, 0, 1);

	child(self, L"STATIC", SS_ETCHEDHORZ, 12, 80, 332, 2, 0);

	self->welcome = child(self, L"STATIC", SS_LEFT, 12, 92, 332, 20, 0);
	self->new_photos = child(self, L"STATIC", SS_LEFT, 12, 116, 332, 20, 0);
	self->shared = child(self, L"STATIC", SS_LEFT, 12, 140, 332, 40, 0);
	self->storage = child(self, L"STATIC", SS_LEFT, 12, 184, 332, 20, 0);

	self->system_button = child(self, L"BUTTON", BS_PUSHBUTTON | WS_TABSTOP,
				    12, 212, 232, 26, ID_SYSTEM);

	self->status = child(self, L"STATIC", SS_LEFT, 12, 246, 332, 36, 0);

	/*
	 * A tooltip is a window of its own rather than a property of the
	 * control it describes, and `TTF_SUBCLASS` is what makes it appear
	 * without the parent having to forward mouse messages to it.
	 */
	self->tooltip = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, NULL,
					WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX,
					CW_USEDEFAULT, CW_USEDEFAULT,
					CW_USEDEFAULT, CW_USEDEFAULT,
					self->window, NULL, NULL, NULL);
	TTTOOLINFOW info = { 0 };
	info.cbSize = sizeof(info);
	info.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
	info.hwnd = self->window;
	info.uId = (UINT_PTR)self->system_button;
	info.lpszText = L"";
	SendMessageW(self->tooltip, TTM_ADDTOOLW, 0, (LPARAM)&info);
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam,
				    LPARAM lparam)
{
	app *self = (app *)GetWindowLongPtrW(window, GWLP_USERDATA);

	switch (message) {
	case WM_CREATE: {
		CREATESTRUCTW *created = (CREATESTRUCTW *)lparam;
		self = created->lpCreateParams;
		self->window = window;
		SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)self);
		create_children(self);
		refresh(self);
		if (self->smoke)
			SetTimer(window, ID_SMOKE_TIMER, 120, NULL);
		return 0;
	}

	case WM_COMMAND:
		if (self == NULL) break;
		switch (LOWORD(wparam)) {
		case ID_LANGUAGE:
			if (HIWORD(wparam) == CBN_SELCHANGE) {
				LRESULT chosen = SendMessageW(
					self->language_menu, CB_GETCURSEL, 0, 0);
				if (chosen != CB_ERR) {
					self->index = (size_t)chosen;
					refresh(self);
				}
			}
			return 0;
		case ID_COUNT:
			/*
			 * The up-down reads its buddy, so a number typed into
			 * the edit arrives here and nowhere else.
			 *
			 * Twice per step, though, when the up-down is what
			 * moved: it clears the edit and then writes the new
			 * number, and each of those is a change. Asking what
			 * the number now is and doing nothing when it has not
			 * moved turns that back into one redraw -- and also
			 * means that typing `007` does not redraw three times.
			 */
			if (HIWORD(wparam) == EN_CHANGE) {
				int now = (int)SendMessageW(self->count_updown,
							    UDM_GETPOS32, 0, 0);
				if (now != self->count) {
					self->count = now;
					refresh(self);
				}
			}
			return 0;
		case ID_SYSTEM:
			if (HIWORD(wparam) == BN_CLICKED) {
				/*
				 * `fluent_preferred_locales` asks
				 * `GetUserPreferredUILanguages` here, which is
				 * where a program started from Explorer has to
				 * ask: there is no `LANG` to read.
				 */
				self->index = catalog_preferred(self->cat, NULL);
				SendMessageW(self->language_menu, CB_SETCURSEL,
					     (WPARAM)self->index, 0);
				refresh(self);
			}
			return 0;
		default:
			break;
		}
		break;

	case WM_TIMER:
		if (self != NULL && wparam == ID_SMOKE_TIMER) smoke_tick(self);
		return 0;

	case WM_CTLCOLORSTATIC:
		/* Static controls paint their own background grey otherwise,
		 * which shows as a rectangle against the window's white. */
		SetBkMode((HDC)wparam, TRANSPARENT);
		return (LRESULT)GetSysColorBrush(COLOR_WINDOW);

	case WM_DESTROY:
		PostQuitMessage(0);
		return 0;

	default:
		break;
	}

	return DefWindowProcW(window, message, wparam, lparam);
}

/* -- getting there -------------------------------------------------------- */

/*
 * A window program has no console, so in smoke mode it borrows the one it was
 * started from. Without this the run says nothing at all and CI has only an
 * exit status to go on.
 *
 * Unless it was handed a stream of its own, which a redirect to a file does,
 * and which has to win: writing to `CONOUT$` regardless would put the output
 * on the console and leave the file empty -- and a run that said nothing
 * looks exactly like a run that passed, which is a thing this example exists
 * to stop happening.
 */
static void attach_console(void)
{
	HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
	if (out != NULL && out != INVALID_HANDLE_VALUE) return;

	if (!AttachConsole(ATTACH_PARENT_PROCESS)) return;
	FILE *unused;
	freopen_s(&unused, "CONOUT$", "w", stdout);
	freopen_s(&unused, "CONOUT$", "w", stderr);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR arguments,
		    int show)
{
	(void)previous;
	(void)arguments;

	app self = { 0 };
	char *requested = NULL;

	for (int i = 1; i < __argc; i += 1) {
		if (wcscmp(__wargv[i], L"--smoke") == 0)
			self.smoke = true;
		else
			requested = narrow(__wargv[i]);
	}

	if (self.smoke) attach_console();

	self.cat = catalog_open(LOCALE_DIR);
	if (self.cat == NULL) {
		MessageBoxW(NULL, L"The translations could not be loaded.",
			    L"Greeting", MB_ICONERROR | MB_OK);
		return EXIT_FAILURE;
	}

	/*
	 * An argument overrides what the system says, so the example can be
	 * tried in a language without changing any settings. It is read with
	 * the same parser the environment goes through, so `greeting fr:de`
	 * works too.
	 */
	self.index = catalog_preferred(self.cat, requested);
	free(requested);

	/*
	 * Windows keeps a display language and a regional format apart, and a
	 * user who reads English in Germany has set them to different things.
	 * Only the translation the system asked for gets them, though: those
	 * settings describe *this user's own* locale, and a language they pick
	 * out of the menu afterwards should be written the way that language
	 * is written.
	 */
	catalog_apply_system_formats(self.cat, self.index);

	INITCOMMONCONTROLSEX controls = { 0 };
	controls.dwSize = sizeof(controls);
	controls.dwICC = ICC_UPDOWN_CLASS | ICC_BAR_CLASSES |
			 ICC_STANDARD_CLASSES;
	InitCommonControlsEx(&controls);

	WNDCLASSEXW window_class = { 0 };
	window_class.cbSize = sizeof(window_class);
	window_class.lpfnWndProc = window_proc;
	window_class.hInstance = instance;
	window_class.hCursor = LoadCursorW(NULL, IDC_ARROW);
	window_class.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
	window_class.lpszClassName = L"FluentGreetingWindow";
	if (RegisterClassExW(&window_class) == 0) return EXIT_FAILURE;

	self.dpi = (int)GetDpiForSystem();

	RECT wanted = { 0, 0, MulDiv(356, self.dpi, USER_DEFAULT_SCREEN_DPI),
			MulDiv(294, self.dpi, USER_DEFAULT_SCREEN_DPI) };
	AdjustWindowRectExForDpi(&wanted, WS_OVERLAPPEDWINDOW, FALSE, 0,
				 (UINT)self.dpi);

	HWND window = CreateWindowExW(0, window_class.lpszClassName, L"",
				      WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
				      CW_USEDEFAULT, wanted.right - wanted.left,
				      wanted.bottom - wanted.top, NULL, NULL,
				      instance, &self);
	if (window == NULL) {
		catalog_close(self.cat);
		return EXIT_FAILURE;
	}

	ShowWindow(window, self.smoke ? SW_SHOWNOACTIVATE : show);
	UpdateWindow(window);

	MSG message;
	while (GetMessageW(&message, NULL, 0, 0) > 0) {
		if (!IsDialogMessageW(window, &message)) {
			TranslateMessage(&message);
			DispatchMessageW(&message);
		}
	}

	DeleteObject(self.font);
	catalog_close(self.cat);
	return (int)message.wParam;
}
