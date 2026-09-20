// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//
//  The C API, wrapped in Swift.
//
//  This is the file the macOS example exists for. `include/fluent.h` states
//  its ownership rules in prose -- a handle is freed with the `_free` function
//  of its own type, text the library returns belongs to the caller and is
//  freed with `fluent_string_free`, nothing that is passed in is retained --
//  and the question is whether those rules survive contact with a language
//  that manages memory for you. They do, and this is what that looks like:
//  one `final class` per handle, one `deinit` per `_free`, and a `defer` at
//  every point where a returned string is turned into a `String`.
//
//  Nothing above this file ever sees a pointer.
//

import CFluent
import Foundation

// MARK: - Text

/// A string the library returned, as a Swift `String`, freed on the way out.
///
/// `fluent_string_len` rather than `strlen`: an `.ftl` file is bytes, so a
/// translation is entitled to contain a NUL, and `String(cString:)` would stop
/// at it. Decoding the exact byte count keeps whatever the translator wrote.
private func take(_ text: UnsafeMutablePointer<CChar>?) -> String? {
	guard let text else { return nil }
	defer { fluent_string_free(text) }
	let bytes = UnsafeRawBufferPointer(start: text, count: fluent_string_len(text))
	return String(decoding: bytes, as: UTF8.self)
}

extension fluent_tag {
	/// The tag as a `String`, such as "sr-Latn-RS".
	///
	/// Not named `text`, which is what the C structure calls the array
	/// itself: a C array of `char` arrives in Swift as a tuple of thirteen
	/// `CChar`s under that name, and an extension cannot add a second
	/// member beside it.
	public var string: String {
		withUnsafeBytes(of: self) { raw in
			String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
		}
	}
}

// MARK: - The library itself

public enum Fluent {
	/// The library version, such as "0.1.0".
	public static var version: String { String(cString: fluent_version()) }

	/// The locales this user would like, best first.
	///
	/// On macOS this reads `AppleLanguages` out of the preferences rather
	/// than the environment, because an application started from the Finder
	/// has no `LANG` -- with the environment still winning where it says
	/// anything, since a shell that sets `LANG` was set up on purpose.
	public static func preferredLocales(limit: Int = 8) -> [String] {
		var tags = [fluent_tag](repeating: fluent_tag(), count: limit)
		let found = tags.withUnsafeMutableBufferPointer { buffer in
			fluent_preferred_locales(buffer.baseAddress, limit)
		}
		return tags.prefix(found).map(\.string)
	}

	/// The locales in a colon-separated list, as `LANGUAGE` is written.
	public static func locales(inList list: String, limit: Int = 8) -> [String] {
		var tags = [fluent_tag](repeating: fluent_tag(), count: limit)
		let found = tags.withUnsafeMutableBufferPointer { buffer in
			list.withCString { fluent_locales_from_list($0, buffer.baseAddress, limit) }
		}
		return tags.prefix(found).map(\.string)
	}
}

// MARK: - Arguments

/// The values a message is formatted with.
///
/// Names and values are copied in, so nothing here has to outlive the call --
/// which is what lets these methods take ordinary Swift `String`s and `Date`s
/// and keep no reference to them.
public final class FluentArgs {
	let handle: OpaquePointer

	public init?() {
		guard let handle = fluent_args_new() else { return nil }
		self.handle = handle
	}

	deinit { fluent_args_free(handle) }

	public var count: Int { fluent_args_len(handle) }

	/// Forget every argument, keeping the memory for the next message.
	public func removeAll() { fluent_args_clear(handle) }

	/// A string argument goes over as a pointer and a length, not as a C
	/// string, because it is a body of text rather than a name and may be
	/// anything at all -- including, legitimately, something with a NUL in
	/// it. The bytes are copied, so this array can go out of scope here.
	@discardableResult
	public func set(_ name: String, to text: String) -> Bool {
		name.withCString { name in
			Array(text.utf8).withUnsafeBytes { raw -> Bool in
				guard let base = raw.bindMemory(to: CChar.self).baseAddress else {
					return fluent_args_set_string(handle, name, "", 0)
				}
				return fluent_args_set_string(handle, name, base, raw.count)
			}
		}
	}

	@discardableResult
	public func set(_ name: String, to value: Double) -> Bool {
		name.withCString { fluent_args_set_number(handle, $0, value) }
	}

	@discardableResult
	public func set(_ name: String, to value: Int) -> Bool {
		set(name, to: Double(value))
	}

