//! Chunker entrypoint: dual-mode CLI and MCP server for JSON file access.
//!
//! Detects mode at startup: if --cli argument is present, runs as a one-shot
//! CLI tool. Otherwise, enters the MCP stdio protocol loop. Both modes use
//! the same core pipeline: mmap -> scanner -> domain operation -> output.
const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const scanner = @import("scanner.zig");
const mmap_mod = @import("mmap.zig");
const inspect_mod = @import("inspect.zig");
const read_mod = @import("read.zig");
const extract_mod = @import("extract.zig");
const search_mod = @import("search.zig");
const mcp = @import("mcp.zig");
const ndjson_mod = @import("ndjson.zig");

const JsonRpcError = mcp.JsonRpcError;
const buildErrorResponse = mcp.buildErrorResponse;
const buildSuccessResponse = mcp.buildSuccessResponse;
const buildToolContent = mcp.buildToolContent;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (hasCliArgs()) {
        return runCliMode(allocator);
    }

    return runMcpMode(allocator);
}

/// Check if CLI arguments were passed.
fn hasCliArgs() bool {
    var args = std.process.args();
    _ = args.skip(); // Skip program name.
    return args.next() != null;
}

// -- CLI Mode --

/// Parsed CLI arguments.
const CliArgs = struct {
    command: []const u8,
    file_path: []const u8,
    path_arg: []const u8 = "",
    chunk_index: u32 = 0,
    chunk_size: u32 = config.default_chunk_size,
    key_pattern: ?[]const u8 = null,
    value_pattern: ?[]const u8 = null,
    max_results: u32 = config.default_max_results,
};

/// Parses CLI arguments after --cli. Returns null on error (message written to stderr).
fn parseCliArgs(stderr_file: std.fs.File) ?CliArgs {
    var args_iter = std.process.args();
    _ = args_iter.skip(); // program name

    const cli_flag = args_iter.next() orelse {
        _ = stderr_file.write("Error: missing arguments\n") catch {};
        return null;
    };
    if (!std.mem.eql(u8, cli_flag, "--cli")) {
        _ = stderr_file.write("Error: expected --cli flag\n") catch {};
        return null;
    }

    const command = args_iter.next() orelse {
        _ = stderr_file.write("Error: missing command\n") catch {};
        return null;
    };

    var result = CliArgs{ .command = command, .file_path = "" };

    var has_file = false;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file")) {
            result.file_path = args_iter.next() orelse "";
            has_file = true;
        } else if (std.mem.eql(u8, arg, "--path")) {
            result.path_arg = args_iter.next() orelse "";
        } else if (std.mem.eql(u8, arg, "--chunk")) {
            const val = args_iter.next() orelse "0";
            result.chunk_index = std.fmt.parseInt(u32, val, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--chunk-size")) {
            const val = args_iter.next() orelse "10000";
            result.chunk_size = std.fmt.parseInt(u32, val, 10) catch config.default_chunk_size;
        } else if (std.mem.eql(u8, arg, "--key")) {
            result.key_pattern = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--value")) {
            result.value_pattern = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--max-results")) {
            const val = args_iter.next() orelse "10";
            result.max_results = std.fmt.parseInt(u32, val, 10) catch config.default_max_results;
        }
    }

    if (result.chunk_size < config.min_chunk_size) {
        result.chunk_size = config.min_chunk_size;
    }

    if (!has_file) {
        _ = stderr_file.write("Error: missing --file argument\n") catch {};
        return null;
    }

    std.debug.assert(result.file_path.len > 0 or !has_file);
    return result;
}

/// Runs the chunker as a one-shot CLI tool.
fn runCliMode(allocator: std.mem.Allocator) !u8 {
    const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    const args = parseCliArgs(stderr_file) orelse return 1;

    var mapped = mmap_mod.MappedFile.open(args.file_path) catch {
        _ = stderr_file.write("Error: could not open file\n") catch {};
        return 1;
    };
    defer mapped.close();
    const buffer = mapped.bytes();

    if (buffer.len == 0) {
        _ = stderr_file.write("Error: file is empty after BOM skip\n") catch {};
        return 1;
    }

    return dispatchCliCommand(allocator, stdout_file, stderr_file, buffer, &args, mapped.file_size);
}

/// Dispatches the parsed CLI command to the appropriate handler.
fn dispatchCliCommand(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    stderr_file: std.fs.File,
    buffer: []const u8,
    args: *const CliArgs,
    file_size: u64,
) !u8 {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(args.file_path.len > 0);

    const format = ndjson_mod.detectFormat(buffer) catch {
        _ = stderr_file.write("Error: invalid file format\n") catch {};
        return 1;
    };

    if (format == .ndjson) {
        return dispatchNdjsonCliCommand(allocator, stdout_file, stderr_file, buffer, args, file_size);
    }

    if (std.mem.eql(u8, args.command, "inspect")) {
        return cliInspect(allocator, stdout_file, stderr_file, buffer, args.file_path, file_size, args.chunk_size);
    } else if (std.mem.eql(u8, args.command, "read")) {
        return cliRead(allocator, stdout_file, stderr_file, buffer, args.path_arg, args.chunk_index, args.chunk_size);
    } else if (std.mem.eql(u8, args.command, "extract")) {
        return cliExtract(allocator, stdout_file, stderr_file, buffer, args.path_arg);
    } else if (std.mem.eql(u8, args.command, "search")) {
        return cliSearch(allocator, stdout_file, stderr_file, buffer, args.key_pattern, args.value_pattern, args.max_results);
    } else {
        _ = stderr_file.write("Error: unknown command\n") catch {};
        return 1;
    }
}

