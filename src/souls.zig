//! The catalog: which Claude Code moments deserve a Dark Souls screen,
//! what each one says by default, and how it looks and sounds.
//!
//! Everything here is comptime data. The config file (see `config.zig`)
//! only ever stores per-event OVERRIDES keyed by `Event.key`, so adding
//! an event to this table gives existing installs a sensible default
//! instead of a parse error.

const std = @import("std");

/// The visual register of a screen. Each style is a colour and a mood,
/// not a layout — every screen draws the same band, only inked
/// differently.
pub const Style = enum(u8) {
    death,
    bonfire,
    victory,
    soul,
    hollow,
    covenant,

    pub const count = @typeInfo(Style).@"enum".fields.len;

    pub fn label(self: Style) []const u8 {
        return switch (self) {
            .death => "Death",
            .bonfire => "Bonfire",
            .victory => "Victory",
            .soul => "Soul",
            .hollow => "Hollow",
            .covenant => "Covenant",
        };
    }

    /// sRGB ink for the headline. Deliberately desaturated: these draw
    /// over whatever the user is actually looking at.
    pub fn ink(self: Style) [3]u8 {
        return switch (self) {
            .death => .{ 0x82, 0x10, 0x1D },
            .bonfire => .{ 0xE0, 0x8A, 0x3C },
            .victory => .{ 0xC9, 0xA2, 0x27 },
            .soul => .{ 0x8F, 0xB4, 0xD0 },
            .hollow => .{ 0x9A, 0x94, 0x86 },
            .covenant => .{ 0xA1, 0x7A, 0xC8 },
        };
    }

    pub fn fromIndex(index: u8) Style {
        if (index >= count) return .death;
        return @enumFromInt(index);
    }

    /// What someone types after `--style`. Case-insensitive against the
    /// enum's own field names, so the CLI can never drift from the
    /// picker in the settings window.
    pub fn fromName(name: []const u8) ?Style {
        return enumFromName(Style, name);
    }
};

/// The bundled sound bank. Files live in `assets/sounds/<file>` and are
/// resolved relative to the app bundle at runtime.
///
/// The order is the cycle order in the settings window, and the numbers
/// are written to the config file — append, never reorder.
pub const Sound = enum(u8) {
    none,
    gong,
    choir,
    chime,
    ember,
    thud,
    you_died,

    pub const count = @typeInfo(Sound).@"enum".fields.len;

    pub fn label(self: Sound) []const u8 {
        return switch (self) {
            .none => "Silent",
            .gong => "Gong",
            .choir => "Choir",
            .chime => "Chime",
            .ember => "Ember",
            .thud => "Thud",
            .you_died => "You Died",
        };
    }

    /// Bundle-relative path, or "" for `.none`.
    pub fn path(self: Sound) []const u8 {
        return switch (self) {
            .none => "",
            .gong => "assets/sounds/gong.mp3",
            .choir => "assets/sounds/choir.mp3",
            .chime => "assets/sounds/chime.mp3",
            .ember => "assets/sounds/ember.mp3",
            .thud => "assets/sounds/thud.mp3",
            .you_died => "assets/sounds/you-died.mp3",
        };
    }

    pub fn fromIndex(index: u8) Sound {
        if (index >= count) return .none;
        return @enumFromInt(index);
    }

    /// What someone types after `--sound`. "you-died" and "you_died"
    /// both land, and "silent" is accepted for `.none` because that is
    /// what the settings window calls it.
    pub fn fromName(name: []const u8) ?Sound {
        if (std.ascii.eqlIgnoreCase(name, "silent")) return .none;
        return enumFromName(Sound, name);
    }
};

/// Match `name` against an enum's field names, case-insensitively, with
/// '-' and '_' treated as the same character. Shared by the two pickers
/// above so neither can grow a hand-written table that falls behind.
fn enumFromName(comptime E: type, name: []const u8) ?E {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (looseEql(field.name, name)) return @enumFromInt(field.value);
    }
    return null;
}

fn looseEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        const l = if (left == '-') '_' else std.ascii.toLower(left);
        const r = if (right == '-') '_' else std.ascii.toLower(right);
        if (l != r) return false;
    }
    return true;
}

