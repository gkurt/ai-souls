//! End-to-end behaviour tests over the real Model/Msg/update loop.
//!
//! The per-module tests cover the codecs and the JSON merge; these
//! cover the thing the app actually is — a command line turning into a
//! window that appears, and a process that goes away with it.

const std = @import("std");
const native_sdk = @import("native_sdk");

const app = @import("app.zig");
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const paths_mod = @import("paths.zig");
const souls = @import("souls.zig");
const throttle = @import("throttle.zig");

const testing = std.testing;

/// Drive `update` without the runtime: the effects channel in fake mode
/// records what was asked for instead of performing it.
const Harness = struct {
    model: app.Model,
    effects: *app.Effects,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Harness {
        const effects = try allocator.create(app.Effects);
        effects.* = app.Effects.init(allocator);
        effects.executor = .fake;
        var model: app.Model = .{};
        model.paths.config.set("/tmp/ai-souls-test/config.txt");
            model.paths.exe.set("/tmp/ai-souls-test/ai-souls");
        return .{ .model = model, .effects = effects, .allocator = allocator };
    }

    fn deinit(self: *Harness) void {
        self.effects.deinit();
        self.allocator.destroy(self.effects);
    }

    fn send(self: *Harness, msg: app.Msg) void {
        app.update(&self.model, msg, self.effects);
    }

    fn fileResult(key: u64, bytes: []const u8) native_sdk.EffectFileResult {
        return .{ .key = key, .op = .read, .outcome = .ok, .bytes = bytes };
    }
};

test "fire resolves an armed event into the screen it will draw" {
    var paths: @import("paths.zig").Paths = .{};
    paths.config.set("/tmp/ai-souls-test/config.txt");

    const outcome = cli.run(
        testing.allocator,
        testing.io,
        &.{ "ai-souls", "fire", "api_error" },
        &paths,
    );

    // No config file on disk, so this is the compiled default for the
    // row — which is exactly what the hook should put on screen.
    const expected = config_mod.Config.default().events[souls.indexOfKey("api_error").?];
    switch (outcome) {
        .run_screen => |entry| {
            try testing.expectEqualStrings(expected.title.slice(), entry.title.slice());
            try testing.expectEqual(expected.sound, entry.sound);
            try testing.expectEqual(expected.style, entry.style);
        },
        else => return error.ExpectedAScreen,
    }
}

// `say` is a no-op under `zig build test` — this process's stdout is
// the build runner's own protocol stream — so these tests are free to
// drive any verb and assert on outcomes and files, never on output.

/// A tmp-dir config path, built the way every file-backed test here
/// builds one.
fn tmpConfigPath(
    tmp: *const std.testing.TmpDir,
    dir_buffer: *[paths_mod.max_path_bytes]u8,
    file_buffer: *[paths_mod.max_path_bytes]u8,
) ![]const u8 {
    const dir = std.fmt.bufPrint(dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch
        return error.PathTooLong;
    return paths_mod.join(file_buffer, dir, "config.txt");
}

test "set disarms an event, on disk, where fire reads it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var file_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var paths: paths_mod.Paths = .{};
    paths.config.set(try tmpConfigPath(&tmp, &dir_buffer, &file_buffer));

    // `turn_complete` ships armed; switch it off.
    const set = &.{ "ai-souls", "set", "turn_complete", "off" };
    try testing.expect(cli.run(testing.allocator, testing.io, set, &paths) == .handled_ok);

    const config = cli.readConfig(testing.io, &paths);
    const index = souls.indexOfKey("turn_complete").?;
    try testing.expect(!config.events[index].enabled);

    // The change reaches the hook: its `fire` now has nothing to draw,
    // and says so with the quiet success a suppressed screen gets.
    const hook = &.{ "ai-souls", "fire", "turn_complete" };
    try testing.expect(cli.run(testing.allocator, testing.io, hook, &paths) == .handled_ok);
}

