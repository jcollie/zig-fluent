// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! zig-fluent: an implementation of Project Fluent for Zig.
//!
//! [Project Fluent](https://projectfluent.org/) is a localization system built
//! around one idea: a translation is not a string with holes in it, but a small
//! program that the translator writes. Grammatical agreement -- plurals,
//! gender, case -- belongs in the translation, where the person who speaks the
//! language can express it, rather than in the calling code, where they cannot
//! reach it and where it would have to be written to suit every language at
//! once.
//!
//! ```ftl
//! shared-photos =
//!     { $userName } { $photoCount ->
//!         [one] added a new photo
//!        *[other] added { $photoCount } new photos
//!     } to { $userGender ->
//!         [male] his stream
//!         [female] her stream
//!        *[other] their stream
//!     }.
//! ```
//!
//! The calling code passes `userName`, `photoCount` and `userGender`, and
//! knows nothing about English's two plural forms or Russian's four. A
//! translation into a language that inflects the verb for gender can do that,
//! and one into a language that does not can ignore the argument, without
//! either of them changing a line of code.
//!
//! ## Pure Zig
//!
//! Every other mature implementation delegates the locale-sensitive part to
//! ICU -- `fluent.js` calls `Intl`, `fluent-rs` leaves number formatting to
//! the host. This one carries its own CLDR-derived tables, generated into
//! `src/cldr/` by `zig build gen-cldr`, so there is nothing to link against
//! and nothing to install.

/// The `.ftl` syntax: parsing, the tree, serializing, and the errors.
///
/// Useful on its own, and free to leave alone: Zig analyses only what is
/// referenced, so a program that formats messages never compiles the
/// serializer and a linter never compiles the resolver.
pub const syntax = @import("syntax.zig");

const bundle_mod = @import("bundle.zig");

/// The messages of one locale, ready to be formatted. The type an application
/// holds.
pub const Bundle = bundle_mod.Bundle;

/// Something that went wrong while adding a resource or formatting a message.
/// None of them stop anything; they are collected for whoever wants to know.
pub const Error = bundle_mod.Error;
pub const Errors = bundle_mod.Errors;

/// A function a translation may call, such as `NUMBER()`. Applications may add
/// their own with `Bundle.addFunction`.
pub const Function = bundle_mod.Function;

/// What such a function is handed.
pub const Call = bundle_mod.Call;

const value_mod = @import("value.zig");

/// What a placeable resolves to, and what an application passes in: text, a
/// number, a moment, or a fallback for something that could not be resolved.
pub const Value = value_mod.Value;
pub const Number = value_mod.Number;
pub const DateTime = value_mod.DateTime;

/// One named value passed to a message.
pub const Argument = value_mod.Argument;

/// The arguments a message is formatted with.
pub const Args = value_mod.Args;

/// A BCP 47 language tag, reduced to the subtags CLDR keys its data by.
pub const Locale = @import("locale.zig").Locale;

/// CLDR's plural rules: which of `zero`, `one`, `two`, `few`, `many` or
/// `other` a number takes in a given language.
pub const plural = @import("plural.zig");

/// The number formatting engine and its ECMA-402 options.
pub const number_format = @import("number_format.zig");

/// The date formatting engine and its ECMA-402 options. The calendar itself is
/// `zig-datetime`'s.
pub const datetime_format = @import("datetime_format.zig");

/// `NUMBER()` and `DATETIME()`, which every bundle has.
pub const builtins = @import("builtins.zig");

test {
    _ = syntax;
    _ = @import("locale.zig");
    _ = plural;
    _ = number_format;
    _ = datetime_format;
    _ = bundle_mod;
    _ = builtins;
    _ = @import("resolver.zig");
    _ = value_mod;
}
