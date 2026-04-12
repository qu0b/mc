const std = @import("std");
const json_mod = @import("../io/json.zig");
const mmap_mod = @import("../io/mmap.zig");

/// Supported hook event types.
pub const HookEvent = enum {
    SessionStart,
    UserPromptSubmit,
    PreToolUse,
    PermissionRequest,
    PermissionDenied,
    PostToolUse,
    PostToolUseFailure,
    Notification,
    SubagentStart,
    SubagentStop,
    TaskCreated,
    TaskCompleted,
    Stop,
    StopFailure,
    TeammateIdle,
    InstructionsLoaded,
    ConfigChange,
    CwdChanged,
    FileChanged,
    WorktreeCreate,
    WorktreeRemove,
    PreCompact,
    PostCompact,
    Elicitation,
    ElicitationResult,
    SessionEnd,
};

/// A resolved hook action.
pub const HookAction = struct {
    @"type": []const u8, // "command", "http", "prompt", "agent"
    command: ?[]const u8 = null,
    url: ?[]const u8 = null,
    timeout: ?u64 = null,
};

/// A hook rule: optional matcher + list of actions.
pub const HookRule = struct {
    matcher: ?[]const u8 = null,
    hooks: []const HookAction,
};

/// Top-level hooks config (hooks.json).
pub const HooksConfig = struct {
    description: ?[]const u8 = null,
    hooks: std.json.Value, // Map of event name -> []HookRule
};

/// Extract hook rules for a specific event from a parsed hooks config.
pub fn extractRulesForEvent(allocator: std.mem.Allocator, config: HooksConfig, event_name: []const u8) ![]HookRule {
    const hooks_obj = switch (config.hooks) {
        .object => |o| o,
        else => return &.{},
    };

    const rules_val = hooks_obj.get(event_name) orelse return &.{};
    const rules_arr = switch (rules_val) {
        .array => |a| a,
        else => return &.{},
    };

    var rules: std.ArrayList(HookRule) = .empty;

    for (rules_arr.items) |rule_val| {
        const rule_obj = switch (rule_val) {
            .object => |o| o,
            else => continue,
        };

        const matcher = getStr(rule_obj, "matcher");
        const inner_hooks_val = rule_obj.get("hooks") orelse continue;
        const inner_hooks_arr = switch (inner_hooks_val) {
            .array => |a| a,
            else => continue,
        };

        var actions: std.ArrayList(HookAction) = .empty;
        for (inner_hooks_arr.items) |action_val| {
            const action_obj = switch (action_val) {
                .object => |o| o,
                else => continue,
            };

            try actions.append(allocator, .{
                .@"type" = getStr(action_obj, "type") orelse "command",
                .command = getStr(action_obj, "command"),
                .url = getStr(action_obj, "url"),
                .timeout = getInt(action_obj, "timeout"),
            });
        }

        try rules.append(allocator, .{
            .matcher = matcher,
            .hooks = try actions.toOwnedSlice(allocator),
        });
    }

    return rules.toOwnedSlice(allocator);
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| @intCast(i),
        else => null,
    };
}

test "parse hooks config" {
    const data =
        \\{
        \\  "description": "Test hooks",
        \\  "hooks": {
        \\    "PreToolUse": [
        \\      {
        \\        "matcher": "Write|Edit",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/check.py",
        \\            "timeout": 10
        \\          }
        \\        ]
        \\      }
        \\    ],
        \\    "Stop": [
        \\      {
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "echo done"
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try json_mod.parseSlice(HooksConfig, arena.allocator(), data);
    const pre_rules = try extractRulesForEvent(arena.allocator(), config, "PreToolUse");
    try std.testing.expectEqual(@as(usize, 1), pre_rules.len);
    try std.testing.expectEqualStrings("Write|Edit", pre_rules[0].matcher.?);
    try std.testing.expectEqual(@as(usize, 1), pre_rules[0].hooks.len);
    try std.testing.expectEqual(@as(u64, 10), pre_rules[0].hooks[0].timeout.?);

    const stop_rules = try extractRulesForEvent(arena.allocator(), config, "Stop");
    try std.testing.expectEqual(@as(usize, 1), stop_rules.len);
    try std.testing.expect(stop_rules[0].matcher == null);
}
