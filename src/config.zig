//! The on-disk settings, and the allocation-free codec for them.
//!
//! Deliberately a flat line format rather than JSON: `update` has no
//! allocator, so both the parse and the serialize have to run out of
//! fixed buffers. One line per event, keyed by `Event.key`, so an
//! unknown key from a newer build is skipped instead of fatal and a
//! missing key simply keeps its compiled default.
//!
//!     claude-souls 1
//!     e <key> <enabled> <style> <sound> <volume> <duration_ms> <title>|<subtitle>

const std = @import("std");
const souls = @import("souls.zig");

pub const max_subtitle_bytes = 64;

/// Longest config file the app will read or write. Ten events at ~140
/// bytes a line leaves room to grow by an order of magnitude.
pub const max_config_bytes = 8 * 1024;

pub const format_version = 1;

/// A fixed-capacity string that can live in the model without an
/// allocator behind it.
pub fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]u8 = @splat(0),
        len: usize = 0,

        pub fn from(source: []const u8) Self {
            var self: Self = .{};
            self.set(source);
            return self;
        }

        pub fn set(self: *Self, source: []const u8) void {
            const n = @min(source.len, capacity);
            @memcpy(self.buffer[0..n], source[0..n]);
            self.len = n;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buffer[0..self.len];
        }
    };
}

pub const Title = Text(souls.max_title_bytes);
pub const Subtitle = Text(max_subtitle_bytes);

/// Shortest and longest screen a user can dial in. The floor keeps a
/// screen readable; the ceiling keeps a misconfigured one from parking
/// a click-through window over the desktop forever.
pub const min_duration_ms: u32 = 600;
pub const max_duration_ms: u32 = 10_000;

pub const EventSettings = struct {
    enabled: bool,
    style: souls.Style,
    sound: souls.Sound,
    /// 0..100; scaled to the player's 0..1 at playback.
    volume: u8,
    /// Total time on screen, fades included.
    duration_ms: u32,
    title: Title,
    subtitle: Subtitle,

    pub fn fromCatalog(event: souls.Event) EventSettings {
        return .{
            .enabled = event.default_enabled,
            .style = event.default_style,
            .sound = event.default_sound,
            .volume = 70,
            .duration_ms = 2600,
            .title = Title.from(event.default_title),
            .subtitle = Subtitle.from(event.default_subtitle),
        };
    }
};

pub const Config = struct {
    events: [souls.event_count]EventSettings,

    pub fn default() Config {
        var config: Config = .{ .events = undefined };
        for (souls.events, 0..) |event, index| {
            config.events[index] = EventSettings.fromCatalog(event);
        }
        return config;
    }

    /// Parse over the compiled defaults: anything the text does not say
    /// keeps its default, so a truncated or partially-written file
    /// degrades instead of failing.
    pub fn parse(text: []const u8) Config {
        var config = Config.default();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (!std.mem.startsWith(u8, line, "e ")) continue;
            parseEventLine(&config, line[2..]);
        }
        return config;
    }

    fn parseEventLine(config: *Config, body: []const u8) void {
        // The title/subtitle tail can hold spaces, so split it off
        // before tokenizing the fixed numeric head.
        var head = body;
        var tail: []const u8 = "";
        if (fieldEnd(body, 6)) |cut| {
            head = body[0..cut];
            tail = std.mem.trimStart(u8, body[cut..], " ");
        }

        var fields = std.mem.tokenizeScalar(u8, head, ' ');
        const key = fields.next() orelse return;
        const index = souls.indexOfKey(key) orelse return;
        const entry = &config.events[index];

        entry.enabled = parseU32(fields.next(), @intFromBool(entry.enabled)) != 0;
        entry.style = souls.Style.fromIndex(clampU8(parseU32(fields.next(), @intFromEnum(entry.style))));
        entry.sound = souls.Sound.fromIndex(clampU8(parseU32(fields.next(), @intFromEnum(entry.sound))));
        entry.volume = @min(100, clampU8(parseU32(fields.next(), entry.volume)));
        entry.duration_ms = std.math.clamp(
            parseU32(fields.next(), entry.duration_ms),
            min_duration_ms,
            max_duration_ms,
        );

        if (tail.len == 0) return;
        const split = std.mem.indexOfScalar(u8, tail, '|') orelse tail.len;
        entry.title.set(std.mem.trim(u8, tail[0..split], " "));
        if (split < tail.len) {
            entry.subtitle.set(std.mem.trim(u8, tail[split + 1 ..], " "));
        } else {
            entry.subtitle.set("");
        }
    }

    /// Byte offset just past the `count`-th space-delimited field, or
    /// null when the line has fewer fields than that.
    fn fieldEnd(body: []const u8, count: usize) ?usize {
        var seen: usize = 0;
        var at: usize = 0;
        while (seen < count) : (seen += 1) {
            while (at < body.len and body[at] == ' ') at += 1;
            if (at >= body.len) return null;
            while (at < body.len and body[at] != ' ') at += 1;
        }
        return at;
    }

    fn parseU32(field: ?[]const u8, fallback: u32) u32 {
        const text = field orelse return fallback;
        return std.fmt.parseInt(u32, text, 10) catch fallback;
    }

    fn clampU8(value: u32) u8 {
        return @intCast(@min(value, 255));
    }

    pub fn write(self: *const Config, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("claude-souls {d}\n", .{format_version});
        for (souls.events, 0..) |event, index| {
            const entry = &self.events[index];
            try writer.print("e {s} {d} {d} {d} {d} {d} {s}|{s}\n", .{
                event.key,
                @intFromBool(entry.enabled),
                @intFromEnum(entry.style),
                @intFromEnum(entry.sound),
                entry.volume,
                entry.duration_ms,
                entry.title.slice(),
                entry.subtitle.slice(),
            });
        }
    }

    /// Serialize into a caller-owned buffer — the shape `update` needs
    /// for `fx.writeFile`.
    pub fn serialize(self: *const Config, buffer: []u8) []const u8 {
        var writer = std.Io.Writer.fixed(buffer);
        self.write(&writer) catch return "";
        return writer.buffered();
    }
};

