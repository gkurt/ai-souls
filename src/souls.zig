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
    /// enum's own field names, so the flag can never drift from the
    /// enum.
    pub fn fromName(name: []const u8) ?Style {
        return enumFromName(Style, name);
    }
};

/// The bundled sound bank. Files live in `assets/sounds/<file>` and are
/// resolved relative to the app bundle at runtime.
///
/// The numbers are written to the config file — append, never reorder.
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

    /// How long the file actually runs, rounded up to the next tenth of
    /// a second.
    ///
    /// Load-bearing, not trivia: the overlay stops audio when it ends,
    /// so a screen shorter than its own sting chops it off mid-ring —
    /// which is why a screen is sized against this. Measured from
    /// `assets/sounds/*.mp3`; `tools/make-sounds.mjs` renders them and
    /// is where the lengths come from. Change a file, change this.
    pub fn durationMs(self: Sound) u32 {
        return switch (self) {
            .none => 0,
            .gong => 3700,
            .choir => 3300,
            .chime => 1700,
            .ember => 2000,
            .thud => 1000,
            .you_died => 7200,
        };
    }

    pub fn fromIndex(index: u8) Sound {
        if (index >= count) return .none;
        return @enumFromInt(index);
    }

    /// What someone types after `--sound`. "you-died" and "you_died"
    /// both land, and "silent" is accepted for `.none` because that is
    /// what its label calls it.
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
    /// Human name in the `status` listing.
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
    /// Short human rendering of `matcher` for the `status` listing, for
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

    /// Which screen wins when both want the glass.
    ///
    /// Higher outranks lower. A screen that outranks the one currently
    /// up takes it down and replaces it; anything that does not is
    /// dropped, because two banners at once is not an option. Equal
    /// ranks do not displace each other, so the second permission
    /// prompt of a run does not interrupt the first one's screen.
    ///
    /// The numbers mean nothing on their own — only their order does.
    /// Roughly: the thing you were working towards, then news you have
    /// to act on, then work landing, then progress you were watching
    /// happen anyway. No default, so a new row has to decide where it
    /// sits rather than silently arriving at the bottom.
    priority: u8,

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

/// A screen someone typed out by hand outranks the whole catalog. It is
/// an instruction, not a notification: `ai-souls "YOU DIED"` is never
/// held back and always takes the glass.
pub const by_hand_priority: u8 = 255;