test "set changes a screen the way the flags say" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var file_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var paths: paths_mod.Paths = .{};
    paths.config.set(try tmpConfigPath(&tmp, &dir_buffer, &file_buffer));

    const set = &.{
        "ai-souls",          "set",     "tool_failed",
        "on",                "--style", "bonfire",
        "--sound",           "gong",    "--volume",
        "55",                "--duration", "3000",
        "--title",           "BONFIRE LIT", "--subtitle",
        "rest here",
    };
    try testing.expect(cli.run(testing.allocator, testing.io, set, &paths) == .handled_ok);

    const config = cli.readConfig(testing.io, &paths);
    const entry = &config.events[souls.indexOfKey("tool_failed").?];
    try testing.expect(entry.enabled);
    try testing.expectEqual(souls.Style.bonfire, entry.style);
    try testing.expectEqual(souls.Sound.gong, entry.sound);
    try testing.expectEqual(@as(u8, 55), entry.volume);
    try testing.expectEqual(@as(u32, 3000), entry.duration_ms);
    try testing.expectEqualStrings("BONFIRE LIT", entry.title.slice());
    try testing.expectEqualStrings("rest here", entry.subtitle.slice());
}

test "set refuses what it does not know, and writes nothing for it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var file_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var paths: paths_mod.Paths = .{};
    paths.config.set(try tmpConfigPath(&tmp, &dir_buffer, &file_buffer));

    const cases = [_][]const []const u8{
        &.{ "ai-souls", "set", "no_such_event", "on" },
        &.{ "ai-souls", "set", "turn_complete", "--volume", "500" },
        &.{ "ai-souls", "set", "turn_complete", "--sound", "kazoo" },
        &.{ "ai-souls", "set", "turn_complete", "--duration" },
        &.{ "ai-souls", "set", "turn_complete", "loudly" },
    };
    for (cases) |case| {
        try testing.expect(cli.run(testing.allocator, testing.io, case, &paths) == .handled_failed);
    }

    // None of those refusals left a config file behind.
    const cwd = std.Io.Dir.cwd();
    try testing.expectError(
        error.FileNotFound,
        cwd.access(testing.io, paths.config.slice(), .{}),
    );
}

test "reset puts one event back without touching its neighbours" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var file_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var paths: paths_mod.Paths = .{};
    paths.config.set(try tmpConfigPath(&tmp, &dir_buffer, &file_buffer));

    const bend = &.{ "ai-souls", "set", "commit_made", "off", "--title", "IT IS DONE" };
    const bend_other = &.{ "ai-souls", "set", "pr_created", "--title", "THE SUN RISES" };
    try testing.expect(cli.run(testing.allocator, testing.io, bend, &paths) == .handled_ok);
    try testing.expect(cli.run(testing.allocator, testing.io, bend_other, &paths) == .handled_ok);

    const undo = &.{ "ai-souls", "reset", "commit_made" };
    try testing.expect(cli.run(testing.allocator, testing.io, undo, &paths) == .handled_ok);

    const config = cli.readConfig(testing.io, &paths);
    const commit = &config.events[souls.indexOfKey("commit_made").?];
    try testing.expect(commit.enabled);
    try testing.expectEqualStrings("Commit made", commit.title.slice());
    // The neighbour keeps its custom headline.
    const pr = &config.events[souls.indexOfKey("pr_created").?];
    try testing.expectEqualStrings("THE SUN RISES", pr.title.slice());
}

test "reset all is the factory floor" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var file_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var paths: paths_mod.Paths = .{};
    paths.config.set(try tmpConfigPath(&tmp, &dir_buffer, &file_buffer));

    const bend = &.{ "ai-souls", "set", "turn_complete", "off", "--volume", "99" };
    try testing.expect(cli.run(testing.allocator, testing.io, bend, &paths) == .handled_ok);
    const undo = &.{ "ai-souls", "reset", "all" };
    try testing.expect(cli.run(testing.allocator, testing.io, undo, &paths) == .handled_ok);

    const config = cli.readConfig(testing.io, &paths);
    const fresh = config_mod.Config.default();
    for (config.events, fresh.events) |entry, default| {
        try testing.expectEqual(default.enabled, entry.enabled);
        try testing.expectEqual(default.volume, entry.volume);
    }
}

