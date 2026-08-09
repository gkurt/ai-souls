//! End-to-end behaviour tests over the real Model/Msg/update loop.
//!
//! The per-module tests cover the codecs and the JSON merge; these
//! cover the thing the app actually is — a trigger file turning into a
//! window that appears and then goes away on its own.

const std = @import("std");
const native_sdk = @import("native_sdk");

const app = @import("app.zig");
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const souls = @import("souls.zig");

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
        model.paths.trigger.set("/tmp/ai-souls-test/trigger");
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

test "a trigger seen for the first time is adopted, not shown" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .trigger_read = Harness.fileResult(12, "1700000000000 tool_failed\n") });

    try testing.expect(!harness.model.overlay.active);
    try testing.expect(harness.model.trigger_seeded);
    try testing.expectEqual(@as(i64, 1700000000000), harness.model.last_trigger_ms);
}

test "with no trigger file at launch, the very first fire still shows" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // First run: nothing on disk yet. The miss is the baseline.
    harness.send(.{ .trigger_read = .{ .key = 12, .op = .read, .outcome = .not_found } });
    try testing.expect(harness.model.trigger_seeded);
    try testing.expect(!harness.model.overlay.active);

    harness.send(.{ .trigger_read = Harness.fileResult(12, "1700000000000 tool_failed\n") });
    try testing.expect(harness.model.overlay.active);
}

test "a fresh trigger raises the overlay for the right event" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .trigger_read = Harness.fileResult(12, "1700000000000 session_start\n") });
    harness.send(.{ .trigger_read = Harness.fileResult(12, "1700000000500 tool_failed\n") });

    try testing.expect(harness.model.overlay.active);
    const expected = harness.model.config.events[souls.indexOfKey("tool_failed").?];
    try testing.expectEqualStrings(expected.title.slice(), harness.model.overlay.entry.title.slice());
    try testing.expectEqual(expected.sound, harness.model.overlay.entry.sound);
}

test "the same trigger read twice shows one screen" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .trigger_read = Harness.fileResult(12, "1 session_start\n") });
    harness.send(.{ .trigger_read = Harness.fileResult(12, "2 tool_failed\n") });
    harness.model.overlay.active = false; // pretend it finished
    harness.send(.{ .trigger_read = Harness.fileResult(12, "2 tool_failed\n") });

    try testing.expect(!harness.model.overlay.active);
}

test "a disabled event's trigger is ignored" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    const index = souls.indexOfKey("tool_failed").?;
    harness.model.config.events[index].enabled = false;

    harness.send(.{ .trigger_read = Harness.fileResult(12, "1 session_start\n") });
    harness.send(.{ .trigger_read = Harness.fileResult(12, "2 tool_failed\n") });

    try testing.expect(!harness.model.overlay.active);
    // Still consumed, so re-enabling does not replay it.
    try testing.expectEqual(@as(i64, 2), harness.model.last_trigger_ms);
}

test "a message from the command line shows exactly what it says" {
    // No catalog row behind this screen: the trigger line IS the
    // screen, and nothing in the config gets a vote.
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .trigger_read = Harness.fileResult(12, "1 session_start\n") });
    harness.send(.{ .trigger_read = Harness.fileResult(
        12,
        "2 !say 5 6 70 3000 PRAISE THE SUN|\\[T]/\n",
    ) });

    try testing.expect(harness.model.overlay.active);
    const entry = harness.model.overlay.entry;
    try testing.expectEqualStrings("PRAISE THE SUN", entry.title.slice());
    try testing.expectEqualStrings("\\[T]/", entry.subtitle.slice());
    try testing.expectEqual(souls.Style.covenant, entry.style);
    try testing.expectEqual(souls.Sound.you_died, entry.sound);
    try testing.expectEqual(@as(u32, 3000), harness.model.overlay.duration_ms);
}

test "a message ignores whether any event is armed" {
    // Every event switched off is a perfectly ordinary configuration,
    // and it must not silence something asked for by hand.
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();
    for (&harness.model.config.events) |*entry| entry.enabled = false;

    harness.send(.{ .trigger_read = Harness.fileResult(12, "1 session_start\n") });
    harness.send(.{ .trigger_read = Harness.fileResult(12, "2 !say 0 0 20 2600 HELLO|\n") });

    try testing.expect(harness.model.overlay.active);
}

test "the settings command opens the window instead of a screen" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    harness.send(.{ .trigger_read = Harness.fileResult(12, "1 session_start\n") });
    const before = harness.effects.window_action_state.show_count;
    harness.send(.{ .trigger_read = Harness.fileResult(12, "2 !settings\n") });

    try testing.expect(harness.effects.window_action_state.show_count > before);
    try testing.expect(!harness.model.overlay.active);
}

