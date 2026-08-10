//! Model, Msg, and update — the whole of AI Souls' behaviour.
//!
//! A process of this app exists to draw exactly one banner. The band is
//! the app's shell window, so `overlay.active` is not the window's
//! visibility — the window is always there for the length of the
//! process — it is whether the band has anything to paint. A screen
//! appears by flipping the bool and ends by flipping it back, and the
//! process exits with it.

const std = @import("std");
const native_sdk = @import("native_sdk");

const config_mod = @import("config.zig");
const paths_mod = @import("paths.zig");
const souls = @import("souls.zig");

/// The main canvas — the band's own surface, declared in `app.zon` and
/// mirrored by the scene `main` builds.
pub const overlay_canvas_label = "overlay-canvas";
/// The opaque-mode fallback window and its canvas — see
/// `main.declaredWindows` for why that mode needs a second window.
pub const overlay_window_label = "soul-overlay";
pub const opaque_canvas_label = "opaque-canvas";

/// Effect keys. Timers and audio each live in their own namespace, but
/// keeping them globally distinct makes the log readable.
const key_anim_timer: u64 = 2;
const key_sound_timer: u64 = 3;
const key_audio: u64 = 30;

/// Overlay animation cadence: one tick per 60 Hz frame.
///
/// Asking for LESS does not buy more frames, and measurably costs some.
/// Effect timers land as `WM_TIMER`, the lowest-priority Win32 message,
/// so while the overlay is animating the frame loop starves them well
/// below whatever was requested — the SDK's own Win32 host says as much
/// where it deliberately uses posted messages instead. Measured on a
/// 4K/150% display, three runs each:
///
///     interval   4 ms  ->  20 fps      (plus flooding the queue)
///     interval  16 ms  ->  21 fps
///
/// `timeBeginPeriod(1)` was tried too and sat inside the same noise, so
/// it is not worth the battery on an app that lives in the tray. The
/// real lever is how much the frame loop has to do — see `bandHeight`.
const anim_interval_ms: u64 = 16;

const fade_in_ms: u32 = 320;
const fade_out_ms: u32 = 620;

/// How long after a screen opens its sound is started.
///
/// Starting audio COSTS the message loop. Media Foundation resolves the
/// source and brings up a session synchronously, and once it is running
/// its position and spectrum reports crowd out the animation timer.
/// Measured as animation advances during the 320 ms fade-in, three
/// screens each:
///
///     silent screen        8 advances
///     sound started at 0   1 advance
///
/// One advance cannot draw a fade, so the banner appeared to snap on
/// late — "the first second or two isn't visible", and only ever with
/// the sound on. Deferring the sound past the fade puts that cost in
/// the hold, where nothing is moving and nobody can see it.
///
/// It is also just better: the type settles, and THEN the gong lands.
const sound_delay_ms: u64 = fade_in_ms + 20;

/// A gap between two animation frames longer than this did not happen
/// because the machine was busy — it happened because the message loop
/// was not running at all. The worst honest gap measured on a screen
/// nothing was blocking is 66 ms.
const stall_threshold_ms: i64 = 250;

/// Total time `advanceOverlay` will refuse to count. Past this the
/// screen gives up and jumps to wherever the clock says it is: a banner
/// stuck on the glass forever is a worse failure than one that snaps.
const max_stall_skip_ms: u32 = 4000;

