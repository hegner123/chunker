# Chunker build and test commands

# Build the chunker executable (debug)
build:
    zig build

# Run all tests (unit + integration)
test:
    zig build test

# Run unit tests only
test-unit:
    zig build test-unit

# Run integration tests only
test-integration:
    zig build test-integration

# Build with ReleaseFast optimization
release:
    zig build release-fast

# Install to /usr/local/bin
install: release
    cp zig-out/bin/chunker /usr/local/bin/chunker

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache
