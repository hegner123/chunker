# chunker

Incremental JSON file access for AI agents. MCP stdio server and CLI tool providing four operations on large JSON files (up to 1 GiB): **inspect**, **read**, **extract**, and **search**.

## Installation

```bash
just install
```

## Usage

```bash
chunker --cli inspect --file path.json
chunker --cli read --file path.json --path users[0].name --chunk 0
chunker --cli extract --file path.json --path config.key
chunker --cli search --file path.json --key pattern --value pattern
```

## Build

```bash
zig build              # Debug build
zig build test         # All tests
zig build release-fast # Release build
```
