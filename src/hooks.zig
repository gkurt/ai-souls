//! Installing and removing the global Claude Code hooks.
//!
//! This is the one part of AI Souls that edits a file it does not
//! own, so it is deliberately conservative: `~/.claude/settings.json` is
//! parsed as JSON, only our own hook entries are touched, and
//! everything else — key order, unrelated hooks, unrelated settings — is
//! carried through untouched. A timestamp-free backup is written once,
//! the first time we ever modify the file.
//!
//! It runs in the CLI tier, never inside `update`: JSON needs an
//! allocator, and the app reaches it by re-invoking its own binary
//! (`ai-souls install`) through the effects channel.

const std = @import("std");
const souls = @import("souls.zig");
const config_mod = @import("config.zig");
const paths_mod = @import("paths.zig");

pub const max_settings_bytes = 4 * 1024 * 1024;

pub const Report = struct {
    installed: usize = 0,
    removed: usize = 0,
    /// The file did not exist and we created it.
    created: bool = false,
};

pub const Error = error{
    /// settings.json exists but its top level is not a JSON object, so
    /// we cannot safely merge into it.
    SettingsNotAnObject,
    /// settings.json exists but is not valid JSON.
    SettingsMalformed,
    NoHomeDirectory,
} || std.mem.Allocator.Error;

/// Rewrite `~/.claude/settings.json` so its hook set matches `config`:
/// every enabled catalog event gets exactly one AI Souls entry, and
/// every disabled one has its entry removed. Returns what changed.
pub fn install(
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: *const paths_mod.Paths,
    config: *const config_mod.Config,
) !Report {
    return apply(gpa, io, paths, config);
}

/// Remove every AI Souls hook entry and leave the rest of the file
/// alone.
pub fn uninstall(
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: *const paths_mod.Paths,
) !Report {
    return apply(gpa, io, paths, null);
}

fn apply(
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: *const paths_mod.Paths,
    config: ?*const config_mod.Config,
) !Report {
    if (paths.claude_settings.isEmpty()) return Error.NoHomeDirectory;
    const settings_path = paths.claude_settings.slice();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = std.Io.Dir.cwd();
    var report: Report = .{};

    const existing: ?[]const u8 = cwd.readFileAlloc(
        io,
        settings_path,
        arena,
        .limited(max_settings_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    var root: std.json.Value = if (existing) |text| blk: {
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) break :blk emptyObject();
        break :blk std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            text,
            .{},
        ) catch return Error.SettingsMalformed;
    } else blk: {
        report.created = true;
        break :blk emptyObject();
    };

    if (root != .object) return Error.SettingsNotAnObject;

    const hooks = try hooksObject(arena, &root);
    report.removed = try stripOurs(arena, hooks);
    if (config) |cfg| report.installed = try addOurs(arena, hooks, paths, cfg);
    try dropEmptyEventArrays(hooks);

    // Write the backup before the first modification, and only then —
    // re-running install must not clobber the user's pristine copy.
    if (existing) |text| try writeBackupOnce(io, cwd, arena, settings_path, text);

    const rendered = try std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
    const parent = paths_mod.parent(settings_path);
    if (parent.len > 0) cwd.createDirPath(io, parent) catch {};
    try cwd.writeFile(io, .{ .sub_path = settings_path, .data = rendered });

    return report;
}

fn emptyObject() std.json.Value {
    return .{ .object = .empty };
}

/// The `hooks` object, created if the file has none.
fn hooksObject(arena: std.mem.Allocator, root: *std.json.Value) !*std.json.ObjectMap {
    if (root.object.getPtr("hooks")) |existing| {
        if (existing.* == .object) return &existing.object;
        // A `hooks` key of the wrong shape is not something we can merge
        // into; replace it, since it could never have worked anyway.
        existing.* = emptyObject();
        return &existing.object;
    }
    try root.object.put(arena, "hooks", emptyObject());
    return &root.object.getPtr("hooks").?.object;
}

