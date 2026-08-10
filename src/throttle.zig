//! Whether a screen has earned its place, and the record of when the
//! last ones were.
//!
//! Nothing stays resident, so there is nowhere to keep "I just showed
//! that one" except a file. `fire` reads it before deciding, writes it
//! after deciding yes, and the whole thing costs one small read and one
//! small write on the only path that was going to open a window anyway.
//!
//! Two rules, and they are different in kind:
//!
//!  - **Never draw over a screen that is still up.** Two full-screen
//!    banners at once is not a matter of taste, so this floor holds
//!    even for an event the catalog does not throttle at all.
//!  - **Then the event's own `throttle_ms`**, which is per event and
//!    only against itself: a burst of tool failures should cost one
//!    screen, but an API error five seconds after a completed turn is
//!    still worth showing.
//!
//! Neither applies to a screen someone typed out by hand — `ai-souls
//! "..."` is an instruction, not a notification. It still records
//! itself, so the next hook does not land on top of it.
//!
//! Racy on purpose. Two hooks firing in the same instant both read the
//! same stamp and both decide yes. Locking a file to arbitrate a
//! decoration would cost more than the double screen it prevents, and
//! the hook events that actually burst are serialized by Claude Code
//! anyway.
//!
//!     ai-souls-fired 1
//!     last <ms> <duration_ms>
//!     f <key> <ms>

const std = @import("std");
const souls = @import("souls.zig");
const config_mod = @import("config.zig");
const paths_mod = @import("paths.zig");

pub const format_version = 1;

/// One `f` line per event at ~40 bytes, and room to grow the catalog by
/// an order of magnitude.
pub const max_bytes = 4 * 1024;

pub const Stamps = struct {
    /// When each catalog event last drew, in milliseconds since the
    /// epoch. Zero means never.
    at: [souls.event_count]i64 = @splat(0),
    /// The last screen of any kind — catalog or hand-typed — and how
    /// long it was going to stay up, which is what makes the no-overlap
    /// floor exact instead of a guess.
    last: i64 = 0,
    last_duration_ms: u32 = 0,

    /// Would a screen for catalog event `index` be welcome right now?
    pub fn allows(self: *const Stamps, index: usize, throttle_ms: u32, now: i64) bool {
        if (since(self.last, now)) |elapsed| {
            if (elapsed < self.last_duration_ms) return false;
        }
        if (throttle_ms == 0) return true;
        if (since(self.at[index], now)) |elapsed| {
            if (elapsed < throttle_ms) return false;
        }
        return true;
    }

    /// `index` is null for a screen with no catalog row behind it: it
    /// takes the floor with it, but has no window of its own to hold.
    pub fn record(self: *Stamps, index: ?usize, now: i64, duration_ms: u32) void {
        self.last = now;
        self.last_duration_ms = duration_ms;
        if (index) |which| self.at[which] = now;
    }

    /// Parse over the zeroes: an unreadable line simply means we have no
    /// record of that event, which shows a screen rather than eating
    /// one. Unknown keys — a file written by a newer build — are
    /// skipped, exactly as in `config.zig`.
    pub fn parse(text: []const u8) Stamps {
        var stamps: Stamps = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var fields = std.mem.tokenizeAny(u8, raw, " \t\r");
            const kind = fields.next() orelse continue;

            if (std.mem.eql(u8, kind, "last")) {
                stamps.last = parseMs(fields.next());
                stamps.last_duration_ms = @intCast(std.math.clamp(
                    parseMs(fields.next()),
                    0,
                    config_mod.max_duration_ms,
                ));
                continue;
            }
            if (!std.mem.eql(u8, kind, "f")) continue;
            const key = fields.next() orelse continue;
            const index = souls.indexOfKey(key) orelse continue;
            stamps.at[index] = parseMs(fields.next());
        }
        return stamps;
    }

    pub fn serialize(self: *const Stamps, buffer: []u8) []const u8 {
        var writer = std.Io.Writer.fixed(buffer);
        write(self, &writer) catch return "";
        return writer.buffered();
    }

    fn write(self: *const Stamps, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ai-souls-fired {d}\n", .{format_version});
        try writer.print("last {d} {d}\n", .{ self.last, self.last_duration_ms });
        for (souls.events, 0..) |event, index| {
            // An event that has never fired has nothing to say, and
            // leaving it out keeps a renamed key from lingering.
            if (self.at[index] == 0) continue;
            try writer.print("f {s} {d}\n", .{ event.key, self.at[index] });
        }
    }
};

/// Milliseconds from `stamp` to `now`, or null when the stamp cannot be
/// trusted: never set, or in the future because the clock moved under
/// us — a timezone change, an NTP step, a dual boot. An untrustworthy
/// stamp must never be able to hold a screen back forever.
fn since(stamp: i64, now: i64) ?u64 {
    if (stamp <= 0 or now < stamp) return null;
    return @intCast(now - stamp);
}

fn parseMs(field: ?[]const u8) i64 {
    const text = field orelse return 0;
    return std.fmt.parseInt(i64, text, 10) catch 0;
}