/// Dispatches NDJSON CLI commands.
fn dispatchNdjsonCliCommand(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    stderr_file: std.fs.File,
    buffer: []const u8,
    args: *const CliArgs,
    file_size: u64,
) !u8 {
    var index = ndjson_mod.buildLineIndex(allocator, buffer) catch {
        _ = stderr_file.write("Error: failed to build NDJSON line index\n") catch {};
        return 1;
    };
    defer index.deinit(allocator);

    if (std.mem.eql(u8, args.command, "inspect")) {
        return cliNdjsonInspect(allocator, stdout_file, stderr_file, buffer, &index, args.file_path, file_size);
    } else if (std.mem.eql(u8, args.command, "read")) {
        return cliNdjsonRead(allocator, stdout_file, stderr_file, buffer, &index, args.path_arg, args.chunk_index, args.chunk_size);
    } else if (std.mem.eql(u8, args.command, "extract")) {
        return cliNdjsonExtract(allocator, stdout_file, stderr_file, buffer, &index, args.path_arg);
    } else if (std.mem.eql(u8, args.command, "search")) {
        return cliNdjsonSearch(allocator, stdout_file, stderr_file, buffer, &index, args.key_pattern, args.value_pattern, args.max_results);
    } else {
        _ = stderr_file.write("Error: unknown command\n") catch {};
        return 1;
    }
}

/// CLI inspect handler.
fn cliInspect(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
    buffer: []const u8,
    file_path: []const u8,
    file_size: u64,
    chunk_size: u32,
) !u8 {
    const result = inspect_mod.inspect(allocator, buffer, file_path, file_size, chunk_size) catch {
        _ = stderr.write("Error: inspect failed\n") catch {};
        return 1;
    };
    defer if (result.keys.len > 0) allocator.free(result.keys);

    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);
    try writeInspectJson(json_buf.writer(allocator), &result);
    _ = try stdout.write(json_buf.items);
    _ = try stdout.write("\n");
    return 0;
}

/// CLI read handler.
fn cliRead(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
    buffer: []const u8,
    path_arg: []const u8,
    chunk_index: u32,
    chunk_size: u32,
) !u8 {
    const result = read_mod.readChunk(allocator, buffer, path_arg, chunk_index, chunk_size) catch {
        _ = stderr.write("Error: read failed\n") catch {};
        return 1;
    };
    defer allocator.free(result.data);

    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);
    try writeReadJson(json_buf.writer(allocator), &result);
    _ = try stdout.write(json_buf.items);
    _ = try stdout.write("\n");
    return 0;
}

/// CLI extract handler.
fn cliExtract(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
    buffer: []const u8,
    path_arg: []const u8,
) !u8 {
    const result = extract_mod.extract(buffer, path_arg) catch {
        _ = stderr.write("Error: extract failed\n") catch {};
        return 1;
    };

    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);
    try writeExtractJson(json_buf.writer(allocator), &result);
    _ = try stdout.write(json_buf.items);
    _ = try stdout.write("\n");
    return 0;
}

/// CLI search handler.
fn cliSearch(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
    buffer: []const u8,
    key_pattern: ?[]const u8,
    value_pattern: ?[]const u8,
    max_results: u32,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = search_mod.searchBuffer(
        arena.allocator(),
        buffer,
        key_pattern,
        value_pattern,
        max_results,
    ) catch {
        _ = stderr.write("Error: search failed\n") catch {};
        return 1;
    };

    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);
    try writeSearchJson(json_buf.writer(allocator), &result);
    _ = try stdout.write(json_buf.items);
    _ = try stdout.write("\n");
    return 0;
}

/// CLI NDJSON inspect handler.
fn cliNdjsonInspect(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
    buffer: []const u8,
    index: *const ndjson_mod.NdjsonIndex,
    file_path: []const u8,
    file_size: u64,
) !u8 {
    const result = ndjson_mod.ndjsonInspect(allocator, buffer, index, file_path, file_size) catch {
        _ = stderr.write("Error: NDJSON inspect failed\n") catch {};
        return 1;
    };
    defer if (result.sample_keys.len > 0) {
        for (result.sample_keys) |k| allocator.free(k);
        allocator.free(result.sample_keys);
    };

    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);
    try writeNdjsonInspectJson(json_buf.writer(allocator), &result);
    _ = try stdout.write(json_buf.items);
    _ = try stdout.write("\n");
    return 0;
}