/// Binary names an entry of ours can be running under. `claude-souls`
/// is the pre-rename name: entries written by an older build have to
/// stay recognisable, or `uninstall` would walk past them and `install`
/// would leave a duplicate screen firing on every event.
const our_binaries = [_][]const u8{ "ai-souls", "claude-souls" };

/// Is this one hook command ours? Matched on shape rather than on a
/// marker field, so we never write a key Claude Code's schema does not
/// know about.
fn isOurCommand(entry: std.json.Value) bool {
    if (entry != .object) return false;
    const kind = entry.object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "command")) return false;

    const command = entry.object.get("command") orelse return false;
    if (command != .string) return false;
    const name = basename(command.string);
    var ours = false;
    for (our_binaries) |candidate| {
        if (std.mem.startsWith(u8, name, candidate)) ours = true;
    }
    if (!ours) return false;

    const args = entry.object.get("args") orelse return false;
    if (args != .array or args.array.items.len < 2) return false;
    const verb = args.array.items[0];
    if (verb != .string or !std.mem.eql(u8, verb.string, "fire")) return false;
    const key = args.array.items[1];
    return key == .string and souls.indexOfKey(key.string) != null;
}

fn basename(path: []const u8) []const u8 {
    var index = path.len;
    while (index > 0) {
        index -= 1;
        if (path[index] == '/' or path[index] == '\\') return path[index + 1 ..];
    }
    return path;
}

/// Drop every AI Souls command from every matcher group, and drop
/// groups we emptied. Returns how many commands were removed.
fn stripOurs(arena: std.mem.Allocator, hooks: *std.json.ObjectMap) !usize {
    var removed: usize = 0;
    for (hooks.values()) |*event_value| {
        if (event_value.* != .array) continue;

        var kept_groups = std.json.Array.init(arena);
        for (event_value.array.items) |group| {
            if (group != .object) {
                try kept_groups.append(group);
                continue;
            }
            const group_hooks = group.object.getPtr("hooks") orelse {
                try kept_groups.append(group);
                continue;
            };
            if (group_hooks.* != .array) {
                try kept_groups.append(group);
                continue;
            }

            var kept_commands = std.json.Array.init(arena);
            for (group_hooks.array.items) |command| {
                if (isOurCommand(command)) {
                    removed += 1;
                } else {
                    try kept_commands.append(command);
                }
            }
            if (kept_commands.items.len == 0) continue; // the group was only ours
            group_hooks.* = .{ .array = kept_commands };
            try kept_groups.append(group);
        }
        event_value.* = .{ .array = kept_groups };
    }
    return removed;
}

/// Append one AI Souls group per enabled catalog event.
fn addOurs(
    arena: std.mem.Allocator,
    hooks: *std.json.ObjectMap,
    paths: *const paths_mod.Paths,
    config: *const config_mod.Config,
) !usize {
    var installed: usize = 0;
    // Not `paths.exe`: a hook outlives the process that wrote it, so it
    // has to name a path that outlives the package manager too.
    const exe = paths.hookCommand();
    if (exe.len == 0) return 0;

    for (souls.events, 0..) |event, index| {
        if (!config.events[index].enabled) continue;

        var command: std.json.ObjectMap = .empty;
        try command.put(arena, "type", .{ .string = "command" });
        try command.put(arena, "command", .{ .string = try arena.dupe(u8, exe) });

        var args = std.json.Array.init(arena);
        try args.append(.{ .string = "fire" });
        try args.append(.{ .string = event.key });
        try command.put(arena, "args", .{ .array = args });

        if (event.condition.len > 0) {
            try command.put(arena, "if", .{ .string = event.condition });
        }
        // The screen is decoration; it must never hold up a turn.
        try command.put(arena, "async", .{ .bool = true });
        try command.put(arena, "timeout", .{ .integer = 5 });

        var group_hooks = std.json.Array.init(arena);
        try group_hooks.append(.{ .object = command });

        var group: std.json.ObjectMap = .empty;
        if (event.matcher.len > 0) try group.put(arena, "matcher", .{ .string = event.matcher });
        try group.put(arena, "hooks", .{ .array = group_hooks });

        const slot = try hooks.getOrPut(arena, event.hook_event);
        if (!slot.found_existing or slot.value_ptr.* != .array) {
            slot.value_ptr.* = .{ .array = std.json.Array.init(arena) };
        }
        try slot.value_ptr.array.append(.{ .object = group });
        installed += 1;
    }
    return installed;
}

