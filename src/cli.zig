//! Every verb — the whole command surface except the banner itself.
//!
//! One executable wears several hats. `ai-souls fire <event>` is what
//! the installed hooks run: it resolves the event's settings and
//! becomes the banner itself, for the two seconds the banner is up, and
//! then exits. `ai-souls install` does the `settings.json` merge;
//! `set` and `reset` edit the config the screens are drawn from.
//!
//! Nothing stays resident. There is no daemon, no trigger file and no
//! heartbeat: a screen is a process, and between screens AI Souls is
//! not running at all.
//!
//! Everything that is not a known verb is a headline to put on screen,
//! so `ai-souls "YOU DIED"` does the obvious thing. Verbs win ties;
//! `--` forces the rest of the line to be read as a message.

const std = @import("std");
const builtin = @import("builtin");
const souls = @import("souls.zig");
const config_mod = @import("config.zig");
const console = @import("console.zig");
const hook_input = @import("hook_input.zig");
const hooks = @import("hooks.zig");
const paths_mod = @import("paths.zig");
const runtime_copy = @import("runtime_copy.zig");
const throttle = @import("throttle.zig");

/// The command a person types. Kept in one place because it appears in
/// every usage string and every error message.
pub const command_name = "ai-souls";

/// How the reader of a message has to type the command, which is not
/// always what it is called. Someone who ran `npx ai-souls install` has
/// nothing on PATH afterwards — see `Paths.viaNpx` — so telling them to
/// run `ai-souls settings` names a command their shell cannot find.
///
/// Only for "type this next" instructions. A message that says which
/// program is complaining uses `command_name`: the prefix on an error is
/// the program's name, not a command to run.
fn invocation(paths: *const paths_mod.Paths) []const u8 {
    if (paths.viaNpx()) return "npx " ++ command_name;
    return command_name;
}

/// Coding agents AI Souls knows how to install hooks for. Claude Code is
/// the only one wired up; the argument exists so that adding a second
/// does not change the shape of the command line.
pub const agents = [_][]const u8{"claude"};
pub const default_agent = "claude";

