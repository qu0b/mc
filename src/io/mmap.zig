const std = @import("std");
const compat = @import("compat.zig");
const posix = std.posix;

/// A memory-mapped file. The `data` slice points directly into the kernel's
/// page cache -- reads are zero-copy. The mapping is read-only and shared.
pub const MappedFile = struct {
    data: []align(std.heap.page_size_min) const u8,
    fd: posix.fd_t,
    len: usize,

    pub fn open(path: []const u8) !MappedFile {
        // Use openat with AT.FDCWD to open an absolute/relative path
        const fd = try posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
        errdefer _ = std.os.linux.close(fd);

        // Get file size via Io.File stat
        const file: compat.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        const stat = try file.stat(compat.getIo());
        const len: usize = @intCast(stat.size);

        if (len == 0) {
            return .{ .data = &.{}, .fd = fd, .len = 0 };
        }

        const mapped = try posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);

        // Hint: we'll read this sequentially
        posix.madvise(mapped.ptr, mapped.len, 2) catch {}; // MADV_SEQUENTIAL

        return .{
            .data = mapped,
            .fd = fd,
            .len = len,
        };
    }

    /// Returns the raw bytes -- the primary zero-copy bridge.
    /// `std.json.parseFromSliceLeaky` will return string slices
    /// pointing directly into this buffer.
    pub fn bytes(self: MappedFile) []const u8 {
        return self.data[0..self.len];
    }

    pub fn close(self: *MappedFile) void {
        if (self.len > 0) {
            posix.munmap(self.data);
        }
        _ = std.os.linux.close(self.fd);
    }
};

// Tests disabled for Zig 0.16 migration
