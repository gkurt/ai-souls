//! The binary's non-GUI modes.
//!
//! One executable wears several hats. `ai-souls` with no arguments is
//! the app. `ai-souls fire <event>` is what the installed hooks run — it
//! must start, write one small file, and exit, because it sits on Claude
//! Code's critical path. `ai-souls install` does the `settings.json`
//! merge, which needs an allocator and therefore cannot live inside the
//! pure `update` — the running app reaches it by spawning itself.
//!
//! Everything that is not a known verb is a headline to put on screen,
//! so `ai-souls "YOU DIED"` does the obvious thing. Verbs win ties;
//! `--` forces the rest of the line to be read as a message.

const std = @import("std");
const souls = @import("souls.zig");
const config_mod = @import("config.zig");
const hooks = @import("hooks.zig");
const paths_mod = @import("paths.zig");

/// The command a person types. Kept in one place because it appears in
/// every usage string and every error message.
pub const command_name = "ai-souls";

/// Coding agents AI Souls knows how to install hooks for. Claude Code is
/// the only one wired up; the argument exists so that adding a second
/// does not change the shape of the command line.
pub const agents = [_][]const u8{"claude"};
pub const default_agent = "claude";

/// Longest line the trigger file ever holds. The worst case is a `!say`
/// carrying a full headline and subtitle plus five numbers.
pub const max_trigger_bytes =
    32 + souls.max_title_bytes + config_mod.max_subtitle_bytes + 48;

