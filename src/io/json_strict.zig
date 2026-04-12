const std = @import("std");
const diag = @import("diagnostic");

pub const FieldType = enum {
    string,
    number,
    integer,
    boolean,
    object,
    array,
    any,
};

/// Declarative schema for one object field.
pub const FieldSpec = struct {
    name: []const u8,
    type: FieldType,
    required: bool = false,
    description: ?[]const u8 = null,

    /// For `.object` fields: schema of the nested object.
    nested: ?[]const FieldSpec = null,

    /// For `.array` fields: type each element must satisfy.
    element_type: ?FieldType = null,
    /// For arrays of objects: schema of each element (elements must be objects).
    element_nested: ?[]const FieldSpec = null,

    /// For `.string` fields: optional whitelist of allowed values.
    enum_values: ?[]const []const u8 = null,

    /// For `.object` fields used as a map (arbitrary keys): schema each VALUE
    /// (which must itself be an object) must satisfy. Mutually exclusive with
    /// `nested`; when set, unknown-key checks are skipped for this object and
    /// each present value is validated against `map_value_nested`.
    map_value_nested: ?[]const FieldSpec = null,

    /// Optional post-type-check validator; invoked only if type matches.
    validate: ?*const fn (
        value: std.json.Value,
        diags: *diag.Diagnostics,
        file: []const u8,
        path: []const u8,
    ) anyerror!void = null,
};

pub const ParseResult = struct {
    /// Null only on JSON syntax failure.
    value: ?std.json.Value,
};

/// Parse `src` and validate it against `schema` (the root schema describes
/// the expected top-level object). Every error is accumulated in `diags`;
/// the walk never short-circuits on validation errors.
///
/// On JSON syntax failure, emits exactly one root diagnostic and returns
/// `.{ .value = null }`.
pub fn parseStrict(
    allocator: std.mem.Allocator,
    file: []const u8,
    src: []const u8,
    schema: []const FieldSpec,
    diags: *diag.Diagnostics,
) !ParseResult {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, src, .{
        .allocate = .alloc_if_needed,
    }) catch |e| {
        try diags.err(file, "", "JSON syntax error: {s}", .{@errorName(e)});
        return .{ .value = null };
    };

    // Root must be an object.
    if (parsed != .object) {
        try diags.err(file, "", "expected object, got {s}", .{typeName(parsed)});
        return .{ .value = parsed };
    }

    try validateObject(allocator, file, "", parsed.object, schema, diags);
    return .{ .value = parsed };
}

fn validateObject(
    allocator: std.mem.Allocator,
    file: []const u8,
    path_prefix: []const u8,
    obj: std.json.ObjectMap,
    schema: []const FieldSpec,
    diags: *diag.Diagnostics,
) anyerror!void {
    // Unknown keys. Path is allocated in diags arena so it outlives this scope.
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (findField(schema, key) == null) {
            const known = try joinFieldNames(allocator, schema);
            defer allocator.free(known);
            const key_path = try joinPath(diags.arena.allocator(), path_prefix, key);
            try diags.err(file, key_path, "unknown key '{s}' (known: {s})", .{ key, known });
        }
    }

    // Required fields.
    for (schema) |spec| {
        if (!spec.required) continue;
        if (!obj.contains(spec.name)) {
            const child_path = try joinPath(diags.arena.allocator(), path_prefix, spec.name);
            try diags.err(file, child_path, "required field '{s}' missing", .{spec.name});
        }
    }

    // Each present field that matches a known spec. Child paths allocated in
    // the working `allocator` here — they are handed to validateValue which
    // either recurses (and reallocs deeper paths) or dups into diags arena
    // when emitting a diagnostic.
    for (schema) |spec| {
        const value = obj.get(spec.name) orelse continue;
        const child_path = try joinPath(allocator, path_prefix, spec.name);
        defer allocator.free(child_path);
        try validateValue(allocator, file, child_path, value, spec, diags);
    }
}

