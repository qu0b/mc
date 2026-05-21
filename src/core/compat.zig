// Install-time compatibility enforcement.
//
// A plugin may declare a `compat` block:
//   {
//     "pluginApi":    "<semver-range>",   // plugin-contract version
//     "minMcVersion": "<semver-range>",   // host mc version
//     "minPiVersion": "<semver-range>"    // host pi version (optional tool)
//   }
// Each range is checked against live host facts; violations produce
// diagnostics and cause `mc add` / `mc install` to refuse the operation
// unless `--ignore-compat` is passed.

const std = @import("std");
const diag = @import("diagnostic");
const semver = @import("semver");
const plugin_schema = @import("plugin");
const io_compat = @import("iocompat");

/// The mc version baked into this binary. Must match `VERSION` in
/// `src/cli/commands.zig` — duplicated because `commands.zig` is a CLI
/// module that pulls in heavier deps.
pub const MC_VERSION: []const u8 = "0.1.0";

/// The plugin API contract version this mc implements. Bump when the
/// plugin contract (`.claude-plugin/plugin.json` semantics) changes
/// incompatibly.
pub const PLUGIN_API: []const u8 = "1.0.0";

pub const HostFacts = struct {
    mc_version: []const u8,
    /// null if `pi` was not found on PATH or returned no parseable version.
    pi_version: ?[]const u8 = null,
    plugin_api: []const u8 = PLUGIN_API,
};

/// Detect host facts. `mc_version` and `plugin_api` are compile-time
/// constants. `pi_version` is best-effort: we shell out to `pi --version`
/// using `std.process.Child.run`; any failure (missing binary, non-zero
/// exit, unparseable output) leaves `pi_version` null.
pub fn detectHostFacts(allocator: std.mem.Allocator) !HostFacts {
    return .{
        .mc_version = MC_VERSION,
        .pi_version = detectPiVersion(allocator),
        .plugin_api = PLUGIN_API,
    };
}

/// Probe `pi --version`. Returns the first semver-looking token on
/// success, otherwise null. All errors are swallowed — the absence of
/// `pi` is a normal condition, not a failure.
fn detectPiVersion(allocator: std.mem.Allocator) ?[]const u8 {
    // Best-effort probe; any failure (missing binary, non-zero exit,
    // unparseable output) yields null. `result.out` is left to the caller's
    // arena/GPA — a single startup string, intentionally not freed here.
    const result = io_compat.runCommandOutput(allocator, &.{ "pi", "--version" }) catch return null;
    if (result.code != 0) return null;
    return extractSemverToken(allocator, result.out);
}

/// Scan `text` for the first `D.D.D[...]` token that `parseVersion`
/// accepts. Returns a newly-allocated copy on success.
fn extractSemverToken(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len) {
        // Advance to next digit.
        while (i < text.len and !isDigit(text[i])) : (i += 1) {}
        if (i >= text.len) break;
        // Consume run of [0-9A-Za-z.+-] (semver-shaped).
        var j: usize = i;
        while (j < text.len and isSemverChar(text[j])) : (j += 1) {}
        const token = text[i..j];
        if (semver.parseVersion(token)) |_| {
            return allocator.dupe(u8, token) catch null;
        } else |_| {}
        i = if (j == i) i + 1 else j;
    }
    return null;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isSemverChar(c: u8) bool {
    return isDigit(c) or c == '.' or c == '-' or c == '+' or
        (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

/// Check a plugin's compat block against host facts.
///
/// Emits one diagnostic per unsatisfied range; returns true iff ALL
/// checks passed. A null `compat` returns true with no diagnostics.
///
/// `plugin_name` is woven into messages for user clarity. `file` is the
/// source path used in the Diagnostics entry (typically the plugin.json
/// that carried the `compat` block).
pub fn checkCompat(
    compat: plugin_schema.Compat,
    host: HostFacts,
    plugin_name: []const u8,
    file: []const u8,
    diags: *diag.Diagnostics,
) !bool {
    var ok = true;

    if (compat.pluginApi) |range| {
        if (!try checkOne(
            range,
            host.plugin_api,
            "pluginApi",
            "plugin API",
            plugin_name,
            file,
            diags,
        )) ok = false;
    }

    if (compat.minMcVersion) |range| {
        if (!try checkOne(
            range,
            host.mc_version,
            "minMcVersion",
            "mc",
            plugin_name,
            file,
            diags,
        )) ok = false;
    }

    if (compat.minPiVersion) |range| {
        if (host.pi_version) |pv| {
            if (!try checkOne(
                range,
                pv,
                "minPiVersion",
                "pi",
                plugin_name,
                file,
                diags,
            )) ok = false;
        } else {
            const path = try diags.arena.allocator().dupe(u8, "compat.minPiVersion");
            try diags.warn(
                file,
                path,
                "plugin '{s}' declares minPiVersion {s} but pi is not available for version detection; skipping check",
                .{ plugin_name, range },
            );
        }
    }

    return ok;
}

fn checkOne(
    range: []const u8,
    host_version: []const u8,
    field: []const u8,
    label: []const u8,
    plugin_name: []const u8,
    file: []const u8,
    diags: *diag.Diagnostics,
) !bool {
    const path = try std.fmt.allocPrint(
        diags.arena.allocator(),
        "compat.{s}",
        .{field},
    );
    const satisfied = semver.satisfies(host_version, range) catch {
        try diags.err(
            file,
            path,
            "plugin '{s}' has invalid semver range '{s}' for {s}",
            .{ plugin_name, range, field },
        );
        return false;
    };
    if (!satisfied) {
        try diags.err(
            file,
            path,
            "plugin '{s}' requires {s} {s}, host is {s}",
            .{ plugin_name, label, range, host_version },
        );
        return false;
    }
    return true;
}

/// Downgrade every `.err` diagnostic to `.warn` in place. Used when
/// `--ignore-compat` is set so the user still SEES what was skipped.
pub fn downgradeErrorsToWarnings(diags: *diag.Diagnostics) void {
    for (diags.items.items) |*d| {
        if (d.severity == .err) d.severity = .warn;
    }
}

/// Find the plugin.json inside a plugin directory.
/// Tries `<dir>/plugin.json`, then `<dir>/.claude-plugin/plugin.json`.
/// Returns the full path (caller owns); null if neither exists.
pub fn locatePluginJson(allocator: std.mem.Allocator, plugin_dir: []const u8) !?[]const u8 {
    const candidates = [_][]const u8{
        "plugin.json",
        ".claude-plugin/plugin.json",
    };
    for (candidates) |rel| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugin_dir, rel });
        io_compat.accessAbsolute(full) catch {
            allocator.free(full);
            continue;
        };
        return full;
    }
    return null;
}

/// Read plugin.json from `plugin_dir`, extract its compat block, and
/// validate against host. Returns true if compat passes OR if no
/// plugin.json / no compat block is present (both are non-fatal).
///
/// All diagnostics accumulate in `diags`. `plugin_name` labels the
/// plugin in error messages.
pub fn checkPluginDir(
    allocator: std.mem.Allocator,
    plugin_dir: []const u8,
    plugin_name: []const u8,
    host: HostFacts,
    diags: *diag.Diagnostics,
) !bool {
    const pj_path = (try locatePluginJson(allocator, plugin_dir)) orelse return true;
    const src = io_compat.readFile(allocator, pj_path) catch return true;
    const parsed = try plugin_schema.parsePluginStrict(allocator, pj_path, src, diags);
    const p = parsed orelse return !diags.hasErrors();
    const c = p.compat orelse return true;
    return checkCompat(c, host, plugin_name, pj_path, diags);
}
