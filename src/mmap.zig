//! Memory-mapped file I/O for the chunker scanner.
//!
//! Provides MappedFile: read-only mmap with size validation, BOM detection,
//! and clean resource cleanup. The OS handles page faulting -- only accessed
//! pages are loaded. MAP.PRIVATE isolates from concurrent writes.
const std = @import("std");
const config = @import("config.zig");

/// Errors returned by MappedFile operations.
pub const MmapError = error{
    /// The file exceeds config.max_file_size (1 GiB).
    FileTooLarge,
    /// The file is empty (0 bytes).
    FileEmpty,
    /// The path points to a directory, not a regular file.
    IsDirectory,
    /// Could not open the file (permissions, not found, etc.).
    OpenFailed,
    /// Could not fstat the file descriptor.
    StatFailed,
    /// mmap system call failed.
    MmapFailed,
};

/// A read-only memory-mapped file.
///
/// Opens the file, validates size constraints, and maps it into memory.
/// The `data` field provides the raw bytes. `content_start` indicates
/// where the JSON content begins (skipping BOM if present). Close via
/// `close()` to unmap and release the file descriptor.
pub const MappedFile = struct {
    data: []align(std.heap.page_size_min) const u8,
    file_descriptor: std.posix.fd_t,
    file_size: u64,
    content_start: u32,

    /// Opens and memory-maps a file for read-only access.
    ///
    /// Validates: file exists, is a regular file, is not empty, does not
    /// exceed max_file_size. Detects UTF-8 BOM and sets content_start
    /// accordingly.
    pub fn open(file_path: []const u8) MmapError!MappedFile {
        std.debug.assert(file_path.len > 0);

        const file = std.fs.cwd().openFile(file_path, .{
            .mode = .read_only,
        }) catch {
            return MmapError.OpenFailed;
        };
        const file_descriptor = file.handle;

        // fstat to get size and validate file type.
        const stat = std.posix.fstat(file_descriptor) catch {
            std.posix.close(file_descriptor);
            return MmapError.StatFailed;
        };

        // Reject directories.
        const file_mode = stat.mode;
        const is_regular = (file_mode & std.posix.S.IFMT) == std.posix.S.IFREG;
        if (!is_regular) {
            std.posix.close(file_descriptor);
            return MmapError.IsDirectory;
        }

        const file_size: u64 = @intCast(stat.size);

        // Reject empty files.
        if (file_size == 0) {
            std.posix.close(file_descriptor);
            return MmapError.FileEmpty;
        }

        // Reject files exceeding max_file_size (strict >).
        if (file_size > config.max_file_size) {
            std.posix.close(file_descriptor);
            return MmapError.FileTooLarge;
        }

        // Memory-map the file read-only with MAP_PRIVATE.
        const data = std.posix.mmap(
            null,
            @intCast(file_size),
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file_descriptor,
            0,
        ) catch {
            std.posix.close(file_descriptor);
            return MmapError.MmapFailed;
        };

        // Detect UTF-8 BOM (EF BB BF).
        var content_start: u32 = 0;
        if (file_size >= 3) {
            if (data[0] == config.utf8_bom[0] and
                data[1] == config.utf8_bom[1] and
                data[2] == config.utf8_bom[2])
            {
                content_start = 3;
            }
        }

        std.debug.assert(data.len > 0);
        std.debug.assert(data.len == file_size);
        return MappedFile{
            .data = data,
            .file_descriptor = file_descriptor,
            .file_size = file_size,
            .content_start = content_start,
        };
    }

    /// Returns the JSON content bytes (after BOM if present).
    pub fn bytes(self: *const MappedFile) []const u8 {
        std.debug.assert(self.content_start <= self.data.len);
        return self.data[self.content_start..];
    }

    /// Unmaps the file and closes the file descriptor.
    pub fn close(self: *MappedFile) void {
        std.debug.assert(self.data.len > 0);

        std.posix.munmap(self.data);
        std.posix.close(self.file_descriptor);
    }
};
