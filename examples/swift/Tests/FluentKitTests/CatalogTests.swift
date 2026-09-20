// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//
//  What CI asserts on.
//
//  A window cannot be checked by a machine without a great deal of machinery,
//  and what would be checked is SwiftUI rather than this library. These run
//  headless against `FluentKit` instead, and they assert the two things worth
//  asserting: that the wrapper does not lose or leak what the C API hands it,
//  and that the translations still say what the grammar of their languages
//  requires.
//

import XCTest

@testable import FluentKit

final class CatalogTests: XCTestCase {
	/// `examples/locales`, found relative to this file rather than to the
	/// working directory, which `swift test` does not promise anything about.
	static let locales: URL = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()  // Tests/FluentKitTests
		.deletingLastPathComponent()  // Tests
		.deletingLastPathComponent()  // examples/swift
		.deletingLastPathComponent()  // examples
		.appendingPathComponent("locales")

	private func makeCatalog() throws -> Catalog {
		try Catalog(directory: Self.locales)
	}

	// MARK: - The library is there at all

	func testVersionIsReported() {
		XCTAssertFalse(Fluent.version.isEmpty)
	}

	// MARK: - Loading

	func testEveryShippedTranslationLoads() throws {
		let catalog = try makeCatalog()
		XCTAssertEqual(catalog.translations.count, Catalog.shipped.count)
	}

	/// Tags come back canonicalized, which is what lets the negotiation below
	/// compare them as ordinary strings.
	func testTagsAreCanonical() throws {
		let catalog = try makeCatalog()
		XCTAssertEqual(catalog.translations.map(\.tag),
			       ["en-US", "de", "fr", "fi", "pl", "ja"])
	}

	/// Each translation names its own language, which is what the menu shows.
	func testEndonymsComeFromTheTranslations() throws {
		let catalog = try makeCatalog()
		let names = Dictionary(uniqueKeysWithValues:
			catalog.translations.map { ($0.tag, $0.endonym) })
		XCTAssertEqual(names["en-US"], "English")
		XCTAssertEqual(names["de"], "Deutsch")
		XCTAssertEqual(names["fi"], "Suomi")
		XCTAssertEqual(names["ja"], "日本語")
	}

	// MARK: - Negotiation

	func testExactTagWins() throws {
		let catalog = try makeCatalog()
		XCTAssertEqual(catalog.translations[catalog.negotiate(["fi"])].tag, "fi")
	}

	/// A region we do not ship falls back to the language we do.
	func testRegionFallsBackToLanguage() throws {
		let catalog = try makeCatalog()
		XCTAssertEqual(catalog.translations[catalog.negotiate(["fr-CA"])].tag, "fr")
	}

	/// Order matters: somebody who asks for French first should get French,
	/// even though an `en-US` translation exists and is exact for nothing
	/// they said.
	func testTheFirstRequestThatMatchesWins() throws {
		let catalog = try makeCatalog()
		XCTAssertEqual(catalog.translations[catalog.negotiate(["fr", "en-US"])].tag, "fr")
	}

	/// Nothing matching means the source locale, whose translation is by
	/// construction complete.
	func testUnknownLanguageFallsBackToTheSource() throws {
		let catalog = try makeCatalog()
		XCTAssertEqual(catalog.translations[catalog.negotiate(["cy"])].tag, "en-US")
	}

	/// The system's answer is a list of tags, whatever the platform read it
	/// from -- `AppleLanguages` here rather than the environment.
	func testTheSystemAnswersWithTags() {
		for tag in Fluent.preferredLocales() {
			XCTAssertFalse(tag.isEmpty)
			XCTAssertFalse(tag.contains("_"), "\(tag) is a POSIX name, not a tag")
		}
	}

	func testAListOfLocalesIsRead() {
		XCTAssertEqual(Fluent.locales(inList: "fr:de_DE.UTF-8:C"), ["fr", "de-DE"])
	}

	// MARK: - What the translations say

	/// Finnish declines the product name rather than putting a preposition in
	/// front of it, and the ending is written after the placeable. The
	/// calling code passes nothing and knows nothing about the case system.
	func testFinnishInflectsTheProductName() throws {
		let catalog = try makeCatalog()
		let finnish = catalog.negotiate(["fi"])
		let welcome = catalog.format("welcome", in: finnish)
		XCTAssertNotNil(welcome)
		XCTAssertTrue(welcome!.contains("Tervetuloa"), welcome!)
		XCTAssertTrue(welcome!.contains("Kuvakirjasto"), welcome!)
	}

	/// The demonstration, asserted: Polish has four plural categories and
	/// this test passes nothing but integers to reach all of them. 22 counts
	/// like 2 and 12 does not, which is the rule no amount of `if (n == 1)`
	/// in the calling code would have got right.
	func testPolishUsesFourPluralForms() throws {
		let catalog = try makeCatalog()
		let polish = catalog.negotiate(["pl"])
		guard let args = FluentArgs() else { return XCTFail("out of memory") }

		var forms: [Int: String] = [:]
		for count in [1, 2, 5, 12, 22] {
			args.set("count", to: count)
			let text = catalog.format("new-photos", in: polish, args: args)
			XCTAssertNotNil(text, "no text for \(count)")
			forms[count] = text
		}

		XCTAssertTrue(forms[1]!.contains("nowe zdjęcie"), forms[1]!)
		XCTAssertTrue(forms[2]!.contains("nowe zdjęcia"), forms[2]!)
		XCTAssertTrue(forms[5]!.contains("nowych zdjęć"), forms[5]!)
		XCTAssertTrue(forms[12]!.contains("nowych zdjęć"), forms[12]!)
		XCTAssertTrue(forms[22]!.contains("nowe zdjęcia"), forms[22]!)
	}

