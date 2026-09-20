// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//
//  The worked example again, in a SwiftUI window.
//
//  `examples/gtk` and `examples/win32` are this program written in C against
//  two other window systems, against the same six translations and the same
//  five messages. What this one is for is the boundary itself: it is the only
//  place the C API is used from a language that manages memory, and
//  `FluentKit` -- one `final class` per handle, one `deinit` per `_free` -- is
//  the answer to whether the ownership rules in `fluent.h` survive that.
//
//  Nothing below this line touches a pointer.
//
//      $ make run
//      $ make app && open Greeting.app
//      $ FLUENT_LOCALE_DIR=../locales swift run Greeting fi
//

import FluentKit
import SwiftUI

@main
struct GreetingApp: App {
	@State private var model = Model()

	var body: some Scene {
		WindowGroup {
			ContentView(model: model)
		}
		.windowResizability(.contentSize)
	}
}

/// Everything on screen, regenerated whenever the language or the count
/// changes.
///
/// One `refresh` for the whole window rather than one per label, because
/// nothing here is expensive and because a partial refresh is how half a
/// window ends up in the previous language.
@Observable
final class Model {
	private let catalog: Catalog?

	/// 2026-02-14T09:30:00Z, fixed so that running this twice says the same
	/// thing. A real application would read a clock.
	private let when = Date(timeIntervalSince1970: 1_771_061_400)

	var index: Int = 0 { didSet { refresh() } }
	var count: Int = 1 { didSet { refresh() } }

	private(set) var title = ""
	private(set) var languageLabel = ""
	private(set) var countLabel = ""
	private(set) var welcome = ""
	private(set) var newPhotos = ""
	private(set) var shared = ""
	private(set) var storage = ""
	private(set) var buttonLabel = ""
	private(set) var buttonHelp = ""
	private(set) var problems: [String] = []

	/// What went wrong before there was anything to show, which is a
	/// different thing from a message that failed to format.
	private(set) var failure: String?

	var languages: [String] {
		catalog?.translations.map(\.endonym) ?? []
	}

	init() {
		do {
			let catalog = try Catalog(directory: Catalog.defaultDirectory())
			self.catalog = catalog

			// An argument overrides what the system says, so the
			// example can be tried in a language without changing any
			// settings: `swift run Greeting fi`, or `fr:de`.
			let asked = CommandLine.arguments.dropFirst().first
			index = catalog.preferred(list: asked)

			// macOS keeps a display language and a regional format
			// apart, and a user who reads English in Germany has set
			// them to different things. Only the translation the
			// system asked for gets them, though: those settings
			// describe this user's own locale, and a language they
			// pick from the menu afterwards should be written the way
			// that language is written.
			catalog.applySystemFormats(to: index)

			refresh()
		} catch {
			catalog = nil
			failure = String(describing: error)
		}
	}

	/// Go back to what the system says the user wants.
	///
	/// On macOS that is `AppleLanguages` out of the preferences, which is
	/// where an application started from the Finder has to ask: there is no
	/// `LANG` for it to read.
	func useSystemLanguage() {
		guard let catalog else { return }
		index = catalog.preferred()
	}

	func refresh() {
		guard let catalog else { return }
		catalog.errors.removeAll()

		title = catalog.format("window-title", in: index) ?? "—"
		languageLabel = catalog.format("language-label", in: index) ?? "—"
		countLabel = catalog.format("count-label", in: index) ?? "—"

		// A label and its tooltip out of one message and its attribute,
		// which is what attributes are for: the several strings a
		// control needs kept together, so that a translation cannot
		// update the label and forget the explanation.
		buttonLabel = catalog.format("use-system-language", in: index) ?? "—"
		buttonHelp = catalog.format(
			"use-system-language", attribute: "tooltip", in: index) ?? ""

		welcome = catalog.format("welcome", in: index) ?? "—"

		guard let args = FluentArgs() else { return }

		args.set("count", to: count)
		newPhotos = catalog.format("new-photos", in: index, args: args) ?? "—"

		// `gender` is here because Polish reads it -- the past tense
		// agrees with the sharer -- and Finnish does not, and this
		// program cannot tell which. That is the arrangement: the
		// application hands over what it knows, and each translation
		// takes what its grammar needs.
		args.removeAll()
		args.set("user", to: "Ada")
		args.set("gender", to: "female")
		args.set("count", to: count)
		args.set("when", to: when)
		shared = catalog.format("shared-with-you", in: index, args: args) ?? "—"

		args.removeAll()
		args.set("used", to: 12345.678)
		args.set("total", to: 50000)
		storage = catalog.format("storage", in: index, args: args) ?? "—"

		// Read before `args` goes out of scope at the end of this
		// function: an error borrows the name it names, from the
		// resource that was parsed or from the arguments a message was
		// formatted with.
		problems = catalog.errors.messages
	}
}
