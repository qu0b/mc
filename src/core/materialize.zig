const std = @import("std");
const diag = @import("diagnostic");
const agent_schema = @import("agent");
const compat = @import("iocompat");

pub const Layer = enum(u8) {
    library = 1,
    project = 2,
    agent = 3,

    pub fn toString(self: Layer) []const u8 {
        return switch (self) {
            .library => "library",
            .project => "project",
            .agent => "agent",
        };
    }
};

pub const FileTrace = struct {
    capability: []const u8,
    relative_path: []const u8,
    layer: Layer,
    source_absolute: []const u8,
};

pub const MaterializeResult = struct {
    runtime_dir: []const u8,
    traces: []const FileTrace,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    agent_name: []const u8,
    /// Parallel to a sorted unique capability list used by writeTrace; optional
    /// library version text discovered from `<library_dir>/plugin.json` (or null
    /// if missing / unparseable). Owned by arena.
    cap_names: []const []const u8,
    cap_versions: []const ?[]const u8,

    pub fn deinit(self: *MaterializeResult) void {
        self.arena.deinit();
    }
};

/// Union of all errors materializeAgent may return. Kept as an `anyerror`-like
/// inferred set implicitly via `!MaterializeResult`; this alias is exposed for
/// callers that wish to name it.
pub const MaterializeError = anyerror;

/// Materialize all capabilities referenced by an agent into
/// `<project_root>/.mc/runtime/<agent.name>/`.
pub fn materializeAgent(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    agent: agent_schema.Agent,
    diags: *diag.Diagnostics,
) !MaterializeResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const agent_name = try a.dupe(u8, agent.name);

    // 1. Build sorted, deduplicated capability list from skills+commands+extensions.
    // Commands aren't materialized (they're slash commands); spec says UNION of
    // skills, commands, extensions — we still treat commands the same for
    // materialization purposes (they point at on-disk directories under plugins).
    var cap_set = std.StringHashMap(void).init(allocator);
    defer cap_set.deinit();
    for (agent.capabilities.skills) |name| try cap_set.put(try a.dupe(u8, name), {});
    for (agent.capabilities.extensions) |name| try cap_set.put(try a.dupe(u8, name), {});
    // commands are `/name` form; strip the leading slash before considering
    // them as capability directory names.
    for (agent.capabilities.commands) |name| {
        const n = if (name.len > 0 and name[0] == '/') name[1..] else name;
        try cap_set.put(try a.dupe(u8, n), {});
    }

    var caps_sorted = try allocator.alloc([]const u8, cap_set.count());
    defer allocator.free(caps_sorted);
    {
        var i: usize = 0;
        var it = cap_set.keyIterator();
        while (it.next()) |k| : (i += 1) caps_sorted[i] = k.*;
        std.mem.sort([]const u8, caps_sorted, {}, strLessThan);
    }

    // 2. Prepare runtime dir: <project_root>/.mc/runtime/<agent.name>/
    const runtime_dir = try std.fs.path.join(a, &.{ project_root, ".mc", "runtime", agent_name });
    compat.makePathAbsolute(runtime_dir) catch return error.RuntimeDirCreationFailed;

    var traces: std.ArrayList(FileTrace) = .empty;
    var cap_versions = try a.alloc(?[]const u8, caps_sorted.len);
    const agent_file_rel = try std.fmt.allocPrint(
        diags.arena.allocator(),
        "agents/{s}/agent.json",
        .{agent_name},
    );

    var missing_any = false;

    for (caps_sorted, 0..) |cap, cap_idx| {
        cap_versions[cap_idx] = null;

        const library_dir = try std.fs.path.join(a, &.{ project_root, ".mc", "plugins", cap });
        const project_dir = try std.fs.path.join(a, &.{ project_root, "overrides", cap });
        const agent_dir = try std.fs.path.join(
            a,
            &.{ project_root, "agents", agent_name, "overrides", cap },
        );

        // Library must exist as a directory.
        const library_present = isDir(library_dir);
        if (!library_present) {
            const dpath = try diags.arena.allocator().dupe(u8, "capabilities.*");
            try diags.err(
                agent_file_rel,
                dpath,
                "capability '{s}' not installed",
                .{cap},
            );
            missing_any = true;
            continue;
        }

        // Optional library version from plugin.json.
        cap_versions[cap_idx] = readPluginVersion(a, library_dir) catch null;

        // Prepare per-capability runtime dir.
        const cap_runtime = try std.fs.path.join(a, &.{ runtime_dir, cap });
        compat.makePathAbsolute(cap_runtime) catch return error.RuntimeDirCreationFailed;

        // Track which relative paths have been materialized (for additive passes).
        var done = std.StringHashMap(void).init(allocator);
        defer {
            // Free duped keys
            var it = done.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            done.deinit();
        }

        // Pass 1: walk library layer; resolve layer per file.
        try walkAndMaterialize(
            allocator,
            a,
            library_dir,
            cap_runtime,
            cap,
            .library,
            project_dir,
            agent_dir,
            &traces,
            &done,
            diags,
            agent_file_rel,
        );

        // Pass 2: additive project files (present in project but not in library).
        if (isDir(project_dir)) {
            try walkAdditive(
                allocator,
                a,
                project_dir,
                cap_runtime,
                cap,
                .project,
                &traces,
                &done,
                diags,
                agent_file_rel,
            );
        }

        // Pass 3: additive agent files (present in agent but not library or project).
        if (isDir(agent_dir)) {
            try walkAdditive(
                allocator,
                a,
                agent_dir,
                cap_runtime,
                cap,
                .agent,
                &traces,
                &done,
                diags,
                agent_file_rel,
            );
        }
    }

    const traces_slice = try traces.toOwnedSlice(a);

    const result = MaterializeResult{
        .runtime_dir = runtime_dir,
        .traces = traces_slice,
        .allocator = allocator,
        .arena = arena,
        .agent_name = agent_name,
        .cap_names = try a.dupe([]const u8, caps_sorted),
        .cap_versions = cap_versions,
    };

    if (missing_any) return error.LibraryCapabilityMissing;

    return result;
}

