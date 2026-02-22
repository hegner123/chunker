//! Unit tests for ndjson.zig: NDJSON format detection, line indexing, and operations.
const std = @import("std");
const chunker = @import("chunker");
const ndjson = chunker.ndjson;
const types = chunker.types;

// -- buildLineIndex tests --

test "buildLineIndex - basic 3-line NDJSON" {
    const buffer = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), index.line_count);

    // Verify each line span points to the right value.
    const line0 = index.lineSpan(0);
    try std.testing.expectEqualStrings("{\"a\":1}", buffer[line0.start..line0.end]);

    const line1 = index.lineSpan(1);
    try std.testing.expectEqualStrings("{\"b\":2}", buffer[line1.start..line1.end]);

    const line2 = index.lineSpan(2);
    try std.testing.expectEqualStrings("{\"c\":3}", buffer[line2.start..line2.end]);
}

test "buildLineIndex - empty lines skipped" {
    const buffer = "{\"a\":1}\n\n{\"b\":2}\n\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), index.line_count);

    const line0 = index.lineSpan(0);
    try std.testing.expectEqualStrings("{\"a\":1}", buffer[line0.start..line0.end]);

    const line1 = index.lineSpan(1);
    try std.testing.expectEqualStrings("{\"b\":2}", buffer[line1.start..line1.end]);
}

test "buildLineIndex - trailing newline" {
    const buffer = "{\"x\":1}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), index.line_count);
}

test "buildLineIndex - single line no trailing newline" {
    const buffer = "{\"x\":1}";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), index.line_count);
    const line0 = index.lineSpan(0);
    try std.testing.expectEqualStrings("{\"x\":1}", buffer[line0.start..line0.end]);
}

test "buildLineIndex - invalid line returns error" {
    const buffer = "{\"a\":1}\nINVALID\n";
    const result = ndjson.buildLineIndex(std.testing.allocator, buffer);
    try std.testing.expectError(types.ScanError.UnexpectedByte, result);
}

test "buildLineIndex - CRLF line endings" {
    const buffer = "{\"a\":1}\r\n{\"b\":2}\r\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), index.line_count);

    const line0 = index.lineSpan(0);
    try std.testing.expectEqualStrings("{\"a\":1}", buffer[line0.start..line0.end]);

    const line1 = index.lineSpan(1);
    try std.testing.expectEqualStrings("{\"b\":2}", buffer[line1.start..line1.end]);
}

// -- detectFormat tests --

test "detectFormat - standard JSON detected as json" {
    const buffer = "{\"key\":\"value\"}";
    const format = try ndjson.detectFormat(buffer);
    try std.testing.expectEqual(ndjson.FileFormat.json, format);
}

test "detectFormat - JSON array detected as json" {
    const buffer = "[1,2,3]";
    const format = try ndjson.detectFormat(buffer);
    try std.testing.expectEqual(ndjson.FileFormat.json, format);
}

test "detectFormat - multi-line NDJSON detected as ndjson" {
    const buffer = "{\"a\":1}\n{\"b\":2}\n";
    const format = try ndjson.detectFormat(buffer);
    try std.testing.expectEqual(ndjson.FileFormat.ndjson, format);
}

test "detectFormat - single-line JSON treated as json" {
    const buffer = "{\"a\":1}\n";
    const format = try ndjson.detectFormat(buffer);
    try std.testing.expectEqual(ndjson.FileFormat.json, format);
}

test "detectFormat - JSON with trailing whitespace is json" {
    const buffer = "{\"a\":1}  \n  ";
    const format = try ndjson.detectFormat(buffer);
    try std.testing.expectEqual(ndjson.FileFormat.json, format);
}

// -- ndjsonInspect tests --

test "ndjsonInspect - line count and first line type" {
    const buffer = "{\"name\":\"Alice\",\"age\":30}\n{\"name\":\"Bob\",\"age\":25}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = try ndjson.ndjsonInspect(std.testing.allocator, buffer, &index, "test.ndjson", 50);
    defer {
        for (result.sample_keys) |k| std.testing.allocator.free(k);
        std.testing.allocator.free(result.sample_keys);
    }

    try std.testing.expectEqual(@as(u32, 2), result.line_count);
    try std.testing.expectEqual(types.ValueType.object, result.first_line_type);
    try std.testing.expectEqual(@as(usize, 2), result.sample_keys.len);
    try std.testing.expectEqualStrings("name", result.sample_keys[0]);
    try std.testing.expectEqualStrings("age", result.sample_keys[1]);
}

test "ndjsonInspect - array lines have no sample keys" {
    const buffer = "[1,2,3]\n[4,5,6]\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = try ndjson.ndjsonInspect(std.testing.allocator, buffer, &index, "arrays.ndjson", 30);

    try std.testing.expectEqual(@as(u32, 2), result.line_count);
    try std.testing.expectEqual(types.ValueType.array, result.first_line_type);
    try std.testing.expectEqual(@as(usize, 0), result.sample_keys.len);
}

// -- ndjsonRead tests --

test "ndjsonRead - empty path packs all lines into chunks" {
    const buffer = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = try ndjson.ndjsonRead(std.testing.allocator, buffer, &index, "", 0, 10000);
    defer std.testing.allocator.free(result.data);

    try std.testing.expectEqual(@as(u32, 0), result.chunk_index);
    try std.testing.expectEqual(@as(u32, 1), result.total_chunks);
    // All three lines packed into one chunk as a JSON array.
    try std.testing.expectEqualStrings("[{\"a\":1},{\"b\":2},{\"c\":3}]", result.data);
}