	/// An argument one translation needs and another never reads. Finnish has
	/// no grammatical gender at all, and nothing has to change for it not to
	/// use the one it is given.
	func testATranslationMayIgnoreAnArgument() throws {
		let catalog = try makeCatalog()
		guard let args = FluentArgs() else { return XCTFail("out of memory") }
		args.set("user", to: "Ada")
		args.set("gender", to: "female")
		args.set("count", to: 1)
		args.set("when", to: Date(timeIntervalSince1970: 1_771_061_400))

		catalog.errors.removeAll()
		let finnish = catalog.format("shared-with-you", in: catalog.negotiate(["fi"]), args: args)
		XCTAssertNotNil(finnish)
		XCTAssertTrue(finnish!.contains("Ada"), finnish!)
		XCTAssertEqual(catalog.errors.count, 0, catalog.errors.messages.joined(separator: "; "))
	}

	/// An attribute: the tooltip that belongs with the button's label.
	func testAttributesFormat() throws {
		let catalog = try makeCatalog()
		let german = catalog.negotiate(["de"])
		XCTAssertEqual(catalog.format("use-system-language", in: german),
			       "Systemsprache verwenden")
		let tooltip = catalog.format("use-system-language", attribute: "tooltip", in: german)
		XCTAssertNotNil(tooltip)
		XCTAssertTrue(tooltip!.contains("Sprache"), tooltip!)
	}

	/// A message the translation does not have is `nil` rather than an error,
	/// because an application falling back through several translations
	/// simply asks the next one.
	func testAMissingMessageIsNil() throws {
		let catalog = try makeCatalog()
		XCTAssertNil(catalog.format("no-such-message", in: 0))
	}

	// MARK: - The wrapper's own behaviour

	/// Isolation marks are on by default, which is right for a window. The
	/// interpolated product name comes back wrapped in U+2068 and U+2069.
	func testIsolationMarksAreOnByDefault() throws {
		let bundle = try XCTUnwrap(FluentBundle(locale: "en-US"))
		bundle.add(resource: Data("-app = Vault\nwelcome = Welcome to { -app }!".utf8))

		let isolated = try XCTUnwrap(bundle.format("welcome"))
		XCTAssertTrue(isolated.unicodeScalars.contains("\u{2068}"), isolated)

		bundle.setUsesIsolating(false)
		XCTAssertEqual(bundle.format("welcome"), "Welcome to Vault!")
	}

	/// Junk recovery: an entry that does not parse is reported and skipped,
	/// and the rest of the file is added regardless.
	func testABrokenEntryDoesNotTakeTheFileWithIt() throws {
		let bundle = try XCTUnwrap(FluentBundle(locale: "en-US"))
		let errors = try XCTUnwrap(FluentErrors())
		bundle.add(resource: Data("good = fine\n= broken\nalso-good = fine too".utf8),
			   collecting: errors)

		XCTAssertGreaterThan(errors.count, 0)
		XCTAssertEqual(bundle.format("good"), "fine")
		XCTAssertEqual(bundle.format("also-good"), "fine too")
	}

	/// A hole in a translation still renders the sentence around it, with the
	/// unresolved part written as `{$name}` and the reason collected.
	func testAnUnresolvedArgumentIsReportedAndSurvives() throws {
		let bundle = try XCTUnwrap(FluentBundle(locale: "en-US"))
		let errors = try XCTUnwrap(FluentErrors())
		bundle.setUsesIsolating(false)
		bundle.add(resource: Data("hello = Hello, { $name }!".utf8))

		XCTAssertEqual(bundle.format("hello", collecting: errors), "Hello, {$name}!")
		XCTAssertEqual(errors.count, 1)
		XCTAssertTrue(errors.messages[0].contains("name"), errors.messages[0])
	}

	/// The arguments are copied in, so the strings they were built from may
	/// go away before the message is formatted. This would be a
	/// use-after-free if that were not true, and ASan-clean silence here is
	/// the whole assertion.
	func testArgumentsAreCopiedIn() throws {
		let bundle = try XCTUnwrap(FluentBundle(locale: "en-US"))
		bundle.setUsesIsolating(false)
		bundle.add(resource: Data("hello = Hello, { $name }!".utf8))

		let args = try XCTUnwrap(FluentArgs())
		do {
			var name = "Ada"
			name.append("")  // defeat the small-string optimization
			args.set("name", to: name)
		}
		XCTAssertEqual(args.count, 1)
		XCTAssertEqual(bundle.format("hello", args: args), "Hello, Ada!")
	}

	/// Setting a name that is already there replaces it rather than adding a
	/// second one.
	func testSettingAnArgumentTwiceReplacesIt() throws {
		let args = try XCTUnwrap(FluentArgs())
		args.set("count", to: 1)
		args.set("count", to: 2)
		XCTAssertEqual(args.count, 1)
	}

	/// A tag that is not one is refused rather than accepted quietly.
	func testABadLocaleIsRefused() {
		XCTAssertNil(FluentBundle(locale: "not a language tag"))
	}
}
