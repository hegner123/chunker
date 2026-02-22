//! Core types for the chunker scanner and domain operations.
//!
//! All position types use u32, which is sufficient for files up to 4 GiB
//! (max_file_size is 1 GiB). Spans reference byte ranges in the mmap buffer.
//! Error sets are explicit -- no anyerror in production code.
const std = @import("std");
const config = @import("config.zig");

/// Byte position within the memory-mapped file buffer.
pub const Pos = u32;

/// A half-open byte range [start, end) in the buffer.
/// For JSON values, the span includes delimiters: quotes for strings,
/// braces/brackets for containers.
pub const Span = struct {
    start: Pos,
    end: Pos,

    /// Returns the number of bytes in this span.
    pub fn len(self: Span) u32 {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start;
    }

    /// Returns the slice of bytes from the buffer for this span.
    pub fn slice(self: Span, buffer: []const u8) []const u8 {
        std.debug.assert(self.end >= self.start);
        std.debug.assert(self.end <= buffer.len);
        return buffer[self.start..self.end];
    }
};

/// JSON value type classification, determined by the first non-whitespace byte.
pub const ValueType = enum {
    array,
    object,
    string,
    number,
    boolean,
    null_type,

    /// Returns the single-character abbreviation used in MCP output.
    pub fn abbreviation(self: ValueType) u8 {
        return switch (self) {
            .array => 'a',
            .object => 'o',
            .string => 's',
            .number => 'n',
            .boolean => 'b',
            .null_type => 'z',
        };
    }
};

/// A key-value pair in an object, with spans for both the key and value.
/// Used during object chunking for sorting and size calculation.
pub const Element = struct {
    key_span: Span,
    value_span: Span,
};

/// A segment in a dot-notation path: either an object key or an array index.
pub const PathSegment = union(enum) {
    key: []const u8,
    index: u32,
};

/// Stack-allocated path segment buffer for navigatePath.
pub const PathBuf = struct {
    segments: [config.max_path_segments]PathSegment,
    length: u16,
};

/// A single search match result.
pub const SearchMatch = struct {
    path: []const u8,
    value_type: ValueType,
    preview: []const u8,
};

/// Errors returned by the byte-level JSON scanner.
/// Every error variant corresponds to a specific structural violation.
pub const ScanError = error{
    /// Input ended before a complete JSON value was found.
    UnexpectedEndOfInput,
    /// A byte was encountered that cannot begin a JSON value or is invalid
    /// in its current position (e.g., unescaped control character in string).
    UnexpectedByte,
    /// An escape sequence in a string is not one of the eight valid JSON escapes.
    InvalidEscape,
    /// A \uXXXX escape does not have exactly 4 hex digits following \u.
    InvalidUnicodeEscape,
    /// A number does not conform to RFC 8259 (e.g., leading zeros, trailing dot).
    InvalidNumber,
    /// A literal (true, false, null) is misspelled or truncated.
    InvalidLiteral,
    /// Closing bracket/brace does not match the opening one (e.g., [}).
    MismatchedBracket,
    /// Nesting depth exceeds max_nesting_depth (256).
    NestingDepthExceeded,
    /// Trailing non-whitespace content after the root value.
    TrailingContent,
};

/// Errors returned by path parsing and navigation.
pub const PathError = error{
    /// A path segment is empty (e.g., "a..b").
    EmptySegment,
    /// An array index is not a valid non-negative integer.
    InvalidIndex,
    /// Too many path segments (exceeds max_path_segments).
    TooManySegments,
    /// Array index is out of range for the target array.
    IndexOutOfRange,
    /// A key segment was used on a non-object value.
    NotAnObject,
    /// An index segment was used on a non-array value.
    NotAnArray,
    /// The specified key was not found in the object.
    KeyNotFound,
};

/// Bracket type for the scanner's nesting stack.
pub const BracketKind = enum(u1) {
    array = 0,
    object = 1,
};