pub const Outcome = union(enum) {
    /// A CLI verb ran; `main` should exit with this status.
    handled_ok,
    handled_failed,
    /// Draw this one screen, then exit.
    ///
    /// There is no resident process: the hook's own `ai-souls fire`
    /// becomes the window, holds it for a couple of seconds, and dies
    /// with it. Nothing is left running between screens, which is the
    /// whole point — a banner that costs nothing when it is not on
    /// screen.
    run_screen: config_mod.EventSettings,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    paths: *const paths_mod.Paths,
) Outcome {
    if (args.len < 2) {
        printUsage(io);
        return .handled_ok;
    }

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
    // What used to open the settings window. The window is gone —
    // `set` is the settings now — but the muscle memory deserves the
    // next best thing rather than a headline reading "settings".
    if (eq(verb, "settings")) return status(io, paths);
    if (eq(verb, "fire")) return fire(io, paths, rest);
    if (eq(verb, "status")) return status(io, paths);
    if (eq(verb, "events")) return listEvents(io);
    if (eq(verb, "set")) return setVerb(io, paths, rest);
    if (eq(verb, "reset")) return resetVerb(io, paths, rest);
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

/// Everything the CLI says goes to stdout, including its failures:
/// one stream keeps redirection simple, and nothing here is chatty
/// enough to need two.
///
/// ONE writer for the whole process, not one per call. A file writer
/// carries its own position, so opening a fresh one per line starts
/// each line back at byte zero — invisible on a console, and on
/// `ai-souls status > file` it silently overwrites everything already
/// written with the last line.
///
/// Not `File.stdout()` directly: on Windows this binary is
/// GUI-subsystem and has to go and find the terminal. See `console.zig`.
var out_buffer: [4096]u8 = undefined;
var out_writer: ?std.Io.File.Writer = null;

fn say(io: std.Io, comptime format: []const u8, args: anytype) void {
    // Under `zig build test` this process's stdout is the build runner's
    // own protocol stream, and a verb that printed down it would wedge
    // the run. Tests assert on outcomes and files, never on output.
    if (builtin.is_test) return;
    if (out_writer == null) out_writer = console.out().writer(io, &out_buffer);
    const out = &out_writer.?.interface;
    out.print(format, args) catch return;
    // Flushed per call rather than at exit: a verb can end in
    // `std.process.exit`, which runs no deferred anything.
    out.flush() catch {};
}

/// What an installed hook runs.
///
/// Resolves the event against the saved config and hands the result
/// back to `main`, which puts it on screen in this same process. Doing
/// it here rather than in the app means the config read and the
/// enabled check cost nothing when the answer is "this event is off" —
/// that path never touches a window system at all.
fn fire(io: std.Io, paths: *const paths_mod.Paths, rest: []const []const u8) Outcome {
    if (rest.len < 1) {
        say(io, "{s} fire: expected an event key\n", .{command_name});
        return .handled_failed;
    }
    const key = rest[0];
    const index = souls.indexOfKey(key) orelse {
        say(io, "{s} fire: unknown event \"{s}\"\n", .{ command_name, key });
        return .handled_failed;
    };
    const config = readConfig(io, paths);
    // A disabled event can still have a hook on disk — the hook set only
    // catches up at the next `install` — so the arming check has to
    // happen here too, and exiting quietly is the whole response.
    if (!config.events[index].enabled) return .handled_ok;

    // A row narrowed to one Bash call checks that call for itself. Its
    // hook carries an `if` rule that was supposed to have settled this,
    // and for the commands Claude Code's parser can model it does — but
    // on the ones it cannot the rule matches everything, and "Commit
    // made" fires for any Bash call at all. See `hook_input`.
    if (!allowsCommand(io, souls.events[index])) return .handled_ok;

    // Quietly, and with the same exit status as a screen that drew: as
    // far as Claude Code is concerned the hook did its job either way,
    // and a hook that chatters about the screens it decided against
    // would be worse than the screens.
    const entry = config.events[index];
    var stamps = throttle.load(io, paths);
    if (!stamps.allows(index, nowMs(io))) return .handled_ok;
    return armScreen(io, paths, &stamps, index, entry);
}

/// Is the Bash call Claude Code is reporting the one this row is about?
///
/// Costs nothing for the rows that are about a whole tool: they never
/// name a command, so nothing reads the payload. Ordered before the
/// throttle so a screen this turns down does not also consume the
/// event's quiet window.
fn allowsCommand(io: std.Io, event: souls.Event) bool {
    if (event.requiredCommand().len == 0) return true;
    var buffer: [hook_input.max_bytes]u8 = undefined;
    return hook_input.allows(event, hook_input.readPayload(io, &buffer));
}

/// Record a screen as about to be drawn, and hand it to `main`.
///
/// Stamped here rather than after the window closes, because the
/// throttle's job is to arbitrate the NEXT process against this one —
/// and by the time this one is over, that decision has been made. The
/// record carries this screen's rank as well as its length, so the next
/// process knows both how long to keep clear of it and whether it is
/// allowed not to.
///
/// Taking down a banner this one has outranked is `main`'s job, not
/// this function's: the decision is made here, and acted on next to the
/// window it clears the way for.
fn armScreen(
    io: std.Io,
    paths: *const paths_mod.Paths,
    stamps: *throttle.Stamps,
    index: ?usize,
    entry: config_mod.EventSettings,
) Outcome {
    stamps.record(index, nowMs(io), entry.duration_ms);
    throttle.save(io, paths, stamps);
    return .{ .run_screen = entry };
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
    var sound_chosen = false;
    var duration_chosen = false;

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
            applyOption(&entry, name, value) catch |err| {
                explainOption(io, err, name, value);
                return .handled_failed;
            };
            if (eq(name, "sound")) sound_chosen = true;
            if (eq(name, "duration")) duration_chosen = true;
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
    // The catalog's rule reaches out here: a death screen sounds like
    // death unless the person said otherwise. `ai-souls "YOU DIED"`
    // therefore needs no flags at all, which is the one command anyone
    // types first.
    if (!sound_chosen and entry.style == .death) entry.sound = .you_died;
    // And then the screen is sized to hold whatever sound it ended up
    // with — after the rule above, so a bare "YOU DIED" gets the seven
    // seconds its sting needs rather than the default two and a half.
    if (!duration_chosen) entry.duration_ms = config_mod.durationFor(entry.sound);

    // Not throttled — this one was asked for, out loud, by a person.
    // Recorded all the same, so the next hook does not open a second
    // banner over it.
    var stamps = throttle.load(io, paths);
    return armScreen(io, paths, &stamps, null, entry);
}

const OptionError = error{
    UnknownOption,
    UnknownStyle,
    UnknownSound,
    BadVolume,
    BadDuration,
};

/// One `--name value` pair onto a screen's settings. Pure so the tests
/// can drive it; `explainOption` does the talking. Shared by `message`
/// and `set`, so the two can never disagree about what a value means.
fn applyOption(
    entry: *config_mod.EventSettings,
    name: []const u8,
    value: []const u8,
) OptionError!void {
    if (eq(name, "style")) {
        entry.style = souls.Style.fromName(value) orelse return error.UnknownStyle;
        return;
    }
    if (eq(name, "sound")) {
        entry.sound = souls.Sound.fromName(value) orelse return error.UnknownSound;
        return;
    }
    if (eq(name, "volume")) {
        const parsed = std.fmt.parseInt(u8, value, 10) catch 255;
        if (parsed > 100) return error.BadVolume;
        entry.volume = parsed;
        return;
    }
    if (eq(name, "duration")) {
        const parsed = std.fmt.parseInt(u32, value, 10) catch return error.BadDuration;
        if (parsed < config_mod.min_duration_ms or parsed > config_mod.max_duration_ms) {
            return error.BadDuration;
        }
        entry.duration_ms = parsed;
        return;
    }
    if (eq(name, "subtitle")) {
        entry.subtitle.set(value);
        return;
    }
    return error.UnknownOption;
}

fn explainOption(io: std.Io, err: OptionError, name: []const u8, value: []const u8) void {
    switch (err) {
        error.UnknownStyle => {
            say(io, "{s}: no style called \"{s}\". Try: ", .{ command_name, value });
            listNames(io, souls.Style);
        },
        error.UnknownSound => {
            say(io, "{s}: no sound called \"{s}\". Try: ", .{ command_name, value });
            listNames(io, souls.Sound);
        },
        error.BadVolume => say(
            io,
            "{s}: --volume takes 0 to 100, not \"{s}\"\n",
            .{ command_name, value },
        ),
        error.BadDuration => say(io, "{s}: --duration takes {d} to {d} milliseconds, not \"{s}\"\n", .{
            command_name,
            config_mod.min_duration_ms,
            config_mod.max_duration_ms,
            value,
        }),
        error.UnknownOption => {
            say(io, "{s}: unknown option \"--{s}\"\n\n", .{ command_name, name });
            printUsage(io);
        },
    }
}

fn listNames(io: std.Io, comptime E: type) void {
    inline for (@typeInfo(E).@"enum".fields, 0..) |field, index| {
        say(io, "{s}{s}", .{ if (index == 0) "" else ", ", field.name });
    }
    say(io, "\n", .{});
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
    // The copy first, because the hooks are about to name it. Whatever
    // path this process is running from — a versioned npm prefix, an
    // npx cache — belongs to a package manager and will move.
    var copied: runtime_copy.Outcome = .self;
    if (installing) {
        copied = runtime_copy.sync(io, paths) catch |err| {
            switch (err) {
                runtime_copy.Error.NoHomeDirectory => say(
                    io,
                    "No HOME/USERPROFILE in the environment.\n",
                    .{},
                ),
                runtime_copy.Error.NoExecutablePath => say(io,
                    \\Could not work out where this binary is, so there is
                    \\nothing to install: a hook names its command by absolute
                    \\path. Nothing was written.
                    \\
                , .{}),
                runtime_copy.Error.CopyFailed => say(io,
                    \\Could not put a copy of this binary in {s}.
                    \\
                    \\Nothing was written: a hook pointing at {s}
                    \\would stop working the moment that path moved, and a
                    \\silently dead hook is worse than no hook.
                    \\
                , .{ paths.runtime_dir.slice(), paths.exe.slice() }),
            }
            return .handled_failed;
        };
    }

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
    switch (copied) {
        .copied => say(io, "hooks run {s}\n", .{paths.runtime_exe.slice()}),
        .kept_stale => say(io,
            \\
            \\The hooks are installed and working, but the copy they run
            \\could not be replaced with this build — something has
            \\{s}
            \\open, almost certainly a banner still on screen. Let it
            \\pass and run `{s} install` again to catch it up.
            \\
        , .{ paths.runtime_exe.slice(), invocation(paths) }),
        .current, .self => {},
    }
    // Where to go next, spelled the way THIS reader has to type it —
    // the recommended way in is `npx ai-souls install`, which leaves
    // nothing on PATH to name.
    if (installing) say(io,
        \\
        \\Hooks ready — screens now fire in every Claude Code session.
        \\Nothing stays running between them — each screen is its own
        \\short-lived process. To change what they say:
        \\
        \\  {s} set turn_complete --title "YOU DIED"
        \\
        \\`{s} status` lists every event and its screen.
        \\
    , .{ invocation(paths), invocation(paths) });
    // Nothing left to answer the hooks, so the copy has no reason to
    // stay. After the settings write, so a failure there leaves a
    // working install rather than a half-dismantled one.
    if (!installing) runtime_copy.remove(io, paths);
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
    // What the hooks on disk actually run, which after an install is
    // never this process's own path.
    if (std.Io.Dir.cwd().access(io, paths.runtime_exe.slice(), .{})) |_| {
        say(io, "hooks run       {s}\n", .{paths.runtime_exe.slice()});
    } else |_| {
        say(io, "hooks run       no copy yet — run `{s} install`\n", .{invocation(paths)});
    }
    say(io, "config          {s}\n", .{paths.config.slice()});
    say(io, "claude settings {s}\n", .{paths.claude_settings.slice()});
    // Where the sounds resolve from is the first thing to check when
    // they do not play, so it is the first thing `status` says.
    if (paths.assets_root.isEmpty()) {
        say(io, "sounds          NOT FOUND — no assets/ near {s}\n\n", .{paths.exe.slice()});
    } else {
        var buffer: [paths_mod.max_path_bytes]u8 = undefined;
        say(io, "sounds          {s}\n\n", .{paths.asset(&buffer, souls.Sound.gong.path())});
    }
    for (0..souls.event_count) |index| sayEventRow(io, &config, index);
    return .handled_ok;
}

/// One event the way `status` lists them — also what `set` and `reset`
/// print back, so a change is confirmed in the same shape it will be
/// read in later.
fn sayEventRow(io: std.Io, config: *const config_mod.Config, index: usize) void {
    const event = &souls.events[index];
    const entry = &config.events[index];
    // What it subscribes to, what narrows it, and what holds it
    // back: between them they answer "why did I not see that
    // screen", which is what anyone runs this for.
    var hook: [160]u8 = undefined;
    var hook_writer = std.Io.Writer.fixed(&hook);
    hook_writer.print("{s}", .{event.hook_event}) catch {};
    if (event.matcher.len > 0) {
        const shown = if (event.matcher_label.len > 0) event.matcher_label else event.matcher;
        hook_writer.print(" {s}", .{shown}) catch {};
    }
    if (event.condition.len > 0) hook_writer.print(" if {s}", .{event.condition}) catch {};
    if (event.throttle_ms > 0) {
        hook_writer.print(" · max 1/{d}s", .{event.throttle_ms / 1000}) catch {};
    }
    // Meaningful only against the other rows, which is why it is a
    // bare number and why every row carries one.
    hook_writer.print(" · rank {d}", .{event.priority}) catch {};
    say(io, "{s:<3} {s:<18} {s:<24} {s}\n", .{
        if (entry.enabled) "on" else "off",
        event.key,
        entry.title.slice(),
        hook_writer.buffered(),
    });
}

fn listEvents(io: std.Io) Outcome {
    for (souls.events) |event| say(io, "{s}\n", .{event.key});
    return .handled_ok;
}

/// `set <event> [on|off] [--option value ...]` — change one row of the
/// config from the command line.
///
/// `on` and `off` are bare words rather than flags because they are the
/// whole reason most people run this. Everything else reuses the
/// message options, plus `--title`, which a message spells as its own
/// words. With nothing after the key it just prints the row, which is
/// `status` for one event.
fn setVerb(io: std.Io, paths: *const paths_mod.Paths, rest: []const []const u8) Outcome {
    if (rest.len < 1) {
        say(io, "{s} set: expected an event key — `{s} events` lists them\n", .{
            command_name,
            invocation(paths),
        });
        return .handled_failed;
    }
    const index = souls.indexOfKey(rest[0]) orelse {
        say(io, "{s} set: unknown event \"{s}\" — `{s} events` lists them\n", .{
            command_name,
            rest[0],
            invocation(paths),
        });
        return .handled_failed;
    };

    var config = readConfig(io, paths);
    const entry = &config.events[index];
    const was_enabled = entry.enabled;

    var at: usize = 1;
    while (at < rest.len) : (at += 1) {
        const arg = rest[at];
        if (eq(arg, "on")) {
            entry.enabled = true;
            continue;
        }
        if (eq(arg, "off")) {
            entry.enabled = false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            const name = arg[2..];
            at += 1;
            if (at >= rest.len) {
                say(io, "{s}: \"--{s}\" needs a value\n", .{ command_name, name });
                return .handled_failed;
            }
            const value = rest[at];
            if (eq(name, "title")) {
                entry.title.set(value);
                continue;
            }
            applyOption(entry, name, value) catch |err| {
                explainOption(io, err, name, value);
                return .handled_failed;
            };
            continue;
        }
        say(io, "{s} set: \"{s}\" is not a setting — on, off, or --option value\n", .{
            command_name,
            arg,
        });
        return .handled_failed;
    }

    if (!writeConfig(io, paths, &config)) {
        say(io, "{s}: could not write {s}\n", .{ command_name, paths.config.slice() });
        return .handled_failed;
    }
    sayEventRow(io, &config, index);
    // The same honesty the duration slider's label had: a sound longer
    // than its screen gets cut off, and nothing else will say so.
    if (entry.sound.durationMs() > entry.duration_ms) {
        say(io, "note: {s} runs {d}ms and gets cut off — set --duration {d} to fit it\n", .{
            entry.sound.label(),
            entry.sound.durationMs(),
            entry.sound.durationMs(),
        });
    }
    if (entry.enabled != was_enabled) sayInstallReminder(io, paths);
    return .handled_ok;
}

/// `reset <event|all>` — back to the catalog defaults.
fn resetVerb(io: std.Io, paths: *const paths_mod.Paths, rest: []const []const u8) Outcome {
    if (rest.len < 1) {
        say(io, "{s} reset: expected an event key or \"all\"\n", .{command_name});
        return .handled_failed;
    }

    var config = readConfig(io, paths);
    if (eq(rest[0], "all")) {
        const was = config;
        config = config_mod.Config.default();
        if (!writeConfig(io, paths, &config)) {
            say(io, "{s}: could not write {s}\n", .{ command_name, paths.config.slice() });
            return .handled_failed;
        }
        for (0..souls.event_count) |index| sayEventRow(io, &config, index);
        for (was.events, config.events) |before, after| {
            if (before.enabled != after.enabled) {
                sayInstallReminder(io, paths);
                break;
            }
        }
        return .handled_ok;
    }

    const index = souls.indexOfKey(rest[0]) orelse {
        say(io, "{s} reset: unknown event \"{s}\" — `{s} events` lists them\n", .{
            command_name,
            rest[0],
            invocation(paths),
        });
        return .handled_failed;
    };
    const was_enabled = config.events[index].enabled;
    config.events[index] = config_mod.EventSettings.fromCatalog(souls.events[index]);
    if (!writeConfig(io, paths, &config)) {
        say(io, "{s}: could not write {s}\n", .{ command_name, paths.config.slice() });
        return .handled_failed;
    }
    sayEventRow(io, &config, index);
    if (config.events[index].enabled != was_enabled) sayInstallReminder(io, paths);
    return .handled_ok;
}

/// Arming and disarming only takes effect once the hooks on disk catch
/// up — `fire` double-checks `enabled`, so a stale hook set fails quiet
/// rather than wrong, but a newly armed event has no hook to fire it.
fn sayInstallReminder(io: std.Io, paths: *const paths_mod.Paths) void {
    say(io, "\nWhich events are armed changed — run `{s} install` to update the hooks.\n", .{
        invocation(paths),
    });
}

/// Best-effort counterpart to `readConfig`. Returns false with nothing
/// said — the caller knows what it was trying to do.
fn writeConfig(io: std.Io, paths: *const paths_mod.Paths, config: *const config_mod.Config) bool {
    if (paths.config.isEmpty()) return false;
    var buffer: [config_mod.max_config_bytes]u8 = undefined;
    const text = config.serialize(&buffer);
    if (text.len == 0) return false;
    const cwd = std.Io.Dir.cwd();
    const parent = paths_mod.parent(paths.config.slice());
    if (parent.len > 0) cwd.createDirPath(io, parent) catch {};
    cwd.writeFile(io, .{ .sub_path = paths.config.slice(), .data = text }) catch return false;
    return true;
}

fn printUsage(io: std.Io) void {
    say(io,
        \\AI Souls — Dark Souls screens for your coding agent
        \\
        \\  ai-souls <message>         put a headline on screen
        \\  ai-souls install [agent]   write the enabled hooks into the agent's settings
        \\  ai-souls uninstall [agent] remove every AI Souls hook
        \\  ai-souls status            show paths and the current per-event settings
        \\  ai-souls events            list the event keys
        \\  ai-souls set <event> ...   change an event: on, off, and the options below
        \\  ai-souls reset <event|all> put an event, or everything, back to its defaults
        \\  ai-souls fire <event>      show a catalog event's screen (this is what hooks run)
        \\
        \\Message options — `set` takes them too, plus --title <text>:
        \\
        \\  --style <name>      death, bonfire, victory, soul, hollow, covenant
        \\  --sound <name>      silent, gong, choir, chime, ember, thud, you-died
        \\  --volume <0-100>
        \\  --duration <ms>
        \\  --subtitle <text>
        \\  --                  everything after this is the message
        \\
        \\  ai-souls "YOU DIED"
        \\  ai-souls -- status         say "status" instead of running it
        \\
        \\A death screen sounds like death unless --sound says otherwise.
        \\
        \\The agent argument is optional and defaults to claude, the only
        \\one supported today.
        \\
        \\Screens fired by hooks are throttled: never one over another,
        \\and the burst-prone events no more than once in their window —
        \\`ai-souls status` prints it. Events are also ranked, so a PR
        \\landing on top of the commit that led to it replaces its screen
        \\instead of being dropped. A screen you ask for by hand outranks
        \\everything and is never held back.
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

test "options apply, and every way to hold one wrong is named" {
    var entry: config_mod.EventSettings = .{};

    try applyOption(&entry, "style", "bonfire");
    try std.testing.expectEqual(souls.Style.bonfire, entry.style);
    try applyOption(&entry, "sound", "you-died");
    try std.testing.expectEqual(souls.Sound.you_died, entry.sound);
    try applyOption(&entry, "volume", "55");
    try std.testing.expectEqual(@as(u8, 55), entry.volume);
    try applyOption(&entry, "duration", "3000");
    try std.testing.expectEqual(@as(u32, 3000), entry.duration_ms);
    try applyOption(&entry, "subtitle", "rest here");
    try std.testing.expectEqualStrings("rest here", entry.subtitle.slice());

    try std.testing.expectError(error.UnknownStyle, applyOption(&entry, "style", "puce"));
    try std.testing.expectError(error.UnknownSound, applyOption(&entry, "sound", "kazoo"));
    try std.testing.expectError(error.BadVolume, applyOption(&entry, "volume", "101"));
    try std.testing.expectError(error.BadVolume, applyOption(&entry, "volume", "loud"));
    try std.testing.expectError(error.BadDuration, applyOption(&entry, "duration", "50"));
    try std.testing.expectError(error.BadDuration, applyOption(&entry, "duration", "long"));
    try std.testing.expectError(error.UnknownOption, applyOption(&entry, "letterbox", "on"));

    // And nothing a failed option touched moved.
    try std.testing.expectEqual(@as(u8, 55), entry.volume);
    try std.testing.expectEqual(@as(u32, 3000), entry.duration_ms);
}

test "a config written by the CLI reads back through the same paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths: paths_mod.Paths = .{};
    var dir_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var file_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch
        return error.PathTooLong;
    // A directory that does not exist yet, so the write has to make it.
    var nested_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    const nested = paths_mod.join(&nested_buffer, dir, "fresh");
    paths.config.set(paths_mod.join(&file_buffer, nested, "config.txt"));

    var config = config_mod.Config.default();
    config.events[0].volume = 42;
    try std.testing.expect(writeConfig(std.testing.io, &paths, &config));

    const read_back = readConfig(std.testing.io, &paths);
    try std.testing.expectEqual(@as(u8, 42), read_back.events[0].volume);
}