pub const Outcome = enum {
    /// A CLI verb ran; `main` should exit with this status.
    handled_ok,
    handled_failed,
    /// No verb given — run the app, settings window and all.
    run_app,
    /// Run the app with its settings window closed to the tray.
    ///
    /// This is how the CLI starts an app for someone who only asked for
    /// a screen: `ai-souls "YOU DIED"` on a machine with nothing running
    /// has to start something, and having a settings window appear —
    /// over the very banner it was asked to draw — is not what anybody
    /// meant.
    run_app_hidden,
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

    // `--` says the rest is a headline even if it reads like a verb.
    if (eq(verb, "--")) return message(io, paths, rest);

    if (eq(verb, "install")) return hooksVerb(gpa, io, paths, rest, true);
    if (eq(verb, "uninstall")) return hooksVerb(gpa, io, paths, rest, false);
    // The pre-rename spellings. An installed hook never calls these,
    // but a script or a muscle memory might.
    if (eq(verb, "install-hooks")) return hooksVerb(gpa, io, paths, rest, true);
    if (eq(verb, "uninstall-hooks")) return hooksVerb(gpa, io, paths, rest, false);
    if (eq(verb, "settings")) return command(io, paths, settings_command);
    if (eq(verb, "serve")) return .run_app_hidden;
    if (eq(verb, "fire")) return fire(io, paths, rest);
    if (eq(verb, "status")) return status(io, paths);
    if (eq(verb, "events")) return listEvents(io);
    if (eq(verb, "help") or eq(verb, "--help") or eq(verb, "-h")) {
        printUsage(io);
        return .handled_ok;
    }

    // An unknown FLAG is a mistake worth reporting; anything else is a
    // headline. Guessing that `--sytle` was meant as a message would
    // put the typo on screen and call it a success.
    if (std.mem.startsWith(u8, verb, "-")) {
        say(io, "{s}: unknown option \"{s}\"\n\n", .{ command_name, verb });
        printUsage(io);
        return .handled_failed;
    }

    return message(io, paths, args[1..]);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Everything the CLI says goes to stdout, including its failures: the
/// running app spawns these verbs and streams their stdout into the
/// settings window's status line, so a message on stderr would be
/// invisible to the person who pressed the button.
///
/// ONE writer for the whole process, not one per call. A file writer
/// carries its own position, so opening a fresh one per line starts
/// each line back at byte zero — invisible on a console, and on
/// `ai-souls status > file` it silently overwrites everything already
/// written with the last line.
var out_buffer: [4096]u8 = undefined;
var out_writer: ?std.Io.File.Writer = null;

fn say(io: std.Io, comptime format: []const u8, args: anytype) void {
    if (out_writer == null) out_writer = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &out_writer.?.interface;
    out.print(format, args) catch return;
    // Flushed per call rather than at exit: a verb can end in
    // `std.process.exit`, which runs no deferred anything.
    out.flush() catch {};
}

/// Stamp the trigger file. The running app polls it five times a
/// second.
///
/// This is what an installed hook runs, so it does the least possible
/// work: no launching, no waiting, no window system. If the app is not
/// running the fire is a no-op the next launch discards, which is the
/// right answer for a hook — a session should not start an app because
/// a tool call failed.
fn fire(io: std.Io, paths: *const paths_mod.Paths, rest: []const []const u8) Outcome {
    if (rest.len < 1) {
        say(io, "{s} fire: expected an event key\n", .{command_name});
        return .handled_failed;
    }
    const key = rest[0];
    if (souls.indexOfKey(key) == null) {
        say(io, "{s} fire: unknown event \"{s}\"\n", .{ command_name, key });
        return .handled_failed;
    }
    var buffer: [max_trigger_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print("{d} {s}\n", .{ nowMs(io), key }) catch return .handled_failed;
    return writeTrigger(io, paths, writer.buffered(), "fire");
}

/// A bare command word (`!settings`). Asked for by a person at a
/// terminal, so unlike `fire` it starts the app if nothing is home.
fn command(io: std.Io, paths: *const paths_mod.Paths, word: []const u8) Outcome {
    const stamp = nowMs(io);
    var buffer: [max_trigger_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print("{d} {s}\n", .{ stamp, word }) catch return .handled_failed;
    const outcome = writeTrigger(io, paths, writer.buffered(), word);
    if (outcome != .handled_ok) return outcome;
    deliver(io, paths, stamp);
    return .handled_ok;
}

/// `ai-souls <headline>` — an ad-hoc screen with no catalog row behind
/// it.
fn message(io: std.Io, paths: *const paths_mod.Paths, args: []const []const u8) Outcome {
    var entry: config_mod.EventSettings = .{
        // A screen someone typed out by hand is worth hearing. The
        // catalog's default volume still applies, so it is an accent
        // rather than an ambush.
        .sound = .gong,
    };

    var headline: [souls.max_title_bytes]u8 = undefined;
    var headline_len: usize = 0;
    var literal = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (!literal and eq(arg, "--")) {
            literal = true;
            continue;
        }
        if (!literal and std.mem.startsWith(u8, arg, "--")) {
            const name = arg[2..];
            index += 1;
            if (index >= args.len) {
                say(io, "{s}: \"--{s}\" needs a value\n", .{ command_name, name });
                return .handled_failed;
            }
            const value = args[index];
            if (!applyOption(io, &entry, name, value)) return .handled_failed;
            continue;
        }

        // A plain word: part of the headline. Words are rejoined with
        // single spaces, so an unquoted phrase and a quoted one land
        // the same way.
        if (headline_len > 0 and headline_len < headline.len) {
            headline[headline_len] = ' ';
            headline_len += 1;
        }
        const room = headline.len - headline_len;
        const take = @min(arg.len, room);
        @memcpy(headline[headline_len..][0..take], arg[0..take]);
        headline_len += take;
    }

    if (headline_len == 0) {
        say(io, "{s}: nothing to say\n\n", .{command_name});
        printUsage(io);
        return .handled_failed;
    }
    entry.title.set(headline[0..headline_len]);

    const stamp = nowMs(io);
    var buffer: [max_trigger_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print("{d} {s} ", .{ stamp, say_command }) catch return .handled_failed;
    entry.writeFields(&writer) catch return .handled_failed;
    writer.writeAll("\n") catch return .handled_failed;

    const outcome = writeTrigger(io, paths, writer.buffered(), "message");
    if (outcome != .handled_ok) return outcome;
    deliver(io, paths, stamp);
    return .handled_ok;
}

/// One `--name value` pair. Returns false having already explained
/// itself.
fn applyOption(
    io: std.Io,
    entry: *config_mod.EventSettings,
    name: []const u8,
    value: []const u8,
) bool {
    if (eq(name, "style")) {
        entry.style = souls.Style.fromName(value) orelse {
            say(io, "{s}: no style called \"{s}\". Try: ", .{ command_name, value });
            listNames(io, souls.Style);
            return false;
        };
        return true;
    }
    if (eq(name, "sound")) {
        entry.sound = souls.Sound.fromName(value) orelse {
            say(io, "{s}: no sound called \"{s}\". Try: ", .{ command_name, value });
            listNames(io, souls.Sound);
            return false;
        };
        return true;
    }
    if (eq(name, "volume")) {
        const parsed = std.fmt.parseInt(u8, value, 10) catch 255;
        if (parsed > 100) {
            say(io, "{s}: --volume takes 0 to 100, not \"{s}\"\n", .{ command_name, value });
            return false;
        }
        entry.volume = parsed;
        return true;
    }
    if (eq(name, "duration")) {
        const parsed = std.fmt.parseInt(u32, value, 10) catch {
            say(io, "{s}: --duration takes milliseconds, not \"{s}\"\n", .{ command_name, value });
            return false;
        };
        if (parsed < config_mod.min_duration_ms or parsed > config_mod.max_duration_ms) {
            say(io, "{s}: --duration takes {d} to {d} milliseconds\n", .{
                command_name,
                config_mod.min_duration_ms,
                config_mod.max_duration_ms,
            });
            return false;
        }
        entry.duration_ms = parsed;
        return true;
    }
    if (eq(name, "subtitle")) {
        entry.subtitle.set(value);
        return true;
    }
    say(io, "{s}: unknown option \"--{s}\"\n\n", .{ command_name, name });
    printUsage(io);
    return false;
}

fn listNames(io: std.Io, comptime E: type) void {
    inline for (@typeInfo(E).@"enum".fields, 0..) |field, index| {
        say(io, "{s}{s}", .{ if (index == 0) "" else ", ", field.name });
    }
    say(io, "\n", .{});
}

fn writeTrigger(
    io: std.Io,
    paths: *const paths_mod.Paths,
    line: []const u8,
    what: []const u8,
) Outcome {
    if (paths.trigger.isEmpty()) {
        say(io, "{s} {s}: no home directory\n", .{ command_name, what });
        return .handled_failed;
    }
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, paths.app_dir.slice()) catch {};
    cwd.writeFile(io, .{ .sub_path = paths.trigger.slice(), .data = line }) catch |err| {
        say(io, "{s} {s}: {t}\n", .{ command_name, what, err });
        return .handled_failed;
    };
    return .handled_ok;
}

// ------------------------------------------------------- is it listening
//
// `~/.ai-souls/alive` is two numbers:
//
//     <heartbeat_ms> <last_consumed_trigger_ms>
//
// The app refreshes it on a slow beat and again the instant it acts on
// a trigger. The heartbeat is what `status` reports; the consumed stamp
// is what actually decides whether the CLI needs to start an app,
// because it is an acknowledgement rather than a guess.

/// How old the heartbeat may be before `status` calls the app gone.
/// Only ever used for the human-readable line: deciding whether to
/// start an app is `awaitConsumed`'s job, and it waits for proof.
pub const alive_stale_ms: i64 = 6_000;

/// How long to give a running app to notice a trigger before deciding
/// there is no running app. It polls five times a second, so this is
/// several chances; a healthy app answers in well under half of it.
const consume_deadline_ms: i64 = 1_200;
const consume_poll_ms: u64 = 40;

pub const Alive = struct {
    heartbeat_ms: i64 = 0,
    consumed_ms: i64 = 0,
};

pub fn parseAlive(bytes: []const u8) ?Alive {
    var fields = std.mem.tokenizeAny(u8, bytes, " \t\r\n");
    const heartbeat = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null;
    // A one-number file is a heartbeat from a build that had not
    // learned to acknowledge yet.
    const consumed = if (fields.next()) |text|
        std.fmt.parseInt(i64, text, 10) catch 0
    else
        0;
    return .{ .heartbeat_ms = heartbeat, .consumed_ms = consumed };
}

/// A heartbeat from the future is a clock that moved, not an app that
/// is dead, so it counts as alive.
pub fn isFresh(now_ms: i64, stamp_ms: i64) bool {
    return now_ms - stamp_ms < alive_stale_ms;
}

fn readAlive(io: std.Io, paths: *const paths_mod.Paths) ?Alive {
    if (paths.alive.isEmpty()) return null;
    var buffer: [64]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, paths.alive.slice(), &buffer) catch return null;
    return parseAlive(text);
}

fn isRunning(io: std.Io, paths: *const paths_mod.Paths) bool {
    const alive = readAlive(io, paths) orelse return false;
    return isFresh(nowMs(io), alive.heartbeat_ms);
}

/// Wait for the app to acknowledge the trigger stamped `stamp_ms`, and
/// start one if nothing is there.
///
/// Two signals, in order of how much they actually prove:
///
///   1. The acknowledgement. The app republishes the newest trigger
///      stamp it has acted on, so seeing our own stamp come back is
///      proof rather than inference. This is the fast path and it
///      normally lands inside a couple of hundred milliseconds.
///
///   2. The heartbeat, consulted only when the acknowledgement never
///      arrives. An app CAN be alive and unable to answer: starting a
///      sound freezes the Win32 message loop for two seconds flat (see
///      `app.sound_delay_ms`), so a message typed while a screen is
///      playing would otherwise look exactly like a dead app and get a
///      second one started on top of the first.
///
/// The gap between them is a few seconds after a crash, where the
/// heartbeat is still warm and the message is dropped. That is the
/// right way round: an app killed in the last six seconds is rare and
/// self-correcting on the next try, and a screen playing a sound is
/// neither.
///
/// All best-effort. The trigger is already on disk either way.
fn deliver(io: std.Io, paths: *const paths_mod.Paths, stamp_ms: i64) void {
    const give_up_at = stamp_ms + consume_deadline_ms;
    var last: ?Alive = null;
    while (nowMs(io) < give_up_at) {
        if (readAlive(io, paths)) |alive| {
            if (alive.consumed_ms >= stamp_ms) return;
            last = alive;
        }
        std.Io.sleep(io, .fromMilliseconds(consume_poll_ms), .awake) catch break;
    }
    if (last) |alive| {
        if (isFresh(nowMs(io), alive.heartbeat_ms)) return;
    }
    startApp(io, paths);
}

fn startApp(io: std.Io, paths: *const paths_mod.Paths) void {
    if (paths.exe.isEmpty()) return;
    var child = std.process.spawn(io, .{
        // `serve`, not a bare launch: whoever is waiting on this asked
        // for a screen, not for the settings window.
        .argv = &.{ paths.exe.slice(), "serve" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // A GUI app started from a terminal should not flash a console
        // window of its own.
        .create_no_window = true,
    }) catch return;
    // Deliberately not waited on: this process is about to exit and the
    // app has to outlive it.
    _ = &child;
}

/// Is this executable somewhere that will be deleted out from under it?
///
/// `npx` unpacks a package into `.../_npx/<hash>/node_modules/...` and
/// npm garbage-collects that directory whenever it feels like it. An
/// installed hook names the binary by absolute path, so hooks written
/// from there keep pointing at a file that is no longer on disk — and
/// because our hooks are `async` with a five second timeout, Claude
/// Code swallows the failure. The screens would simply stop, with
/// nothing anywhere saying why.
///
/// Matched on a whole path SEGMENT, so a project that merely has the
/// letters in its name is not caught.
pub fn isTransientPath(path: []const u8) bool {
    var start: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '/' or byte == '\\') {
            if (eq(path[start..index], "_npx")) return true;
            start = index + 1;
        }
    }
    return eq(path[start..], "_npx");
}

