//! The binary's non-GUI modes.
//!
//! One executable wears three hats. `claude-souls` with no arguments is
//! the app. `claude-souls fire <event>` is what the installed hooks run
//! — it must start, write one small file, and exit, because it sits on
//! Claude Code's critical path. `claude-souls install-hooks` does the
//! `settings.json` merge, which needs an allocator and therefore cannot
//! live inside the pure `update` — the running app reaches it by
//! spawning itself.

const std = @import("std");
const souls = @import("souls.zig");
const config_mod = @import("config.zig");
const hooks = @import("hooks.zig");
const paths_mod = @import("paths.zig");

/// Longest line the trigger file ever holds: a millisecond timestamp
/// and an event key.
pub const max_trigger_bytes = 64;

pub const Outcome = enum {
    /// A CLI verb ran; `main` should exit with this status.
    handled_ok,
    handled_failed,
    /// No verb given — run the app.
    run_app,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    paths: *const paths_mod.Paths,
) Outcome {
    if (args.len < 2) return .run_app;

    const verb = args[1];
    const rest = args[2..];

    if (eq(verb, "fire")) return fire(io, paths, rest);
    if (eq(verb, "install-hooks")) return installHooks(gpa, io, paths, true);
    if (eq(verb, "uninstall-hooks")) return installHooks(gpa, io, paths, false);
    if (eq(verb, "status")) return status(io, paths);
    if (eq(verb, "events")) return listEvents(io);
    if (eq(verb, "help") or eq(verb, "--help") or eq(verb, "-h")) {
        printUsage(io);
        return .handled_ok;
    }

    say(io, "claude-souls: unknown command \"{s}\"\n\n", .{verb});
    printUsage(io);
    return .handled_failed;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Everything the CLI says goes to stdout, including its failures: the
/// running app spawns these verbs and streams their stdout into the
/// settings window's status line, so a message on stderr would be
/// invisible to the person who pressed the button.
fn say(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    const out = &writer.interface;
    out.print(format, args) catch return;
    out.flush() catch {};
}

/// Stamp the trigger file. The running app polls it; if nothing is
/// running this is a harmless no-op that the next launch will skip
/// (boot reads the stamp without showing a screen).
fn fire(io: std.Io, paths: *const paths_mod.Paths, rest: []const []const u8) Outcome {
    if (rest.len < 1) {
        say(io, "claude-souls fire: expected an event key\n", .{});
        return .handled_failed;
    }
    const key = rest[0];
    if (souls.indexOfKey(key) == null) {
        say(io, "claude-souls fire: unknown event \"{s}\"\n", .{key});
        return .handled_failed;
    }
    if (paths.trigger.isEmpty()) {
        say(io, "claude-souls fire: no home directory\n", .{});
        return .handled_failed;
    }

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, paths.app_dir.slice()) catch {};

    const now_ms = nowMs(io);
    var buffer: [max_trigger_bytes]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{d} {s}\n", .{ now_ms, key }) catch return .handled_failed;

    cwd.writeFile(io, .{ .sub_path = paths.trigger.slice(), .data = line }) catch |err| {
        say(io, "claude-souls fire: {t}\n", .{err});
        return .handled_failed;
    };
    return .handled_ok;
}

fn installHooks(
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: *const paths_mod.Paths,
    installing: bool,
) Outcome {
    const config = readConfig(io, paths);
    const report = blk: {
        if (installing) {
            break :blk hooks.install(gpa, io, paths, &config) catch |err| {
                reportHookError(io, err, paths);
                return .handled_failed;
            };
        }
        break :blk hooks.uninstall(gpa, io, paths) catch |err| {
            reportHookError(io, err, paths);
            return .handled_failed;
        };
    };

    say(io, "{d} hooks written, {d} removed — {s}{s}\n", .{
        report.installed,
        report.removed,
        paths.claude_settings.slice(),
        if (report.created) " (created)" else "",
    });
    return .handled_ok;
}

