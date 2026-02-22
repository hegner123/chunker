//! Unit tests for extract.zig: value extraction by path.
const std = @import("std");
const chunker = @import("chunker");
const extract_mod = chunker.extract;

test "extract - root value" {
    const buffer = "{\"a\":1}";
    const result = try extract_mod.extract(buffer, "");

    try std.testing.expectEqualStrings("", result.path);
    try std.testing.expectEqual(chunker.types.ValueType.object, result.value_type);
    try std.testing.expectEqualStrings("{\"a\":1}", result.value);
    try std.testing.expectEqual(@as(u32, 7), result.size);
}

test "extract - nested path" {
    const buffer = "{\"users\":[{\"name\":\"Alice\"}]}";
    const result = try extract_mod.extract(buffer, "users[0].name");

    try std.testing.expectEqual(chunker.types.ValueType.string, result.value_type);
    try std.testing.expectEqualStrings("\"Alice\"", result.value);
    try std.testing.expectEqual(@as(u32, 7), result.size);
}

test "extract - array element" {
    const buffer = "[10,20,30]";
    const result = try extract_mod.extract(buffer, "[1]");

    try std.testing.expectEqual(chunker.types.ValueType.number, result.value_type);
    try std.testing.expectEqualStrings("20", result.value);
}

test "extract - scalar at path" {
    const buffer = "{\"count\":42}";
    const result = try extract_mod.extract(buffer, "count");

    try std.testing.expectEqual(chunker.types.ValueType.number, result.value_type);
    try std.testing.expectEqualStrings("42", result.value);
    try std.testing.expectEqual(@as(u32, 2), result.size);
}

test "extract - boolean value" {
    const buffer = "{\"active\":true}";
    const result = try extract_mod.extract(buffer, "active");

    try std.testing.expectEqual(chunker.types.ValueType.boolean, result.value_type);
    try std.testing.expectEqualStrings("true", result.value);
}

test "extract - null value" {
    const buffer = "{\"data\":null}";
    const result = try extract_mod.extract(buffer, "data");

    try std.testing.expectEqual(chunker.types.ValueType.null_type, result.value_type);
    try std.testing.expectEqualStrings("null", result.value);
}

test "extract - key not found" {
    const buffer = "{\"a\":1}";
    const result = extract_mod.extract(buffer, "missing");
    try std.testing.expectError(chunker.types.PathError.KeyNotFound, result);
}

test "extract - index out of range" {
    const buffer = "[1,2]";
    const result = extract_mod.extract(buffer, "[5]");
    try std.testing.expectError(chunker.types.PathError.IndexOutOfRange, result);
}

test "extract - pretty-printed value" {
    const buffer =
        \\{
        \\  "items": [
        \\    1,
        \\    2
        \\  ]
        \\}
    ;
    const result = try extract_mod.extract(buffer, "items");

    try std.testing.expectEqual(chunker.types.ValueType.array, result.value_type);
    // compactSize should reflect the compact representation.
    try std.testing.expectEqual(@as(u32, 5), result.size); // [1,2]
}