/// One row of the catalog: a Claude Code hook occasion plus the screen
/// it summons.
pub const Event = struct {
    /// Stable id. Written to the config file, passed to `ai-souls
    /// fire <key>`, and used as the hook's own identity — never change
    /// one without a migration.
    key: []const u8,
    /// Human name in the settings list.
    label: []const u8,
    /// What actually triggers it, in the user's words.
    blurb: []const u8,
    /// The Claude Code hook event this subscribes to.
    hook_event: []const u8,
    /// The hook group's `matcher`; "" for events with no matcher axis.
    /// What it is matched AGAINST depends on the hook event — a tool
    /// name for the `*ToolUse*` family, an `error_type` for
    /// `StopFailure` — so a pipe-separated list is legal here.
    matcher: []const u8 = "",
    /// Short human rendering of `matcher` for the settings pane, for
    /// the events whose real matcher is a long alternation.
    matcher_label: []const u8 = "",
    /// Permission-rule narrowing (`"if"`), so "PR created" can mean the
    /// one Bash call that creates a PR rather than every Bash call.
    condition: []const u8 = "",

    /// Shortest gap between two of THIS event's screens, in
    /// milliseconds.
    ///
    /// Zero is not "no throttle": no screen ever draws over one that is
    /// still up, whatever the catalog says. This is the extra quiet on
    /// top of that, for the events that arrive in bursts — twenty
    /// failures out of one retry loop should cost one screen, not
    /// twenty. See `throttle.zig`.
    throttle_ms: u32 = 0,

    /// What the headline says out of the box.
    ///
    /// Deliberately just the event's own name. The Souls wording is the
    /// fun part and it is also personal, so the app ships neutral and
    /// lets people write their own — "YOU DIED" is a much better joke
    /// when you chose it.
    default_title: []const u8,
    default_subtitle: []const u8 = "",
    default_style: Style,
    default_sound: Sound,
    default_enabled: bool,
};

/// The matcher covering every `StopFailure` error type that is not the
/// API telling us to slow down — auth, billing, a bad request, a server
/// fault. Listed rather than wildcarded so a new error type Claude Code
/// invents later does not silently start firing a screen.
const api_error_types =
    "authentication_failed|oauth_org_not_allowed|billing_error|" ++
    "invalid_request|model_not_found|server_error|max_output_tokens|unknown";