/// CLI NDJSON read handler.
fn cliNdjsonRead(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
    buffer: []const u8,
    index: *const ndjson_mod.NdjsonIndex,
    path_arg: []const u8,
    chunk_index: u32,
    chunk_size: u32,
) !u8 {
    const result = ndjson_mod.ndjsonRead(allocator, buffer, index, path_arg, chunk_index, chunk_size) catch |err| {
        const msg: []const u8 = switch (err) {
            error.EmptyNdjsonPath => "Error: NDJSON paths must start with a line index [N] (e.g., [0] or [0].name)\n",
            error.InvalidLineIndex => "Error: line index out of range\n",
            error.ChunkOutOfRange => "Error: chunk index out of range\n",
            else => "Error: NDJSON read failed\n",
        };
        _ = stderr.write(msg) catch {};
        return 1;
    };
    defer allocator.free(result.data);

    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);
    try writeReadJson(json_buf.writer(allocator), &result);
    _ = try stdout.write(json_buf.items);
    _ = try stdout.write("\n");
    return 0;
}

/// CLI NDJSON extract handler.
fn cliNdjsonExtract(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
    buffer: []const u8,
    index: *const ndjson_mod.NdjsonIndex,
    path_arg: []const u8,
) !u8 {
    const result = ndjson_mod.ndjsonExtract(buffer, index, path_arg) catch |err| {
        const msg: []const u8 = switch (err) {
            error.EmptyNdjsonPath => "Error: NDJSON extract requires a path starting with [N] (e.g., [0] or [0].name)\n",
            error.InvalidLineIndex => "Error: line index out of range\n",
            error.KeyNotFound => "Error: key not found at path\n",
            error.IndexOutOfRange => "Error: index out of range at path\n",
            else => "Error: NDJSON extract failed\n",
        };
        _ = stderr.write(msg) catch {};
        return 1;
    };

    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);
    try writeExtractJson(json_buf.writer(allocator), &result);
    _ = try stdout.write(json_buf.items);
    _ = try stdout.write("\n");
    return 0;
}

/// CLI NDJSON search handler.
fn cliNdjsonSearch(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
    buffer: []const u8,
    index: *const ndjson_mod.NdjsonIndex,
    key_pattern: ?[]const u8,
    value_pattern: ?[]const u8,
    max_results: u32,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = ndjson_mod.ndjsonSearch(
        arena.allocator(),
        buffer,
        index,
        key_pattern,
        value_pattern,
        max_results,
    ) catch {
        _ = stderr.write("Error: NDJSON search failed\n") catch {};
        return 1;
    };

    var json_buf = std.ArrayList(u8){};
    defer json_buf.deinit(allocator);
    try writeSearchJson(json_buf.writer(allocator), &result);
    _ = try stdout.write(json_buf.items);
    _ = try stdout.write("\n");
    return 0;
}

// -- MCP Mode --

/// Validated JSON-RPC request fields extracted during parsing.
const McpRequest = struct {
    id: ?std.json.Value,
    method: []const u8,
    is_notification: bool,
};

/// Sends a JSON-RPC error response on stdout. Errors are silently dropped.
fn sendErrorResponse(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    id: ?std.json.Value,
    code: i32,
    message: []const u8,
) void {
    const resp = buildErrorResponse(allocator, id, code, message) catch return;
    defer allocator.free(resp);
    _ = stdout.write(resp) catch {};
    _ = stdout.write("\n") catch {};
}

/// Validates jsonrpc version and extracts method from a parsed JSON-RPC object.
/// Returns null and sends an error response if validation fails.
fn validateJsonRpc(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    obj: std.json.ObjectMap,
) ?McpRequest {
    const request_id = obj.get("id");

    if (obj.get("jsonrpc")) |jsonrpc| {
        if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
            sendErrorResponse(allocator, stdout, request_id, JsonRpcError.INVALID_REQUEST, "Invalid Request: 'jsonrpc' must be '2.0'");
            return null;
        }
    } else {
        sendErrorResponse(allocator, stdout, request_id, JsonRpcError.INVALID_REQUEST, "Invalid Request: missing 'jsonrpc' field");
        return null;
    }

    const method = if (obj.get("method")) |m| m.string else {
        sendErrorResponse(allocator, stdout, request_id, JsonRpcError.INVALID_REQUEST, "Invalid Request: missing 'method' field");
        return null;
    };

    return .{
        .id = request_id,
        .method = method,
        .is_notification = mcp.isNotification(method),
    };
}

/// Handles a notification (no response required). Updates cancellation tracker
/// and advances protocol state.
fn handleNotification(
    parsed: std.json.Value,
    method: []const u8,
    cancellation_tracker: *mcp.CancellationTracker,
    protocol_state: *mcp.ProtocolState,
) void {
    if (std.mem.eql(u8, method, "notifications/cancelled")) {
        if (parsed.object.get("params")) |params| {
            if (params.object.get("requestId")) |cancelled_id| {
                cancellation_tracker.cancel(cancelled_id) catch {};
            }
        }
    }
    protocol_state.* = protocol_state.nextState(method);
}

