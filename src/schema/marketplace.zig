const std = @import("std");
const json_mod = @import("json");
const mmap_mod = @import("mmap");
const source_mod = @import("source.zig");

/// Zero-copy representation of marketplace.json.
/// All []const u8 fields are slices into the mmap'd buffer.
pub const Marketplace = struct {
    @"$schema": ?[]const u8 = null,
    name: []const u8,
    description: ?[]const u8 = null,
    owner: Owner,
    metadata: ?Metadata = null,
    plugins: []const PluginEntry,

    pub const Owner = struct {
        name: []const u8,
        email: ?[]const u8 = null,
    };

    pub const Metadata = struct {
        description: ?[]const u8 = null,
        version: ?[]const u8 = null,
        pluginRoot: ?[]const u8 = null,
    };
};

/// A single plugin entry in the marketplace plugins array.
pub const PluginEntry = struct {
    name: []const u8,
    source: std.json.Value, // String or Object -- resolved via source.resolveSource
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
    author: ?Author = null,
    homepage: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    license: ?[]const u8 = null,
    category: ?[]const u8 = null,
    keywords: ?[]const []const u8 = null,
    tags: ?[]const []const u8 = null,
    strict: ?bool = null,
    commands: ?std.json.Value = null,
    agents: ?std.json.Value = null,
    skills: ?std.json.Value = null,
    hooks: ?std.json.Value = null,
    mcpServers: ?std.json.Value = null,
    lspServers: ?std.json.Value = null,
    outputStyles: ?std.json.Value = null,
};

pub const Author = struct {
    name: []const u8,
    email: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

/// Parsed marketplace backed by an mmap'd file.
pub const ParsedMarketplace = struct {
    value: Marketplace,
    mapped: mmap_mod.MappedFile,

    pub fn deinit(self: *ParsedMarketplace) void {
        self.mapped.close();
    }

    /// Resolve the source for a plugin entry.
    pub fn resolvePluginSource(entry: *const PluginEntry) !source_mod.Source {
        return source_mod.resolveSource(entry.source);
    }

    /// Find a plugin by name.
    pub fn findPlugin(self: *const ParsedMarketplace, name: []const u8) ?*const PluginEntry {
        for (self.value.plugins) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// Search plugins by substring in name or description.
    pub fn searchPlugins(self: *const ParsedMarketplace, allocator: std.mem.Allocator, query: []const u8) ![]const *const PluginEntry {
        var results: std.ArrayList(*const PluginEntry) = .empty;
        const query_lower = try toLower(allocator, query);

        for (self.value.plugins) |*p| {
            const name_lower = try toLower(allocator, p.name);
            if (std.mem.indexOf(u8, name_lower, query_lower) != null) {
                try results.append(allocator, p);
                continue;
            }
            if (p.description) |desc| {
                const desc_lower = try toLower(allocator, desc);
                if (std.mem.indexOf(u8, desc_lower, query_lower) != null) {
                    try results.append(allocator, p);
                }
            }
        }
        return results.toOwnedSlice(allocator);
    }
};

fn toLower(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const buf = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf;
}

/// Parse a marketplace.json file with zero-copy semantics.
pub fn parseMarketplace(allocator: std.mem.Allocator, path: []const u8) !ParsedMarketplace {
    const result = try json_mod.parseFile(Marketplace, allocator, path);
    return .{
        .value = result.value,
        .mapped = result.mapped,
    };
}

test "parse marketplace json" {
    const data =
        \\{
        \\  "name": "test-marketplace",
        \\  "owner": { "name": "Test", "email": "test@example.com" },
        \\  "plugins": [
        \\    {
        \\      "name": "my-plugin",
        \\      "source": "./plugins/my-plugin",
        \\      "description": "A test plugin",
        \\      "version": "1.0.0"
        \\    },
        \\    {
        \\      "name": "gh-plugin",
        \\      "source": { "source": "github", "repo": "user/repo", "sha": "abc123" },
        \\      "description": "GitHub-hosted plugin"
        \\    }
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const m = try json_mod.parseSlice(Marketplace, arena.allocator(), data);
    try std.testing.expectEqualStrings("test-marketplace", m.name);
    try std.testing.expectEqual(@as(usize, 2), m.plugins.len);

    // Resolve sources
    const src0 = try source_mod.resolveSource(m.plugins[0].source);
    try std.testing.expectEqualStrings("./plugins/my-plugin", src0.local);

    const src1 = try source_mod.resolveSource(m.plugins[1].source);
    try std.testing.expectEqualStrings("user/repo", src1.github.repo);
}