test "ndjsonRead - chunking splits lines by byte budget" {
    const buffer = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    // Each line is 7 bytes compact. With chunk_size=8, each line gets its own chunk.
    const result0 = try ndjson.ndjsonRead(std.testing.allocator, buffer, &index, "", 0, 8);
    defer std.testing.allocator.free(result0.data);

    try std.testing.expectEqual(@as(u32, 3), result0.total_chunks);
    try std.testing.expectEqualStrings("[{\"a\":1}]", result0.data);

    const result1 = try ndjson.ndjsonRead(std.testing.allocator, buffer, &index, "", 1, 8);
    defer std.testing.allocator.free(result1.data);
    try std.testing.expectEqualStrings("[{\"b\":2}]", result1.data);
}

test "ndjsonRead - chunk out of range" {
    const buffer = "{\"a\":1}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = ndjson.ndjsonRead(std.testing.allocator, buffer, &index, "", 5, 10000);
    try std.testing.expectError(error.ChunkOutOfRange, result);
}

test "ndjsonRead - path [N] reads specific line" {
    const buffer = "{\"x\":10}\n{\"x\":20}\n{\"x\":30}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = try ndjson.ndjsonRead(std.testing.allocator, buffer, &index, "[1]", 0, 10000);
    defer std.testing.allocator.free(result.data);

    // Line 1 is {"x":20}, read as a single chunk.
    try std.testing.expectEqual(@as(u32, 1), result.total_chunks);
}

test "ndjsonRead - path [N].key navigates within line" {
    const buffer = "{\"name\":\"Alice\",\"items\":[1,2,3]}\n{\"name\":\"Bob\"}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = try ndjson.ndjsonRead(std.testing.allocator, buffer, &index, "[0].items", 0, 10000);
    defer std.testing.allocator.free(result.data);

    try std.testing.expectEqualStrings("[1,2,3]", result.data);
}

test "ndjsonRead - key path without index returns error" {
    const buffer = "{\"a\":1}\n{\"b\":2}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = ndjson.ndjsonRead(std.testing.allocator, buffer, &index, "name", 0, 10000);
    try std.testing.expectError(error.EmptyNdjsonPath, result);
}

// -- ndjsonExtract tests --

test "ndjsonExtract - [N] returns whole line" {
    const buffer = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = try ndjson.ndjsonExtract(buffer, &index, "[0]");
    try std.testing.expectEqual(types.ValueType.object, result.value_type);
    try std.testing.expectEqualStrings("{\"a\":1}", result.value);
}

test "ndjsonExtract - [N].key navigates within line" {
    const buffer = "{\"name\":\"Alice\"}\n{\"name\":\"Bob\"}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = try ndjson.ndjsonExtract(buffer, &index, "[1].name");
    try std.testing.expectEqual(types.ValueType.string, result.value_type);
    try std.testing.expectEqualStrings("\"Bob\"", result.value);
}

test "ndjsonExtract - empty path returns error" {
    const buffer = "{\"a\":1}\n{\"b\":2}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = ndjson.ndjsonExtract(buffer, &index, "");
    try std.testing.expectError(error.EmptyNdjsonPath, result);
}

test "ndjsonExtract - line index out of range" {
    const buffer = "{\"a\":1}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = ndjson.ndjsonExtract(buffer, &index, "[5]");
    try std.testing.expectError(error.InvalidLineIndex, result);
}

test "ndjsonExtract - nested path within line" {
    const buffer = "{\"user\":{\"name\":\"Eve\",\"id\":42}}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    const result = try ndjson.ndjsonExtract(buffer, &index, "[0].user.name");
    try std.testing.expectEqual(types.ValueType.string, result.value_type);
    try std.testing.expectEqualStrings("\"Eve\"", result.value);
}

// -- ndjsonSearch tests --

test "ndjsonSearch - value match across lines with [N] path prefix" {
    const buffer = "{\"name\":\"Alice\"}\n{\"name\":\"Bob\"}\n{\"name\":\"Alice\"}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try ndjson.ndjsonSearch(
        arena.allocator(),
        buffer,
        &index,
        null,
        "Alice",
        10,
    );

    // Alice appears in line 0 and line 2.
    try std.testing.expect(result.matches.len >= 2);
    try std.testing.expectEqualStrings("[0].name", result.matches[0].path);
    try std.testing.expectEqualStrings("[2].name", result.matches[1].path);
}

test "ndjsonSearch - key match" {
    const buffer = "{\"error\":\"not found\"}\n{\"status\":\"ok\"}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try ndjson.ndjsonSearch(
        arena.allocator(),
        buffer,
        &index,
        "error",
        null,
        10,
    );

    try std.testing.expect(result.matches.len >= 1);
    try std.testing.expectEqualStrings("[0].error", result.matches[0].path);
}

test "ndjsonSearch - max_results respected" {
    const buffer = "{\"v\":\"match\"}\n{\"v\":\"match\"}\n{\"v\":\"match\"}\n{\"v\":\"match\"}\n{\"v\":\"match\"}\n";
    var index = try ndjson.buildLineIndex(std.testing.allocator, buffer);
    defer index.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try ndjson.ndjsonSearch(
        arena.allocator(),
        buffer,
        &index,
        null,
        "match",
        2,
    );

    try std.testing.expectEqual(@as(usize, 2), result.matches.len);
}