/// `SessionStart` fires for five different reasons and says which in its
/// `source`, which is also what its matcher is matched against. They are
/// five separate rows rather than one, because "I opened a terminal" and
/// "the context just got compacted out from under me" are not the same
/// news — and the second one is the only one worth a screen by default.
pub const events = [_]Event{
    .{
        .key = "session_start",
        .label = "Session started",
        .blurb = "A Claude Code session starts fresh.",
        .hook_event = "SessionStart",
        .matcher = "startup",
        .default_title = "Session started",
        .default_style = .bonfire,
        .default_sound = .ember,
        .default_enabled = false,
    },
    .{
        .key = "session_resumed",
        .label = "Session resumed",
        .blurb = "An earlier session is picked back up.",
        .hook_event = "SessionStart",
        .matcher = "resume",
        .default_title = "Session resumed",
        .default_style = .bonfire,
        .default_sound = .ember,
        .default_enabled = false,
    },
    .{
        .key = "session_cleared",
        .label = "Session cleared",
        .blurb = "The conversation is wiped with `/clear`.",
        .hook_event = "SessionStart",
        .matcher = "clear",
        .default_title = "Session cleared",
        .default_style = .hollow,
        .default_sound = .thud,
        .default_enabled = false,
    },
    .{
        .key = "session_forked",
        .label = "Session forked",
        .blurb = "A session is branched into a new one.",
        .hook_event = "SessionStart",
        .matcher = "fork",
        .default_title = "Session forked",
        .default_style = .soul,
        .default_sound = .chime,
        .default_enabled = false,
    },
    .{
        .key = "compaction",
        .label = "Compacting context",
        .blurb = "The conversation is about to be compacted.",
        .hook_event = "PreCompact",
        .default_title = "Compacting context",
        .default_style = .hollow,
        .default_sound = .thud,
        .default_enabled = false,
    },
    .{
        .key = "compaction_done",
        .label = "Context compacted",
        // The one screen of this family that earns being on: compaction
        // happens without asking, takes a while, and the session that
        // comes back has forgotten things. Worth knowing it happened.
        .blurb = "Compaction finishes and the session picks up again.",
        .hook_event = "SessionStart",
        .matcher = "compact",
        .default_title = "Context compacted",
        .default_style = .bonfire,
        .default_sound = .ember,
        .default_enabled = true,
    },
    .{
        .key = "turn_complete",
        .label = "Turn completed",
        .blurb = "Claude finishes responding.",
        .hook_event = "Stop",
        .default_title = "Turn completed",
        .default_style = .victory,
        .default_sound = .choir,
        .default_enabled = true,
    },
    .{
        .key = "question_asked",
        .label = "Question asked",
        .blurb = "Claude Code raises a notification — a permission prompt or an idle nudge.",
        .hook_event = "Notification",
        // A run that needs three permissions in a row asks for them one
        // after another, and the idle nudge repeats on its own.
        .throttle_ms = 10_000,
        .default_title = "Question asked",
        .default_style = .soul,
        .default_sound = .chime,
        .default_enabled = true,
    },
    .{
        .key = "tool_failed",
        .label = "Tool call failed",
        .blurb = "Any tool call comes back a failure.",
        .hook_event = "PostToolUseFailure",
        .matcher = "*",
        // The burstiest event in the catalog by a distance: an agent
        // that has got something wrong tends to get it wrong repeatedly
        // and quickly, and the twentieth screen says nothing the first
        // one did not.
        .throttle_ms = 15_000,
        .default_title = "Tool call failed",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = true,
    },
    .{
        .key = "rate_limited",
        .label = "Rate limited",
        .blurb = "The turn ends because the API rate-limited us or is overloaded.",
        .hook_event = "StopFailure",
        .matcher = "rate_limit|overloaded",
        .matcher_label = "rate limit / overloaded",
        // A rate limit lasts minutes and is retried into the whole
        // time. It is one piece of news.
        .throttle_ms = 60_000,
        .default_title = "Rate limited",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = true,
    },
    .{
        .key = "api_error",
        .label = "API error",
        .blurb = "The turn ends on an API error — authentication, billing, or a server fault.",
        .hook_event = "StopFailure",
        .matcher = api_error_types,
        .matcher_label = "any non-rate-limit API error",
        .throttle_ms = 30_000,
        .default_title = "API error",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = true,
    },
    .{
        .key = "pr_created",
        .label = "PR created",
        .blurb = "A `gh pr create` Bash call succeeds.",
        .hook_event = "PostToolUse",
        .matcher = "Bash",
        .condition = "Bash(gh pr create:*)",
        .default_title = "PR created",
        .default_style = .soul,
        .default_sound = .choir,
        .default_enabled = true,
    },
    .{
        .key = "commit_made",
        .label = "Commit made",
        .blurb = "A `git commit` Bash call succeeds.",
        .hook_event = "PostToolUse",
        .matcher = "Bash",
        .condition = "Bash(git commit:*)",
        .default_title = "Commit made",
        .default_style = .bonfire,
        .default_sound = .ember,
        .default_enabled = true,
    },
    .{
        .key = "permission_denied",
        .label = "Permission denied",
        .blurb = "A tool call is refused.",
        .hook_event = "PermissionDenied",
        .throttle_ms = 10_000,
        .default_title = "Permission denied",
        .default_style = .covenant,
        .default_sound = .thud,
        .default_enabled = false,
    },
    .{
        .key = "subagent_done",
        .label = "Subagent finished",
        .blurb = "A spawned subagent returns.",
        .hook_event = "SubagentStop",
        // A fan-out of ten agents lands all at once.
        .throttle_ms = 10_000,
        .default_title = "Subagent finished",
        .default_style = .soul,
        .default_sound = .chime,
        .default_enabled = false,
    },
    .{
        .key = "session_end",
        .label = "Session ended",
        .blurb = "The session terminates.",
        .hook_event = "SessionEnd",
        .default_title = "Session ended",
        .default_style = .hollow,
        .default_sound = .gong,
        .default_enabled = false,
    },
};

pub const event_count = events.len;

/// Longest custom headline the config and the model will carry. Screens
/// are meant to be shouted, not read.
pub const max_title_bytes = 48;

pub fn indexOfKey(key: []const u8) ?usize {
    for (events, 0..) |event, index| {
        if (std.mem.eql(u8, event.key, key)) return index;
    }
    return null;
}

test "event keys are unique and fit the config line format" {
    for (events, 0..) |event, index| {
        try std.testing.expectEqual(index, indexOfKey(event.key).?);
        try std.testing.expect(event.key.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, event.key, ' ') == null);
        try std.testing.expect(event.default_title.len <= max_title_bytes);
    }
}

test "the shipped headline is just the event's name" {
    // The flavour is the user's to write, so nothing in the catalog
    // gets to be clever on their behalf.
    for (events) |event| {
        try std.testing.expectEqualStrings(event.label, event.default_title);
        try std.testing.expectEqualStrings("", event.default_subtitle);
    }
}