test "defaults round-trip through the codec" {
    var config = Config.default();
    config.events[0].enabled = !config.events[0].enabled;
    config.events[0].volume = 33;
    config.events[0].duration_ms = 4321;
    config.events[0].title.set("BONFIRE UNLIT");
    config.events[0].subtitle.set("the flame gutters");

    var buffer: [max_config_bytes]u8 = undefined;
    const text = config.serialize(&buffer);
    const parsed = Config.parse(text);

    try std.testing.expectEqual(config.events[0].enabled, parsed.events[0].enabled);
    try std.testing.expectEqual(@as(u8, 33), parsed.events[0].volume);
    try std.testing.expectEqual(@as(u32, 4321), parsed.events[0].duration_ms);
    try std.testing.expectEqualStrings("BONFIRE UNLIT", parsed.events[0].title.slice());
    try std.testing.expectEqualStrings("the flame gutters", parsed.events[0].subtitle.slice());
}

test "unknown keys and junk lines leave the defaults standing" {
    const parsed = Config.parse(
        \\claude-souls 1
        \\# a comment
        \\e not_a_real_event 1 0 0 50 1000 NOPE|
        \\garbage
        \\e session_start 0 2 3 12 999999 EMBER FADES|to ash
    );
    try std.testing.expectEqual(false, parsed.events[0].enabled);
    try std.testing.expectEqual(souls.Style.victory, parsed.events[0].style);
    try std.testing.expectEqual(souls.Sound.chime, parsed.events[0].sound);
    try std.testing.expectEqual(@as(u8, 12), parsed.events[0].volume);
    // Out-of-range durations clamp rather than sticking.
    try std.testing.expectEqual(max_duration_ms, parsed.events[0].duration_ms);
    try std.testing.expectEqualStrings("EMBER FADES", parsed.events[0].title.slice());
    try std.testing.expectEqualStrings("to ash", parsed.events[0].subtitle.slice());
    // A later event the text never mentioned keeps its catalog default.
    try std.testing.expectEqualStrings(
        souls.events[1].default_title,
        parsed.events[1].title.slice(),
    );
}

test "a title with no subtitle separator still parses" {
    const parsed = Config.parse("e turn_complete 1 2 3 70 2000 GREAT SOUL EMBRACED");
    try std.testing.expectEqualStrings("GREAT SOUL EMBRACED", parsed.events[1].title.slice());
    try std.testing.expectEqualStrings("", parsed.events[1].subtitle.slice());
}