	/// A moment. The C API takes milliseconds since 1970, which is what a
	/// `Date` is once it has been asked the right question.
	@discardableResult
	public func set(_ name: String, to moment: Date) -> Bool {
		let epochMilliseconds = Int64((moment.timeIntervalSince1970 * 1000).rounded())
		return name.withCString {
			fluent_args_set_datetime(handle, $0, epochMilliseconds)
		}
	}
}

// MARK: - Errors

/// What went wrong while adding a resource or formatting a message.
///
/// None of it stops anything: a message with a bad reference still formats,
/// with the unresolved part written as `{$name}` so that the sentence around
/// it survives and the gap is obvious. The list is collected for whoever wants
/// to know -- a test, a lint mode, a log.
public final class FluentErrors {
	let handle: OpaquePointer

	public init?() {
		guard let handle = fluent_errors_new() else { return nil }
		self.handle = handle
	}

	deinit { fluent_errors_free(handle) }

	public var count: Int { fluent_errors_len(handle) }

	/// The list only ever grows, so this is what tells one operation's
	/// errors from the next's.
	public func removeAll() { fluent_errors_clear(handle) }

	public func kind(at index: Int) -> fluent_error_kind {
		fluent_errors_kind(handle, index)
	}

	/// The error as a sentence, such as "unknown variable: $count".
	///
	/// Read it while what it talks about is still alive: an error borrows
	/// the name it names, from the resource that was parsed or from the
	/// arguments a message was formatted with.
	public func message(at index: Int) -> String? {
		take(fluent_errors_message(handle, index))
	}

	public var messages: [String] {
		(0..<count).compactMap { message(at: $0) }
	}
}

// MARK: - Bundles

/// The messages of one locale, ready to be formatted.
public final class FluentBundle {
	let handle: OpaquePointer

	/// `nil` when `locale` is not a language tag, or memory ran out.
	public init?(locale: String) {
		guard let handle = locale.withCString({ fluent_bundle_new($0) }) else {
			return nil
		}
		self.handle = handle
	}

	deinit { fluent_bundle_free(handle) }

	/// The locale this bundle speaks, canonicalized: "en-us" comes back as
	/// "en-US".
	public var locale: String { String(cString: fluent_bundle_locale(handle)) }

	/// Whether to wrap interpolations in Unicode isolation marks, so that a
	/// right-to-left name dropped into a left-to-right sentence does not drag
	/// the punctuation around it to the wrong end of the line.
	///
	/// On by default, which is right here: these strings are going into a
	/// window, and AppKit honours the marks. A command-line tool turns them
	/// off, because a terminal prints them.
	public func setUsesIsolating(_ on: Bool) {
		fluent_bundle_set_use_isolating(handle, on)
	}

	/// Parse `source` and add its messages and terms.
	///
	/// `Data` rather than `String` because that is what the API takes and
	/// what a file is: an entry that does not parse is reported and skipped,
	/// and the rest of the file is added regardless.
	@discardableResult
	public func add(resource source: Data, collecting errors: FluentErrors? = nil) -> Bool {
		source.withUnsafeBytes { raw in
			guard let base = raw.bindMemory(to: CChar.self).baseAddress else {
				return true // an empty resource adds nothing and fails at nothing
			}
			return fluent_bundle_add_resource(handle, base, raw.count, errors?.handle)
		}
	}

	public func hasMessage(_ id: String) -> Bool {
		id.withCString { fluent_bundle_has_message(handle, $0) }
	}

	/// Format a message, or `nil` when this bundle has no such message.
	///
	/// Missing is a value rather than an error because an application falling
	/// back through several translations simply asks the next one.
	public func format(
		_ id: String,
		args: FluentArgs? = nil,
		collecting errors: FluentErrors? = nil
	) -> String? {
		id.withCString { id in
			take(fluent_bundle_format(handle, id, args?.handle, errors?.handle))
		}
	}

	/// Format one attribute of a message, such as a `.tooltip`.
	public func format(
		_ id: String,
		attribute: String,
		args: FluentArgs? = nil,
		collecting errors: FluentErrors? = nil
	) -> String? {
		id.withCString { id in
			attribute.withCString { attribute in
				take(fluent_bundle_format_attribute(
					handle, id, attribute, args?.handle, errors?.handle))
			}
		}
	}

	/// Write numbers, money and dates the way the system's settings ask for,
	/// which macOS keeps apart from the display language. The message
	/// language is not touched, so plural rules stay those of the text.
	public func applySystemFormats() {
		var categories = fluent_categories()
		fluent_categories_current(&categories)
		fluent_bundle_apply_categories(handle, &categories)
	}
}