fn reportHookError(io: std.Io, err: anyerror, paths: *const paths_mod.Paths) void {
    switch (err) {
        hooks.Error.SettingsMalformed => say(
            io,
            "{s} is not valid JSON — fix it and try again; nothing was written\n",
            .{paths.claude_settings.slice()},
        ),
        hooks.Error.SettingsNotAnObject => say(
            io,
            "{s} has no JSON object at its top level; nothing was written\n",
            .{paths.claude_settings.slice()},
        ),
        hooks.Error.NoHomeDirectory => say(
            io,
            "No HOME/USERPROFILE in the environment.\n",
            .{},
        ),
        else => say(io, "Could not update the hooks: {t}\n", .{err}),
    }
}

fn status(io: std.Io, paths: *const paths_mod.Paths) Outcome {
    const config = readConfig(io, paths);
    say(io, "executable      {s}\n", .{paths.exe.slice()});
    say(io, "config          {s}\n", .{paths.config.slice()});
    say(io, "trigger         {s}\n", .{paths.trigger.slice()});
    say(io, "claude settings {s}\n\n", .{paths.claude_settings.slice()});
    for (souls.events, 0..) |event, index| {
        const entry = &config.events[index];
        say(io, "{s:<3} {s:<18} {s:<24} {s}\n", .{
            if (entry.enabled) "on" else "off",
            event.key,
            entry.title.slice(),
            event.hook_event,
        });
    }
    return .handled_ok;
}

fn listEvents(io: std.Io) Outcome {
    for (souls.events) |event| say(io, "{s}\n", .{event.key});
    return .handled_ok;
}

fn printUsage(io: std.Io) void {
    say(
        io,
        \\claude-souls — Dark Souls screens for Claude Code
        \\
        \\  claude-souls                  open the settings window
        \\  claude-souls fire <event>     show a screen (this is what hooks run)
        \\  claude-souls install-hooks    write the enabled hooks into ~/.claude/settings.json
        \\  claude-souls uninstall-hooks  remove every Claude Souls hook
        \\  claude-souls status           show paths and the current per-event settings
        \\  claude-souls events           list the event keys
        \\
    , .{});
}

/// Best-effort config read: a missing or unreadable file is simply the
/// compiled defaults.
pub fn readConfig(io: std.Io, paths: *const paths_mod.Paths) config_mod.Config {
    if (paths.config.isEmpty()) return config_mod.Config.default();
    var buffer: [config_mod.max_config_bytes]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFile(io, paths.config.slice(), &buffer) catch
        return config_mod.Config.default();
    return config_mod.Config.parse(text);
}

pub fn nowMs(io: std.Io) i64 {
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

/// Parse a trigger line (`"<ms> <event-key>\n"`). Pure, so the app's
/// `update` can call it on the bytes the file effect delivers.
pub const Trigger = struct {
    stamp_ms: i64,
    event_index: usize,
};

pub fn parseTrigger(bytes: []const u8) ?Trigger {
    const line = std.mem.trim(u8, bytes, " \t\r\n");
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const stamp = std.fmt.parseInt(i64, line[0..space], 10) catch return null;
    const key = std.mem.trim(u8, line[space + 1 ..], " \t\r\n");
    const index = souls.indexOfKey(key) orelse return null;
    return .{ .stamp_ms = stamp, .event_index = index };
}

test "trigger lines round-trip" {
    var buffer: [max_trigger_bytes]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{d} {s}\n", .{ @as(i64, 1717171717171), "tool_failed" });
    const parsed = parseTrigger(line).?;
    try std.testing.expectEqual(@as(i64, 1717171717171), parsed.stamp_ms);
    try std.testing.expectEqual(souls.indexOfKey("tool_failed").?, parsed.event_index);
}

test "malformed trigger lines are ignored, not guessed at" {
    try std.testing.expect(parseTrigger("") == null);
    try std.testing.expect(parseTrigger("nonsense") == null);
    try std.testing.expect(parseTrigger("abc tool_failed") == null);
    try std.testing.expect(parseTrigger("123 no_such_event") == null);
}
