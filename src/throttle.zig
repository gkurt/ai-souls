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
//!  - **Never draw over a screen that is still up, unless you outrank
//!    it.** Two full-screen banners at once is not a matter of taste,
//!    so this floor holds even for an event the catalog does not
//!    throttle at all. The exception is `Event.priority`: a PR landing
//!    seconds after the commit that led to it is the screen worth
//!    having, so it takes the glass and the commit's banner comes down.
//!    Equal ranks do not displace each other.
//!  - **Then the event's own `throttle_ms`**, which is per event and
//!    only against itself: a burst of tool failures should cost one
//!    screen, but an API error five seconds after a completed turn is
//!    still worth showing.
//!
//! Neither applies to a screen someone typed out by hand — `ai-souls
//! "..."` is an instruction, not a notification. It still records
//! itself, at `souls.by_hand_priority`, so nothing lands on top of it.
//!
//! Racy on purpose. Two hooks firing in the same instant both read the
//! same stamp and both decide yes. Locking a file to arbitrate a
//! decoration would cost more than the double screen it prevents, and
//! the hook events that actually burst are serialized by Claude Code
//! anyway.
//!
//!     ai-souls-fired 1
//!     last <ms> <duration_ms> <priority>
//!     f <key> <ms>

const std = @import("std");
const souls = @import("souls.zig");
const config_mod = @import("config.zig");
const overlay_style = @import("overlay_style.zig");
const paths_mod = @import("paths.zig");

/// Whether outranking the incumbent is allowed to mean anything.
///
/// Preemption is only honest where there is a way to take the standing
/// banner down, and today that is Win32 alone — see
/// `overlay_style.dismissOthers`. Everywhere else the floor stays
/// absolute, because two banners drawn over each other is a worse
/// outcome than the one that was missed.
pub const can_preempt = overlay_style.can_dismiss;

pub const format_version = 1;

/// One `f` line per event at ~40 bytes, and room to grow the catalog by
/// an order of magnitude.
pub const max_bytes = 4 * 1024;

pub const Stamps = struct {
    /// When each catalog event last drew, in milliseconds since the
    /// epoch. Zero means never.
    at: [souls.event_count]i64 = @splat(0),
    /// The last screen of any kind — catalog or hand-typed — how long
    /// it was going to stay up, and what it outranks. The duration is
    /// what makes the no-overlap floor exact instead of a guess; the
    /// rank is what lets better news through it.
    last: i64 = 0,
    last_duration_ms: u32 = 0,
    last_priority: u8 = 0,

    /// Would a screen for catalog event `index` be welcome right now?
    ///
    /// Reads the window and the rank off the catalog rather than taking
    /// them as arguments, so no caller can ask the question with one
    /// event's rules and another event's index.
    pub fn allows(self: *const Stamps, index: usize, now: i64) bool {
        const event = souls.events[index];
        if (self.holdsGlass(now) and !outranks(event.priority, self.last_priority)) return false;
        if (event.throttle_ms == 0) return true;
        if (since(self.at[index], now)) |elapsed| {
            if (elapsed < event.throttle_ms) return false;
        }
        return true;
    }

    /// Is a banner still on screen? Also the answer to "is there
    /// anything to take down", which is why `fire` does not need to ask
    /// the window system before it decides.
    pub fn holdsGlass(self: *const Stamps, now: i64) bool {
        const elapsed = since(self.last, now) orelse return false;
        return elapsed < self.last_duration_ms;
    }

    /// `index` is null for a screen with no catalog row behind it: it
    /// takes the floor with it at `souls.by_hand_priority`, but has no
    /// window of its own to hold.
    pub fn record(self: *Stamps, index: ?usize, now: i64, duration_ms: u32) void {
        self.last = now;
        self.last_duration_ms = duration_ms;
        self.last_priority = if (index) |which| souls.events[which].priority else souls.by_hand_priority;
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
                // Absent in a file written before ranks existed, which
                // reads as rank zero — everything outranks it. The worst
                // that costs is one preemption too many, once.
                stamps.last_priority = @intCast(std.math.clamp(parseMs(fields.next()), 0, 255));
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
        try writer.print("last {d} {d} {d}\n", .{ self.last, self.last_duration_ms, self.last_priority });
        for (souls.events, 0..) |event, index| {
            // An event that has never fired has nothing to say, and
            // leaving it out keeps a renamed key from lingering.
            if (self.at[index] == 0) continue;
            try writer.print("f {s} {d}\n", .{ event.key, self.at[index] });
        }
    }
};