/// Best-effort read: no file, no home, nothing parseable — all mean the
/// same thing, which is that this screen is not being held back.
pub fn load(io: std.Io, paths: *const paths_mod.Paths) Stamps {
    if (paths.fired.isEmpty()) return .{};
    var buffer: [max_bytes]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, paths.fired.slice(), &buffer) catch return .{};
    return Stamps.parse(text);
}

/// Best-effort write. A screen that draws without recording itself is a
/// missed throttle; a screen that refuses to draw because it could not
/// write a file would be a bug.
pub fn save(io: std.Io, paths: *const paths_mod.Paths, stamps: *const Stamps) void {
    if (paths.fired.isEmpty()) return;
    var buffer: [max_bytes]u8 = undefined;
    const text = stamps.serialize(&buffer);
    if (text.len == 0) return;
    const cwd = std.Io.Dir.cwd();
    const parent = paths_mod.parent(paths.fired.slice());
    if (parent.len > 0) cwd.createDirPath(io, parent) catch {};
    cwd.writeFile(io, .{ .sub_path = paths.fired.slice(), .data = text }) catch {};
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "a screen never draws over one that is still up" {
    const index = souls.indexOfKey("commit_made").?;
    var stamps: Stamps = .{};
    stamps.record(index, 1_000_000, 2600);

    // The same event and an unrelated one are both refused while the
    // band is up, throttle or no throttle.
    try testing.expect(!stamps.allows(index, 0, 1_002_000));
    try testing.expect(!stamps.allows(souls.indexOfKey("turn_complete").?, 0, 1_002_000));

    // And both are welcome the moment it is gone.
    try testing.expect(stamps.allows(index, 0, 1_002_600));
    try testing.expect(stamps.allows(souls.indexOfKey("turn_complete").?, 0, 1_002_600));

    // An ad-hoc screen keeps the floor honest for whatever comes next
    // without claiming a window of its own.
    stamps.record(null, 1_002_600, 2600);
    try testing.expect(!stamps.allows(index, 0, 1_003_000));
}

test "a burst costs one screen, and the clock starts again after it" {
    const index = souls.indexOfKey("tool_failed").?;
    const window = souls.events[index].throttle_ms;
    var stamps: Stamps = .{};

    try testing.expect(stamps.allows(index, window, 1_000_000));
    stamps.record(index, 1_000_000, 2600);

    // Nineteen more failures in the next fifteen seconds draw nothing.
    var at: i64 = 1_003_000;
    while (at < 1_000_000 + window) : (at += 600) {
        try testing.expect(!stamps.allows(index, window, at));
    }
    try testing.expect(stamps.allows(index, window, 1_000_000 + window));
}

test "one event's throttle never swallows another's news" {
    // The regression this guards: a single global cooldown would mean
    // the third permission prompt of the minute could eat the API error
    // that came right after it.
    const asked = souls.indexOfKey("question_asked").?;
    const failure = souls.indexOfKey("api_error").?;
    var stamps: Stamps = .{};
    stamps.record(asked, 1_000_000, 2600);

    // Three seconds later the band is down. The question is still
    // inside its own ten-second window; the error was never in one.
    try testing.expect(!stamps.allows(asked, souls.events[asked].throttle_ms, 1_003_000));
    try testing.expect(stamps.allows(failure, souls.events[failure].throttle_ms, 1_003_000));
}

test "stamps round-trip, and only the events that fired are written" {
    var stamps: Stamps = .{};
    const index = souls.indexOfKey("rate_limited").?;
    stamps.record(index, 1_700_000_000_000, 2600);

    var buffer: [max_bytes]u8 = undefined;
    const text = stamps.serialize(&buffer);
    try testing.expect(std.mem.indexOf(u8, text, "rate_limited") != null);
    try testing.expect(std.mem.indexOf(u8, text, "turn_complete") == null);

    const parsed = Stamps.parse(text);
    try testing.expectEqual(stamps.last, parsed.last);
    try testing.expectEqual(stamps.last_duration_ms, parsed.last_duration_ms);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), parsed.at[index]);
    try testing.expectEqual(@as(i64, 0), parsed.at[souls.indexOfKey("turn_complete").?]);
}

test "a clock that moved backwards does not wedge every screen" {
    // Written under one timezone, read under an earlier one. Without
    // the guard the stamp stays in the future and nothing ever fires
    // again.
    const index = souls.indexOfKey("tool_failed").?;
    var stamps: Stamps = .{};
    stamps.record(index, 2_000_000, 2600);
    try testing.expect(stamps.allows(index, souls.events[index].throttle_ms, 1_000_000));
}

test "a junk or truncated file loses nothing but the throttle" {
    const parsed = Stamps.parse(
        \\ai-souls-fired 1
        \\last
        \\f
        \\f not_an_event 12345
        \\garbage garbage garbage
        \\f tool_failed banana
    );
    try testing.expectEqual(@as(i64, 0), parsed.last);
    try testing.expectEqual(@as(i64, 0), parsed.at[souls.indexOfKey("tool_failed").?]);
    try testing.expect(parsed.allows(souls.indexOfKey("tool_failed").?, 15_000, 1_000));
}