pub const Overlay = struct {
    active: bool = false,
    /// What to draw and what to play. A COPY, not a catalog index: a
    /// screen asked for from the command line has no catalog row behind
    /// it, and one already playing should not change under a settings
    /// edit halfway through.
    entry: config_mod.EventSettings = .{},
    started_ms: i64 = 0,
    elapsed_ms: u32 = 0,
    duration_ms: u32 = 2600,
    /// Wall clock at the previous `advanceOverlay`, so the next one can
    /// tell a slow frame from a stopped clock.
    last_advance_ms: i64 = 0,
    /// How much frozen time has been forgiven so far, against
    /// `max_stall_skip_ms`.
    stall_skipped_ms: u32 = 0,

    /// 0..1 ink strength for the current moment: rise, hold, fall.
    pub fn opacity(self: *const Overlay) f32 {
        if (!self.active) return 0;
        const elapsed: f32 = @floatFromInt(self.elapsed_ms);
        const total: f32 = @floatFromInt(self.duration_ms);
        const rise: f32 = @floatFromInt(fade_in_ms);
        const fall: f32 = @floatFromInt(fade_out_ms);
        if (elapsed < rise) return smoothstep(elapsed / rise);
        if (elapsed > total - fall) {
            const remaining = total - elapsed;
            if (remaining <= 0) return 0;
            return smoothstep(remaining / fall);
        }
        return 1;
    }

    /// Where the fall begins. A duration shorter than the fall itself
    /// starts falling immediately.
    fn fadeStart(self: *const Overlay) i64 {
        return @max(0, @as(i64, self.duration_ms) - @as(i64, fade_out_ms));
    }

    /// How much of a `gap`-long freeze ending at `now` to refuse to
    /// count, so the fade-out survives it. Pure arithmetic on the
    /// overlay's own clock; the caller adds it to `started_ms`.
    ///
    ///   frozen entirely inside the hold  -> 0, it was holding anyway
    ///   frozen across the top of the fade -> just the overshoot
    ///   frozen during the fade            -> all of it
    fn forgive(self: *Overlay, now: i64, gap: i64) i64 {
        const at = now - self.started_ms;
        const before = at - gap;
        const fade = self.fadeStart();
        const target = if (before > fade) before else @min(at, fade);
        const budget: i64 = @intCast(max_stall_skip_ms - self.stall_skipped_ms);
        const skip = @max(0, @min(at - target, budget));
        self.stall_skipped_ms += @intCast(skip);
        return skip;
    }

    /// The headline drifts up a few points as it fades in — the Souls
    /// screens never just pop.
    pub fn driftY(self: *const Overlay) f32 {
        if (!self.active) return 0;
        const elapsed: f32 = @floatFromInt(self.elapsed_ms);
        const rise: f32 = @floatFromInt(fade_in_ms);
        if (elapsed >= rise) return 0;
        return (1 - smoothstep(elapsed / rise)) * 14;
    }
};

fn smoothstep(t: f32) f32 {
    const x = std.math.clamp(t, 0, 1);
    return x * x * (3 - 2 * x);
}

/// Headline point size. Every other measurement of the screen is a
/// multiple of this one, so the banner keeps its proportions on any
/// display instead of being a pile of independent magic numbers.
pub fn headlineSize(screen_width: f32) f32 {
    return std.math.clamp(screen_width * 0.055, 40, 104);
}

/// How tall the bar is — and therefore how tall the overlay WINDOW is,
/// because the two are the same thing.
///
/// 2.5x the headline: enough to sit the type in air rather than in a
/// box. The window matching the bar is also the whole framerate story
/// on Windows. A transparent top-level window cannot take the Direct2D
/// packet path — the host refuses it outright, because
/// `UpdateLayeredWindow` replaces the entire top-level image and cannot
/// compose child HWNDs. Every frame is rasterized on the CPU instead,
/// and the cost tracks the window's AREA. Measured on a 4K/150%
/// display, three runs each:
///
///     full screen (1440pt)  ->   6 fps
///     320pt band            ->  16 fps
///     260pt band (2.5x)     ->  20 fps
///
/// (An opaque band of the same size measures 28, because it regains the
/// Direct2D path — that is what `AI_SOULS_OPAQUE=1` buys, at the
/// cost of the bar no longer being see-through.)
///
/// Those runs all had a sound playing, which was independently holding
/// the framerate down (see `sound_delay_ms`); the ratios between them
/// are the point, not the absolute numbers. A screen now runs at
/// roughly 22 fps whether or not it makes a noise.
///
/// The height guard is for the freak case of a very wide, very short
/// display, where 2.5x a width-derived headline could otherwise ask for
/// more rows than exist.
pub fn bandHeight(screen_width: f32, screen_height: f32) f32 {
    return @min(headlineSize(screen_width) * 2.5, screen_height * 0.6);
}

/// How far the bar fades at each end: a quarter of the headline, which
/// on an unguarded bar is exactly a tenth of its height. Taken off the
/// bar rather than off the headline so the proportion survives the
/// short-display guard above.
///
/// The bar has to stop without drawing a line across the screen.
pub fn bandSoftEdge(screen_width: f32, screen_height: f32) f32 {
    return bandHeight(screen_width, screen_height) * 0.1;
}

/// Top edge of that window: vertically centred on the display.
pub fn bandTop(screen_width: f32, screen_height: f32) f32 {
    return @round((screen_height - bandHeight(screen_width, screen_height)) / 2);
}