/// An event key whose array we emptied would otherwise linger as noise.
fn dropEmptyEventArrays(hooks: *std.json.ObjectMap) !void {
    var index: usize = 0;
    while (index < hooks.count()) {
        const value = hooks.values()[index];
        if (value == .array and value.array.items.len == 0) {
            // orderedRemove keeps the user's remaining key order intact.
            _ = hooks.orderedRemove(hooks.keys()[index]);
            continue;
        }
        index += 1;
    }
}

fn writeBackupOnce(
    io: std.Io,
    cwd: std.Io.Dir,
    arena: std.mem.Allocator,
    settings_path: []const u8,
    original: []const u8,
) !void {
    // A pre-rename backup counts: the point is one snapshot of the file
    // as it was before AI Souls ever touched it, and that is what an
    // older build already took.
    const legacy = try std.fmt.allocPrint(arena, "{s}.claude-souls-backup", .{settings_path});
    if (cwd.access(io, legacy, .{})) |_| return else |_| {}
    const backup = try std.fmt.allocPrint(arena, "{s}.ai-souls-backup", .{settings_path});
    if (cwd.access(io, backup, .{})) |_| return else |_| {}
    cwd.writeFile(io, .{ .sub_path = backup, .data = original }) catch {};
}

// ------------------------------------------------------------- tests

const testing = std.testing;

fn renderApplied(
    arena: std.mem.Allocator,
    source: []const u8,
    config: ?*const config_mod.Config,
) ![]const u8 {
    var root = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
    const hooks = try hooksObject(arena, &root);
    _ = try stripOurs(arena, hooks);
    if (config) |cfg| {
        var paths: paths_mod.Paths = .{};
        paths.exe.set("/opt/npm/ai-souls");
        // What install would have put there before writing anything.
        paths.runtime_exe.set("/home/ashen/.ai-souls/bin/ai-souls");
        _ = try addOurs(arena, hooks, &paths, cfg);
    }
    try dropEmptyEventArrays(hooks);
    return std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });
}

test "install preserves unrelated settings and unrelated hooks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = config_mod.Config.default();
    const rendered = try renderApplied(arena,
        \\{
        \\  "model": "opus",
        \\  "hooks": {
        \\    "Stop": [
        \\      { "hooks": [ { "type": "command", "command": "/usr/bin/say", "args": ["done"] } ] }
        \\    ]
        \\  }
        \\}
    , &config);

    try testing.expect(std.mem.indexOf(u8, rendered, "\"model\": \"opus\"") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "/usr/bin/say") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"turn_complete\"") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "/home/ashen/.ai-souls/bin/ai-souls") != null);
}

test "hooks name the copy under the home directory, never the package manager's path" {
    // The regression this guards is silent and delayed: npm's global
    // prefix is versioned and npx's cache is collected, so a hook that
    // named either would stop working with nothing to show for it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var paths: paths_mod.Paths = .{};
    paths.exe.set("/home/ashen/.npm/_npx/ab12/node_modules/ai-souls/vendor/linux-x64/ai-souls");
    paths.runtime_exe.set("/home/ashen/.ai-souls/bin/ai-souls");
    try testing.expectEqualStrings("/home/ashen/.ai-souls/bin/ai-souls", paths.hookCommand());

    var root = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const hooks = try hooksObject(arena, &root);
    const config = config_mod.Config.default();
    _ = try addOurs(arena, hooks, &paths, &config);
    const rendered = try std.json.Stringify.valueAlloc(arena, root, .{ .whitespace = .indent_2 });

    try testing.expect(std.mem.indexOf(u8, rendered, "_npx") == null);
    try testing.expect(std.mem.indexOf(u8, rendered, ".ai-souls/bin/ai-souls") != null);

    // With no home to copy into there is nothing better than the
    // running binary — a case `install` refuses before reaching here.
    var homeless: paths_mod.Paths = .{};
    homeless.exe.set("/opt/ai-souls");
    try testing.expectEqualStrings("/opt/ai-souls", homeless.hookCommand());
}

