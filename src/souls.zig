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
            .death => .{ 0x8B, 0x14, 0x14 },
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
};

/// The bundled sound bank. Files live in `assets/sounds/<file>` and are
/// resolved relative to the app bundle at runtime.
pub const Sound = enum(u8) {
    none,
    gong,
    choir,
    chime,
    ember,
    thud,

    pub const count = @typeInfo(Sound).@"enum".fields.len;

    pub fn label(self: Sound) []const u8 {
        return switch (self) {
            .none => "Silent",
            .gong => "Gong",
            .choir => "Choir",
            .chime => "Chime",
            .ember => "Ember",
            .thud => "Thud",
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
        };
    }

    pub fn fromIndex(index: u8) Sound {
        if (index >= count) return .none;
        return @enumFromInt(index);
    }
};

/// One row of the catalog: a Claude Code hook occasion plus the screen
/// it summons.
pub const Event = struct {
    /// Stable id. Written to the config file, passed to `claude-souls
    /// fire <key>`, and used as the hook's own identity — never change
    /// one without a migration.
    key: []const u8,
    /// Human name in the settings list.
    label: []const u8,
    /// What actually triggers it, in the user's words.
    blurb: []const u8,
    /// The Claude Code hook event this subscribes to.
    hook_event: []const u8,
    /// Tool matcher for tool-scoped events; "" for events with no
    /// matcher axis.
    matcher: []const u8 = "",
    /// Permission-rule narrowing (`"if"`), so "PR created" can mean the
    /// one Bash call that creates a PR rather than every Bash call.
    condition: []const u8 = "",

    default_title: []const u8,
    default_subtitle: []const u8 = "",
    default_style: Style,
    default_sound: Sound,
    default_enabled: bool,
};

pub const events = [_]Event{
    .{
        .key = "session_start",
        .label = "Session started",
        .blurb = "A Claude Code session begins or resumes.",
        .hook_event = "SessionStart",
        .default_title = "BONFIRE LIT",
        .default_style = .bonfire,
        .default_sound = .ember,
        .default_enabled = true,
    },
    .{
        .key = "turn_complete",
        .label = "Turn completed",
        .blurb = "Claude finishes responding.",
        .hook_event = "Stop",
        .default_title = "VICTORY ACHIEVED",
        .default_style = .victory,
        .default_sound = .choir,
        .default_enabled = true,
    },
    .{
        .key = "question_asked",
        .label = "Question asked",
        .blurb = "Claude Code raises a notification — a permission prompt or an idle nudge.",
        .hook_event = "Notification",
        .default_title = "THE ASHEN ONE BECKONS",
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
        .default_title = "YOU DIED",
        .default_style = .death,
        .default_sound = .gong,
        .default_enabled = true,
    },
    .{
        .key = "pr_created",
        .label = "PR created",
        .blurb = "A `gh pr create` Bash call succeeds.",
        .hook_event = "PostToolUse",
        .matcher = "Bash",
        .condition = "Bash(gh pr create:*)",
        .default_title = "SUMMON SIGN CAST",
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
        .default_title = "BONFIRE KINDLED",
        .default_style = .bonfire,
        .default_sound = .ember,
        .default_enabled = true,
    },
    .{
        .key = "permission_denied",
        .label = "Permission denied",
        .blurb = "A tool call is refused.",
        .hook_event = "PermissionDenied",
        .default_title = "COVENANT BROKEN",
        .default_style = .covenant,
        .default_sound = .thud,
        .default_enabled = false,
    },
    .{
        .key = "subagent_done",
        .label = "Subagent finished",
        .blurb = "A spawned subagent returns.",
        .hook_event = "SubagentStop",
        .default_title = "PHANTOM RETURNS",
        .default_style = .soul,
        .default_sound = .chime,
        .default_enabled = false,
    },
    .{
        .key = "compaction",
        .label = "Context compacted",
        .blurb = "The conversation is about to be compacted.",
        .hook_event = "PreCompact",
        .default_title = "HOLLOWING",
        .default_style = .hollow,
        .default_sound = .thud,
        .default_enabled = false,
    },
    .{
        .key = "session_end",
        .label = "Session ended",
        .blurb = "The session terminates.",
        .hook_event = "SessionEnd",
        .default_title = "ASHEN ONE DEPARTS",
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
