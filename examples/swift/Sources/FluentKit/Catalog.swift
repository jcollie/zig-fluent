// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//
//  The translations an application ships, and the choice between them.
//
//  This is `examples/common/catalog.c` in Swift, and deliberately so: the two
//  GUI examples written in C share that file, and reading this one beside it
//  shows what changes when the language does and what does not. The
//  negotiation is the same three passes, for the same reason -- it is the
//  application's decision rather than the library's.
//

import Foundation

public struct Translation {
	public let tag: String
	/// The name this translation gives its own language: "Deutsch", not
	/// "German". It comes from the `language-name` message inside the
	/// translation, which is the only place that knows it.
	public let endonym: String
	let bundle: FluentBundle
}

public enum CatalogError: Error, CustomStringConvertible {
	case noBundle(String)
	case unreadable(String, underlying: Error)
	case malformed(String, problems: [String])
	case outOfMemory

	public var description: String {
		switch self {
		case .noBundle(let tag): "\(tag) is not a language tag"
		case .unreadable(let tag, let underlying): "\(tag).ftl: \(underlying.localizedDescription)"
		case .malformed(let tag, let problems): "\(tag).ftl: \(problems.joined(separator: "; "))"
		case .outOfMemory: "out of memory"
		}
	}
}

public final class Catalog {
	/// The first entry is the source locale and is the last resort, which is
	/// why its translation must be complete.
	public static let shipped = ["en-US", "de", "fr", "fi", "pl", "ja"]

	public private(set) var translations: [Translation] = []

	/// One list, cleared by the caller between screenfuls, so that a window
	/// can format a dozen messages and then ask once what went wrong.
	public let errors: FluentErrors

	public init(directory: URL) throws {
		guard let errors = FluentErrors() else { throw CatalogError.outOfMemory }
		self.errors = errors

		for tag in Self.shipped {
			guard let bundle = FluentBundle(locale: tag) else {
				throw CatalogError.noBundle(tag)
			}

			// Left on, unlike a command-line tool: these strings are
			// going into a window, where the isolation marks do their
			// job and are invisible.
			bundle.setUsesIsolating(true)

			let file = directory.appendingPathComponent("\(tag).ftl")
			let source: Data
			do {
				source = try Data(contentsOf: file)
			} catch {
				throw CatalogError.unreadable(tag, underlying: error)
			}

			// A translation that does not parse is a bug in this
			// repository rather than something to paper over at run
			// time, so these are fatal where a *formatting* error
			// later on is merely shown.
			guard let parseErrors = FluentErrors() else {
				throw CatalogError.outOfMemory
			}
			bundle.add(resource: source, collecting: parseErrors)
			if parseErrors.count > 0 {
				throw CatalogError.malformed(tag, problems: parseErrors.messages)
			}

			translations.append(Translation(
				tag: bundle.locale,
				// A translation that has not got round to
				// `language-name` yet still belongs in the menu,
				// under the only name we have for it.
				endonym: bundle.format("language-name") ?? bundle.locale,
				bundle: bundle))
		}
	}

	// MARK: - Negotiation

	/// Whether two canonical tags name the same language.
	///
	/// A tag out of the library is canonical -- language lowercase, script
	/// title case, region uppercase -- so the language is everything before
	/// the first hyphen and a plain comparison is enough. No locale library
	/// is needed for this, which is the point: what comes back is a string.
	private static func language(of tag: String) -> Substring {
		tag.prefix { $0 != "-" }
	}

	/// The script subtag, or `nil` when the tag does not state one. A
	/// four-letter subtag in that position is a script; a two-letter or
	/// three-digit one is a region, and there is then no script.
	private static func script(of tag: String) -> Substring? {
		let parts = tag.split(separator: "-")
		guard parts.count > 1, parts[1].count == 4 else { return nil }
		return parts[1]
	}

	private static func matches(_ have: String, _ want: String, pass: Int) -> Bool {
		guard language(of: have) == language(of: want) else { return false }
		switch pass {
		case 0:
			return have == want
		case 1:
			guard let left = script(of: have), let right = script(of: want) else {
				return true // unstated counts as agreeing
			}
			return left == right
		default:
			return true
		}
	}

	/// The translation that best serves the locales asked for.
	///
	/// Each requested locale is tried in turn, and for each one the
	/// translations are searched for the closest match: the same tag, then
	/// the same language and script, then merely the same language. Asking
	/// in that order matters -- somebody who asks for `fr` before `en`
	/// should get French even though an `en-US` translation exists and is a
	/// better match for nothing they said.
	///
	/// When nothing matches, the first entry: showing English is a better
	/// outcome than showing message names.
	public func negotiate(_ requested: [String]) -> Int {
		for want in requested {
			for pass in 0..<3 {
				for (index, translation) in translations.enumerated()
				where Self.matches(translation.tag, want, pass: pass) {
					return index
				}
			}
		}
		return 0
	}

	/// The same, for what the system says the user wants -- or for a
	/// colon-separated list, as `LANGUAGE` is written, when one is given.
	public func preferred(list: String? = nil) -> Int {
		negotiate(list.map { Fluent.locales(inList: $0) } ?? Fluent.preferredLocales())
	}

	public func applySystemFormats(to index: Int) {
		guard translations.indices.contains(index) else { return }
		translations[index].bundle.applySystemFormats()
	}

	// MARK: - Saying it

	public func format(_ id: String, in index: Int, args: FluentArgs? = nil) -> String? {
		guard translations.indices.contains(index) else { return nil }
		return translations[index].bundle.format(id, args: args, collecting: errors)
	}

	public func format(
		_ id: String, attribute: String, in index: Int, args: FluentArgs? = nil
	) -> String? {
		guard translations.indices.contains(index) else { return nil }
		return translations[index].bundle.format(
			id, attribute: attribute, args: args, collecting: errors)
	}

	// MARK: - Finding the translations

	/// Where the `.ftl` files are.
	///
	/// Inside the application bundle when there is one, which is what `make
	/// app` builds; otherwise `FLUENT_LOCALE_DIR`, and otherwise the
	/// repository's own copy relative to the working directory, which is
	/// where `swift run` leaves it.
	public static func defaultDirectory() -> URL {
		let manager = FileManager.default

		if let resources = Bundle.main.resourceURL {
			let inside = resources.appendingPathComponent("locales")
			if manager.fileExists(atPath: inside.path) { return inside }
		}

		if let named = ProcessInfo.processInfo.environment["FLUENT_LOCALE_DIR"] {
			return URL(fileURLWithPath: named)
		}

		return URL(fileURLWithPath: "../locales")
	}
}