test "the same hook twice in a row draws one screen" {
    // The wiring, against a real file. `throttle.zig` proves the rules
    // themselves against an injected clock; what this catches is a
    // `fire` that forgot to read the record, or to write it.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths: paths_mod.Paths = .{};
    var dir_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var file_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch
        return error.PathTooLong;
    paths.fired.set(paths_mod.join(&file_buffer, dir, "fired.txt"));

    // An armed row with a window of its own, so the second call is
    // refused by that window rather than by the absolute floor.
    const hook = &.{ "ai-souls", "fire", "api_error" };
    try testing.expect(cli.run(testing.allocator, testing.io, hook, &paths) == .run_screen);

    // `handled_ok`, not a failure: the hook did its job, it just had
    // nothing to add. Claude Code must never see this as an error.
    try testing.expect(cli.run(testing.allocator, testing.io, hook, &paths) == .handled_ok);
}

test "a PR takes the glass from the commit that led to it" {
    if (!throttle.can_preempt) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths: paths_mod.Paths = .{};
    var dir_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var file_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch
        return error.PathTooLong;
    paths.fired.set(paths_mod.join(&file_buffer, dir, "fired.txt"));

    // Both fire inside one banner's length, which is the whole point:
    // without the ranking the second one would be dropped for landing
    // on top of the first.
    const commit = &.{ "ai-souls", "fire", "commit_made" };
    const pr = &.{ "ai-souls", "fire", "pr_created" };
    try testing.expect(cli.run(testing.allocator, testing.io, commit, &paths) == .run_screen);
    try testing.expect(cli.run(testing.allocator, testing.io, pr, &paths) == .run_screen);

    // And not the other way round — a commit does not interrupt a PR.
    try testing.expect(cli.run(testing.allocator, testing.io, commit, &paths) == .handled_ok);
}

test "a screen asked for by hand is never held back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var paths: paths_mod.Paths = .{};
    var dir_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    var file_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch
        return error.PathTooLong;
    paths.fired.set(paths_mod.join(&file_buffer, dir, "fired.txt"));

    const shout = &.{ "ai-souls", "PRAISE THE SUN" };
    try testing.expect(cli.run(testing.allocator, testing.io, shout, &paths) == .run_screen);
    try testing.expect(cli.run(testing.allocator, testing.io, shout, &paths) == .run_screen);

    // But it did take the floor with it, so a hook does not land on top.
    const hook = &.{ "ai-souls", "fire", "turn_complete" };
    try testing.expect(cli.run(testing.allocator, testing.io, hook, &paths) == .handled_ok);
}

test "a bare message sounds like the death screen it is" {
    var paths: paths_mod.Paths = .{};
    const outcome = cli.run(
        testing.allocator,
        testing.io,
        &.{ "ai-souls", "YOU DIED" },
        &paths,
    );
    switch (outcome) {
        .run_screen => |entry| {
            try testing.expectEqual(souls.Style.death, entry.style);
            try testing.expectEqual(souls.Sound.you_died, entry.sound);
        },
        else => return error.ExpectedAScreen,
    }
}

test "a bare message stays up long enough to finish its sting" {
    var paths: paths_mod.Paths = .{};
    const outcome = cli.run(
        testing.allocator,
        testing.io,
        &.{ "ai-souls", "YOU DIED" },
        &paths,
    );
    switch (outcome) {
        .run_screen => |entry| try testing.expectEqual(
            souls.Sound.you_died.durationMs(),
            entry.duration_ms,
        ),
        else => return error.ExpectedAScreen,
    }
}

test "an explicit duration is never second-guessed" {
    var paths: paths_mod.Paths = .{};
    const outcome = cli.run(
        testing.allocator,
        testing.io,
        &.{ "ai-souls", "YOU DIED", "--duration", "1000" },
        &paths,
    );
    switch (outcome) {
        .run_screen => |entry| try testing.expectEqual(@as(u32, 1000), entry.duration_ms),
        else => return error.ExpectedAScreen,
    }
}

