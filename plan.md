
 Here is Claude's plan:
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Chunker: Performance-Engineered Zig Implementation

 Context

 The chunker MCP tool provides incremental JSON file access for AI agents (inspect, read, extract, search). It is being built in Zig as a ground-up
 performance-engineered system. The design operates directly on memory-mapped file bytes with a custom zero-copy structural scanner, following
 TigerBeetle coding discipline.

 Motivation: Performance-optimized large JSON log file handling. The read path (most common agent operation) should never build a parse tree or copy
 file contents. The 1GB file size limit reflects the intended use case of processing large JSON log files.

 Scope: Internal developer tool, single user, per-request invocation, 64-bit only. Blast radius of failure is low (agent retries). But we are doing
 inherently unsafe byte-level operations, so correctness and safety are paramount.

 Latency targets (26MB / 1GB):
 - read:    < 100ms / < 2s
 - extract: < 100ms / < 2s
 - inspect: < 500ms / < 10s (O(total_bytes) -- compactSize walks all values)
 - search:  < 500ms / < 10s (full traversal)
 Inspect and search are inherently full-file scans. The budgets above are generous targets for Phase 6 benchmarking, not hard guarantees.

 ---
 Architecture Overview

   File on disk
        |
   mmap (zero-copy)
        |
   []const u8 buffer --- scanner operates directly on this
        |
   Position arithmetic (Span = start/end into buffer)
        |
   Output builder (only phase that allocates -- assembles response JSON)
        |
   MCP JSON-RPC response to stdout

 Core insight: Most chunker operations only need structural awareness (where values begin and end), not semantic parsing (what values mean). The scanner
  finds boundaries; the output builder slices the original buffer.

 ---
 TigerBeetle Principles Applied

 ┌────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────┐
 │         Principle          │                                   Application                                   │
 ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Static allocation          │ Scanner: zero heap allocation. All state on stack or in caller-provided buffers │
 ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Arena per request          │ Each tools/call gets an ArenaAllocator. Single deinit() at end                  │
 ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Paired assertions          │ Every scanner function asserts preconditions at both call site and definition   │
 ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Zero dependencies          │ Custom JSON scanner for file scanning. No external packages. MCP layer uses     │