test "hooks written by the pre-rename binary are still ours to remove" {
    // Someone who installed under the old name and then upgraded has
    // claude-souls entries in their settings.json. Walking past them
    // would leave every screen firing twice.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cleaned = try renderApplied(arena,
        \\{
        \\  "hooks": {
        \\    "Stop": [
        \\      { "hooks": [
        \\        { "type": "command", "command": "/opt/claude-souls", "args": ["fire", "turn_complete"] },
        \\        { "type": "command", "command": "/usr/bin/say", "args": ["done"] }
        \\      ] }
        \\    ]
        \\  }
        \\}
    , null);

    try testing.expect(std.mem.indexOf(u8, cleaned, "claude-souls") == null);
    try testing.expect(std.mem.indexOf(u8, cleaned, "/usr/bin/say") != null);
}

test "uninstall removes only our entries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = config_mod.Config.default();
    const installed = try renderApplied(arena,
        \\{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/bin/say", "args": ["done"] } ] } ] } }
    , &config);

    const cleaned = try renderApplied(arena, installed, null);
    try testing.expect(std.mem.indexOf(u8, cleaned, "/usr/bin/say") != null);
    try testing.expect(std.mem.indexOf(u8, cleaned, "claude-souls") == null);
}

test "install is idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = config_mod.Config.default();
    const once = try renderApplied(arena, "{}", &config);
    const twice = try renderApplied(arena, once, &config);
    try testing.expectEqualStrings(once, twice);
}

test "a disabled event has no hook after install" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var config = config_mod.Config.default();
    const index = souls.indexOfKey("turn_complete").?;
    config.events[index].enabled = false;

    const rendered = try renderApplied(arena, "{}", &config);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"turn_complete\"") == null);
    // Its neighbours are untouched — the one we turned off is the only
    // one missing.
    try testing.expect(std.mem.indexOf(u8, rendered, "\"api_error\"") != null);
}

test "the five ways a session starts install as five matcher groups" {
    // They all live under one `SessionStart` key, so the thing that
    // tells them apart on disk is the matcher — and a missing one would
    // quietly make that row fire on all five sources.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var config = config_mod.Config.default();
    for (souls.events, 0..) |event, index| {
        if (std.mem.eql(u8, event.hook_event, "SessionStart")) config.events[index].enabled = true;
    }

    const rendered = try renderApplied(arena, "{}", &config);
    for ([_][]const u8{ "startup", "resume", "clear", "fork", "compact" }) |source| {
        const quoted = try std.fmt.allocPrint(arena, "\"matcher\": \"{s}\"", .{source});
        try testing.expect(std.mem.indexOf(u8, rendered, quoted) != null);
    }

    // And out of the box only the one worth interrupting someone for.
    const defaults = try renderApplied(arena, "{}", &config_mod.Config.default());
    try testing.expect(std.mem.indexOf(u8, defaults, "\"compaction_done\"") != null);
    try testing.expect(std.mem.indexOf(u8, defaults, "\"session_start\"") == null);
}

test "a settings file with no hooks key gains one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = config_mod.Config.default();
    const rendered = try renderApplied(arena, "{\"theme\":\"dark\"}", &config);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"theme\": \"dark\"") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "\"hooks\"") != null);
}
