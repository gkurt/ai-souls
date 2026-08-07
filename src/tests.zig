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
        model.paths.config.set("/tmp/claude-souls-test/config.txt");
        model.paths.trigger.set("/tmp/claude-souls-test/trigger");
        model.paths.exe.set("/tmp/claude-souls-test/claude-souls");
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
    try testing.expectEqual(souls.indexOfKey("tool_failed").?, harness.model.overlay.event_index);
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