│                            │ std.json for JSON-RPC request parsing (protocol layer only)                     │
 ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Safety > Perf > DX         │ Bounds-check every byte access explicitly. ScanError returns, never UB          │
 ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Iterative not recursive    │ Nesting tracked with depth counter, not call stack. Search uses explicit stack  │
 ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Defense-in-depth testing   │ Unit + fuzz + property + integration tests. std.testing.allocator catches leaks │
 ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ snake_case, 100-col lines  │ All identifiers, all files                                                      │
 ├────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────┤
 │ Do it right the first time │ Each phase reviewed and tested before moving to next                            │
 └────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────┘

 ---
 File Structure

 chunker/
   build.zig              # Adapted from stump, name = "chunker"
   justfile               # zig build, zig build test, install
   src/
     main.zig             # Entry point, CLI dispatch, MCP server loop, tool handlers
     scanner.zig          # Core byte-level JSON structural scanner
     scanner_strings.zig  # String skip, compare, extract
     types.zig            # Pos, Span, ValueType, Element, PathSegment, all errors
     config.zig           # Compile-time constants
     mmap.zig             # Memory-mapped file I/O (MappedFile)
     mcp.zig              # MCP protocol layer (adapted from stump, uses std.json for JSON-RPC)
     path.zig             # Dot-notation path parser and navigator
     inspect.zig          # chunker_inspect implementation
     read.zig             # chunker_read implementation (HOT PATH)
     extract.zig          # chunker_extract implementation
     search.zig           # chunker_search implementation
     output.zig           # Zero-copy JSON output assembly
     lib.zig              # Re-exports for test access
   test/
     unit/
       all_tests.zig
       scanner_test.zig
       scanner_strings_test.zig
       path_test.zig
       inspect_test.zig
       read_test.zig
       extract_test.zig
       search_test.zig
     integration/
       all_tests.zig
       cli_test.zig
     fuzz/
       fuzz_scanner.zig   # Fuzz harness for skipValue
       fuzz_path.zig      # Fuzz harness for parsePath
     fixtures/             # Test JSON files

 ---
 Key Design Decisions

 1. File I/O: mmap

 Classic C pattern adapted to Zig. The file is memory-mapped read-only via std.posix.mmap with PROT.READ and MAP.PRIVATE. The OS handles page faulting
 -- if we only scan the first 10KB (common for inspect on a large file where the root is an object with few keys), only those pages load.

 pub const MappedFile = struct {
     data: []align(std.mem.page_size) const u8,
     fd: std.posix.fd_t,

     pub fn open(path: []const u8) !MappedFile  // fstat -> validate size -> mmap
     pub fn close(self: *MappedFile) void        // munmap -> close fd
 };

 Safety: fstat before mmap rejects files > max_file_size (strict >, so exactly 1GB is accepted) and empty files. MAP.PRIVATE means no dirty page
 tracking. File is read-only throughout. BOM handling: if the first 3 bytes are EF BB BF (UTF-8 BOM), advance the scanner start position by 3.

 Known limitation: MAP.PRIVATE protects against concurrent writes but not file deletion/truncation. If the underlying file is removed while mapped,
 the OS may reclaim pages and the scanner will receive SIGBUS. This is acceptable for a single-user tool -- document the constraint that files must
 not be deleted while a chunker operation is in progress.

 2. Custom JSON Scanner: Zero-Copy Structural Navigation

 The scanner operates on []const u8 and returns positions/spans into the buffer. No tree. No allocation.

 Top-level entry: scanValue(buf) wraps skipValue with leading whitespace skip and trailing content validation. After skipValue returns end_pos,
 scanValue skips trailing whitespace and verifies end_pos == buf.len. A file like `[1,2,3] garbage` is rejected as invalid.

 Core primitive: skipValue(buf, pos) -> end_pos
 - Dispatches by first byte: " -> string, {/[ -> container, digit/- -> number, t/f/n -> literal
 - Containers use iterative tracking with a fixed bracket-type stack (not just a depth counter). Each `{` or `[` pushes its type; the matching `}`
   or `]` must correspond. `[}` is detected and returns ScanError.MismatchedBracket. Max depth: 256
 - String scanning handles all eight JSON escape sequences: \\, \", \/, \b, \f, \n, \r, \t, and \uXXXX. Validation of \uXXXX is structural only
   (4 hex digits must follow \u); surrogate pair semantics are not validated (not needed for boundary finding)
 - Number scanning validates per RFC 8259: optional leading minus, integer part (no leading zeros except bare 0), optional fractional part
   (decimal point followed by one or more digits), optional exponent (e/E with optional sign and one or more digits). Rejects `007`, `1.`, `.5`,
   `1e` as invalid

 Path Syntax Grammar:
 - Segments are delimited by `.` (object key) and `[N]` (array index)
 - Examples: `users[0].name`, `data.items[3].id`, `[0]` (root array element), `config` (root object key)
 - Valid segment characters: any UTF-8 byte except `.` and `[`
 - No escaping mechanism exists. Keys containing literal `.` or `[` are not addressable via path syntax. This is a known limitation
 - Empty path means the root value itself (used by extract to return the entire top-level value)
 - Array indices are decimal integers, zero-based. No negative indices. Out-of-range index returns a PathError

 Navigation: navigatePath(buf, path) -> Span
 - Parses dot-notation path into stack-allocated segments (max 64)
 - For each segment: scan object keys (comparing without allocation via stringEquals) or skip array elements to target index
 - stringEquals compares a JSON-encoded key in the buffer against an unescaped search term from the path. The comparison decodes the buffer key
   on the fly and compares decoded bytes against the raw search term. This handles keys containing JSON-escaped characters correctly
 - Skips irrelevant values entirely -- never parses what it doesn't need

 Iteration: TopLevelIterator yields (start, end) for each element
 - Caller-driven, no allocation, no buffering

 Chunking: Position arithmetic
 - Array: iterate elements, measure byte sizes via compactSize (counts non-whitespace bytes without copying), accumulate until chunk boundary
 - Object: collect all pair positions into caller-provided buffer, sort by key text, then apply chunk boundaries on sorted order
 - Key insight: element byte size = end_pos - start_pos for compact JSON, or a whitespace-skipping count for pretty-printed JSON

 3. Position Type: u32

 1GB = 1,073,741,824 bytes. u32 max = 4,294,967,295. u32 is sufficient with 4x headroom, halves struct sizes vs usize, improves cache utilization. All
 Span and Element structs use u32 positions. Enforced at compile time: comptime { assert(max_file_size < std.math.maxInt(u32)); }.

 4. Memory Management Tiers

 ┌───────────────┬────────────────────────────────────────────────────────────┬───────────────────────────────────────────────────┐
 │     Tier      │                           Where                            │                     Allocator                     │
 ├───────────────┼────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ 0: Zero alloc │ Scanner hot path (skip, navigate, iterate)                 │ None -- stack + mmap buffer                       │
 ├───────────────┼────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ 1: Static     │ Path segments, search stack, error messages                │ Stack-allocated fixed arrays                      │
 ├───────────────┼────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ 2: Arena      │ Per-request work (output assembly, pair sorting buffer)    │ ArenaAllocator, single deinit                     │
 ├───────────────┼────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────┤
 │ 3: GPA        │ Server lifetime (stdin line reading, cancellation tracker) │ GeneralPurposeAllocator (leak detection in debug) │
 └───────────────┴────────────────────────────────────────────────────────────┴───────────────────────────────────────────────────┘

 5. Compact Size Calculation

 compactSize returns the number of bytes a value would occupy in minimized JSON (no insignificant whitespace). This is a full JSON-aware scanner walk,
 not a simple byte filter -- it must track whether the current position is inside a string (literal spaces in string values are content, not
 whitespace to skip) and handle all escape sequences via the same skipString logic used elsewhere. Complexity is comparable to skipValue.

 compactSize reference:
   Input              compactSize
   "hello"            7  (includes quotes)
   123                3
   true               4
   null               4
   { "a" : 1 }        7  ({"a":1})
   [ 1 , 2 ]          5  ([1,2])

 compactSize is implemented in scanner.zig (zero-allocation, operates on buffer). output.zig imports and calls it but does not re-implement it.

 Fast path: during inspect, scan the full top-level structure for insignificant whitespace between structural tokens at depth 0. If none is found,
 the file is flagged as compact. When compact, all subsequent compactSize calls for that request can return span.len() directly without scanning.
 This is a file-level property detected once across the entire top level (not sampled from the first few tokens), because log files may change
 formatting mid-file. This is a per-span check avoided, not a per-token check.

 6. Object Key Sorting

 Must sort keys alphabetically for deterministic chunk boundaries. Strategy:
 1. First pass: count pairs (skip all values, count at depth-1 commas)
 2. Allocate pair buffer from arena (exact size known from count)
 3. Second pass: collect Element{key_span, value_span} for each pair
 4. Sort by key content using std.sort.pdq with comparator: fn(ctx, a, b) calling std.mem.lessThan(u8, ...) on buf[key_start+1..key_end-1]
    (exclude quotes for raw key byte comparison). Note: sort order is by raw JSON-encoded bytes, not decoded Unicode codepoints. For keys with
    escape sequences, `\n` (0x5C 0x6E) sorts between uppercase and lowercase ASCII. This is deterministic and acceptable for the use case
 5. Apply chunk boundaries on sorted order

 Pair size formula: pair_size = compactSize(key_span) + compactSize(value_span) + 1 (for `:` separator). Chunk size does NOT include the wrapping
 `{}` braces -- it measures only the content between them. This formula differs from the Go implementation (which uses json.Marshal wrapping that
 adds 2 bytes for `{}`), so chunk counts will differ between Go and Zig for the same file and chunk_size. Agents that cached chunk counts from the
 Go version may request invalid chunk indices.

 Chunk accumulation algorithm (objects -- arrays are analogous, without keys or sorting):
   running_size = 0
   for each pair in sorted order:
       pair_cost = compactSize(key) + compactSize(value) + 1    // colon
       if running_size > 0:
           pair_cost += 1                                        // comma before this pair
       if running_size + pair_cost > chunk_size and running_size > 0:
           emit chunk boundary
           running_size = compactSize(key) + compactSize(value) + 1  // restart without comma
       else:
           running_size += pair_cost

 This formula must be used identically in inspect (chunk estimation) and read (chunk generation).

 Chunk size validation: chunk_size must be >= 1. Values of 0 or negative are rejected. No upper bound is enforced -- a chunk_size larger than the
 file produces a single chunk. Degenerate chunk_size (e.g., 1) produces one chunk per element since no element is smaller than 1 compact byte.
 Maximum response size is bounded by chunk_size + output framing overhead.

 1GB limit implication: A pathological 1GB object could have millions of keys. At 12 bytes per Element, 10M keys = 120MB pair buffer. The arena
 allocator handles this (backed by page_allocator, returns to OS on deinit). The sort is O(n log n) on key count -- still fast for practical key counts.
 Safety: config.zig defines max_object_keys (1M). Objects exceeding this return an error rather than allocating unbounded memory.

 7. Search: Iterative Stack-Based Traversal

 Search uses an explicit stack:
 const StackFrame = struct { pos: u32, path_len: u16, kind: enum { array, object }, index: u32 };
 var stack: [256]StackFrame = undefined;  // fixed, no allocation
 Dual-match behavior: when both key and value are specified, matches are additive (key match OR value match), not conjunctive. Deduplication: if
 the same path matches on both key and value, emit a single match entry (deduplicate by path before adding to results). Match results are collected
 into an arena-allocated list (tier 2). Deduplication is O(n^2) in match count but max_results is capped (default 10), so this is negligible.

 Path building: search builds dot-notation paths (e.g., `users[0].name`) by appending segments as traversal descends. Paths are formatted into
 arena-allocated strings (tier 2) since worst-case path length with 256 nesting levels and long keys exceeds any reasonable fixed buffer.

 Span semantics: all returned Spans include delimiters. For strings, the span includes opening and closing quotes. For containers, the span
 includes opening and closing braces/brackets. Scalar passthrough in read and extract returns the raw span bytes (quotes included for strings).

 ---
 Error Handling: Truncated and Invalid JSON

 Log files -- the primary use case -- may be truncated (process crash mid-write). All tools fail cleanly on invalid JSON:
 - Scanner returns ScanError (UnexpectedEndOfInput, UnexpectedByte, etc.)
 - Each tool wraps scanner errors into an MCP error response with a descriptive message including the byte position of the failure
 - No partial results: if the scanner encounters an error at any point, the entire operation fails. This is simpler to reason about and test.
   Partial result support can be added later if needed, but is not worth the complexity for v1
 - Test fixtures must include truncated JSON files to verify clean error reporting

 Cancellation: the scanner is synchronous -- there is no cancellation mechanism within a scan. The MCP CancellationTracker handles protocol-level
 cancellation between requests, but an in-progress scan (e.g., inspect on a 1GB file) cannot be interrupted gracefully. The user must kill the
 process. This is acceptable for a per-request tool where each operation is bounded by the latency targets above.

 ---
 Security Measures

 ┌───────────────────────────────┬────────────────────────────────────────────────────────────┐
 │            Threat             │                          Defense                           │
 ├───────────────────────────────┼────────────────────────────────────────────────────────────┤
 │ File > 1GB                    │ Rejected at fstat before mmap                              │
 ├───────────────────────────────┼────────────────────────────────────────────────────────────┤
 │ Unterminated string/container │ Scanner returns ScanError, never loops forever             │
 ├───────────────────────────────┼────────────────────────────────────────────────────────────┤
 │ Nesting > 256 levels          │ NestingDepthExceeded error (iterative counter, not stack)  │
 ├───────────────────────────────┼────────────────────────────────────────────────────────────┤
 │ Malicious escapes in strings  │ Every escape validated. Invalid \uXXXX returns error       │
 ├───────────────────────────────┼────────────────────────────────────────────────────────────┤
 │ Integer overflow in sizes     │ @addWithOverflow for running totals, saturating arithmetic │
 ├───────────────────────────────┼────────────────────────────────────────────────────────────┤
 │ Unescaped control chars       │ Detected and reported as UnexpectedByte                    │
 ├───────────────────────────────┼────────────────────────────────────────────────────────────┤
 │ Concurrent file modification  │ MAP.PRIVATE isolates our view. Document constraint         │
 ├───────────────────────────────┼────────────────────────────────────────────────────────────┤
 │ Huge single element           │ No problem: scanner just scans bytes, zero allocation      │
 └───────────────────────────────┴────────────────────────────────────────────────────────────┘

 Every buf[i] access is preceded by explicit if (i >= buf.len) return error.UnexpectedEndOfInput. Zig's slice bounds checking is a second layer, not the
  primary defense. Critical edge case: when the closing delimiter (" or ] or }) is the last byte in the buffer, the returned end_pos equals buf.len.
 Any subsequent read of buf[end_pos] (e.g., to check for comma or colon) must be preceded by a bounds check. Test coverage required for this case.

 ---
 Output Format Compatibility

 - InspectResult: {"file":"...","size":N,"type":"...","elements":N,"avg_size":N,"keys":[...],"chunks":N,"chunk_size":N}
   - size: file size in bytes (from fstat, before BOM adjustment)
   - type: single-character type abbreviation of the root value
   - elements: number of top-level elements (array items or object key-value pairs). For scalars: 1
   - avg_size: total compactSize of all elements divided by element count, integer division (truncating). For scalars: compactSize of the value
   - keys: array of key name strings for objects, [] (empty array) for arrays and scalars
   - chunks: number of chunks at the given chunk_size. For scalars: 1. For empty containers ([] or {}): 1 (the single chunk is empty)
   - chunk_size: the chunk_size used (from request parameter or config default). Unit: bytes of compact JSON content

 - ReadResult: {"chunk":N,"total":N,"bytes":N,"data":<raw JSON>}
   - bytes: compactSize of the data field's content (the chunk payload, not including output framing)
   - For scalar values, only chunk 0 is valid. Chunk indices > 0 return an MCP error: "chunk index N out of range (0..0)"

 - ExtractResult: {"path":"...","type":"...","size":N,"value":<raw JSON>}
   - Empty path extracts the root value (equivalent to reading the entire top-level value)

 - SearchResult: {"matches":[{"path":"...","type":"...","preview":"..."}],"total":N}
   - preview: first N bytes of the matched value's raw JSON, where N = config preview_max_bytes (default 100). If truncated, append "..." (3 literal
     dots). For key matches, preview is the value associated with the matched key. When a deduplicated match hits both key and value, use the value
   - Search value matching: substring match against decoded string content (without quotes). For non-string values, substring match against raw JSON
     bytes. Searching for "1" matches the string "abc1def" and the number 1, but not 10 or 100 (exact token boundaries apply for non-strings)

 - Type abbreviations: a=array, o=object, s=string, n=number, b=bool, z=null. Used in all `type` fields of all four result schemas and in each
   search match `type` field. Internal code uses the full ValueType enum; abbreviation happens only at output serialization
 - CRITICAL: MCP text field must be a JSON string (escaped), not raw JSON. Stump's buildToolContent writes raw JSON as the text value, but MCP
   requires text to be a JSON string containing escaped JSON. Getting this wrong breaks all MCP client parsing. Phase 5 blocking acceptance criterion.

 ---
 Implementation Phases

 Each phase is independently testable. Each phase gets a review before proceeding to the next.

 Phase 1: Scanner Foundation

 Files: types.zig, config.zig, scanner_strings.zig, scanner.zig, build.zig, lib.zig
 Tests: scanner_test.zig, scanner_strings_test.zig, fuzz/fuzz_scanner.zig

 1. config.zig -- compile-time constants (max_file_size = 1GB, default_chunk_size, min_chunk_size = 1, default_max_results, max_nesting_depth,
 max_path_segments, max_object_keys = 1M, preview_max_bytes = 100). Include comptime assertions: max_file_size < std.math.maxInt(u32), @sizeOf(usize) >= 8
 2. types.zig -- Pos (u32), Span, ValueType, Element, ScanError, PathSegment, PathBuf, SearchMatch
 3. scanner_strings.zig -- skipString, stringEquals, stringContent, stringContentLength
 4. scanner.zig -- skipWhitespace, classifyValue, skipNumber, skipLiteral, skipValue, scanValue (top-level entry: whitespace skip + skipValue + trailing content validation)
 5. build.zig -- adapted from stump
 6. lib.zig -- re-exports
 7. Tests: every skip function on every JSON type, all eight escape sequences (\\, \", \/, \b, \f, \n, \r, \t, \uXXXX), number validation
    (reject 007, 1., .5, 1e, accept 0, -1, 1.0, 1e10, 1.5E-3), bracket mismatch detection ([}, {]), error cases, depth limits, closing delimiter
    as last byte in buffer
 8. Fuzz: arbitrary bytes into skipValue -- must never panic, always return valid position or error

 Review gate: Scanner passes all unit tests. Fuzz runs 60s minimum with no crashes (gate for phase progression). Phase 6 includes extended
 overnight fuzz runs for string escape handling and depth counting paths.

 Phase 2: Navigation and Iteration

 Files: path.zig, scanner additions (iterators, navigation), output.zig
 Tests: path_test.zig, navigation tests in scanner_test.zig

 9. path.zig -- parsePath (stack-allocated, no allocation)
 10. scanner.zig additions -- TopLevelIterator, navigatePath, navigateSegments, arrayElementAt, objectValueForKey, compactSize
 11. output.zig -- buildCompactArray, buildCompactObject (the allocating output assembly; these call scanner.compactSize, not a reimplementation)
 12. Tests: path parsing edge cases + navigation into nested structures + whitespace handling

 Review gate: Can navigate any path in test JSON files. Iterator correctly yields all elements.

 Phase 3: File I/O

 Files: mmap.zig (or integrated into a file module)

 13. MappedFile -- open (fstat + validate + mmap), close (munmap), bytes accessor
 14. Tests: mmap real files, reject oversized files, reject empty files, reject directories

 Review gate: Can mmap test fixtures and pass buffer to scanner.

 Phase 4: Domain Operations

 Files: inspect.zig, read.zig, extract.zig, search.zig
 Tests: inspect_test.zig, read_test.zig, extract_test.zig, search_test.zig

 15. inspect.zig -- type detection, element counting, key listing, chunk estimation. Note: computing per-key sz requires compactSize walks over each
 value span, making inspect O(total_bytes) not O(key_count) on large files. This cost is inherent to the zero-copy design
 16. read.zig -- chunkArray, chunkObject, scalar passthrough, path+chunk combo
 17. extract.zig -- navigate path + return raw value + type + size (size = compactSize of value span, not raw span length)
 18. search.zig -- iterative stack-based traversal, key/value matching, path building, preview generation
 19. Tests: comprehensive test cases for each operation. Include both compact and pretty-printed JSON fixtures to verify compactSize correctness

 Review gate: All 4 operations produce correct output for all test fixtures (compact and pretty-printed).

 Phase 5: MCP Integration and Entry Point

 Files: mcp.zig, main.zig, justfile
 Tests: cli_test.zig, integration/all_tests.zig

 20. mcp.zig -- adapt from stump (ProtocolState, JSON-RPC builders, CancellationTracker)
 21. main.zig -- MCP server loop (stdin line reading, request parsing, dispatch), CLI mode, tool schemas as compile-time string literals, response
 wrapping with proper text-field escaping
 22. justfile -- build, test, install commands
 23. Integration tests: CLI round-trip, MCP protocol handshake, tools/list, tools/call for each tool

 Review gate: Full MCP round-trip works. just install succeeds. Registered as MCP server. BLOCKING: MCP text field contains properly escaped JSON
 string (not raw JSON). Test: parse the text field value as a JSON string, then parse the unescaped content as JSON -- both must succeed.

 Phase 6: Stress Testing and Performance

 24. Performance benchmarking on large JSON logs (26MB+): measure latency for each operation
 25. Stress test with ~1GB file to validate mmap + u32 positions at limit
 26. Memory profiling: verify zero heap allocation in scanner hot path
 27. Extended fuzz runs (overnight) on skipValue, parsePath, compactSize

 ---
 Testing Strategy

 Layer: Unit
 What: Every public scanner function
 How: Table-driven tests with t.Run-style subtests via Zig test blocks
 ────────────────────────────────────────
 Layer: Fuzz
 What: skipValue, parsePath
 How: AFL/libFuzzer harness. Property: never panic, always return valid pos or error
 ────────────────────────────────────────
 Layer: Property
 What: Structural invariants
 How: For valid JSON: skipValue(buf, 0) == buf.len. Chunk element counts sum to total. Sorted keys in object chunks
 ────────────────────────────────────────
 Layer: Integration
 What: CLI round-trip, MCP protocol
 How: Spawn process, feed input, validate output JSON
 ────────────────────────────────────────
 All tests use std.testing.allocator to catch leaks.

 ---
 Critical Reference Files

 - /Users/home/Documents/Code/terse-mcp/stump/src/mcp.zig -- MCP protocol layer to adapt
 - /Users/home/Documents/Code/terse-mcp/stump/src/main.zig -- Server loop pattern (uses Zig 0.15 stream reader API: readerStreaming, takeDelimiter)
 - /Users/home/Documents/Code/terse-mcp/stump/build.zig -- Build system template

 Stump Deltas (what to copy, modify, or omit):

 build.zig:
 - Copy structure verbatim
 - Change: executable name to "chunker", replace stump source file list with chunker sources, update test file paths

 mcp.zig -- copy verbatim:
 - ProtocolState enum and isMethodAllowed/nextState
 - JsonRpcError constants
 - CancellationTracker struct (init, deinit, cancel, isCancelled, remove, clear)
 - isNotification
 - buildErrorResponse
 - serializeId
 - writeJsonEscapedString
 - buildSuccessResponse

 mcp.zig -- modify:
 - buildToolContent: stump writes raw JSON as the text field value. Chunker must JSON-string-escape the text field content. Replace the raw write
   with a call that wraps the payload in quotes and escapes internal quotes/newlines/backslashes via writeJsonEscapedString

 mcp.zig -- omit:
 - Any stump-specific output formatting or serialization helpers not listed above

 main.zig -- copy pattern, rewrite content:
 - Copy: main() CLI-vs-MCP detection, readLine, processRequest dispatch structure, handleInitialize, handlePing
 - Replace: handleToolsList with chunker's four tool schemas (chunker_inspect, chunker_read, chunker_extract, chunker_search)
 - Replace: handleToolsCall with chunker's dispatch (match tool name -> call inspect/read/extract/search)
 - Omit: all stump-specific logic (parseConfig, executeStump, buildOutputData, serializeFileSuccess, tree-related code)

 ---
 Verification

 1. zig build test -- all unit + property tests pass, zero leaks
 2. Fuzz scanner for 60s minimum with no crashes (extended overnight runs before release)
 3. CLI: ./chunker --cli inspect --file test/fixtures/large.json produces valid JSON
 4. CLI: ./chunker --cli read --file test/fixtures/large.json --chunk 0 produces valid chunked output
 5. CLI: operations on pretty-printed JSON fixtures produce correct chunk boundaries (compactSize validation)
 5a. CLI: operations on truncated JSON fixtures return clean error with byte position (no panic, no partial output)
 6. MCP: echo '{"jsonrpc":"2.0","id":1,"method":"initialize",...}' | ./chunker returns valid handshake
 7. MCP: text field in tool responses is a properly escaped JSON string (parse as string, then parse content)
 8. Performance: read on 26MB < 100ms, inspect on 26MB < 500ms, search on 26MB < 500ms
 9. Stress: ~1GB file -- read < 2s, inspect < 10s, search < 10s, u32 positions remain valid, no crash
