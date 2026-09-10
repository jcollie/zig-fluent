// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! A cursor over FTL source, with the lookahead the grammar needs.
//!
//! Fluent's grammar cannot be tokenized ahead of the parse. Whether a run of
//! spaces is indentation inside a pattern or the blank line that ends one
//! depends on what follows it, and whether `[` begins a variant or is just a
//! bracket in a sentence depends on where in the pattern it sits. So the
//! parser looks ahead instead, and this type is the lookahead: `peek*` moves a
//! second cursor and can be wound back with `resetPeek`, `skip*` commits the
//! main one to where the second one got to.
//!
//! ## Bytes, not code points
//!
//! Every character the grammar gives meaning to is ASCII, and UTF-8 never
//! encodes an ASCII byte as part of a longer sequence. So the cursor can step
//! a byte at a time and still never split a character it cares about, and a
//! multi-byte character passes through a text element as the several ordinary
//! bytes it is made of. This is why byte offsets are safe to slice at.
//!
//! It does mean offsets here count bytes where `fluent-syntax` counts UTF-16
//! code units. Nothing in the AST depends on the two agreeing; a tool that
//! reports an error position to an editor is the one place it would matter,
//! and byte offsets are what an editor working in UTF-8 wants anyway.

const std = @import("std");

const errors = @import("errors.zig");

const testing = std.testing;

/// What `charAt` returns past the end of the source. Fluent treats the end of
/// the file as a line ending, so a great deal of the parser is written to
/// accept it wherever a newline would do.
pub const eof: ?u8 = null;