/// `SessionStart` fires for five different reasons and says which in its
/// `source`, which is also what its matcher is matched against. They are
/// five separate rows rather than one, because "I opened a terminal" and
/// "the context just got compacted out from under me" are not the same
/// news — and the second one is the only one worth a screen by default.
///
/// Every row ships as the Death screen. Not because every event is a
/// disaster, but because YOU DIED in that red serif is the one screen
/// the game is actually known for, and the other five styles are
/// educated guesses at what a bonfire or a covenant banner should look
/// like. They are all still there to pick — none of them becomes a
/// default until it has been checked against the real thing.
pub const events = [_]Event{
    .{
        .key = "session_start",
        .label = "Session started",
        .blurb = "A Claude Code session starts fresh.",
        .hook_event = "SessionStart",
        .matcher = "startup",
        // You are the one who opened the terminal. Bottom of the pile:
        // anything else that turns up in the same breath is news, and
        // this is not.
        .priority = 10,
        .default_title = "Session started",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = false,
    },
    .{
        .key = "session_resumed",
        .label = "Session resumed",
        .blurb = "An earlier session is picked back up.",
        .hook_event = "SessionStart",
        .matcher = "resume",
        .priority = 10,
        .default_title = "Session resumed",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = false,
    },
    .{
        .key = "session_cleared",
        .label = "Session cleared",
        .blurb = "The conversation is wiped with `/clear`.",
        .hook_event = "SessionStart",
        .matcher = "clear",
        .priority = 10,
        .default_title = "Session cleared",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = false,
    },
    .{
        .key = "session_forked",
        .label = "Session forked",
        .blurb = "A session is branched into a new one.",
        .hook_event = "SessionStart",
        .matcher = "fork",
        .priority = 10,
        .default_title = "Session forked",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = false,
    },
    .{
        .key = "compaction",
        .label = "Compacting context",
        .blurb = "The conversation is about to be compacted.",
        .hook_event = "PreCompact",
        // Below the screen that says it finished, so a compaction that
        // runs quickly does not spend its one banner on the start of it.
        .priority = 35,
        .default_title = "Compacting context",
        .default_style = .death,
        .default_sound = .you_died,
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
        .priority = 40,
        .default_title = "Context compacted",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = true,
    },
    .{
        .key = "turn_complete",
        .label = "Turn completed",
        .blurb = "Claude finishes responding.",
        .hook_event = "Stop",
        // Fires at the end of every single turn, and `Stop` lands a
        // second or two after the last tool call — so it is the screen
        // most likely to be standing in front of something better.
        // Above only the five you caused yourself.
        .priority = 20,
        .default_title = "Turn completed",
        .default_style = .death,
        .default_sound = .you_died,
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
        // The only event where a missed screen costs wall-clock: the
        // run is stopped until you look at it.
        .priority = 80,
        .default_title = "Question asked",
        .default_style = .death,
        .default_sound = .you_died,
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
        // one did not. Wide, because the screen it draws is itself
        // seven seconds long — half a shorter window.
        .throttle_ms = 30_000,
        // Loud but usually not yours to deal with — the agent tries
        // something else and carries on. Under the errors that end the
        // turn outright.
        .priority = 50,
        .default_title = "Tool call failed",
        .default_style = .death,
        .default_sound = .you_died,
        // Off, for the same reason it is ranked and throttled the way it
        // is: a failed tool call is usually a step in a working run, not
        // news. Even one screen per thirty seconds is a screen for
        // something the agent already handled.
        .default_enabled = false,
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
        // Under `api_error`: there is nothing to do about a rate limit
        // but wait, where an auth or billing failure needs you.
        .priority = 65,
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
        .priority = 70,
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
        // The top of the catalog. A PR is the thing the whole session
        // was for, and it is the one screen that should never lose —
        // least of all to the commit that came just before it.
        .priority = 90,
        .default_title = "PR created",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = true,
    },
    .{
        .key = "commit_made",
        .label = "Commit made",
        .blurb = "A `git commit` Bash call succeeds.",
        .hook_event = "PostToolUse",
        .matcher = "Bash",
        .condition = "Bash(git commit:*)",
        // Work landing, which beats work merely progressing.
        .priority = 60,
        .default_title = "Commit made",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = true,
    },
    .{
        .key = "permission_denied",
        .label = "Permission denied",
        .blurb = "A tool call is refused.",
        .hook_event = "PermissionDenied",
        .throttle_ms = 10_000,
        // Level with the question that usually precedes it: the run has
        // stopped and it is waiting on you either way.
        .priority = 80,
        .default_title = "Permission denied",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = false,
    },
    .{
        .key = "subagent_done",
        .label = "Subagent finished",
        .blurb = "A spawned subagent returns.",
        .hook_event = "SubagentStop",
        // A fan-out of ten agents lands all at once.
        .throttle_ms = 10_000,
        .priority = 30,
        .default_title = "Subagent finished",
        .default_style = .death,
        .default_sound = .you_died,
        .default_enabled = false,
    },
    .{
        .key = "session_end",
        .label = "Session ended",
        .blurb = "The session terminates.",
        .hook_event = "SessionEnd",
        .priority = 10,
        .default_title = "Session ended",
        .default_style = .death,
        .default_sound = .you_died,
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

    // Every label the CLI prints has to be typeable back.
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

test "what is armed out of the box is news you could not have seen coming" {
    // A default that fires is a screen someone did not ask for, so each
    // one has to earn it. The line this draws: something happened that
    // you would want to know about and could not have predicted. A
    // failed tool call is not that — the agent tries something else and
    // carries on — which is why it ships off despite being loud.
    for (events) |event| {
        const armed = std.mem.eql(u8, event.key, "pr_created") or
            std.mem.eql(u8, event.key, "commit_made") or
            std.mem.eql(u8, event.key, "turn_complete") or
            std.mem.eql(u8, event.key, "question_asked") or
            std.mem.eql(u8, event.key, "api_error") or
            std.mem.eql(u8, event.key, "rate_limited") or
            std.mem.eql(u8, event.key, "compaction_done");
        try std.testing.expectEqual(armed, event.default_enabled);
    }
}

test "every screen ships as the one screen the game is known for" {
    // The other five styles are guesses until someone has checked them
    // against the real thing, so none of them gets to be a default.
    for (events) |event| {
        try std.testing.expectEqual(Style.death, event.default_style);
        try std.testing.expectEqual(Sound.you_died, event.default_sound);
    }
}

test "the catalog ranks the news above the noise" {
    const rank = struct {
        fn of(key: []const u8) u8 {
            return events[indexOfKey(key).?].priority;
        }
    }.of;

    // The one the ranking exists for: a commit and the PR it leads to
    // arrive seconds apart, and the PR is what the session was for.
    try std.testing.expect(rank("commit_made") < rank("pr_created"));
    // And nothing in the catalog outranks it.
    for (events) |event| {
        try std.testing.expect(event.priority <= rank("pr_created"));
    }

    // Blocked-and-waiting-on-you beats a failure the agent will retry
    // by itself, which beats a turn simply ending.
    try std.testing.expect(rank("tool_failed") < rank("api_error"));
    try std.testing.expect(rank("rate_limited") < rank("api_error"));
    try std.testing.expect(rank("tool_failed") < rank("question_asked"));
    try std.testing.expect(rank("turn_complete") < rank("tool_failed"));
    try std.testing.expect(rank("compaction") < rank("compaction_done"));

    // The five you caused yourself sit at the bottom, under the events
    // that tell you something you could not have known.
    for (events) |event| {
        if (!std.mem.eql(u8, event.hook_event, "SessionStart")) continue;
        if (std.mem.eql(u8, event.key, "compaction_done")) continue;
        try std.testing.expect(event.priority < rank("turn_complete"));
    }

    // A screen a person typed out is not in the running at all.
    for (events) |event| {
        try std.testing.expect(event.priority < by_hand_priority);
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