test "a style that is not death keeps the ad-hoc gong" {
    var paths: paths_mod.Paths = .{};
    const outcome = cli.run(
        testing.allocator,
        testing.io,
        &.{ "ai-souls", "BONFIRE LIT", "--style", "bonfire" },
        &paths,
    );
    switch (outcome) {
        .run_screen => |entry| try testing.expectEqual(souls.Sound.gong, entry.sound),
        else => return error.ExpectedAScreen,
    }
}

test "a message becomes the screen it describes, with no catalog vote" {
    var paths: @import("paths.zig").Paths = .{};
    const outcome = cli.run(
        testing.allocator,
        testing.io,
        &.{ "ai-souls", "PRAISE", "THE", "SUN", "--style", "covenant", "--sound", "you-died", "--subtitle", "\\[T]/", "--duration", "3000" },
        &paths,
    );

    switch (outcome) {
        .run_screen => |entry| {
            try testing.expectEqualStrings("PRAISE THE SUN", entry.title.slice());
            try testing.expectEqualStrings("\\[T]/", entry.subtitle.slice());
            try testing.expectEqual(souls.Style.covenant, entry.style);
            try testing.expectEqual(souls.Sound.you_died, entry.sound);
            try testing.expectEqual(@as(u32, 3000), entry.duration_ms);
        },
        else => return error.ExpectedAScreen,
    }
}

test "settings asks for the window, not a screen" {
    var paths: @import("paths.zig").Paths = .{};
    const outcome = cli.run(testing.allocator, testing.io, &.{ "ai-souls", "settings" }, &paths);
    try testing.expect(outcome == .run_app);
}

test "a screen process is already showing its banner by the end of init" {
    // No trigger file, no poll, no waiting: the entry came in on the
    // command line and `init` is the whole handshake.
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    var entry: config_mod.EventSettings = .{};
    entry.title.set("YOU DIED");
    harness.model.screen_only = entry;

    app.init(&harness.model, harness.effects);

    try testing.expect(harness.model.overlay.active);
    try testing.expectEqualStrings("YOU DIED", harness.model.overlay.entry.title.slice());
}

test "a settings process opens no screen and reads its config" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    app.init(&harness.model, harness.effects);

    try testing.expect(!harness.model.overlay.active);
    var index: usize = 0;
    var read_config = false;
    while (harness.effects.pendingFileAt(index)) |request| : (index += 1) {
        if (request.op == .read and std.mem.endsWith(u8, request.path, "config.txt")) read_config = true;
    }
    try testing.expect(read_config);
}

test "a screen process exits with its banner" {
    // The point of the whole design: nothing is left running afterwards.
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    var entry: config_mod.EventSettings = .{};
    entry.title.set("YOU DIED");
    entry.duration_ms = 2600;
    harness.model.screen_only = entry;
    app.init(&harness.model, harness.effects);

    const before = harness.effects.window_action_state.quit_count;
    harness.model.overlay.started_ms -= 5000; // past its own end
    harness.send(.{ .anim_tick = .{ .key = 2, .outcome = .fired } });

    try testing.expect(!harness.model.overlay.active);
    try testing.expect(harness.effects.window_action_state.quit_count > before);
}

test "the settings window does not quit when a preview ends" {
    // Same code path, opposite answer: a preview from the settings
    // window must not take the window down with it.
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.preview);
    try testing.expect(harness.model.overlay.active);

    const before = harness.effects.window_action_state.quit_count;
    harness.model.overlay.started_ms -= @intCast(harness.model.overlay.duration_ms + 50);
    harness.send(.{ .anim_tick = .{ .key = 2, .outcome = .fired } });

    try testing.expect(!harness.model.overlay.active);
    try testing.expectEqual(before, harness.effects.window_action_state.quit_count);
}

test "the overlay closes itself once its duration elapses" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.preview);
    try testing.expect(harness.model.overlay.active);

    // Rewind the start so the next tick lands past the end.
    harness.model.overlay.started_ms -= @intCast(harness.model.overlay.duration_ms + 50);
    harness.send(.{ .anim_tick = .{ .key = 2, .outcome = .fired } });

    try testing.expect(!harness.model.overlay.active);
}