pub const Stream = struct {
    source: []const u8,
    index: usize = 0,
    peek_offset: usize = 0,

    /// The error a `ParseError` refers to. Zig's error set cannot carry a
    /// payload, so the code and its argument are parked here and the error
    /// value is only the signal that they are worth reading.
    pending: errors.Annotation = undefined,

    pub const Error = error{ParseError};

    /// A cursor at the start of `source`.
    pub fn init(source: []const u8) Stream {
        return .{ .source = source };
    }

    test init {
        const stream = Stream.init("hello = Hi");
        try testing.expectEqual(@as(usize, 0), stream.index);
        try testing.expectEqual(@as(usize, 0), stream.peek_offset);
        try testing.expectEqual(@as(?u8, 'h'), stream.currentChar());
    }

    /// Raise a parse error, recording the code and where the parser gave up.
    pub fn fail(self: *Stream, code: errors.Code, argument: ?[]const u8) Error {
        self.pending = .{ .code = code, .argument = argument, .position = self.index };
        return error.ParseError;
    }

    test fail {
        var stream = Stream.init("m = ");
        stream.index = 4;
        // It returns the error rather than raising it, so a caller writes
        // `return self.fail(...)`.
        try testing.expectEqual(error.ParseError, stream.fail(.E0005, "m"));
        // The code and its argument are parked on the stream, since a Zig error
        // cannot carry them.
        try testing.expectEqual(errors.Code.E0005, stream.pending.code);
        try testing.expectEqualStrings("m", stream.pending.argument.?);
        try testing.expectEqual(@as(usize, 4), stream.pending.position);
    }

    // -- reading ------------------------------------------------------------

    /// The byte at `offset`, or null past the end.
    ///
    /// A CRLF reads as a plain newline without the cursor moving, so that
    /// every test for a line ending in the parser can be a test for `\n` and
    /// a slice taken up to this position still ends where the line does.
    pub fn charAt(self: Stream, offset: usize) ?u8 {
        if (offset >= self.source.len) return eof;
        if (self.source[offset] == '\r' and
            offset + 1 < self.source.len and
            self.source[offset + 1] == '\n') return '\n';
        return self.source[offset];
    }

    test charAt {
        const stream = Stream.init("a\r\nb");
        try testing.expectEqual(@as(?u8, 'a'), stream.charAt(0));
        // A CRLF reads as the one newline it is, without the cursor moving, so
        // every test for a line ending can be a test for `\n`.
        try testing.expectEqual(@as(?u8, '\n'), stream.charAt(1));
        try testing.expectEqual(@as(?u8, null), stream.charAt(99));
    }

    /// The character under the cursor, or null at the end of the source.
    pub fn currentChar(self: Stream) ?u8 {
        return self.charAt(self.index);
    }

    test currentChar {
        var stream = Stream.init("ab");
        try testing.expectEqual(@as(?u8, 'a'), stream.currentChar());
        _ = stream.next();
        try testing.expectEqual(@as(?u8, 'b'), stream.currentChar());
    }

    /// The character under the lookahead.
    pub fn currentPeek(self: Stream) ?u8 {
        return self.charAt(self.index + self.peek_offset);
    }

    test currentPeek {
        var stream = Stream.init("  x");
        try testing.expectEqual(@as(?u8, ' '), stream.currentPeek());
        _ = stream.peek();
        _ = stream.peek();
        // The lookahead has moved; the cursor has not.
        try testing.expectEqual(@as(?u8, 'x'), stream.currentPeek());
        try testing.expectEqual(@as(?u8, ' '), stream.currentChar());
    }

    /// Advance the cursor one character, abandoning any lookahead.
    ///
    /// A CRLF counts as the one character it reads as.
    pub fn next(self: *Stream) ?u8 {
        self.peek_offset = 0;
        if (self.index < self.source.len and
            self.source[self.index] == '\r' and
            self.index + 1 < self.source.len and
            self.source[self.index + 1] == '\n') self.index += 1;
        self.index += 1;
        // Deliberately the raw byte and not `charAt`: the callers that use
        // this result are testing what the next line begins with, and want the
        // `\r` of a CRLF to read as itself rather than as a newline.
        return if (self.index < self.source.len) self.source[self.index] else eof;
    }

    test next {
        var stream = Stream.init("a\r\nb");
        _ = stream.next();
        // The CRLF counts as the single character it reads as.
        try testing.expectEqual(@as(usize, 1), stream.index);
        _ = stream.next();
        try testing.expectEqual(@as(usize, 3), stream.index);
        try testing.expectEqual(@as(?u8, 'b'), stream.currentChar());
    }

    /// Advance the lookahead one character and return what is then under it.
    pub fn peek(self: *Stream) ?u8 {
        const at = self.index + self.peek_offset;
        if (at < self.source.len and
            self.source[at] == '\r' and
            at + 1 < self.source.len and
            self.source[at + 1] == '\n') self.peek_offset += 1;
        self.peek_offset += 1;
        const then = self.index + self.peek_offset;
        return if (then < self.source.len) self.source[then] else eof;
    }

    test peek {
        var stream = Stream.init("abc");
        try testing.expectEqual(@as(?u8, 'b'), stream.peek());
        try testing.expectEqual(@as(?u8, 'c'), stream.peek());
        // Looking ahead never moves the cursor.
        try testing.expectEqual(@as(usize, 0), stream.index);
    }

    /// Wind the lookahead back to `offset` characters past the cursor.
    pub fn resetPeek(self: *Stream, offset: usize) void {
        self.peek_offset = offset;
    }

    test resetPeek {
        var stream = Stream.init("   x");
        _ = stream.peekBlankInline();
        try testing.expectEqual(@as(usize, 3), stream.peek_offset);
        stream.resetPeek(0);
        try testing.expectEqual(@as(usize, 0), stream.peek_offset);
    }

    /// Commit the cursor to where the lookahead reached.
    pub fn skipToPeek(self: *Stream) void {
        self.index += self.peek_offset;
        self.peek_offset = 0;
    }

    test skipToPeek {
        var stream = Stream.init("   x");
        _ = stream.peekBlankInline();
        stream.skipToPeek();
        // What the lookahead found is now behind the cursor.
        try testing.expectEqual(@as(usize, 3), stream.index);
        try testing.expectEqual(@as(?u8, 'x'), stream.currentChar());
    }

    // -- whitespace ---------------------------------------------------------

    /// Look past a run of spaces on this line, and return it.
    pub fn peekBlankInline(self: *Stream) []const u8 {
        const start = self.index + self.peek_offset;
        while (self.currentPeek() == ' ') _ = self.peek();
        return self.source[start .. self.index + self.peek_offset];
    }

    test peekBlankInline {
        var stream = Stream.init("   x");
        try testing.expectEqualStrings("   ", stream.peekBlankInline());
        // Found, but not consumed: `skipToPeek` is what commits it.
        try testing.expectEqual(@as(usize, 0), stream.index);
    }

    /// Consume a run of spaces on this line, and return it.
    pub fn skipBlankInline(self: *Stream) []const u8 {
        const blank = self.peekBlankInline();
        self.skipToPeek();
        return blank;
    }

    test skipBlankInline {
        var stream = Stream.init("   x");
        try testing.expectEqualStrings("   ", stream.skipBlankInline());
        try testing.expectEqual(@as(?u8, 'x'), stream.currentChar());
    }

    /// Look past a run of blank lines, and return the newlines in it.
    ///
    /// Stops with the lookahead at the start of the first line that has
    /// something on it, not after that line's indentation, because whoever
    /// asked still has to decide whether that indentation continues a pattern.
    pub fn peekBlankBlock(self: *Stream, buffer: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        while (true) {
            const line_start = self.peek_offset;
            _ = self.peekBlankInline();
            if (self.currentPeek() == '\n') {
                try buffer.append(gpa, '\n');
                _ = self.peek();
                continue;
            }
            // A run of spaces at the very end of the file is a blank block:
            // there is no line after it for them to be the indentation of.
            if (self.currentPeek() == eof) return;
            self.resetPeek(line_start);
            return;
        }
    }

    test peekBlankBlock {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(testing.allocator);

        var stream = Stream.init("\n\n    text");
        try stream.peekBlankBlock(&buffer, testing.allocator);
        try testing.expectEqualStrings("\n\n", buffer.items);
    }

    /// How many blank lines follow, without recording them.
    pub fn peekBlankBlockCount(self: *Stream) usize {
        var count: usize = 0;
        while (true) {
            const line_start = self.peek_offset;
            _ = self.peekBlankInline();
            if (self.currentPeek() == '\n') {
                count += 1;
                _ = self.peek();
                continue;
            }
            if (self.currentPeek() == eof) return count;
            self.resetPeek(line_start);
            return count;
        }
    }

    test peekBlankBlockCount {
        var stream = Stream.init("\n\n    text");
        try testing.expectEqual(@as(usize, 2), stream.peekBlankBlockCount());
        // It stops at the start of the line, before the indentation, because
        // whoever asked still has to decide what that indentation means.
        stream.skipToPeek();
        try testing.expectEqual(@as(?u8, ' '), stream.currentChar());
    }

    /// Consume a run of blank lines, and return how many there were.
    pub fn skipBlankBlockCount(self: *Stream) usize {
        const count = self.peekBlankBlockCount();
        self.skipToPeek();
        return count;
    }

    test skipBlankBlockCount {
        var stream = Stream.init("\n   ");
        // Spaces at the very end of the file are a blank block: there is no line
        // after them for them to be the indentation of.
        try testing.expectEqual(@as(usize, 1), stream.skipBlankBlockCount());
        try testing.expectEqual(@as(?u8, null), stream.currentChar());
    }

    /// Look past whitespace of any kind, spaces and newlines alike.
    pub fn peekBlank(self: *Stream) void {
        while (self.currentPeek() == ' ' or self.currentPeek() == '\n') _ = self.peek();
    }

    test peekBlank {
        var stream = Stream.init(" \n \n x");
        stream.peekBlank();
        try testing.expectEqual(@as(?u8, 'x'), stream.currentPeek());
        try testing.expectEqual(@as(usize, 0), stream.index);
    }

    /// Consume whitespace of any kind, spaces and newlines alike.
    pub fn skipBlank(self: *Stream) void {
        self.peekBlank();
        self.skipToPeek();
    }

    test skipBlank {
        var stream = Stream.init(" \n \n x");
        stream.skipBlank();
        try testing.expectEqual(@as(?u8, 'x'), stream.currentChar());
    }

    // -- expectations -------------------------------------------------------

    /// Consume `ch`, or fail with E0003 naming it.
    pub fn expectChar(self: *Stream, ch: u8) Error!void {
        if (self.currentChar() == ch) {
            _ = self.next();
            return;
        }
        return self.fail(.E0003, &[_]u8{ch});
    }

    test expectChar {
        var stream = Stream.init("=v");
        try stream.expectChar('=');
        try testing.expectEqual(@as(?u8, 'v'), stream.currentChar());

        try testing.expectError(error.ParseError, stream.expectChar('='));
        try testing.expectEqual(errors.Code.E0003, stream.pending.code);
    }

    /// Consume a line ending, of which the end of the file is one.
    pub fn expectLineEnd(self: *Stream) Error!void {
        if (self.currentChar() == eof) return; // The end of the file ends a line.
        if (self.currentChar() == '\n') {
            _ = self.next();
            return;
        }
        // U+2424 SYMBOL FOR NEWLINE, which is how Fluent names a newline in an
        // error message without putting one in it.
        return self.fail(.E0003, "\u{2424}");
    }

    test expectLineEnd {
        var newline = Stream.init("\nnext");
        try newline.expectLineEnd();
        try testing.expectEqual(@as(?u8, 'n'), newline.currentChar());

        // The end of the file ends a line, which is why a resource need not end
        // with a newline.
        var end_of_file = Stream.init("");
        try end_of_file.expectLineEnd();

        var other = Stream.init("x");
        try testing.expectError(error.ParseError, other.expectLineEnd());
    }

    /// Consume the current character if it satisfies `pred`, and return it.
    pub fn takeChar(self: *Stream, comptime pred: fn (u8) bool) ?u8 {
        const ch = self.currentChar() orelse return null;
        if (pred(ch)) {
            _ = self.next();
            return ch;
        }
        return null;
    }

    test takeChar {
        const isDigitChar = struct {
            /// The predicate `takeChar` is being shown with.
            fn f(c: u8) bool {
                return std.ascii.isDigit(c);
            }
        }.f;

        var stream = Stream.init("7x");
        try testing.expectEqual(@as(?u8, '7'), stream.takeChar(isDigitChar));
        // The predicate failed, so nothing was consumed.
        try testing.expectEqual(@as(?u8, null), stream.takeChar(isDigitChar));
        try testing.expectEqual(@as(?u8, 'x'), stream.currentChar());
    }

    // -- character classes --------------------------------------------------

    /// Whether `ch` may begin an identifier: an ASCII letter.
    pub fn isCharIdStart(ch: ?u8) bool {
        const c = ch orelse return false;
        return std.ascii.isAlphabetic(c);
    }

    test isCharIdStart {
        try testing.expect(Stream.isCharIdStart('a'));
        try testing.expect(Stream.isCharIdStart('Z'));
        try testing.expect(!Stream.isCharIdStart('1'));
        try testing.expect(!Stream.isCharIdStart('-'));
        try testing.expect(!Stream.isCharIdStart(null));
    }

    /// Whether `ch` may appear in an identifier after its first character.
    fn isIdChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
    }

    /// Whether `ch` is a decimal digit.
    fn isDigit(ch: u8) bool {
        return std.ascii.isDigit(ch);
    }

    /// Whether `ch` is a hexadecimal digit, in either case.
    fn isHexDigit(ch: u8) bool {
        return std.ascii.isHex(ch);
    }

    /// Consume the first character of an identifier, or fail with E0004.
    pub fn takeIdStart(self: *Stream) Error!u8 {
        if (isCharIdStart(self.currentChar())) {
            const ret = self.currentChar().?;
            _ = self.next();
            return ret;
        }
        return self.fail(.E0004, "a-zA-Z");
    }

    test takeIdStart {
        var stream = Stream.init("name");
        try testing.expectEqual(@as(u8, 'n'), try stream.takeIdStart());

        var digit = Stream.init("1bad");
        try testing.expectError(error.ParseError, digit.takeIdStart());
        try testing.expectEqual(errors.Code.E0004, digit.pending.code);
    }

    /// Consume a character that may appear after the first of an identifier.
    pub fn takeIdChar(self: *Stream) ?u8 {
        return self.takeChar(isIdChar);
    }

    test takeIdChar {
        var stream = Stream.init("a_1-!");
        for ("a_1-") |expected| {
            try testing.expectEqual(@as(?u8, expected), stream.takeIdChar());
        }
        try testing.expectEqual(@as(?u8, null), stream.takeIdChar());
    }

    /// Consume one decimal digit, if there is one.
    pub fn takeDigit(self: *Stream) ?u8 {
        return self.takeChar(isDigit);
    }

    test takeDigit {
        var stream = Stream.init("42x");
        try testing.expectEqual(@as(?u8, '4'), stream.takeDigit());
        try testing.expectEqual(@as(?u8, '2'), stream.takeDigit());
        try testing.expectEqual(@as(?u8, null), stream.takeDigit());
    }

    /// Consume one hexadecimal digit, if there is one.
    pub fn takeHexDigit(self: *Stream) ?u8 {
        return self.takeChar(isHexDigit);
    }

    test takeHexDigit {
        var stream = Stream.init("aF0g");
        for ("aF0") |expected| {
            try testing.expectEqual(@as(?u8, expected), stream.takeHexDigit());
        }
        try testing.expectEqual(@as(?u8, null), stream.takeHexDigit());
    }

    // -- what comes next ----------------------------------------------------

    /// Whether an identifier begins under the lookahead.
    pub fn isIdentifierStart(self: Stream) bool {
        return isCharIdStart(self.currentPeek());
    }

    test isIdentifierStart {
        try testing.expect((Stream.init("name = v")).isIdentifierStart());
        try testing.expect(!(Stream.init("-term = v")).isIdentifierStart());
        try testing.expect(!(Stream.init("# comment")).isIdentifierStart());
    }

    /// Whether a number begins here, counting a leading minus sign.
    pub fn isNumberStart(self: *Stream) bool {
        const ch = if (self.currentChar() == '-') self.peek() else self.currentChar();
        defer self.resetPeek(0);
        const c = ch orelse return false;
        return std.ascii.isDigit(c);
    }

    test isNumberStart {
        var negative = Stream.init("-1");
        try testing.expect(negative.isNumberStart());
        // The lookahead is wound back, so the caller starts where it left off.
        try testing.expectEqual(@as(usize, 0), negative.peek_offset);

        var term = Stream.init("-term");
        try testing.expect(!term.isNumberStart());

        var bare = Stream.init("-");
        try testing.expect(!bare.isNumberStart());
    }

    /// The characters that cannot begin a continuation line of a pattern.
    ///
    /// Each is already the start of something else at that position: `}` a
    /// stray brace, `.` an attribute, `[` and `*` a variant. Forbidding them
    /// is what lets a multi-line pattern end without a terminator.
    fn isCharPatternContinuation(ch: ?u8) bool {
        const c = ch orelse return false;
        return c != '}' and c != '.' and c != '[' and c != '*';
    }

    /// Whether a value begins right here, on the same line as the `=`.
    pub fn isValueStart(self: Stream) bool {
        const ch = self.currentPeek();
        return ch != '\n' and ch != eof;
    }

    test isValueStart {
        // Anything at all may begin a value on the `=` line...
        try testing.expect((Stream.init("Hello")).isValueStart());
        // ...except the end of that line, or of the file.
        try testing.expect(!(Stream.init("\n    Hello")).isValueStart());
        try testing.expect(!(Stream.init("")).isValueStart());
    }

    /// Whether the line the lookahead is on continues the pattern above it.
    pub fn isValueContinuation(self: *Stream) bool {
        const column1 = self.peek_offset;
        _ = self.peekBlankInline();

        // A placeable may begin at column 1, since there is no way to mistake
        // a brace for the start of another entry.
        if (self.currentPeek() == '{') {
            self.resetPeek(column1);
            return true;
        }
        // Anything else has to be indented, or it is a new entry.
        if (self.peek_offset - column1 == 0) return false;

        if (isCharPatternContinuation(self.currentPeek())) {
            self.resetPeek(column1);
            return true;
        }
        return false;
    }

    test isValueContinuation {
        // Indented text continues the pattern above.
        var indented = Stream.init("\n    more");
        _ = indented.peekBlankBlockCount();
        try testing.expect(indented.isValueContinuation());

        // A placeable may begin at column 1: no brace can be mistaken for the
        // start of another entry.
        var brace = Stream.init("\n{ $x }");
        _ = brace.peekBlankBlockCount();
        try testing.expect(brace.isValueContinuation());

        // An indented `.` is an attribute, not more of the value.
        var attribute = Stream.init("\n    .label = x");
        _ = attribute.peekBlankBlockCount();
        try testing.expect(!attribute.isValueContinuation());

        // And an unindented word is the next entry.
        var entry = Stream.init("\nnext = x");
        _ = entry.peekBlankBlockCount();
        try testing.expect(!entry.isValueContinuation());
    }

    /// Whether the next line is a comment of the given depth.
    ///
    /// `level` is the number of `#` beyond the first, so 0 is `#`, 1 is `##`
    /// and 2 is `###`; null means any depth will do. The depth has to match
    /// exactly, because `##` below a `#` starts a new comment rather than
    /// continuing the one above.
    pub fn isNextLineComment(self: *Stream, level: ?u8) bool {
        if (self.currentChar() != '\n') return false;
        defer self.resetPeek(0);

        var i: u8 = 0;
        while (if (level) |l| i <= l else i < 3) {
            if (self.peek() != '#') {
                if (level) |l| if (i <= l) return false;
                break;
            }
            i += 1;
        }

        // What follows the `#`s has to be a space or the end of the line;
        // `#comment` with no space is not a comment.
        const ch = self.peek();
        return ch == ' ' or ch == '\n' or ch == eof;
    }

    test isNextLineComment {
        // Depth has to match exactly: `##` below `#` starts a new comment rather
        // than continuing the one above.
        var same = Stream.init("\n# more");
        try testing.expect(same.isNextLineComment(0));

        var deeper = Stream.init("\n## group");
        try testing.expect(!deeper.isNextLineComment(0));
        try testing.expect(deeper.isNextLineComment(1));

        // `#comment` with no space is not a comment line at all.
        var tight = Stream.init("\n#tight");
        try testing.expect(!tight.isNextLineComment(0));
    }

    /// Whether a variant begins under the lookahead, `*` and all.
    pub fn isVariantStart(self: *Stream) bool {
        const saved = self.peek_offset;
        defer self.resetPeek(saved);
        if (self.currentPeek() == '*') _ = self.peek();
        return self.currentPeek() == '[';
    }

    test isVariantStart {
        var plain = Stream.init("[one] a");
        try testing.expect(plain.isVariantStart());

        var default = Stream.init("*[other] a");
        try testing.expect(default.isVariantStart());

        var text = Stream.init("text");
        try testing.expect(!text.isVariantStart());
    }

    /// Whether an attribute begins under the lookahead.
    pub fn isAttributeStart(self: Stream) bool {
        return self.currentPeek() == '.';
    }

    test isAttributeStart {
        try testing.expect((Stream.init(".label = x")).isAttributeStart());
        try testing.expect(!(Stream.init("label = x")).isAttributeStart());
    }

    /// Move the cursor to something that looks like it could start an entry.
    ///
    /// This is the whole of Fluent's error recovery. Everything skipped over
    /// becomes junk, and the file carries on being parsed after it, so a
    /// translator who breaks one message does not lose the rest of the file.
    ///
    /// The rewind at the top matters: the parser usually fails part-way
    /// through a line, and without rewinding to the start of that line the
    /// junk would begin in the middle of it. It only rewinds when the newline
    /// it finds is after the point the entry began, since otherwise it would
    /// land back inside the entry it is trying to get past and loop.
    pub fn skipToNextEntryStart(self: *Stream, junk_start: usize) void {
        if (std.mem.lastIndexOfScalar(u8, self.source[0..@min(self.index, self.source.len)], '\n')) |last_newline| {
            if (junk_start < last_newline) self.index = last_newline;
        }

        while (self.currentChar() != eof) {
            if (self.currentChar() != '\n') {
                _ = self.next();
                continue;
            }
            const first = self.next();
            if (isCharIdStart(first) or first == '-' or first == '#') break;
        }
    }

    test skipToNextEntryStart {
        var stream = Stream.init("broken = { $x\nnext = fine\n");
        stream.index = 13; // where the parser gave up, part-way through the line
        stream.skipToNextEntryStart(0);

        // It rewinds to the start of the broken line, so the junk begins where the
        // entry did rather than in the middle of it, and stops at the next thing
        // that could start an entry.
        try testing.expectEqualStrings("broken = { $x\n", stream.source[0..stream.index]);
    }
};
