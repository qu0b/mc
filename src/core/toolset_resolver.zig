const std = @import("std");
const diag = @import("diagnostic");
const toolset = @import("toolset");

pub const ResolveError = error{
    UnknownToolset,
    CyclicIncludes,
    OutOfMemory,
};

/// Internal state carried through DFS.
const State = struct {
    allocator: std.mem.Allocator,
    registry: *const toolset.ToolsetRegistry,
    file: []const u8,
    diags: *diag.Diagnostics,

    /// De-duplicated output list of tool IDs (preserves first-seen order).
    out: std.ArrayList([]const u8),
    /// Set of tool IDs already pushed to `out`.
    seen_tools: std.StringHashMap(void),

    /// Toolsets currently on the DFS stack — cycle detection.
    visiting: std.StringHashMap(void),
    /// Toolsets already fully resolved — memo to avoid re-work.
    visited: std.StringHashMap(void),

    /// Ordered DFS path, used to format cycle diagnostics.
    path_stack: std.ArrayList([]const u8),

    /// Sticky flag: at least one `includes` entry pointed to an unknown
    /// toolset. Walk continues, final result returns UnknownToolset.
    unknown_include_seen: bool,
};

/// Flatten the named toolset into its full list of tool IDs.
/// - Transitively expands `includes` (depth-first, left-to-right).
/// - De-duplicates tool IDs (preserves first-seen order).
/// - Detects cycles and emits a diagnostic with the cycle path.
/// - Unknown toolset name -> emits diagnostic + ResolveError.UnknownToolset.
///
/// Returns a newly-allocated owned slice of tool IDs on success.
/// Caller frees via `allocator.free(result)`.
pub fn resolve(
    allocator: std.mem.Allocator,
    registry: *const toolset.ToolsetRegistry,
    name: []const u8,
    file: []const u8,
    diags: *diag.Diagnostics,
) ResolveError![]const []const u8 {
    // Fast-path: unknown target toolset.
    if (registry.entries.get(name) == null) {
        try diags.err(file, "", "toolset '{s}' not found in registry", .{name});
        return ResolveError.UnknownToolset;
    }

    var state = State{
        .allocator = allocator,
        .registry = registry,
        .file = file,
        .diags = diags,
        .out = std.ArrayList([]const u8).init(allocator),
        .seen_tools = std.StringHashMap(void).init(allocator),
        .visiting = std.StringHashMap(void).init(allocator),
        .visited = std.StringHashMap(void).init(allocator),
        .path_stack = std.ArrayList([]const u8).init(allocator),
        .unknown_include_seen = false,
    };
    defer state.seen_tools.deinit();
    defer state.visiting.deinit();
    defer state.visited.deinit();
    defer state.path_stack.deinit();
    errdefer state.out.deinit();

    try dfs(&state, name);

    if (state.unknown_include_seen) {
        // errdefer on `state.out` will free it when we return the error.
        return ResolveError.UnknownToolset;
    }

    return state.out.toOwnedSlice();
}

/// Resolve every toolset in the registry. Useful for validation — catches all
/// cycles/unknowns in one pass. On any error records diagnostics and returns
/// the first error encountered.
pub fn resolveAll(
    allocator: std.mem.Allocator,
    registry: *const toolset.ToolsetRegistry,
    file: []const u8,
    diags: *diag.Diagnostics,
) !void {
    var first_err: ?ResolveError = null;

    var it = registry.entries.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const result = resolve(allocator, registry, name, file, diags) catch |e| {
            if (first_err == null) first_err = e;
            continue;
        };
        allocator.free(result);
    }

    if (first_err) |e| return e;
}

fn dfs(state: *State, name: []const u8) ResolveError!void {
    // Already fully resolved — merge memo results via a re-walk would be
    // wasted work; the memo only skips the INCLUDES graph traversal, not
    // tool emission, because tool order must match first-encounter DFS.
    // So: if visited, the tools were already emitted on the first visit
    // (dedup via seen_tools). Safe to skip.
    if (state.visited.contains(name)) return;

    // Cycle: `name` is already on the current DFS stack.
    if (state.visiting.contains(name)) {
        try emitCycle(state, name);
        return ResolveError.CyclicIncludes;
    }

    const ts = state.registry.entries.get(name) orelse {
        // Should be caught by caller for target, and by includes-check for
        // nested lookups. Defensive: record + mark unknown.
        try state.diags.err(state.file, "", "toolset '{s}' not found in registry", .{name});
        state.unknown_include_seen = true;
        return;
    };

    try state.visiting.put(name, {});
    try state.path_stack.append(name);

    // Emit own tools first (DFS pre-order, left-to-right).
    for (ts.tools) |tool_id| {
        if (state.seen_tools.contains(tool_id)) continue;
        try state.seen_tools.put(tool_id, {});
        try state.out.append(tool_id);
    }

    // Then recurse into includes.
    for (ts.includes) |inc| {
        if (state.registry.entries.get(inc) == null) {
            try state.diags.err(
                state.file,
                "",
                "toolset '{s}' not found in registry",
                .{inc},
            );
            state.unknown_include_seen = true;
            continue;
        }
        try dfs(state, inc);
    }

    _ = state.visiting.remove(name);
    _ = state.path_stack.pop();
    try state.visited.put(name, {});
}

/// Format: `cyclic includes: a -> b -> c -> a`
/// Where `name` is the toolset that closed the cycle (already in path_stack).
fn emitCycle(state: *State, name: []const u8) ResolveError!void {
    // Find where `name` first appears on the stack — the cycle starts there.
    var start: usize = 0;
    for (state.path_stack.items, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) {
            start = i;
            break;
        }
    }

    var buf = std.ArrayList(u8).init(state.diags.arena.allocator());
    defer buf.deinit();
    var w = buf.writer();
    try w.writeAll("cyclic includes: ");
    var first = true;
    for (state.path_stack.items[start..]) |n| {
        if (!first) try w.writeAll(" -> ");
        try w.writeAll(n);
        first = false;
    }
    // Close the loop by re-appending the cycle head.
    try w.writeAll(" -> ");
    try w.writeAll(name);

    const owned = try buf.toOwnedSlice();
    try state.diags.err(state.file, "", "{s}", .{owned});
}