pub const Model = struct {
    paths: paths_mod.Paths = .{},

    /// The one screen this process exists to draw. Resolved by the CLI
    /// before `init`, so `update` never reads the config file — a
    /// banner's settings arrive whole.
    entry: config_mod.EventSettings = .{},

    overlay: Overlay = .{},

    /// Primary display size in logical points, measured in `main`.
    screen_width: f32 = 1440,
    screen_height: f32 = 900,

    /// The file the last `playAudio` was pointed at. What a failure
    /// would need to name — and the proof the tests lean on that a
    /// sound was, or was not, started.
    last_sound_path: paths_mod.PathText = .{},

    /// Per-pixel window transparency, so the screen floats over the
    /// desktop instead of blanking it. Set from
    /// `AI_SOULS_OPAQUE=1` at launch: some remote-desktop and
    /// compositor setups cannot present a layered window, and a solid
    /// banner beats an invisible one. When false the banner draws in
    /// the opaque declared window instead of the shell band — see
    /// `main.declaredWindows`.
    overlay_transparent: bool = true,
};

pub const Msg = union(enum) {
    audio_event: native_sdk.EffectAudio,
    anim_tick: native_sdk.EffectTimer,
    sound_tick: native_sdk.EffectTimer,

    /// The banner has no controls — its window is click-through and
    /// could not receive a press if it wanted one — so every Msg
    /// arrives from the host.
    pub const view_unbound = .{
        "audio_event",
        "anim_tick",
        "sound_tick",
    };
};

pub const Effects = native_sdk.Effects(Msg);

/// Boot: straight to the banner. The entry was already resolved by the
/// CLI, so there is nothing to wait for and nothing to poll.
pub fn init(model: *Model, fx: *Effects) void {
    showEntry(model, fx, model.entry);
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .audio_event => {
            // A failed sound has no one to tell — the window is a
            // banner, not a status line — so the screen simply runs
            // silent. Whatever else it says, an audio event is a
            // HEARTBEAT — and during playback it is the only one that
            // arrives. See `advanceOverlay`.
            advanceOverlay(model, fx);
        },

        .anim_tick => |timer| {
            if (timer.outcome != .fired) return;
            advanceOverlay(model, fx);
        },
        .sound_tick => |timer| {
            if (timer.outcome != .fired) return;
            // The screen may already be over — a cancelled timer can
            // still have one fire in flight, and nothing should play
            // over an empty overlay.
            if (!model.overlay.active) return;
            playSound(model, fx, model.overlay.entry.sound, model.overlay.entry.volume);
        },
    }
}

/// Move the screen to wherever the wall clock says it is, and end it
/// when its time is up.
///
/// Driven from TWO clocks, because on Windows neither one is enough.
///
/// The animation timer is an `fx` timer, which the Win32 host services
/// with `SetTimer` — and `WM_TIMER` is the lowest-priority message
/// there is, delivered only when the queue is otherwise empty. Playing
/// a sound fills that queue: the audio backend posts a position report
/// and a spectrum frame every ~40 ms each, and posted messages keep
/// their place ahead of a timer. Measured over the first second of a
/// screen fired after the app had been idle:
///
///     silent screen      28 timer ticks
///     screen with sound   1 timer tick
///
/// One tick cannot draw a 320 ms fade, so the banner used to sit
/// invisible and then appear at full strength — the "first second or
/// two isn't there" symptom, and only ever with the sound on.
///
/// The audio events are the thing crowding the timer out, so they are
/// also the thing that reliably arrives: during playback they ARE the
/// frame clock, at ~16-25 Hz. Between them the screen is animated by
/// whichever clock is actually running.
///
/// Both paths are idempotent — this reads the wall clock rather than
/// counting ticks, so being called twice in a millisecond, or not at
/// all for fifty, only changes the framerate and never the timing.
fn advanceOverlay(model: *Model, fx: *Effects) void {
    if (!model.overlay.active) return;
    const now = fx.wallMs();

    // A frozen message loop must not be allowed to skip the fade-out.
    //
    // Starting a sound blocks the Win32 loop for two solid seconds (see
    // `sound_delay_ms`) — longer than the hold, so the clock came back
    // past the end of the screen and the banner vanished without ever
    // fading. What is deducted here is only the part of the freeze that
    // would have eaten animation: a screen frozen during its hold is
    // still holding, and stays up for exactly as long as it was asked
    // to. Only the overshoot past the top of the fade is given back.
    if (model.overlay.last_advance_ms != 0) {
        const gap = now - model.overlay.last_advance_ms;
        if (gap > stall_threshold_ms) {
            model.overlay.started_ms += model.overlay.forgive(now, gap);
        }
    }
    model.overlay.last_advance_ms = now;

    const elapsed = now - model.overlay.started_ms;
    if (elapsed < 0) return;
    model.overlay.elapsed_ms = @intCast(@min(
        elapsed,
        @as(i64, @intCast(model.overlay.duration_ms)),
    ));
    if (model.overlay.elapsed_ms >= model.overlay.duration_ms) {
        // Presence is visibility: clearing the flag closes the window
        // on the next reconcile.
        model.overlay.active = false;
        fx.cancelTimer(key_anim_timer);
        // A screen shorter than `sound_delay_ms` ends before its sound
        // was ever due; the pending start has to go with it.
        fx.cancelTimer(key_sound_timer);
        fx.stopAudio();
        // The whole reason this process exists is over.
        fx.quitApp();
    }
}