test "the overlay stays up mid-flight" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.preview);
    harness.model.overlay.started_ms -= 100;
    harness.send(.{ .anim_tick = .{ .key = 2, .outcome = .fired } });

    try testing.expect(harness.model.overlay.active);
    try testing.expect(harness.model.overlay.elapsed_ms > 0);
    try testing.expect(harness.model.overlay.opacity() > 0);
}

test "an audio event advances the overlay too" {
    // The regression: with a sound playing, the Win32 host starves the
    // animation timer to about one tick per second, so the fade never
    // rendered. Audio events are the clock that still arrives.
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.preview);
    harness.model.overlay.started_ms -= 100;
    harness.send(.{ .audio_event = .{ .key = 30, .kind = .position } });

    try testing.expect(harness.model.overlay.active);
    try testing.expect(harness.model.overlay.elapsed_ms > 0);
    try testing.expect(harness.model.overlay.opacity() > 0);
}

test "an audio event can also end the screen" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.preview);
    harness.model.overlay.started_ms -= @intCast(harness.model.overlay.duration_ms + 50);
    harness.send(.{ .audio_event = .{ .key = 30, .kind = .position } });

    try testing.expect(!harness.model.overlay.active);
}

test "the sound waits until the fade has drawn" {
    // Starting audio stalls the Win32 message loop, which ate the
    // fade-in when it happened at t=0. The screen opens first.
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    const index = souls.indexOfKey("tool_failed").?;
    harness.model.selected = index;
    try testing.expect(harness.model.config.events[index].sound != .none);

    harness.send(.preview);
    try testing.expect(harness.model.overlay.active);
    // Nothing has been asked to play yet.
    try testing.expectEqual(@as(usize, 0), harness.model.last_sound_path.len);

    harness.send(.{ .sound_tick = .{ .key = 3, .outcome = .fired } });
    try testing.expect(harness.model.last_sound_path.len > 0);
}

test "a sound due after its screen ended never plays" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.model.selected = souls.indexOfKey("tool_failed").?;
    harness.send(.preview);
    harness.model.overlay.started_ms -= @intCast(harness.model.overlay.duration_ms + 50);
    harness.send(.{ .anim_tick = .{ .key = 2, .outcome = .fired } });
    try testing.expect(!harness.model.overlay.active);

    harness.send(.{ .sound_tick = .{ .key = 3, .outcome = .fired } });
    try testing.expectEqual(@as(usize, 0), harness.model.last_sound_path.len);
}

test "a screen frozen past its fade-out still fades out" {
    // The regression: starting a sound freezes the Win32 loop for two
    // seconds, and the screen came back from the freeze already over.
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.model.selected = souls.indexOfKey("tool_failed").?;
    harness.send(.preview);
    const duration = harness.model.overlay.duration_ms;

    // Two seconds pass with the loop dead: no advance happened, so both
    // clocks are simply that much older than they should be.
    harness.model.overlay.started_ms -= 2035;
    harness.model.overlay.last_advance_ms -= 2035;
    harness.send(.{ .anim_tick = .{ .key = 2, .outcome = .fired } });

    // Still up, and parked at the top of the fall rather than past it.
    try testing.expect(harness.model.overlay.active);
    try testing.expect(harness.model.overlay.elapsed_ms <= duration - 600);
    try testing.expectApproxEqAbs(@as(f32, 1), harness.model.overlay.opacity(), 0.05);
}

test "an audio event with no screen up is harmless" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .audio_event = .{ .key = 30, .kind = .completed } });
    try testing.expect(!harness.model.overlay.active);
}

test "a rejected timer fire changes nothing" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.preview);
    const before = harness.model.overlay.elapsed_ms;
    harness.send(.{ .anim_tick = .{ .key = 2, .outcome = .rejected } });

    try testing.expect(harness.model.overlay.active);
    try testing.expectEqual(before, harness.model.overlay.elapsed_ms);
}

