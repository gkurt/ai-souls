//! The binary's non-GUI modes.
//!
//! One executable wears several hats. `ai-souls` with no arguments is
//! the settings window. `ai-souls fire <event>` is what the installed
//! hooks run: it resolves the event's settings and becomes the banner
//! itself, for the two seconds the banner is up, and then exits.
//! `ai-souls install` does the `settings.json` merge, which needs an
//! allocator and therefore cannot live inside the pure `update` — the
//! running app reaches it by spawning itself.
//!
//! Nothing stays resident. There is no daemon, no trigger file and no
//! heartbeat: a screen is a process, and between screens AI Souls is
//! not running at all.
//!
//! Everything that is not a known verb is a headline to put on screen,
//! so `ai-souls "YOU DIED"` does the obvious thing. Verbs win ties;
//! `--` forces the rest of the line to be read as a message.

const std = @import("std");
const souls = @import("souls.zig");
const config_mod = @import("config.zig");
const console = @import("console.zig");
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
    /// No verb given — run the app, settings window and all.
    run_app,
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
    if (eq(verb, "settings")) return .run_app;
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
///
/// Not `File.stdout()` directly: on Windows this binary is
/// GUI-subsystem and has to go and find the terminal. See `console.zig`.
var out_buffer: [4096]u8 = undefined;
var out_writer: ?std.Io.File.Writer = null;

fn say(io: std.Io, comptime format: []const u8, args: anytype) void {
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

    // Quietly, and with the same exit status as a screen that drew: as
    // far as Claude Code is concerned the hook did its job either way,
    // and a hook that chatters about the screens it decided against
    // would be worse than the screens.
    const entry = config.events[index];
    var stamps = throttle.load(io, paths);
    if (!stamps.allows(index, nowMs(io))) return .handled_ok;
    return armScreen(io, paths, &stamps, index, entry);
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
            if (!applyOption(io, &entry, name, value)) return .handled_failed;
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
                runtime_copy.Error.CopyFailed => say(
                    io,
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
            \\open, almost certainly a running AI Souls. Quit it from the
            \\tray and run `{s} install` again to catch it up.
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
        \\  {s} settings
        \\
    , .{invocation(paths)});
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
    for (souls.events, 0..) |event, index| {
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
