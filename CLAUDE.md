# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Chunker is a Zig MCP (Model Context Protocol) server and CLI tool for incremental JSON file access. It gives AI agents four operations on large JSON files (up to 1 GiB): **inspect**, **read**, **extract**, and **search**. The tool is dual-mode: runs as an MCP stdio server by default, or as a one-shot CLI with `--cli`.

## Build and Test Commands

```bash
zig build                    # Debug build
zig build test               # All tests (unit + integration)
zig build test-unit          # Unit tests only
zig build test-integration   # Integration tests only
zig build release-fast       # ReleaseFast build
zig build run -- [args]      # Build and run with arguments
```

A `justfile` wraps these: `just build`, `just test`, `just test-unit`, `just test-integration`, `just release`, `just install`.

Install puts the binary at `/usr/local/bin/chunker`.

## CLI Usage

```bash
chunker --cli inspect --file path.json [--chunk-size N]
chunker --cli read --file path.json [--path a.b[0]] [--chunk 0] [--chunk-size N]
chunker --cli extract --file path.json [--path a.b.c]
chunker --cli search --file path.json [--key pattern] [--value pattern] [--max-results N]
```

## Architecture

The data pipeline is: **mmap -> scanner -> domain operation -> output builder -> JSON-RPC response**.

### Layer Responsibilities

- **mmap.zig** - Memory-maps the file read-only (`MAP.PRIVATE`). Validates size (max 1 GiB), detects UTF-8 BOM, returns `[]const u8` buffer. Only accessed pages are loaded by the OS.
- **scanner.zig** - Core byte-level JSON structural scanner. Operates on `[]const u8` with **zero heap allocation**. Finds value boundaries (positions and spans) without building a parse tree. Uses an iterative bracket stack (not recursion) for containers. Max nesting depth: 256.
- **scanner_strings.zig** - String scanning, escape validation, zero-copy key comparison (`stringEquals`), and string content decoding.
- **types.zig** - All shared types: `Pos` (u32), `Span` (half-open byte range), `ValueType`, `Element`, `PathSegment`, `PathBuf`, and all error sets (`ScanError`, `PathError`).
- **config.zig** - Compile-time constants (limits, defaults). Comptime assertions enforce u32 fits max_file_size and 64-bit architecture.
- **path.zig** - Dot-notation path parser (`users[0].name` -> segments). Stack-allocated, zero allocation. Keys containing `.` or `[` are not addressable.
- **output.zig** - Assembles compact JSON from scanner spans by slicing the original buffer. This is the only phase that heap-allocates.
- **inspect.zig** - File structure analysis: type, element count, keys (objects), chunk count. O(total_bytes).
- **read.zig** - Chunk-based reading. Objects sorted alphabetically by key before chunking. The hot path.
- **extract.zig** - Navigate path, return raw value slice (zero-copy).
- **search.zig** - Iterative stack-based traversal with key/value substring matching.
- **mcp.zig** - JSON-RPC 2.0 protocol layer: state machine (uninitialized -> initializing -> ready), response builders, cancellation tracking.
- **main.zig** - Entry point. CLI arg parsing and dispatch, MCP stdio loop, tool call routing, JSON output serialization.
- **lib.zig** - Re-exports all modules for test access as the `chunker` import.

### Key Design Patterns

- **TigerBeetle discipline**: paired assertions at call sites and definitions, iterative (no recursion), explicit bounds-checking on every byte access, explicit error sets (no `anyerror` in production).
- **Allocation tiers**: Scanner = zero allocation (stack only). Domain operations = arena per request. Output builder = ArrayList for response assembly.
- **Object chunking**: Objects are sorted alphabetically by key before chunking so chunk boundaries are deterministic regardless of source key order.
- **Compact size**: `scanner.compactSize()` computes minimized byte count by walking the value. Used for chunk boundary calculations.
- **MCP tool content**: Unlike the related `stump` project, `buildToolContent` wraps text as a JSON-escaped string (the MCP spec requires this).

## Test Structure

Tests import modules via `@import("chunker")` which maps to `src/lib.zig`. Unit test files in `test/unit/` mirror source modules (e.g., `scanner_test.zig` tests `scanner.zig`). All unit tests are aggregated in `test/unit/all_tests.zig`.

## Zig Version

Uses modern Zig conventions: `std.ArrayList(u8)` with explicit allocator passed to methods, `std.fs.File.Reader` with `readerStreaming`, `std.heap.page_size_min` for mmap alignment.
