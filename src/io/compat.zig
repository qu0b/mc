/// Zig 0.16 I/O compatibility layer.
/// Provides simple function calls wrapping the new std.Io API.
const std = @import("std");
pub const Io = std.Io;
pub const Dir = std.Io.Dir;
pub const File = std.Io.File;
const Allocator = std.mem.Allocator;

var threaded: Io.Threaded = undefined;
var io_instance: Io = undefined;
var initialized: bool = false;

/// Initialize the global Io context. Call once from main.
pub fn initIo(allocator: Allocator) void {
    threaded = Io.Threaded.init(allocator, .{});
    io_instance = threaded.io();
    initialized = true;
}

/// Get the global Io context.
pub fn getIo() Io {
    if (!initialized) {
        threaded = Io.Threaded.init(std.heap.page_allocator, .{});
        io_instance = threaded.io();
        initialized = true;
    }
    return io_instance;
}

pub fn cwd() Dir {
    return Dir.cwd();
}

// --- File read/write ---

pub fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(getIo(), path, allocator, .unlimited);
}

pub fn readFileInDir(dir: Dir, name: []const u8, allocator: Allocator) ![]u8 {
    return dir.readFileAlloc(getIo(), name, allocator, .unlimited);
}

pub fn writeFileAtPath(path: []const u8, data: []const u8) !void {
    return Dir.cwd().writeFile(getIo(), .{ .sub_path = path, .data = data });
}

pub fn writeFileInDir(dir: Dir, name: []const u8, data: []const u8) !void {
    return dir.writeFile(getIo(), .{ .sub_path = name, .data = data });
}

pub fn openFileAbsolute(path: []const u8) !File {
    return Dir.openFileAbsolute(getIo(), path, .{});
}

pub fn createFileInDir(dir: Dir, name: []const u8) !File {
    return dir.createFile(getIo(), name, .{});
}

pub fn closeFile(f: File) void {
    f.close(getIo());
}

pub fn fileRead(f: File, buf: []u8) !usize {
    var read_buf: [8192]u8 = undefined;
    var reader = f.reader(getIo(), &read_buf);
    var slices = [_][]u8{buf};
    return reader.readVec(&slices) catch return 0;
}

pub fn fileStat(f: File) !File.Stat {
    return f.stat(getIo());
}

// --- Access / exists ---

pub fn accessAbsolute(path: []const u8) !void {
    return Dir.accessAbsolute(getIo(), path, .{});
}

pub fn accessInDir(dir: Dir, name: []const u8) !void {
    return dir.access(getIo(), name, .{});
}

pub fn exists(path: []const u8) bool {
    Dir.accessAbsolute(getIo(), path, .{}) catch return false;
    return true;
}

// --- Directory ops ---

pub fn makeDirAbsolute(path: []const u8) !void {
    Dir.createDirAbsolute(getIo(), path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

pub fn makeDirInDir(dir: Dir, name: []const u8) !void {
    dir.createDir(getIo(), name, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

pub fn openDirAbsolute(path: []const u8) !Dir {
    return Dir.openDirAbsolute(getIo(), path, .{ .iterate = true });
}

pub fn openDirAbsoluteNoIter(path: []const u8) !Dir {
    return Dir.openDirAbsolute(getIo(), path, .{});
}

pub fn deleteTreeAbsolute(path: []const u8) void {
    Dir.cwd().deleteTree(getIo(), path) catch {};
}

pub fn renameInDir(dir: Dir, old: []const u8, new: []const u8) !void {
    return dir.rename(old, dir, new, getIo());
}

pub fn deleteFileInDir(dir: Dir, name: []const u8) !void {
    return dir.deleteFile(getIo(), name);
}

pub fn copyFileInDir(src_dir: Dir, src_name: []const u8, dst_dir: Dir, dst_name: []const u8) !void {
    return src_dir.copyFile(src_name, dst_dir, dst_name, getIo(), .{});
}

pub fn symLinkInDir(dir: Dir, target: []const u8, name: []const u8) !void {
    return dir.symLink(getIo(), target, name, .{});
}

pub fn readLinkInDir(dir: Dir, name: []const u8, buf: []u8) !usize {
    return dir.readLink(getIo(), name, buf);
}

// --- Realpath ---

pub fn realpathAlloc(allocator: Allocator, path: []const u8) ![]const u8 {
    return Dir.cwd().realPathFileAlloc(getIo(), path, allocator);
}

// --- Dir iteration ---

pub const DirEntry = Dir.Entry;

pub fn iterateDir(dir: Dir) DirIterator {
    return .{ .inner = dir.iterate(), .io_ctx = getIo() };
}

pub const DirIterator = struct {
    inner: Dir.Iterator,
    io_ctx: Io,

    pub fn next(self: *DirIterator) !?DirEntry {
        return self.inner.next(self.io_ctx);
    }
};

// --- Stdout/Stderr writer ---

pub const OutWriter = struct {
    file_writer: File.Writer,

    pub fn writeAll(self: *OutWriter, bytes: []const u8) void {
        self.file_writer.interface.writeAll(bytes) catch {};
    }

    pub fn print(self: *OutWriter, comptime fmt: []const u8, args: anytype) void {
        self.file_writer.interface.print(fmt, args) catch {};
    }

    pub fn flush(self: *OutWriter) void {
        self.file_writer.flush() catch {};
    }
};

var stdout_buf: [8192]u8 = undefined;
var stderr_buf: [4096]u8 = undefined;

pub fn getStdout() OutWriter {
    return .{ .file_writer = File.stdout().writer(getIo(), &stdout_buf) };
}

pub fn getStderr() OutWriter {
    return .{ .file_writer = File.stderr().writer(getIo(), &stderr_buf) };
}

// --- Process execution ---

pub fn runCommand(argv: []const []const u8) !u8 {
    var child = try std.process.spawn(getIo(), .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    const result = try child.wait(getIo());
    return switch (result) {
        .exited => |code| code,
        else => 1,
    };
}

pub fn runCommandOutput(allocator: Allocator, argv: []const []const u8) !struct { out: []const u8, code: u8 } {
    var child = try std.process.spawn(getIo(), .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var out: []u8 = &.{};
    if (child.stdout) |stdout_file| {
        var read_buf: [8192]u8 = undefined;
        var reader = stdout_file.reader(getIo(), &read_buf);
        out = reader.interface.allocRemaining(allocator, .unlimited) catch &.{};
    }

    const result = try child.wait(getIo());
    // Trim trailing newline
    if (out.len > 0 and out[out.len - 1] == '\n') out = out[0 .. out.len - 1];

    return .{
        .out = out,
        .code = switch (result) {
            .exited => |code| code,
            else => 1,
        },
    };
}

// --- posix mmap ---

pub fn mmap(len: usize, fd: std.posix.fd_t) ![]align(std.heap.page_size_min) const u8 {
    return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
}

pub fn munmap(data: []align(std.heap.page_size_min) const u8) void {
    std.posix.munmap(data);
}

pub fn fstat(fd: std.posix.fd_t) !std.posix.Stat {
    return std.posix.fstat(fd);
}