/// Put a screen up. The settings come in whole rather than by
/// reference: they may be a catalog row or an ad-hoc screen typed on
/// the command line, and by now there is no difference.
fn showEntry(model: *Model, fx: *Effects, entry: config_mod.EventSettings) void {
    const now = fx.wallMs();
    model.overlay = .{
        .active = true,
        .entry = entry,
        .started_ms = now,
        .elapsed_ms = 0,
        .duration_ms = entry.duration_ms,
        .last_advance_ms = now,
    };
    fx.startTimer(.{
        .key = key_anim_timer,
        .interval_ms = anim_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.anim_tick),
    });
    // Silence needs no lead time and costs the loop nothing, so it can
    // be dealt with now; a real sound waits until the fade has drawn
    // (see `sound_delay_ms`).
    if (entry.sound == .none) {
        fx.stopAudio();
        return;
    }
    fx.startTimer(.{
        .key = key_sound_timer,
        .interval_ms = sound_delay_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.sound_tick),
    });
}

fn playSound(model: *Model, fx: *Effects, sound: souls.Sound, volume: u8) void {
    if (sound == .none) {
        fx.stopAudio();
        return;
    }
    var buffer: [paths_mod.max_path_bytes]u8 = undefined;
    const path = model.paths.asset(&buffer, sound.path());
    model.last_sound_path.set(path);
    fx.setAudioVolume(@as(f32, @floatFromInt(volume)) / 100.0);
    fx.playAudio(.{
        .key = key_audio,
        .path = path,
        .on_event = Effects.audioMsg(.audio_event),
    });
}

// -------------------------------------------------------------- tests

const testing = std.testing;

test "opacity rises, holds, and falls inside the configured duration" {
    var overlay: Overlay = .{ .active = true, .duration_ms = 2600 };

    overlay.elapsed_ms = 0;
    try testing.expectApproxEqAbs(@as(f32, 0), overlay.opacity(), 0.001);

    overlay.elapsed_ms = fade_in_ms;
    try testing.expectApproxEqAbs(@as(f32, 1), overlay.opacity(), 0.001);

    overlay.elapsed_ms = 1500;
    try testing.expectApproxEqAbs(@as(f32, 1), overlay.opacity(), 0.001);

    overlay.elapsed_ms = 2600;
    try testing.expectApproxEqAbs(@as(f32, 0), overlay.opacity(), 0.001);
}

test "a short screen still fades all the way in and out" {
    // The floor duration is shorter than fade-in plus fade-out, so the
    // curves overlap; opacity must stay in range and start and end dark.
    var overlay: Overlay = .{ .active = true, .duration_ms = config_mod.min_duration_ms };
    var elapsed: u32 = 0;
    while (elapsed <= overlay.duration_ms) : (elapsed += 10) {
        overlay.elapsed_ms = elapsed;
        const value = overlay.opacity();
        try testing.expect(value >= 0 and value <= 1);
    }
    overlay.elapsed_ms = 0;
    try testing.expectApproxEqAbs(@as(f32, 0), overlay.opacity(), 0.001);
    overlay.elapsed_ms = overlay.duration_ms;
    try testing.expectApproxEqAbs(@as(f32, 0), overlay.opacity(), 0.001);
}

test "an inactive overlay paints nothing" {
    const overlay: Overlay = .{ .active = false, .elapsed_ms = 100, .duration_ms = 2600 };
    try testing.expectEqual(@as(f32, 0), overlay.opacity());
    try testing.expectEqual(@as(f32, 0), overlay.driftY());
}

test "the bar is 2.5x the headline and its edges a quarter of it" {
    // The proportions the design is specified in. Checked against a
    // width where the headline clamp is not binding, so the ratios are
    // the thing under test rather than the clamp.
    const width: f32 = 1600;
    const headline = headlineSize(width);
    try testing.expect(headline > 40 and headline < 104);

    const band = bandHeight(width, 1200);
    try testing.expectApproxEqAbs(headline * 2.5, band, 0.01);
    try testing.expectApproxEqAbs(headline * 0.25, bandSoftEdge(width, 1200), 0.01);
}