/// Sends an error response for a failed processRequest call, mapping error
/// types to JSON-RPC error codes and messages.
fn sendRequestError(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    id: ?std.json.Value,
    err: anyerror,
) void {
    const error_code: i32 = switch (err) {
        error.InvalidRequest => JsonRpcError.INVALID_REQUEST,
        error.MethodNotFound => JsonRpcError.METHOD_NOT_FOUND,
        error.InvalidParams => JsonRpcError.INVALID_PARAMS,
        error.ToolNotFound => JsonRpcError.TOOL_NOT_FOUND,
        else => JsonRpcError.INTERNAL_ERROR,
    };
    const error_message: []const u8 = switch (err) {
        error.InvalidRequest => "Invalid Request: missing required fields",
        error.MethodNotFound => "Method not found",
        error.InvalidParams => "Invalid params",
        error.ToolNotFound => "Tool not found",
        else => "Internal error",
    };
    sendErrorResponse(allocator, stdout, id, error_code, error_message);
}

/// Runs the MCP stdio protocol loop.
fn runMcpMode(allocator: std.mem.Allocator) !u8 {
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = stdin.readerStreaming(&reader_buffer);

    var protocol_state = mcp.ProtocolState.uninitialized;
    var cancellation_tracker = mcp.CancellationTracker.init(allocator);
    defer cancellation_tracker.deinit();

    while (true) {
        const line = readLine(allocator, &reader) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        defer allocator.free(line);

        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            sendErrorResponse(allocator, stdout, null, JsonRpcError.PARSE_ERROR, "Parse error: invalid JSON");
            continue;
        };
        defer parsed.deinit();

        const req = validateJsonRpc(allocator, stdout, parsed.value.object) orelse continue;

        if (!protocol_state.isMethodAllowed(req.method)) {
            if (!req.is_notification) {
                const msg = switch (protocol_state) {
                    .uninitialized => "Invalid Request: must call 'initialize' first",
                    .initializing => "Invalid Request: waiting for 'initialized' notification",
                    .ready => "Invalid Request: 'initialize' already called",
                };
                sendErrorResponse(allocator, stdout, req.id, JsonRpcError.INVALID_REQUEST, msg);
            }
            continue;
        }

        if (req.is_notification) {
            handleNotification(parsed.value, req.method, &cancellation_tracker, &protocol_state);
            continue;
        }

        if (req.id) |id| {
            if (cancellation_tracker.isCancelled(id)) {
                cancellation_tracker.remove(id);
                continue;
            }
        }

        const response_json = processRequest(allocator, parsed.value) catch |err| {
            sendRequestError(allocator, stdout, req.id, err);
            continue;
        };
        defer allocator.free(response_json);

        protocol_state = protocol_state.nextState(req.method);

        _ = try stdout.write(response_json);
        _ = try stdout.write("\n");
    }

    return 0;
}

/// Reads one newline-delimited line from stdin.
fn readLine(allocator: std.mem.Allocator, reader: *std.fs.File.Reader) ![]u8 {
    var line_buffer = std.ArrayList(u8){};
    errdefer line_buffer.deinit(allocator);

    const line_slice = reader.interface.takeDelimiter('\n') catch |err| {
        if (err == error.ReadFailed) {
            const remaining = reader.interface.buffered();
            if (remaining.len == 0 and line_buffer.items.len == 0) {
                return error.EndOfStream;
            }
            try line_buffer.appendSlice(allocator, remaining);
            reader.interface.tossBuffered();
            return try line_buffer.toOwnedSlice(allocator);
        }
        if (err == error.StreamTooLong) {
            const buffered = reader.interface.buffered();
            try line_buffer.appendSlice(allocator, buffered);
            reader.interface.tossBuffered();
            if (line_buffer.items.len > 10 * 1024 * 1024) {
                return error.StreamTooLong;
            }
            const rest = try readLine(allocator, reader);
            defer allocator.free(rest);
            try line_buffer.appendSlice(allocator, rest);
            return try line_buffer.toOwnedSlice(allocator);
        }
        return err;
    };

    if (line_slice) |slice| {
        if (line_buffer.items.len > 0) {
            try line_buffer.appendSlice(allocator, slice);
            return try line_buffer.toOwnedSlice(allocator);
        }
        return try allocator.dupe(u8, slice);
    } else {
        if (line_buffer.items.len == 0) {
            return error.EndOfStream;
        }
        return try line_buffer.toOwnedSlice(allocator);
    }
}

/// Routes a parsed JSON-RPC request to the appropriate handler.
fn processRequest(allocator: std.mem.Allocator, request_value: std.json.Value) ![]u8 {
    const method = if (request_value.object.get("method")) |m|
        m.string
    else
        return error.InvalidRequest;

    const id = if (request_value.object.get("id")) |i| i else return error.InvalidRequest;

    if (std.mem.eql(u8, method, "initialize")) {
        return handleInitialize(allocator, id);
    } else if (std.mem.eql(u8, method, "ping")) {
        return handlePing(allocator, id);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return handleToolsList(allocator, id);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        return handleToolsCall(allocator, request_value, id);
    } else {
        return error.MethodNotFound;
    }
}

