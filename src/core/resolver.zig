const std = @import("std");
const config_mod = @import("config.zig");
const marketplace_mod = @import("../schema/marketplace.zig");
const source_mod = @import("../schema/source.zig");
const json_mod = @import("../io/json.zig");

/// Result of resolving a package name.
pub const ResolvedPlugin = struct {
    name: []const u8,
    marketplace_name: []const u8,
    marketplace_path: []const u8,
    entry: marketplace_mod.PluginEntry,
    source: source_mod.Source,
};

/// Resolve a package specification into a concrete source.
/// Supports: "name" (searches all marketplaces), "name@marketplace" (specific marketplace).
pub fn resolve(allocator: std.mem.Allocator, spec: []const u8) !ResolvedPlugin {
    // Parse "name@marketplace" format
    const sep = std.mem.indexOfScalar(u8, spec, '@');
    const name = if (sep) |s| spec[0..s] else spec;
    const marketplace_filter = if (sep) |s| spec[s + 1 ..] else null;

    const mp_refs = try config_mod.listMarketplaces(allocator);

    for (mp_refs) |ref| {
        // If a specific marketplace was requested, skip others
        if (marketplace_filter) |filter| {
            if (!std.mem.eql(u8, ref.name, filter)) continue;
        }

        const mp_json = try std.fmt.allocPrint(
            allocator,
            "{s}/.claude-plugin/marketplace.json",
            .{ref.install_path orelse continue},
        );

        var parsed = marketplace_mod.parseMarketplace(allocator, mp_json) catch continue;

        if (parsed.findPlugin(name)) |entry| {
            const source = try source_mod.resolveSource(entry.source);
            return .{
                .name = entry.name,
                .marketplace_name = parsed.value.name,
                .marketplace_path = ref.install_path.?,
                .entry = entry.*,
                .source = source,
            };
        }
        parsed.deinit();
    }

    return error.PluginNotFound;
}

/// Search all marketplaces for plugins matching a query.
pub fn search(allocator: std.mem.Allocator, query: []const u8) ![]SearchResult {
    const mp_refs = try config_mod.listMarketplaces(allocator);
    var results: std.ArrayList(SearchResult) = .empty;

    for (mp_refs) |ref| {
        const mp_json = try std.fmt.allocPrint(
            allocator,
            "{s}/.claude-plugin/marketplace.json",
            .{ref.install_path orelse continue},
        );

        var parsed = marketplace_mod.parseMarketplace(allocator, mp_json) catch continue;
        const matches = try parsed.searchPlugins(allocator, query);

        for (matches) |entry| {
            try results.append(allocator, .{
                .name = entry.name,
                .marketplace = parsed.value.name,
                .description = entry.description,
                .version = entry.version,
                .category = entry.category,
            });
        }
    }

    return results.toOwnedSlice(allocator);
}

pub const SearchResult = struct {
    name: []const u8,
    marketplace: []const u8,
    description: ?[]const u8,
    version: ?[]const u8,
    category: ?[]const u8,
};