/// Walk `src_dir` and copy each regular file to `dst_dir`/<rel>, choosing the
/// effective source from (agent > project > library) based on `override_a` /
/// `override_p` existence. Records traces and marks `done` for each copied
/// relative path.
fn walkAndMaterialize(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    library_dir: []const u8,
    dst_dir: []const u8,
    cap: []const u8,
    _: Layer, // always library base pass
    project_dir: []const u8,
    agent_dir: []const u8,
    traces: *std.ArrayList(FileTrace),
    done: *std.StringHashMap(void),
    diags: *diag.Diagnostics,
    diag_file: []const u8,
) !void {
    var root = try compat.openDirAbsolute(library_dir);
    defer root.close(compat.getIo());

    var walker = try root.walk(allocator);
    defer walker.deinit();

    while (try walker.next(compat.getIo())) |entry| {
        if (entry.kind == .directory) {
            // skip .git subtrees; walker will still descend but we can't easily
            // prune. To prune, detect on first visit and simply don't record it.
            // Files inside .git will be rejected below via relative-path check.
            continue;
        }

        const rel = try arena.dupe(u8, entry.path);
        if (containsGitDir(rel)) continue;

        if (entry.kind != .file) {
            // symlink, socket, etc.
            const dpath = try std.fmt.allocPrint(
                diags.arena.allocator(),
                "{s}/{s}",
                .{ cap, rel },
            );
            try diags.warn(
                diag_file,
                dpath,
                "skipping non-regular file (kind={s})",
                .{@tagName(entry.kind)},
            );
            continue;
        }

        // Determine effective source layer.
        var src_abs: []const u8 = undefined;
        var layer: Layer = .library;

        const agent_candidate = try std.fs.path.join(arena, &.{ agent_dir, rel });
        const project_candidate = try std.fs.path.join(arena, &.{ project_dir, rel });
        const library_candidate = try std.fs.path.join(arena, &.{ library_dir, rel });

        if (isRegularFile(agent_candidate)) {
            src_abs = agent_candidate;
            layer = .agent;
        } else if (isRegularFile(project_candidate)) {
            src_abs = project_candidate;
            layer = .project;
        } else {
            src_abs = library_candidate;
            layer = .library;
        }

        try copyInto(dst_dir, rel, src_abs);

        try traces.append(arena, .{
            .capability = try arena.dupe(u8, cap),
            .relative_path = rel,
            .layer = layer,
            .source_absolute = try arena.dupe(u8, src_abs),
        });

        const key = try allocator.dupe(u8, rel);
        try done.put(key, {});
    }
}

/// Walk an additive source directory; copy any file whose relative path is
/// not yet present in `done`.
fn walkAdditive(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    src_dir: []const u8,
    dst_dir: []const u8,
    cap: []const u8,
    layer: Layer,
    traces: *std.ArrayList(FileTrace),
    done: *std.StringHashMap(void),
    diags: *diag.Diagnostics,
    diag_file: []const u8,
) !void {
    var root = try compat.openDirAbsolute(src_dir);
    defer root.close(compat.getIo());

    var walker = try root.walk(allocator);
    defer walker.deinit();

    while (try walker.next(compat.getIo())) |entry| {
        if (entry.kind == .directory) continue;
        const rel = try arena.dupe(u8, entry.path);
        if (containsGitDir(rel)) continue;

        if (entry.kind != .file) {
            const dpath = try std.fmt.allocPrint(
                diags.arena.allocator(),
                "{s}/{s}",
                .{ cap, rel },
            );
            try diags.warn(
                diag_file,
                dpath,
                "skipping non-regular file (kind={s})",
                .{@tagName(entry.kind)},
            );
            continue;
        }

        if (done.contains(rel)) continue;

        const src_abs = try std.fs.path.join(arena, &.{ src_dir, rel });
        try copyInto(dst_dir, rel, src_abs);

        try traces.append(arena, .{
            .capability = try arena.dupe(u8, cap),
            .relative_path = rel,
            .layer = layer,
            .source_absolute = try arena.dupe(u8, src_abs),
        });
        const key = try allocator.dupe(u8, rel);
        try done.put(key, {});
    }
}