fn validateValue(
    allocator: std.mem.Allocator,
    file: []const u8,
    path: []const u8,
    value: std.json.Value,
    spec: FieldSpec,
    diags: *diag.Diagnostics,
) anyerror!void {
    const ok = checkType(spec.type, value);
    if (!ok) {
        const owned_path = try diags.arena.allocator().dupe(u8, path);
        try diags.err(file, owned_path, "expected {s}, got {s}", .{ @tagName(spec.type), typeName(value) });
        return;
    }

    switch (spec.type) {
        .string => {
            if (spec.enum_values) |allowed| {
                const s = value.string;
                var matched = false;
                for (allowed) |v| if (std.mem.eql(u8, v, s)) {
                    matched = true;
                    break;
                };
                if (!matched) {
                    const joined = try joinStrings(allocator, allowed, ", ");
                    defer allocator.free(joined);
                    const owned_path = try diags.arena.allocator().dupe(u8, path);
                    try diags.err(file, owned_path, "must be one of: {s}", .{joined});
                }
            }
        },
        .object => {
            if (spec.nested) |nested| {
                try validateObject(allocator, file, path, value.object, nested, diags);
            } else if (spec.map_value_nested) |value_schema| {
                var it = value.object.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const v = entry.value_ptr.*;
                    const child_path = try joinPath(allocator, path, key);
                    defer allocator.free(child_path);
                    if (v != .object) {
                        const owned = try diags.arena.allocator().dupe(u8, child_path);
                        try diags.err(file, owned, "expected object, got {s}", .{typeName(v)});
                        continue;
                    }
                    try validateObject(allocator, file, child_path, v.object, value_schema, diags);
                }
            }
        },
        .array => {
            const items = value.array.items;
            if (spec.element_nested) |nested| {
                for (items, 0..) |item, i| {
                    const elem_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, i });
                    defer allocator.free(elem_path);
                    if (item != .object) {
                        const owned = try diags.arena.allocator().dupe(u8, elem_path);
                        try diags.err(file, owned, "expected object, got {s}", .{typeName(item)});
                        continue;
                    }
                    try validateObject(allocator, file, elem_path, item.object, nested, diags);
                }
            } else if (spec.element_type) |et| {
                for (items, 0..) |item, i| {
                    if (checkType(et, item)) continue;
                    const elem_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, i });
                    defer allocator.free(elem_path);
                    const owned = try diags.arena.allocator().dupe(u8, elem_path);
                    try diags.err(file, owned, "expected {s}, got {s}", .{ @tagName(et), typeName(item) });
                }
            }
        },
        else => {},
    }

    if (spec.validate) |v| try v(value, diags, file, path);
}

fn checkType(expected: FieldType, v: std.json.Value) bool {
    return switch (expected) {
        .string => v == .string,
        .number => v == .integer or v == .float or v == .number_string,
        .integer => switch (v) {
            .integer => true,
            // Accept floats that are exactly integral (e.g. 42.0).
            .float => |f| std.math.isFinite(f) and @floor(f) == f,
            else => false,
        },
        .boolean => v == .bool,
        .object => v == .object,
        .array => v == .array,
        .any => true,
    };
}

fn typeName(v: std.json.Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "boolean",
        .integer => "integer",
        .float => "number",
        .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn findField(schema: []const FieldSpec, name: []const u8) ?*const FieldSpec {
    for (schema) |*s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

fn joinFieldNames(allocator: std.mem.Allocator, schema: []const FieldSpec) ![]u8 {
    var total: usize = 0;
    for (schema, 0..) |s, i| {
        total += s.name.len;
        if (i + 1 < schema.len) total += 2; // ", "
    }
    const buf = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (schema, 0..) |s, i| {
        @memcpy(buf[off .. off + s.name.len], s.name);
        off += s.name.len;
        if (i + 1 < schema.len) {
            buf[off] = ',';
            buf[off + 1] = ' ';
            off += 2;
        }
    }
    return buf;
}

fn joinStrings(allocator: std.mem.Allocator, parts: []const []const u8, sep: []const u8) ![]u8 {
    var total: usize = 0;
    for (parts, 0..) |p, i| {
        total += p.len;
        if (i + 1 < parts.len) total += sep.len;
    }
    const buf = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (parts, 0..) |p, i| {
        @memcpy(buf[off .. off + p.len], p);
        off += p.len;
        if (i + 1 < parts.len) {
            @memcpy(buf[off .. off + sep.len], sep);
            off += sep.len;
        }
    }
    return buf;
}

fn joinPath(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, name });
}