/// `install [agent]` / `uninstall [agent]`. The agent argument is
/// optional and today has exactly one legal value, but naming it is
/// what keeps the command line stable when there are two.
fn hooksVerb(
    gpa: std.mem.Allocator,
    io: std.Io,
    paths: *const paths_mod.Paths,
    rest: []const []const u8,
    installing: bool,
) Outcome {
    // Only installing. Removing hooks from a throwaway copy is a
    // perfectly good thing to want, and it edits nothing that outlives
    // the run.
    if (installing and isTransientPath(paths.exe.slice())) {
        say(io,
            \\{s}: not installing hooks from a temporary copy.
            \\
            \\A hook names this binary by absolute path, and this one is
            \\running out of an npx cache that npm deletes later. The hooks
            \\would survive the binary and then quietly do nothing.
            \\
            \\  npm install -g {s}
            \\  {s} install
            \\
        , .{ command_name, command_name, command_name });
        return .handled_failed;
    }

    if (rest.len > 0) {
        var known = false;
        for (agents) |agent| {
            if (eq(rest[0], agent)) known = true;
        }
        if (!known) {
            say(io, "{s}: no agent called \"{s}\". Supported: ", .{ command_name, rest[0] });
            for (agents, 0..) |agent, index| {
                say(io, "{s}{s}", .{ if (index == 0) "" else ", ", agent });
            }
            say(io, "\n", .{});
            return .handled_failed;
        }
    }
    return installHooks(gpa, io, paths, installing);
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
    say(io, "app             {s}\n", .{
        if (isRunning(io, paths)) "running" else "not running",
    });
    say(io, "config          {s}\n", .{paths.config.slice()});
    say(io, "trigger         {s}\n", .{paths.trigger.slice()});
    say(io, "claude settings {s}\n", .{paths.claude_settings.slice()});
    // Where the sounds resolve from is the first thing to check when
    // they do not play, so it is the first thing `status` says.
    if (paths.assets_root.isEmpty()) {
        say(io, "sounds          NOT FOUND — no assets/ near {s}\n\n", .{paths.exe.slice()});
    } else {
        var buffer: [paths_mod.max_path_bytes]u8 = undefined;
        say(io, "sounds          {s}\n\n", .{paths.asset(&buffer, souls.Sound.gong.path())});
    }
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
        \\AI Souls — Dark Souls screens for your coding agent
        \\
        \\  ai-souls <message>         put a headline on screen
        \\  ai-souls settings          open the settings window
        \\  ai-souls install [agent]   write the enabled hooks into the agent's settings
        \\  ai-souls uninstall [agent] remove every AI Souls hook
        \\  ai-souls status            show paths and the current per-event settings
        \\  ai-souls events            list the event keys
        \\  ai-souls fire <event>      show a catalog event's screen (this is what hooks run)
        \\  ai-souls serve             run in the tray with no window (started for you
        \\                             when a message arrives and nothing is listening)
        \\
        \\Message options:
        \\
        \\  --style <name>      death, bonfire, victory, soul, hollow, covenant
        \\  --sound <name>      silent, gong, choir, chime, ember, thud, you-died
        \\  --volume <0-100>
        \\  --duration <ms>
        \\  --subtitle <text>
        \\  --                  everything after this is the message
        \\
        \\  ai-souls "YOU DIED" --style death --sound you-died
        \\  ai-souls -- status         say "status" instead of running it
        \\
        \\The agent argument is optional and defaults to claude, the only
        \\one supported today.
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

// ----------------------------------------------------------- the trigger
//
// One file, one line, written by whoever wants the running app to do
// something and polled five times a second by the app itself:
//
//     <ms> <event-key>
//     <ms> !say <style> <sound> <volume> <duration> <title>|<subtitle>
//     <ms> !settings
//
// The tail of a `!say` line is exactly what a config event line carries
// after its `enabled` flag, so the two formats share their codec.
//
// Command words are spelled with a leading `!` and event keys are plain
// identifiers, so the two namespaces cannot collide however the catalog
// grows.

pub const say_command = "!say";
pub const settings_command = "!settings";

pub const Action = union(enum) {
    /// Show a catalog event's configured screen.
    event: usize,
    /// Show this exact screen, whatever the catalog says.
    message: config_mod.EventSettings,
    /// Bring the settings window up.
    settings,
};

/// Parse a trigger line. Pure, so the app's `update` can call it on the
/// bytes the file effect delivers.
pub const Trigger = struct {
    stamp_ms: i64,
    action: Action,
};

pub fn parseTrigger(bytes: []const u8) ?Trigger {
    const line = std.mem.trim(u8, bytes, " \t\r\n");
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const stamp = std.fmt.parseInt(i64, line[0..space], 10) catch return null;
    const rest = std.mem.trim(u8, line[space + 1 ..], " \t\r\n");

    if (eq(rest, settings_command)) return .{ .stamp_ms = stamp, .action = .settings };

    if (std.mem.startsWith(u8, rest, say_command)) {
        const tail = std.mem.trimStart(u8, rest[say_command.len..], " ");
        // A screen with nothing to say is not a screen.
        if (tail.len == 0) return null;
        var entry: config_mod.EventSettings = .{};
        entry.readFields(tail);
        if (entry.title.len == 0) return null;
        return .{ .stamp_ms = stamp, .action = .{ .message = entry } };
    }

    const index = souls.indexOfKey(rest) orelse return null;
    return .{ .stamp_ms = stamp, .action = .{ .event = index } };
}

test "trigger lines round-trip" {
    var buffer: [max_trigger_bytes]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{d} {s}\n", .{ @as(i64, 1717171717171), "tool_failed" });
    const parsed = parseTrigger(line).?;
    try std.testing.expectEqual(@as(i64, 1717171717171), parsed.stamp_ms);
    try std.testing.expectEqual(souls.indexOfKey("tool_failed").?, parsed.action.event);
}

test "malformed trigger lines are ignored, not guessed at" {
    try std.testing.expect(parseTrigger("") == null);
    try std.testing.expect(parseTrigger("nonsense") == null);
    try std.testing.expect(parseTrigger("abc tool_failed") == null);
    try std.testing.expect(parseTrigger("123 no_such_event") == null);
    // A command word is never mistaken for an event, and a say with no
    // headline is not a screen.
    try std.testing.expect(parseTrigger("123 !nonsense") == null);
    try std.testing.expect(parseTrigger("123 !say") == null);
    try std.testing.expect(parseTrigger("123 !say 0 0 20 2600 |") == null);
}

test "a message carries its whole screen through the trigger file" {
    var source: config_mod.EventSettings = .{
        .style = .covenant,
        .sound = .you_died,
        .volume = 55,
        .duration_ms = 4200,
        .title = config_mod.Title.from("BONFIRE LIT"),
        .subtitle = config_mod.Subtitle.from("undead parish"),
    };

    var buffer: [max_trigger_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("{d} {s} ", .{ @as(i64, 42), say_command });
    try source.writeFields(&writer);

    const parsed = parseTrigger(writer.buffered()).?;
    const entry = parsed.action.message;
    try std.testing.expectEqual(@as(i64, 42), parsed.stamp_ms);
    try std.testing.expectEqual(souls.Style.covenant, entry.style);
    try std.testing.expectEqual(souls.Sound.you_died, entry.sound);
    try std.testing.expectEqual(@as(u8, 55), entry.volume);
    try std.testing.expectEqual(@as(u32, 4200), entry.duration_ms);
    try std.testing.expectEqualStrings("BONFIRE LIT", entry.title.slice());
    try std.testing.expectEqualStrings("undead parish", entry.subtitle.slice());
}

test "the settings command is not an event" {
    const parsed = parseTrigger("7 !settings").?;
    try std.testing.expectEqual(Action.settings, parsed.action);
}

test "an npx cache is recognised as temporary, and a real install is not" {
    // The exact shapes npm uses, on both separators.
    try std.testing.expect(isTransientPath(
        "C:\\Users\\x\\AppData\\Local\\npm-cache\\_npx\\ab12\\node_modules\\ai-souls\\vendor\\win32-x64\\ai-souls.exe",
    ));
    try std.testing.expect(isTransientPath("/home/x/.npm/_npx/ab12/node_modules/ai-souls/vendor/linux-x64/ai-souls"));

    // A global install, which is the whole point of telling them apart.
    try std.testing.expect(!isTransientPath("/usr/local/lib/node_modules/ai-souls/vendor/darwin-arm64/ai-souls"));
    try std.testing.expect(!isTransientPath(
        "C:\\Users\\x\\AppData\\Roaming\\npm\\node_modules\\ai-souls\\vendor\\win32-x64\\ai-souls.exe",
    ));
    try std.testing.expect(!isTransientPath("S:\\Work\\ai-souls\\zig-out\\bin\\ai-souls.exe"));

    // A segment that merely CONTAINS the marker is not the marker.
    try std.testing.expect(!isTransientPath("/home/x/_npx_notreally/ai-souls"));
    try std.testing.expect(!isTransientPath("/home/x/my_npx/ai-souls"));
    try std.testing.expect(!isTransientPath(""));
}

test "no event key could ever be read as a command" {
    for (souls.events) |event| {
        try std.testing.expect(event.key[0] != '!');
    }
}