fn copyInto(dst_dir: []const u8, rel: []const u8, src_abs: []const u8) !void {
    // Ensure parent dir exists under dst_dir/<rel>.
    var stack_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const tmp_a = fba.allocator();

    const dst_abs = try std.fs.path.join(tmp_a, &.{ dst_dir, rel });
    if (std.fs.path.dirname(dst_abs)) |parent| {
        try compat.makePathAbsolute(parent);
    }

    // copyFile preserves source file mode by default.
    try compat.copyFileAbsolute(src_abs, dst_abs);
}

fn isDir(abs: []const u8) bool {
    return compat.isDir(abs);
}

fn isRegularFile(abs: []const u8) bool {
    return compat.isFile(abs);
}

fn containsGitDir(rel_path: []const u8) bool {
    // Walker's path uses platform separator; check each component for ".git".
    var it = std.mem.splitScalar(u8, rel_path, std.fs.path.sep);
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".git")) return true;
    }
    return false;
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn readPluginVersion(arena: std.mem.Allocator, library_dir: []const u8) !?[]const u8 {
    const plugin_json_path = try std.fs.path.join(arena, &.{ library_dir, "plugin.json" });
    const contents = compat.readFile(arena, plugin_json_path) catch return null;

    var parsed = std.json.parseFromSlice(std.json.Value, arena, contents, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const v = parsed.value.object.get("version") orelse return null;
    if (v != .string) return null;
    return try arena.dupe(u8, v.string);
}

// -- trace.json writing -----------------------------------------------------

const TraceFile = struct {
    path: []const u8,
    layer: []const u8,
    source: []const u8,
};

/// Write trace.json to `<runtime_dir>/trace.json`.
pub fn writeTrace(result: MaterializeResult, allocator: std.mem.Allocator) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    // Group traces by capability.
    var by_cap = std.StringHashMap(std.ArrayList(TraceFile)).init(a);

    for (result.traces) |t| {
        const gop = try by_cap.getOrPut(t.capability);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, .{
            .path = t.relative_path,
            .layer = t.layer.toString(),
            .source = t.source_absolute,
        });
    }

    // Sort capabilities alphabetically; within each, sort files by path.
    var cap_order = try a.alloc([]const u8, result.cap_names.len);
    for (result.cap_names, 0..) |n, i| cap_order[i] = n;
    std.mem.sort([]const u8, cap_order, {}, strLessThan);

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\n  \"agent\": ");
    try std.json.Stringify.encodeJsonString(result.agent_name, .{}, w);
    try w.writeAll(",\n  \"generated_at\": ");
    const ts = try isoTimestamp(a);
    try std.json.Stringify.encodeJsonString(ts, .{}, w);
    try w.writeAll(",\n  \"capabilities\": [");

    var first_cap = true;
    for (cap_order) |cap_name| {
        if (!first_cap) try w.writeAll(",");
        first_cap = false;
        try w.writeAll("\n    {\n      \"name\": ");
        try std.json.Stringify.encodeJsonString(cap_name, .{}, w);
        try w.writeAll(",\n      \"library_version\": ");
        // Find version from cap_versions via cap_names ordering.
        var version: ?[]const u8 = null;
        for (result.cap_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, cap_name)) {
                version = result.cap_versions[i];
                break;
            }
        }
        if (version) |v| {
            try std.json.Stringify.encodeJsonString(v, .{}, w);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\n      \"files\": [");

        if (by_cap.getPtr(cap_name)) |list_ptr| {
            const list = list_ptr.*;
            std.mem.sort(TraceFile, list.items, {}, traceFileLessThan);
            var first_f = true;
            for (list.items) |tf| {
                if (!first_f) try w.writeAll(",");
                first_f = false;
                try w.writeAll("\n        { \"path\": ");
                try std.json.Stringify.encodeJsonString(tf.path, .{}, w);
                try w.writeAll(", \"layer\": ");
                try std.json.Stringify.encodeJsonString(tf.layer, .{}, w);
                try w.writeAll(", \"source\": ");
                try std.json.Stringify.encodeJsonString(tf.source, .{}, w);
                try w.writeAll(" }");
            }
            if (list.items.len > 0) try w.writeAll("\n      ");
        }
        try w.writeAll("]\n    }");
    }
    if (cap_order.len > 0) try w.writeAll("\n  ");
    try w.writeAll("]\n}\n");

    const trace_path = try std.fs.path.join(a, &.{ result.runtime_dir, "trace.json" });
    try compat.writeFileAtPath(trace_path, aw.writer.buffered());
}

fn traceFileLessThan(_: void, a: TraceFile, b: TraceFile) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn isoTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    const ts: i64 = compat.nowUnixSeconds();
    // Break down into UTC components (simple epoch-based calc).
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            @as(u32, year_day.year),
            month_day.month.numeric(),
            @as(u32, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}
