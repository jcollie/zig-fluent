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

    pub fn init(source: []const u8) Stream {
        return .{ .source = source };
    }

    /// Raise a parse error, recording the code and where the parser gave up.
    pub fn fail(self: *Stream, code: errors.Code, argument: ?[]const u8) Error {
        self.pending = .{ .code = code, .argument = argument, .position = self.index };
        return error.ParseError;
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

    pub fn currentChar(self: Stream) ?u8 {
        return self.charAt(self.index);
    }

    pub fn currentPeek(self: Stream) ?u8 {
        return self.charAt(self.index + self.peek_offset);
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

    pub fn resetPeek(self: *Stream, offset: usize) void {
        self.peek_offset = offset;
    }

    /// Commit the cursor to where the lookahead reached.
    pub fn skipToPeek(self: *Stream) void {
        self.index += self.peek_offset;
        self.peek_offset = 0;
    }

    // -- whitespace ---------------------------------------------------------

    /// Look past a run of spaces on this line, and return it.
    pub fn peekBlankInline(self: *Stream) []const u8 {
        const start = self.index + self.peek_offset;
        while (self.currentPeek() == ' ') _ = self.peek();
        return self.source[start .. self.index + self.peek_offset];
    }

    pub fn skipBlankInline(self: *Stream) []const u8 {
        const blank = self.peekBlankInline();
        self.skipToPeek();
        return blank;
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

    pub fn skipBlankBlockCount(self: *Stream) usize {
        const count = self.peekBlankBlockCount();
        self.skipToPeek();
        return count;
    }

    /// Look past whitespace of any kind, spaces and newlines alike.
    pub fn peekBlank(self: *Stream) void {
        while (self.currentPeek() == ' ' or self.currentPeek() == '\n') _ = self.peek();
    }

    pub fn skipBlank(self: *Stream) void {
        self.peekBlank();
        self.skipToPeek();
    }

    // -- expectations -------------------------------------------------------

    pub fn expectChar(self: *Stream, ch: u8) Error!void {
        if (self.currentChar() == ch) {
            _ = self.next();
            return;
        }
        return self.fail(.E0003, &[_]u8{ch});
    }

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

    /// Consume the current character if it satisfies `pred`, and return it.
    pub fn takeChar(self: *Stream, comptime pred: fn (u8) bool) ?u8 {
        const ch = self.currentChar() orelse return null;
        if (pred(ch)) {
            _ = self.next();
            return ch;
        }
        return null;
    }

    // -- character classes --------------------------------------------------

    pub fn isCharIdStart(ch: ?u8) bool {
        const c = ch orelse return false;
        return std.ascii.isAlphabetic(c);
    }

    fn isIdChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
    }

    fn isDigit(ch: u8) bool {
        return std.ascii.isDigit(ch);
    }

    fn isHexDigit(ch: u8) bool {
        return std.ascii.isHex(ch);
    }

    pub fn takeIdStart(self: *Stream) Error!u8 {
        if (isCharIdStart(self.currentChar())) {
            const ret = self.currentChar().?;
            _ = self.next();
            return ret;
        }
        return self.fail(.E0004, "a-zA-Z");
    }

    pub fn takeIdChar(self: *Stream) ?u8 {
        return self.takeChar(isIdChar);
    }

    pub fn takeDigit(self: *Stream) ?u8 {
        return self.takeChar(isDigit);
    }

    pub fn takeHexDigit(self: *Stream) ?u8 {
        return self.takeChar(isHexDigit);
    }

    // -- what comes next ----------------------------------------------------

    pub fn isIdentifierStart(self: Stream) bool {
        return isCharIdStart(self.currentPeek());
    }

    pub fn isNumberStart(self: *Stream) bool {
        const ch = if (self.currentChar() == '-') self.peek() else self.currentChar();
        defer self.resetPeek(0);
        const c = ch orelse return false;
        return std.ascii.isDigit(c);
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

    pub fn isVariantStart(self: *Stream) bool {
        const saved = self.peek_offset;
        defer self.resetPeek(saved);
        if (self.currentPeek() == '*') _ = self.peek();
        return self.currentPeek() == '[';
    }

    pub fn isAttributeStart(self: Stream) bool {
        return self.currentPeek() == '.';
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
};

const testing = std.testing;

test "a CRLF reads as one newline" {
    var s = Stream.init("a\r\nb");
    try testing.expectEqual(@as(?u8, 'a'), s.currentChar());
    _ = s.next();
    try testing.expectEqual(@as(?u8, '\n'), s.currentChar());
    try testing.expectEqual(@as(usize, 1), s.index);
    _ = s.next();
    try testing.expectEqual(@as(?u8, 'b'), s.currentChar());
    try testing.expectEqual(@as(usize, 3), s.index);
}

test "a lone carriage return is an ordinary character" {
    var s = Stream.init("a\rb");
    _ = s.next();
    try testing.expectEqual(@as(?u8, '\r'), s.currentChar());
}

test "peeking can be wound back" {
    var s = Stream.init("   x");
    _ = s.peekBlankInline();
    try testing.expectEqual(@as(usize, 3), s.peek_offset);
    s.resetPeek(0);
    try testing.expectEqual(@as(usize, 0), s.peek_offset);
    _ = s.skipBlankInline();
    try testing.expectEqual(@as(usize, 3), s.index);
}

test "a blank block stops at the start of the next non-blank line" {
    var s = Stream.init("\n\n    text");
    const count = s.skipBlankBlockCount();
    try testing.expectEqual(@as(usize, 2), count);
    // Stopped before the indentation, not after it.
    try testing.expectEqual(@as(?u8, ' '), s.currentChar());
}

test "trailing spaces at the end of the file are a blank block" {
    var s = Stream.init("\n   ");
    try testing.expectEqual(@as(usize, 1), s.skipBlankBlockCount());
    try testing.expectEqual(@as(?u8, null), s.currentChar());
}

test "a number may start with a minus sign" {
    var one = Stream.init("-1");
    try testing.expect(one.isNumberStart());
    try testing.expectEqual(@as(usize, 0), one.peek_offset);
    var word = Stream.init("-term");
    try testing.expect(!word.isNumberStart());
    var bare = Stream.init("-");
    try testing.expect(!bare.isNumberStart());
}