test "toggling an event writes the config back out" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    const enabled_before = harness.model.config.events[0].enabled;
    harness.send(.toggle_enabled);

    try testing.expectEqual(!enabled_before, harness.model.config.events[0].enabled);
    try testing.expect(harness.effects.pendingFileCount() > 0);
}

test "typing edits the selected event's headline" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .select = 0 });
    harness.send(.{ .title_edit = .clear });
    harness.send(.{ .title_edit = .{ .insert_text = "ASH" } });

    try testing.expectEqualStrings("ASH", harness.model.config.events[0].title.slice());

    harness.send(.{ .title_edit = .delete_backward });
    try testing.expectEqualStrings("AS", harness.model.config.events[0].title.slice());
}

test "reset restores an event to its catalog default" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .select = 0 });
    harness.send(.{ .title_edit = .clear });
    harness.send(.reset_event);

    try testing.expectEqualStrings(
        souls.events[0].default_title,
        harness.model.config.events[0].title.slice(),
    );
}

test "the volume slider maps its fraction onto 0..100" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .volume_changed = 0.25 });
    try testing.expectEqual(@as(u8, 25), harness.model.config.events[0].volume);

    harness.send(.{ .volume_changed = 2.0 }); // out of range clamps
    try testing.expectEqual(@as(u8, 100), harness.model.config.events[0].volume);
}

test "the duration slider stays inside the allowed span" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .duration_changed = 0 });
    try testing.expectEqual(config_mod.min_duration_ms, harness.model.config.events[0].duration_ms);

    harness.send(.{ .duration_changed = 1 });
    try testing.expectEqual(config_mod.max_duration_ms, harness.model.config.events[0].duration_ms);
}

test "loading a saved config replaces the defaults" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .config_loaded = Harness.fileResult(
        10,
        "e session_start 0 0 0 10 900 GONE|\n",
    ) });

    try testing.expect(!harness.model.config.events[0].enabled);
    try testing.expectEqualStrings("GONE", harness.model.config.events[0].title.slice());
    try testing.expect(!harness.model.dirty);
}

test "a missing config file leaves the defaults in place" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .config_loaded = .{ .key = 10, .op = .read, .outcome = .not_found } });

    try testing.expectEqualStrings(
        souls.events[0].default_title,
        harness.model.config.events[0].title.slice(),
    );
    try testing.expectEqual(@as(usize, 0), harness.model.status.len);
}

test "a failed hook run reports rather than hanging the buttons" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.install_hooks);
    try testing.expect(harness.model.hooks_busy);

    harness.send(.{ .hooks_exit = .{ .key = 20, .code = 1, .reason = .exited } });
    try testing.expect(!harness.model.hooks_busy);
    try testing.expect(harness.model.status.len > 0);
}

test "the hook CLI's own summary line becomes the status line" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.install_hooks);
    harness.send(.{ .hooks_line = .{ .key = 20, .line = "6 hooks written, 0 removed — /home/x/.claude/settings.json\n" } });
    harness.send(.{ .hooks_exit = .{ .key = 20, .code = 0, .reason = .exited } });

    try testing.expectEqualStrings(
        "6 hooks written, 0 removed — /home/x/.claude/settings.json",
        harness.model.status.slice(),
    );
}

test "selecting an event moves the carets to that event's text" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .select = 3 });
    try testing.expectEqual(@as(usize, 3), harness.model.selected);
    try testing.expectEqual(
        harness.model.config.events[3].title.len,
        harness.model.title_selection.focus,
    );
}

test "style and sound cycle both ways without falling off the ends" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    var index: usize = 0;
    while (index < souls.Style.count + 2) : (index += 1) harness.send(.cycle_style);
    while (index > 0) : (index -= 1) harness.send(.cycle_style_back);
    try testing.expectEqual(souls.events[0].default_style, harness.model.config.events[0].style);

    index = 0;
    while (index < souls.Sound.count + 2) : (index += 1) harness.send(.cycle_sound);
    while (index > 0) : (index -= 1) harness.send(.cycle_sound_back);
    try testing.expectEqual(souls.events[0].default_sound, harness.model.config.events[0].sound);
}