test "a trigger written moments before launch is honoured" {
    // `ai-souls "..."` writes the trigger and THEN starts the app, so
    // the first poll of a just-started process is exactly the case that
    // must not be treated as history.
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    var line: [cli.max_trigger_bytes]u8 = undefined;
    const fresh = try std.fmt.bufPrint(
        &line,
        "{d} !say 0 0 20 2600 JUST NOW|\n",
        .{cli.nowMs(testing.io)},
    );
    harness.send(.{ .trigger_read = Harness.fileResult(12, fresh) });

    try testing.expect(harness.model.overlay.active);
    try testing.expectEqualStrings("JUST NOW", harness.model.overlay.entry.title.slice());
}

/// The newest `alive` file the harness's effects channel was asked to
/// write. The fake executor keeps every request pending and does not
/// promise slot order, so "newest" is by content rather than position —
/// which is also what a real reader of the file would see, since each
/// write replaces the last.
fn writtenAlive(harness: *Harness) ?cli.Alive {
    var index: usize = 0;
    var found: ?cli.Alive = null;
    while (harness.effects.pendingFileAt(index)) |request| : (index += 1) {
        if (request.op != .write) continue;
        if (!std.mem.endsWith(u8, request.path, "alive")) continue;
        const alive = cli.parseAlive(request.bytes) orelse continue;
        // The consumed stamp only ever climbs, so it orders the writes
        // even when two land in the same millisecond.
        if (found == null or alive.consumed_ms > found.?.consumed_ms) found = alive;
    }
    return found;
}

test "the app stamps a heartbeat so status can find it" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();
    harness.model.paths.alive.set("/tmp/ai-souls-test/alive");

    harness.send(.{ .poll_tick = .{ .key = 1, .outcome = .fired } });

    const alive = writtenAlive(&harness) orelse return error.NoHeartbeat;
    // Fresh by its own definition, which is the question `status` asks.
    try testing.expect(cli.isFresh(cli.nowMs(testing.io), alive.heartbeat_ms));
}

test "acting on a trigger acknowledges its stamp" {
    // This is the handshake `ai-souls "..."` waits on before deciding
    // no app is listening. A heartbeat alone cannot answer it: an app
    // killed a second ago still has a fresh one.
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();
    harness.model.paths.alive.set("/tmp/ai-souls-test/alive");

    harness.send(.{ .trigger_read = Harness.fileResult(12, "1 session_start\n") });
    harness.send(.{ .trigger_read = Harness.fileResult(12, "5150 !say 0 0 20 2600 HELLO|\n") });
    // Published on the next poll rather than where it was earned, so
    // the tick's own heartbeat cannot be holding the effect key.
    harness.send(.{ .poll_tick = .{ .key = 1, .outcome = .fired } });

    const alive = writtenAlive(&harness) orelse return error.NoAcknowledgement;
    try testing.expectEqual(@as(i64, 5150), alive.consumed_ms);
}

test "a trigger the app decides to ignore is still acknowledged" {
    // Otherwise the CLI waits out its whole deadline and starts a
    // second app, every time a disabled event fires.
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();
    harness.model.paths.alive.set("/tmp/ai-souls-test/alive");
    harness.model.config.events[souls.indexOfKey("tool_failed").?].enabled = false;

    harness.send(.{ .trigger_read = Harness.fileResult(12, "1 session_start\n") });
    harness.send(.{ .trigger_read = Harness.fileResult(12, "99 tool_failed\n") });
    harness.send(.{ .poll_tick = .{ .key = 1, .outcome = .fired } });

    try testing.expect(!harness.model.overlay.active);
    const alive = writtenAlive(&harness) orelse return error.NoAcknowledgement;
    try testing.expectEqual(@as(i64, 99), alive.consumed_ms);
}

test "an alive file is read back the way it was written" {
    const alive = cli.parseAlive("1700000000000 1700000000500\n").?;
    try testing.expectEqual(@as(i64, 1700000000000), alive.heartbeat_ms);
    try testing.expectEqual(@as(i64, 1700000000500), alive.consumed_ms);

    // A one-number file is what an older build wrote; it still reports
    // a heartbeat, and simply never claims to have consumed anything.
    const old = cli.parseAlive("1700000000000\n").?;
    try testing.expectEqual(@as(i64, 1700000000000), old.heartbeat_ms);
    try testing.expectEqual(@as(i64, 0), old.consumed_ms);

    try testing.expect(cli.parseAlive("") == null);
    try testing.expect(cli.parseAlive("nonsense") == null);
}

test "a heartbeat old enough to be a corpse is not mistaken for a pulse" {
    const now: i64 = 1_000_000;
    try testing.expect(cli.isFresh(now, now));
    try testing.expect(cli.isFresh(now, now - cli.alive_stale_ms + 1));
    try testing.expect(!cli.isFresh(now, now - cli.alive_stale_ms));
    try testing.expect(!cli.isFresh(now, now - 60_000));
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