/// Responds to the MCP "initialize" handshake.
fn handleInitialize(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    const result =
        \\{"protocolVersion":"2024-11-05","serverInfo":{"name":"chunker","version":"1.0.0"},"capabilities":{"tools":{"list":true,"call":true,"listChanged":true}}}
    ;
    return buildSuccessResponse(allocator, id, result);
}

/// Handle MCP ping request.
fn handlePing(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    return buildSuccessResponse(allocator, id, "{}");
}

/// Tool schema constants (compile-time string literals).
const tool_schema_inspect =
    \\{"name":"chunker_inspect","description":"Inspect JSON/NDJSON file structure. Auto-detects format. JSON: type, element count, keys, chunk count. NDJSON: line count, first line type, sample keys.","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"Path to JSON or NDJSON file"},"chunk_size":{"type":"integer","description":"Chunk size in bytes (default 10000)"}},"required":["file"]}}
;

const tool_schema_read =
    \\{"name":"chunker_read","description":"Read a specific chunk of a JSON/NDJSON file. Auto-detects format. For NDJSON, use [N] path prefix to select a line (e.g., [0].name). Empty path reads all lines as an array.","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"Path to JSON or NDJSON file"},"path":{"type":"string","description":"Dot-notation path. For NDJSON: [N] selects line N, [N].key navigates within."},"chunk":{"type":"integer","description":"Chunk index (0-based)"},"chunk_size":{"type":"integer","description":"Chunk size in bytes (default 10000)"}},"required":["file"]}}
;

const tool_schema_extract =
    \\{"name":"chunker_extract","description":"Extract a value at a specific path from a JSON/NDJSON file. Auto-detects format. For NDJSON, path must start with [N] to select a line.","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"Path to JSON or NDJSON file"},"path":{"type":"string","description":"Dot-notation path. For NDJSON: [N] required (e.g., [0] or [0].name)."}},"required":["file"]}}
;

const tool_schema_search =
    \\{"name":"chunker_search","description":"Search for keys or values in a JSON/NDJSON file. Auto-detects format. For NDJSON, results include [N] line prefix in paths.","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"Path to JSON or NDJSON file"},"key":{"type":"string","description":"Key pattern to search for (substring)"},"value":{"type":"string","description":"Value pattern to search for"},"max_results":{"type":"integer","description":"Maximum results (default 10)"}},"required":["file"]}}
;

const tools_list_result = "{\"tools\":[" ++
    tool_schema_inspect ++ "," ++
    tool_schema_read ++ "," ++
    tool_schema_extract ++ "," ++
    tool_schema_search ++ "]}";

/// Returns the tool catalog with four chunker tools.
fn handleToolsList(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    return buildSuccessResponse(allocator, id, tools_list_result);
}

/// Dispatches tools/call to the correct handler.
fn handleToolsCall(
    allocator: std.mem.Allocator,
    request_value: std.json.Value,
    id: std.json.Value,
) ![]u8 {
    const params = request_value.object.get("params") orelse return error.InvalidParams;
    const tool_name = if (params.object.get("name")) |name| name.string else return error.InvalidParams;
    const arguments = params.object.get("arguments") orelse return error.InvalidParams;

    // Get file path (required for all tools).
    const file_value = arguments.object.get("file") orelse return error.InvalidParams;
    const file_path = file_value.string;

    // Open and mmap the file.
    var mapped = mmap_mod.MappedFile.open(file_path) catch {
        return buildMcpError(allocator, id, "Could not open file");
    };
    defer mapped.close();
    const buffer = mapped.bytes();

    if (buffer.len == 0) {
        return buildMcpError(allocator, id, "File is empty after BOM skip");
    }

    const format = ndjson_mod.detectFormat(buffer) catch {
        return buildMcpError(allocator, id, "Invalid file format");
    };

    if (format == .ndjson) {
        return handleNdjsonToolsCall(allocator, id, buffer, file_path, mapped.file_size, tool_name, arguments);
    }

    if (std.mem.eql(u8, tool_name, "chunker_inspect")) {
        return handleInspectCall(allocator, id, buffer, file_path, mapped.file_size, arguments);
    } else if (std.mem.eql(u8, tool_name, "chunker_read")) {
        return handleReadCall(allocator, id, buffer, arguments);
    } else if (std.mem.eql(u8, tool_name, "chunker_extract")) {
        return handleExtractCall(allocator, id, buffer, arguments);
    } else if (std.mem.eql(u8, tool_name, "chunker_search")) {
        return handleSearchCall(allocator, id, buffer, arguments);
    } else {
        return error.ToolNotFound;
    }
}

/// Dispatches NDJSON MCP tool calls.
fn handleNdjsonToolsCall(
    allocator: std.mem.Allocator,
    id: std.json.Value,
    buffer: []const u8,
    file_path: []const u8,
    file_size: u64,
    tool_name: []const u8,
    arguments: std.json.Value,
) ![]u8 {
    var index = ndjson_mod.buildLineIndex(allocator, buffer) catch {
        return buildMcpError(allocator, id, "Failed to build NDJSON line index");
    };
    defer index.deinit(allocator);

    if (std.mem.eql(u8, tool_name, "chunker_inspect")) {
        return handleNdjsonInspectCall(allocator, id, buffer, &index, file_path, file_size);
    } else if (std.mem.eql(u8, tool_name, "chunker_read")) {
        return handleNdjsonReadCall(allocator, id, buffer, &index, arguments);
    } else if (std.mem.eql(u8, tool_name, "chunker_extract")) {
        return handleNdjsonExtractCall(allocator, id, buffer, &index, arguments);
    } else if (std.mem.eql(u8, tool_name, "chunker_search")) {
        return handleNdjsonSearchCall(allocator, id, buffer, &index, arguments);
    } else {
        return error.ToolNotFound;
    }
}

/// Build an MCP error response for tool execution failures.
fn buildMcpError(allocator: std.mem.Allocator, id: std.json.Value, message: []const u8) ![]u8 {
    const error_json = try buildErrorResponse(
        allocator,
        id,
        JsonRpcError.INTERNAL_ERROR,
        message,
    );
    return error_json;
}

/// Handle chunker_inspect tool call.
fn handleInspectCall(
    allocator: std.mem.Allocator,
    id: std.json.Value,
    buffer: []const u8,
    file_path: []const u8,
    file_size: u64,
    arguments: std.json.Value,
) ![]u8 {
    var chunk_size: u32 = config.default_chunk_size;
    if (arguments.object.get("chunk_size")) |cs| {
        chunk_size = @intCast(cs.integer);
        if (chunk_size < config.min_chunk_size) {
            chunk_size = config.min_chunk_size;
        }
    }

    const result = inspect_mod.inspect(allocator, buffer, file_path, file_size, chunk_size) catch {
        return buildMcpError(allocator, id, "Inspect failed: scan error");
    };
    defer if (result.keys.len > 0) allocator.free(result.keys);

    // Serialize result to JSON.
    var json_buffer = std.ArrayList(u8){};
    defer json_buffer.deinit(allocator);
    const writer = json_buffer.writer(allocator);
    try writeInspectJson(writer, &result);

    const json_str = try json_buffer.toOwnedSlice(allocator);
    defer allocator.free(json_str);

    const tool_content = try buildToolContent(allocator, json_str, false);
    defer allocator.free(tool_content);

    return buildSuccessResponse(allocator, id, tool_content);
}

/// Handle chunker_read tool call.
fn handleReadCall(
    allocator: std.mem.Allocator,
    id: std.json.Value,
    buffer: []const u8,
    arguments: std.json.Value,
) ![]u8 {
    var path_arg: []const u8 = "";
    if (arguments.object.get("path")) |p| {
        path_arg = p.string;
    }

    var chunk_index: u32 = 0;
    if (arguments.object.get("chunk")) |c| {
        chunk_index = @intCast(c.integer);
    }

    var chunk_size: u32 = config.default_chunk_size;
    if (arguments.object.get("chunk_size")) |cs| {
        chunk_size = @intCast(cs.integer);
        if (chunk_size < config.min_chunk_size) {
            chunk_size = config.min_chunk_size;
        }
    }

    const result = read_mod.readChunk(allocator, buffer, path_arg, chunk_index, chunk_size) catch |err| {
        const msg: []const u8 = switch (err) {
            error.ChunkOutOfRange => "Chunk index out of range",
            error.KeyNotFound => "Key not found at path",
            error.IndexOutOfRange => "Index out of range at path",
            else => "Read failed",
        };
        return buildMcpError(allocator, id, msg);
    };
    defer allocator.free(result.data);

    var json_buffer = std.ArrayList(u8){};
    defer json_buffer.deinit(allocator);
    const writer = json_buffer.writer(allocator);
    try writeReadJson(writer, &result);

    const json_str = try json_buffer.toOwnedSlice(allocator);
    defer allocator.free(json_str);

    const tool_content = try buildToolContent(allocator, json_str, false);
    defer allocator.free(tool_content);

    return buildSuccessResponse(allocator, id, tool_content);
}

/// Handle chunker_extract tool call.
fn handleExtractCall(
    allocator: std.mem.Allocator,
    id: std.json.Value,
    buffer: []const u8,
    arguments: std.json.Value,
) ![]u8 {
    var path_arg: []const u8 = "";
    if (arguments.object.get("path")) |p| {
        path_arg = p.string;
    }

    const result = extract_mod.extract(buffer, path_arg) catch |err| {
        const msg: []const u8 = switch (err) {
            error.KeyNotFound => "Key not found at path",
            error.IndexOutOfRange => "Index out of range at path",
            else => "Extract failed",
        };
        return buildMcpError(allocator, id, msg);
    };

    var json_buffer = std.ArrayList(u8){};
    defer json_buffer.deinit(allocator);
    const writer = json_buffer.writer(allocator);
    try writeExtractJson(writer, &result);

    const json_str = try json_buffer.toOwnedSlice(allocator);
    defer allocator.free(json_str);

    const tool_content = try buildToolContent(allocator, json_str, false);
    defer allocator.free(tool_content);

    return buildSuccessResponse(allocator, id, tool_content);
}

/// Handle chunker_search tool call.
fn handleSearchCall(
    allocator: std.mem.Allocator,
    id: std.json.Value,
    buffer: []const u8,
    arguments: std.json.Value,
) ![]u8 {
    var key_pattern: ?[]const u8 = null;
    if (arguments.object.get("key")) |k| {
        key_pattern = k.string;
    }

    var value_pattern: ?[]const u8 = null;
    if (arguments.object.get("value")) |v| {
        value_pattern = v.string;
    }

    var max_results: u32 = config.default_max_results;
    if (arguments.object.get("max_results")) |mr| {
        max_results = @intCast(mr.integer);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = search_mod.searchBuffer(
        arena.allocator(),
        buffer,
        key_pattern,
        value_pattern,
        max_results,
    ) catch {
        return buildMcpError(allocator, id, "Search failed");
    };

    // Serialize using the main allocator (arena is about to be freed).
    var json_buffer = std.ArrayList(u8){};
    defer json_buffer.deinit(allocator);
    const writer = json_buffer.writer(allocator);
    try writeSearchJson(writer, &result);

    const json_str = try json_buffer.toOwnedSlice(allocator);
    defer allocator.free(json_str);

    const tool_content = try buildToolContent(allocator, json_str, false);
    defer allocator.free(tool_content);

    return buildSuccessResponse(allocator, id, tool_content);
}

/// Handle NDJSON chunker_inspect tool call.
fn handleNdjsonInspectCall(
    allocator: std.mem.Allocator,
    id: std.json.Value,
    buffer: []const u8,
    index: *const ndjson_mod.NdjsonIndex,
    file_path: []const u8,
    file_size: u64,
) ![]u8 {
    const result = ndjson_mod.ndjsonInspect(allocator, buffer, index, file_path, file_size) catch {
        return buildMcpError(allocator, id, "NDJSON inspect failed");
    };
    defer if (result.sample_keys.len > 0) {
        for (result.sample_keys) |k| allocator.free(k);
        allocator.free(result.sample_keys);
    };

    var json_buffer = std.ArrayList(u8){};
    defer json_buffer.deinit(allocator);
    const writer = json_buffer.writer(allocator);
    try writeNdjsonInspectJson(writer, &result);

    const json_str = try json_buffer.toOwnedSlice(allocator);
    defer allocator.free(json_str);

    const tool_content = try buildToolContent(allocator, json_str, false);
    defer allocator.free(tool_content);

    return buildSuccessResponse(allocator, id, tool_content);
}

/// Handle NDJSON chunker_read tool call.
fn handleNdjsonReadCall(
    allocator: std.mem.Allocator,
    id: std.json.Value,
    buffer: []const u8,
    index: *const ndjson_mod.NdjsonIndex,
    arguments: std.json.Value,
) ![]u8 {
    var path_arg: []const u8 = "";
    if (arguments.object.get("path")) |p| {
        path_arg = p.string;
    }

    var chunk_index: u32 = 0;
    if (arguments.object.get("chunk")) |c| {
        chunk_index = @intCast(c.integer);
    }

    var chunk_size: u32 = config.default_chunk_size;
    if (arguments.object.get("chunk_size")) |cs| {
        chunk_size = @intCast(cs.integer);
        if (chunk_size < config.min_chunk_size) {
            chunk_size = config.min_chunk_size;
        }
    }

    const result = ndjson_mod.ndjsonRead(allocator, buffer, index, path_arg, chunk_index, chunk_size) catch |err| {
        const msg: []const u8 = switch (err) {
            error.EmptyNdjsonPath => "NDJSON paths must start with a line index [N] (e.g., [0] or [0].name)",
            error.InvalidLineIndex => "Line index out of range",
            error.ChunkOutOfRange => "Chunk index out of range",
            error.KeyNotFound => "Key not found at path",
            error.IndexOutOfRange => "Index out of range at path",
            else => "NDJSON read failed",
        };
        return buildMcpError(allocator, id, msg);
    };
    defer allocator.free(result.data);

    var json_buffer = std.ArrayList(u8){};
    defer json_buffer.deinit(allocator);
    const writer = json_buffer.writer(allocator);
    try writeReadJson(writer, &result);

    const json_str = try json_buffer.toOwnedSlice(allocator);
    defer allocator.free(json_str);

    const tool_content = try buildToolContent(allocator, json_str, false);
    defer allocator.free(tool_content);

    return buildSuccessResponse(allocator, id, tool_content);
}

/// Handle NDJSON chunker_extract tool call.
fn handleNdjsonExtractCall(
    allocator: std.mem.Allocator,
    id: std.json.Value,
    buffer: []const u8,
    index: *const ndjson_mod.NdjsonIndex,
    arguments: std.json.Value,
) ![]u8 {
    var path_arg: []const u8 = "";
    if (arguments.object.get("path")) |p| {
        path_arg = p.string;
    }

    const result = ndjson_mod.ndjsonExtract(buffer, index, path_arg) catch |err| {
        const msg: []const u8 = switch (err) {
            error.EmptyNdjsonPath => "NDJSON extract requires a path starting with [N] (e.g., [0] or [0].name)",
            error.InvalidLineIndex => "Line index out of range",
            error.KeyNotFound => "Key not found at path",
            error.IndexOutOfRange => "Index out of range at path",
            else => "NDJSON extract failed",
        };
        return buildMcpError(allocator, id, msg);
    };

    var json_buffer = std.ArrayList(u8){};
    defer json_buffer.deinit(allocator);
    const writer = json_buffer.writer(allocator);
    try writeExtractJson(writer, &result);

    const json_str = try json_buffer.toOwnedSlice(allocator);
    defer allocator.free(json_str);

    const tool_content = try buildToolContent(allocator, json_str, false);
    defer allocator.free(tool_content);

    return buildSuccessResponse(allocator, id, tool_content);
}

/// Handle NDJSON chunker_search tool call.
fn handleNdjsonSearchCall(
    allocator: std.mem.Allocator,
    id: std.json.Value,
    buffer: []const u8,
    index: *const ndjson_mod.NdjsonIndex,
    arguments: std.json.Value,
) ![]u8 {
    var key_pattern: ?[]const u8 = null;
    if (arguments.object.get("key")) |k| {
        key_pattern = k.string;
    }

    var value_pattern: ?[]const u8 = null;
    if (arguments.object.get("value")) |v| {
        value_pattern = v.string;
    }

    var max_results: u32 = config.default_max_results;
    if (arguments.object.get("max_results")) |mr| {
        max_results = @intCast(mr.integer);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = ndjson_mod.ndjsonSearch(
        arena.allocator(),
        buffer,
        index,
        key_pattern,
        value_pattern,
        max_results,
    ) catch {
        return buildMcpError(allocator, id, "NDJSON search failed");
    };

    var json_buffer = std.ArrayList(u8){};
    defer json_buffer.deinit(allocator);
    const writer = json_buffer.writer(allocator);
    try writeSearchJson(writer, &result);

    const json_str = try json_buffer.toOwnedSlice(allocator);
    defer allocator.free(json_str);

    const tool_content = try buildToolContent(allocator, json_str, false);
    defer allocator.free(tool_content);

    return buildSuccessResponse(allocator, id, tool_content);
}

// -- JSON output serialization --

/// Writes InspectResult as JSON.
fn writeInspectJson(writer: anytype, result: *const inspect_mod.InspectResult) !void {
    try writer.writeAll("{\"file\":\"");
    try mcp.writeJsonEscapedString(writer, result.file_path);
    try writer.print("\",\"size\":{d},\"type\":\"{c}\",\"elements\":{d},\"avg_size\":{d},\"keys\":[", .{
        result.file_size,
        result.value_type.abbreviation(),
        result.element_count,
        result.average_size,
    });
    for (result.keys, 0..) |key, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try mcp.writeJsonEscapedString(writer, key);
        try writer.writeByte('"');
    }
    try writer.print("],\"chunks\":{d},\"chunk_size\":{d}}}", .{
        result.chunk_count,
        result.chunk_size,
    });
}

/// Writes ReadResult as JSON.
fn writeReadJson(writer: anytype, result: *const read_mod.ReadResult) !void {
    try writer.print("{{\"chunk\":{d},\"total\":{d},\"bytes\":{d},\"data\":", .{
        result.chunk_index,
        result.total_chunks,
        result.bytes_size,
    });
    try writer.writeAll(result.data);
    try writer.writeByte('}');
}

/// Writes ExtractResult as JSON.
fn writeExtractJson(writer: anytype, result: *const extract_mod.ExtractResult) !void {
    try writer.writeAll("{\"path\":\"");
    try mcp.writeJsonEscapedString(writer, result.path);
    try writer.print("\",\"type\":\"{c}\",\"size\":{d},\"value\":", .{
        result.value_type.abbreviation(),
        result.size,
    });
    try writer.writeAll(result.value);
    try writer.writeByte('}');
}

/// Writes SearchResult as JSON.
fn writeSearchJson(writer: anytype, result: *const search_mod.SearchResult) !void {
    try writer.writeAll("{\"matches\":[");
    for (result.matches, 0..) |match_entry, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":\"");
        try mcp.writeJsonEscapedString(writer, match_entry.path);
        try writer.print("\",\"type\":\"{c}\",\"preview\":\"", .{
            match_entry.value_type.abbreviation(),
        });
        try mcp.writeJsonEscapedString(writer, match_entry.preview);
        try writer.writeAll("\"}");
    }
    try writer.print("],\"total\":{d}}}", .{result.total_found});
}

/// Writes NdjsonInspectResult as JSON.
fn writeNdjsonInspectJson(writer: anytype, result: *const ndjson_mod.NdjsonInspectResult) !void {
    try writer.writeAll("{\"file\":\"");
    try mcp.writeJsonEscapedString(writer, result.file_path);
    try writer.print("\",\"size\":{d},\"format\":\"ndjson\",\"lines\":{d},\"first_line_type\":\"{c}\",\"sample_keys\":[", .{
        result.file_size,
        result.line_count,
        result.first_line_type.abbreviation(),
    });
    for (result.sample_keys, 0..) |key, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try mcp.writeJsonEscapedString(writer, key);
        try writer.writeByte('"');
    }
    try writer.writeAll("]}");
}