test "every sound but silence names a file, and names a different one" {
    var seen: [Sound.count][]const u8 = undefined;
    for (0..Sound.count) |index| {
        const sound = Sound.fromIndex(@intCast(index));
        try std.testing.expect(sound.label().len > 0);
        if (sound == .none) {
            try std.testing.expectEqualStrings("", sound.path());
            seen[index] = "";
            continue;
        }
        const path = sound.path();
        try std.testing.expect(std.mem.startsWith(u8, path, "assets/sounds/"));
        try std.testing.expect(std.mem.endsWith(u8, path, ".mp3"));
        for (seen[0..index]) |earlier| {
            try std.testing.expect(!std.mem.eql(u8, earlier, path));
        }
        seen[index] = path;
    }
}

test "styles and sounds can be named on the command line" {
    try std.testing.expectEqual(Style.death, Style.fromName("death").?);
    try std.testing.expectEqual(Style.covenant, Style.fromName("COVENANT").?);
    try std.testing.expect(Style.fromName("puce") == null);

    try std.testing.expectEqual(Sound.you_died, Sound.fromName("you-died").?);
    try std.testing.expectEqual(Sound.you_died, Sound.fromName("you_died").?);
    try std.testing.expectEqual(Sound.none, Sound.fromName("silent").?);
    try std.testing.expectEqual(Sound.none, Sound.fromName("none").?);
    try std.testing.expect(Sound.fromName("kazoo") == null);

    // Every name the settings window shows has to be typeable.
    for (0..Sound.count) |index| {
        const sound = Sound.fromIndex(@intCast(index));
        try std.testing.expectEqual(sound, Sound.fromName(@tagName(sound)).?);
    }
    for (0..Style.count) |index| {
        const style = Style.fromIndex(@intCast(index));
        try std.testing.expectEqual(style, Style.fromName(@tagName(style)).?);
    }
}

test "a death screen always sounds like death" {
    // The rule, not one example of it: the red screen and that sound
    // are one thing, so a new `.death` row cannot ship with anything
    // else under it. Someone who wants the gong can still pick it.
    var seen_any = false;
    for (events) |event| {
        if (event.default_style != .death) continue;
        seen_any = true;
        try std.testing.expectEqual(Sound.you_died, event.default_sound);
    }
    try std.testing.expect(seen_any);
}

test "every way a session can start is its own row" {
    // A bare `SessionStart` with no matcher would fire on all five
    // sources at once, which is what these rows replaced.
    var sources: usize = 0;
    for (events) |event| {
        if (!std.mem.eql(u8, event.hook_event, "SessionStart")) continue;
        sources += 1;
        try std.testing.expect(event.matcher.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, event.matcher, '|') == null);
        for (events) |other| {
            if (std.mem.eql(u8, other.key, event.key)) continue;
            if (!std.mem.eql(u8, other.hook_event, "SessionStart")) continue;
            try std.testing.expect(!std.mem.eql(u8, other.matcher, event.matcher));
        }
    }
    try std.testing.expectEqual(@as(usize, 5), sources);

    // Only the one that tells you something you could not have seen
    // coming is armed out of the box.
    for (events) |event| {
        if (!std.mem.eql(u8, event.hook_event, "SessionStart")) continue;
        const armed = std.mem.eql(u8, event.key, "compaction_done");
        try std.testing.expectEqual(armed, event.default_enabled);
    }
}

test "the burst-prone events are throttled and the rest are not" {
    for (events) |event| {
        const throttled = event.throttle_ms > 0;
        const bursty =
            std.mem.eql(u8, event.key, "tool_failed") or
            std.mem.eql(u8, event.key, "rate_limited") or
            std.mem.eql(u8, event.key, "api_error") or
            std.mem.eql(u8, event.key, "question_asked") or
            std.mem.eql(u8, event.key, "permission_denied") or
            std.mem.eql(u8, event.key, "subagent_done");
        try std.testing.expectEqual(bursty, throttled);
    }
}

test "the sound numbering on disk never moves" {
    // These integers are what `config.txt` stores. Reordering the enum
    // would silently re-point every user's saved choices.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Sound.none));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Sound.gong));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(Sound.you_died));
}

test "a matcher that is an alternation carries a readable label" {
    for (events) |event| {
        if (std.mem.indexOfScalar(u8, event.matcher, '|') == null) continue;
        try std.testing.expect(event.matcher_label.len > 0);
    }
}