/// Does a screen ranked `challenger` get to take the glass from one
/// ranked `incumbent`?
///
/// Strictly greater, so two screens of the same rank never interrupt
/// each other — the second permission prompt of a run leaves the first
/// one's banner alone.
fn outranks(challenger: u8, incumbent: u8) bool {
    if (!can_preempt) return false;
    return challenger > incumbent;
}

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
    // A high rank so nothing in the catalog can preempt it, which keeps
    // this about the floor and not about the ranking.
    const index = souls.indexOfKey("pr_created").?;
    var stamps: Stamps = .{};
    stamps.record(index, 1_000_000, 2600);

    // The same event and a lesser one are both refused while the band
    // is up, throttle or no throttle.
    try testing.expect(!stamps.allows(index, 1_002_000));
    try testing.expect(!stamps.allows(souls.indexOfKey("turn_complete").?, 1_002_000));

    // And both are welcome the moment it is gone.
    try testing.expect(stamps.allows(index, 1_002_600));
    try testing.expect(stamps.allows(souls.indexOfKey("turn_complete").?, 1_002_600));

    // An ad-hoc screen keeps the floor honest for whatever comes next
    // without claiming a window of its own — and it outranks the whole
    // catalog, so nothing gets through it either.
    stamps.record(null, 1_002_600, 2600);
    try testing.expectEqual(souls.by_hand_priority, stamps.last_priority);
    try testing.expect(!stamps.allows(index, 1_003_000));
}

test "better news takes the glass from a screen still up" {
    if (!can_preempt) return error.SkipZigTest;

    // The case this was built for: a commit banner is still on screen
    // when the PR it led to lands.
    const commit = souls.indexOfKey("commit_made").?;
    const pr = souls.indexOfKey("pr_created").?;
    var stamps: Stamps = .{};
    stamps.record(commit, 1_000_000, 7200);

    try testing.expect(stamps.allows(pr, 1_002_000));
    // Not the other way round: a commit does not interrupt a PR.
    stamps.record(pr, 1_002_000, 7200);
    try testing.expect(!stamps.allows(commit, 1_004_000));
    // And a tie is not a win — a second question leaves the first alone.
    stamps.record(souls.indexOfKey("question_asked").?, 1_010_000, 7200);
    try testing.expect(!stamps.allows(souls.indexOfKey("permission_denied").?, 1_012_000));
}

test "outranking does not exempt an event from its own window" {
    if (!can_preempt) return error.SkipZigTest;

    // A PR outranks a turn ending, but two PRs a second apart are still
    // one piece of news as far as `throttle_ms` is concerned — except
    // `pr_created` has no window, so pick one that does.
    const denied = souls.indexOfKey("permission_denied").?;
    const window = souls.events[denied].throttle_ms;
    var stamps: Stamps = .{};
    stamps.record(souls.indexOfKey("turn_complete").?, 1_000_000, 7200);

    // Through the floor on rank...
    try testing.expect(stamps.allows(denied, 1_001_000));
    stamps.record(denied, 1_001_000, 7200);
    // ...and then held by its own window like anything else.
    try testing.expect(!stamps.allows(denied, 1_001_000 + window - 1));
    try testing.expect(stamps.allows(denied, 1_001_000 + window));
}

test "a burst costs one screen, and the clock starts again after it" {
    const index = souls.indexOfKey("tool_failed").?;
    const window = souls.events[index].throttle_ms;
    var stamps: Stamps = .{};

    try testing.expect(stamps.allows(index, 1_000_000));
    stamps.record(index, 1_000_000, 2600);

    // Nineteen more failures in the next thirty seconds draw nothing.
    var at: i64 = 1_003_000;
    while (at < 1_000_000 + window) : (at += 600) {
        try testing.expect(!stamps.allows(index, at));
    }
    try testing.expect(stamps.allows(index, 1_000_000 + window));
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
    try testing.expect(!stamps.allows(asked, 1_003_000));
    try testing.expect(stamps.allows(failure, 1_003_000));
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
    // The rank has to survive the file, or every screen would preempt
    // every other one across process boundaries — which is all of them.
    try testing.expectEqual(souls.events[index].priority, parsed.last_priority);
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
    try testing.expect(stamps.allows(index, 1_000_000));
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
    try testing.expectEqual(@as(u8, 0), parsed.last_priority);
    try testing.expectEqual(@as(i64, 0), parsed.at[souls.indexOfKey("tool_failed").?]);
    try testing.expect(parsed.allows(souls.indexOfKey("tool_failed").?, 1_000));
}

test "a record written before ranks existed reads as the bottom of the pile" {
    const parsed = Stamps.parse("last 1000000 7200");
    try testing.expectEqual(@as(i64, 1_000_000), parsed.last);
    try testing.expectEqual(@as(u32, 7200), parsed.last_duration_ms);
    try testing.expectEqual(@as(u8, 0), parsed.last_priority);
}