test "the overlay window is a bar, not a screen" {
    // The regression this guards is a framerate one: a transparent
    // window is software-rasterized per frame on Windows, so covering
    // the display costs several times what the banner does.
    const width: f32 = 2560;
    const height: f32 = 1440;
    const band = bandHeight(width, height);
    try testing.expect(band < height / 4);
    // Vertically centred, and fully on screen.
    const top = bandTop(width, height);
    try testing.expect(top > 0);
    try testing.expectApproxEqAbs(height - top - band, top, 1);
}

test "the bar fits on screen at any display size" {
    const sizes = [_][2]f32{
        .{ 1280, 800 }, .{ 1920, 1080 }, .{ 2560, 1440 },
        .{ 3840, 2160 }, .{ 3440, 1440 }, // ultrawide
        .{ 5120, 300 }, // absurd: wide and very short
        .{ 800, 1280 }, // portrait
    };
    for (sizes) |size| {
        const width = size[0];
        const height = size[1];
        const band = bandHeight(width, height);
        const edge = bandSoftEdge(width, height);
        try testing.expect(band > 0);
        // The two soft edges must never eat the whole bar, or there is
        // no solid core left to sit the headline on.
        try testing.expect(edge * 2 < band);
        const top = bandTop(width, height);
        try testing.expect(top >= 0);
        try testing.expect(top + band <= height);
    }
    // The short-display guard genuinely binds on that absurd one, so it
    // is not dead code.
    try testing.expect(bandHeight(5120, 300) < headlineSize(5120) * 2.5);
}

test "a freeze inside the hold costs the screen nothing" {
    // The banner is static through the hold, so a loop that stops there
    // and starts again has not skipped anything worth seeing. The screen
    // still ends when it was asked to.
    var overlay: Overlay = .{ .active = true, .duration_ms = 2600 };
    try testing.expectEqual(@as(i64, 1980), overlay.fadeStart());
    try testing.expectEqual(@as(i64, 0), overlay.forgive(1340, 1000));
    try testing.expectEqual(@as(u32, 0), overlay.stall_skipped_ms);
}

test "a freeze that would swallow the fade gives back only the overshoot" {
    // The two-second audio freeze, exactly: the sound starts at 340 ms
    // and the loop comes back at 2375, past the top of the fade. The
    // screen resumes at the fade's first frame, not 395 ms into it.
    var overlay: Overlay = .{ .active = true, .duration_ms = 2600 };
    const skip = overlay.forgive(2375, 2035);
    try testing.expectEqual(@as(i64, 395), skip);
    // Where the clock now reads: the very top of the fall.
    overlay.started_ms += skip;
    overlay.elapsed_ms = @intCast(2375 - overlay.started_ms);
    try testing.expectEqual(@as(u32, 1980), overlay.elapsed_ms);
    try testing.expectApproxEqAbs(@as(f32, 1), overlay.opacity(), 0.001);
}

test "a freeze during the fade is refused outright" {
    var overlay: Overlay = .{ .active = true, .duration_ms = 2600 };
    // Already 120 ms into the fall when the loop stopped for 500 ms.
    try testing.expectEqual(@as(i64, 500), overlay.forgive(2600, 500));
}

test "forgiveness runs out" {
    // A screen that is being starved indefinitely has to be allowed to
    // end. Better a banner that snaps away than one that never leaves.
    var overlay: Overlay = .{ .active = true, .duration_ms = 2600 };
    var granted: i64 = 0;
    var round: i64 = 0;
    while (round < 40) : (round += 1) {
        // Each round: frozen for a second, deep inside the fall.
        granted += overlay.forgive(2600 + round * 1000, 1000);
    }
    try testing.expectEqual(@as(i64, max_stall_skip_ms), granted);
    try testing.expectEqual(max_stall_skip_ms, overlay.stall_skipped_ms);
}

test "a short screen falls from its first frame" {
    var overlay: Overlay = .{ .active = true, .duration_ms = config_mod.min_duration_ms };
    try testing.expect(overlay.duration_ms < fade_out_ms);
    try testing.expectEqual(@as(i64, 0), overlay.fadeStart());
    // Nothing on such a screen is holdable, so a freeze is refused whole.
    try testing.expectEqual(@as(i64, 900), overlay.forgive(900, 900));
}
