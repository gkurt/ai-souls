//! The payload Claude Code writes to a hook's stdin, and the two
//! questions `fire` asks of it.
//!
//! The first is which Bash call a narrowed row is looking at.
//!
//! A hook entry carries an `if` rule — `Bash(git commit:*)` — so that
//! "Commit made" means the one Bash call that commits rather than every
//! Bash call in the session. Claude Code does honour it, but its Bash
//! matcher fails OPEN: when the shell text is something its static
//! analyser will not model, the rule matches everything instead of
//! nothing. Measured against 2.1.220, not guessed — `echo {alpha,beta}`
//! is enough, and so are a heredoc with an unquoted delimiter, a
//! redirect it cannot account for, and a parse it had to abandon. Both
//! `git commit` rows fired for that `echo`.
//!
//! So the rule is an optimisation and not a decision: it saves spawning
//! us for the Bash calls Claude Code does recognise, and this module is
//! the decision. `fire` reads the payload and asks whether the command
//! really runs what the row is about.
//!
//! The second is whether a turn that ended actually ended. `Stop` fires
//! when the main loop hands work to a subagent and parks to wait for it,
//! exactly as it fires when the work is done, so "Turn completed" was
//! drawing over turns that had done nothing of the kind. The payload
//! carries `background_tasks` — the session's running and pending
//! backgrounded work — and that is the difference between the two.
//! Measured against 2.1.220, where the list is the task registry
//! filtered to `running` and `pending` and each entry names its kind; it
//! is not in the published hook reference, so treat it as something to
//! re-check rather than something promised.
//!
//! Only the rows that ask something read stdin at all, and a payload we
//! cannot make sense of means the screen draws. The gate is here to
//! catch a hook that fired for the wrong Bash call, or a screen about to
//! announce the wrong thing, not to invent a new way to lose one.

const std = @import("std");
const builtin = @import("builtin");
const souls = @import("souls.zig");

/// Enough of the payload to hold whichever end of it is being read.
/// See `Keep`: a payload longer than this is rolled past rather than
/// truncated when the question is at the tail.
const max_bytes = 32 * 1024;

/// Which end of an over-long payload is worth keeping.
///
/// The two questions live at opposite ends. The command is in
/// `tool_input`, which Claude Code writes early, before the
/// `tool_response` that is as long as a `git log` output. The background
/// work is written last, after a `last_assistant_message` that is the
/// whole of Claude's final reply and just as unbounded. A row asks one
/// or the other, never both.
const Keep = enum { head, tail };

fn keepFor(event: souls.Event) ?Keep {
    if (event.yields_to_background) return .tail;
    if (event.requiredCommand().len > 0) return .head;
    return null;
}

/// The gate `fire` puts in front of a screen: read what Claude Code
/// piped us, and answer whether this row's screen is really about it.
///
/// A row that asks nothing of the payload never touches stdin.
pub fn allowsPayload(io: std.Io, event: souls.Event) bool {
    const keep = keepFor(event) orelse return true;
    var buffer: [max_bytes]u8 = undefined;
    return allows(event, readPayload(io, &buffer, keep));
}

/// The decision itself, over a payload already in hand.
///
/// Yes for every row that asks nothing, and yes for a payload with
/// nothing to answer with: see the module comment for why the unknown
/// cases draw.
pub fn allows(event: souls.Event, payload: []u8) bool {
    if (event.yields_to_background and subagentRunning(payload)) return false;

    const required = event.requiredCommand();
    if (required.len == 0) return true;
    const command = commandField(payload) orelse return true;
    return runsCommand(command, required);
}

/// Is the session parked on a subagent it launched?
///
/// `background_tasks` is written already filtered to the running and the
/// pending, so an entry being there at all means it is still going. Only
/// a subagent counts: a backgrounded shell command keeps running with
/// the turn genuinely over, where a subagent is work the loop stopped to
/// wait for.
///
/// Scoped to the list, the way `commandField` is scoped to `tool_input`.
/// The scope is belt and braces here — a `"type"` inside a task's
/// description arrives with its quotes escaped, so it can never match
/// the key — but it keeps the scan off the rest of the payload.
fn subagentRunning(payload: []const u8) bool {
    const key = "\"type\"";
    const start = std.mem.indexOf(u8, payload, "\"background_tasks\"") orelse return false;
    const end = std.mem.indexOfPos(u8, payload, start, "\"session_crons\"") orelse payload.len;
    const list = payload[start..end];

    var at: usize = 0;
    while (std.mem.indexOfPos(u8, list, at, key)) |found| {
        at = found + 1;
        var after = skipSpace(list, found + key.len);
        if (after >= list.len or list[after] != ':') continue;
        after = skipSpace(list, after + 1);
        if (std.mem.startsWith(u8, list[after..], "\"subagent\"")) return true;
    }
    return false;
}

/// Read what Claude Code piped us, as much of it as `buffer` holds.
///
/// A payload longer than the buffer is not an error. `keep` says which
/// end the caller's question lives at, and a `.tail` read rolls the
/// buffer forward instead of stopping, so the end of the payload always
/// survives however long the reply before it was.
fn readPayload(io: std.Io, buffer: []u8, keep: Keep) []u8 {
    // Under `zig build test` this process's stdin is the build runner's
    // own protocol stream — the same reason `cli.say` writes nothing
    // there. Reading it would wedge the run, so the tests drive `allows`
    // and the parsing directly and the gate sees an empty payload.
    if (builtin.is_test) return buffer[0..0];

    const stdin = std.Io.File.stdin();
    // A terminal would leave us blocked waiting for someone to type, and
    // a banner must never sit there. `ai-souls fire commit_made` run by
    // hand has no payload to check and is not trying to claim one.
    if (stdin.isTty(io) catch return buffer[0..0]) return buffer[0..0];

    var filled: usize = 0;
    while (true) {
        if (filled == buffer.len) {
            if (keep == .head) break;
            // Half of what we are holding goes and the rest slides down,
            // so a payload of any length still ends inside the buffer.
            const half = filled / 2;
            std.mem.copyForwards(u8, buffer[0 .. filled - half], buffer[half..filled]);
            filled -= half;
        }
        const chunk = stdin.readStreaming(io, &.{buffer[filled..]}) catch break;
        if (chunk == 0) break;
        filled += chunk;
    }
    return buffer[0..filled];
}

/// `tool_input.command` out of the payload, decoded in place.
///
/// Hand-rolled rather than parsed, for the same reason `config.zig` is:
/// this sits on the hook's critical path with no allocator, and one
/// string out of a shape we know is not worth a JSON reader. Scoped to
/// `tool_input`, so the tool's own output — which for `git log` is full
/// of other people's commit messages — can never be read as the command.
fn commandField(payload: []u8) ?[]const u8 {
    const key = "\"command\"";
    const start = std.mem.indexOf(u8, payload, "\"tool_input\"") orelse return null;
    const end = std.mem.indexOfPos(u8, payload, start, "\"tool_response\"") orelse payload.len;

    var at = std.mem.indexOfPos(u8, payload[0..end], start, key) orelse return null;
    at = skipSpace(payload, at + key.len);
    if (at >= payload.len or payload[at] != ':') return null;
    at = skipSpace(payload, at + 1);
    if (at >= payload.len or payload[at] != '"') return null;
    return decode(payload[at + 1 ..]);
}

fn skipSpace(text: []const u8, from: usize) usize {
    var at = from;
    while (at < text.len and (text[at] == ' ' or text[at] == '\t' or
        text[at] == '\r' or text[at] == '\n')) at += 1;
    return at;
}

/// The JSON string starting at `text` — everything up to its closing
/// quote — with its escapes resolved.
///
/// Decoded over itself, which is always safe because every escape is
/// longer than what it stands for. Null when the closing quote never
/// arrives: the payload was longer than `max_bytes` and we are holding a
/// piece of a command, which is not something to judge a screen on.
fn decode(text: []u8) ?[]const u8 {
    var read: usize = 0;
    var write: usize = 0;
    while (read < text.len) {
        const byte = text[read];
        if (byte == '"') return text[0..write];
        if (byte != '\\') {
            text[write] = byte;
            read += 1;
            write += 1;
            continue;
        }

        read += 1;
        if (read >= text.len) return null;
        const escape = text[read];
        read += 1;
        const literal: u8 = switch (escape) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 8,
            'f' => 12,
            '"', '\\', '/' => escape,
            // A code point we cannot make sense of is dropped rather
            // than guessed at. Nothing downstream reads this text for
            // anything but ASCII, so a mangled emoji costs nothing and a
            // surrogate half would only be noise.
            'u' => {
                if (read + 4 > text.len) return null;
                const point = std.fmt.parseInt(u16, text[read..][0..4], 16) catch return null;
                read += 4;
                if (point >= 0xD800 and point <= 0xDFFF) continue;
                write += std.unicode.utf8Encode(point, text[write..]) catch continue;
                continue;
            },
            else => return null,
        };
        text[write] = literal;
        write += 1;
    }
    return null;
}

/// Does `command` — the shell text of one Bash call — run `required`,
/// say "git commit"?
///
/// Deliberately the same question the permission rule asks, so that the
/// second gate agrees with the first wherever the first works:
/// `required` has to begin a command and be the whole of the words it
/// spans. `cd repo && git commit -m x` counts, `$(git commit)` counts,
/// and `echo git commit` does not.
pub fn runsCommand(command: []const u8, required: []const u8) bool {
    if (required.len == 0) return true;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, command, from, required)) |found| {
        from = found + 1;
        if (!beginsCommand(command, found)) continue;
        const after = found + required.len;
        if (after < command.len and !ends(command[after])) continue;
        return true;
    }
    return false;
}

/// Is the word at `at` in command position — the start of the line, or
/// the far side of a separator?
///
/// Spaces and tabs are stepped over; a newline is not, because a newline
/// is itself where one command ends and the next begins.
fn beginsCommand(command: []const u8, at: usize) bool {
    var before = at;
    while (before > 0 and (command[before - 1] == ' ' or command[before - 1] == '\t')) {
        before -= 1;
    }
    if (before == 0) return true;
    return separator(command[before - 1]);
}

/// Can `byte` follow the last word of `required` without changing which
/// command it was? Anything else means we matched a longer word —
/// `git commitment` is not `git commit`.
fn ends(byte: u8) bool {
    if (byte == ' ' or byte == '\t') return true;
    return separator(byte);
}

fn separator(byte: u8) bool {
    return switch (byte) {
        ';', '\n', '\r', '|', '&', '(', ')', '{', '}', '`' => true,
        else => false,
    };
}

// ------------------------------------------------------------- tests

const testing = std.testing;

/// A payload shaped like the one Claude Code writes, with `command` in
/// it — including the fields either side, so the scoping is under test
/// and not just the extraction.
fn payloadFor(buffer: []u8, command: []const u8) []u8 {
    return std.fmt.bufPrint(buffer,
        \\{{"session_id":"abc","cwd":"/repo","hook_event_name":"PostToolUse",
        \\"tool_name":"Bash","tool_input":{{"command":"{s}","description":"do a thing"}},
        \\"tool_response":{{"stdout":"","stderr":""}},"tool_use_id":"tu_1"}}
    , .{command}) catch unreachable;
}

test "the command comes out of tool_input, escapes and all" {
    var buffer: [1024]u8 = undefined;

    const plain = payloadFor(&buffer, "git commit -m x");
    try testing.expectEqualStrings("git commit -m x", commandField(plain).?);

    // The shape that started this: a heredoc, which arrives as escaped
    // newlines and escaped quotes and must come back out as neither.
    const heredoc = payloadFor(&buffer, "python3 - <<'PY'\\nprint(\\\"hi\\\")\\nPY");
    try testing.expectEqualStrings(
        "python3 - <<'PY'\nprint(\"hi\")\nPY",
        commandField(heredoc).?,
    );

    // A code point we drop rather than guess at still leaves the rest of
    // the command readable.
    const wide = payloadFor(&buffer, "git commit -m \\u00e9t\\u00e9");
    try testing.expect(std.mem.startsWith(u8, commandField(wide).?, "git commit -m "));
}

/// The parsing decodes over its input, so a literal payload has to be
/// copied somewhere writable before a test can hand it over.
fn writable(buffer: []u8, payload: []const u8) []u8 {
    @memcpy(buffer[0..payload.len], payload);
    return buffer[0..payload.len];
}

test "the tool's own output is never read as the command" {
    // `git log` printing somebody's commit message must not be able to
    // pass itself off as a `git commit` call. The scope is `tool_input`,
    // so the `"command"` in the output below is not even looked at.
    var buffer: [512]u8 = undefined;
    const payload = writable(&buffer,
        \\{"tool_name":"Bash","tool_input":{"description":"read the log"},
        \\"tool_response":{"stdout":"fix the \"command\": \"git commit\" path"}}
    );
    try testing.expect(commandField(payload) == null);
}

test "a payload cut off mid-command is not something to judge a screen on" {
    var buffer: [64]u8 = undefined;
    const truncated = writable(&buffer,
        \\{"tool_input":{"command":"git commit -m 'a very long
    );
    try testing.expect(commandField(truncated) == null);

    // And an unknown command draws, rather than eating the screen.
    const commit = souls.events[souls.indexOfKey("commit_made").?];
    try testing.expect(allows(commit, truncated));
    try testing.expect(allows(commit, buffer[0..0]));
}

test "a command counts only where it is the command being run" {
    const runs = [_][]const u8{
        "git commit",
        "git commit -m 'ship it'",
        "cd /repo && git commit -m x",
        "git add . ; git commit",
        "git status | cat; git commit -m x",
        "echo $(git commit)",
        // A newline is a separator in its own right, which is how a
        // heredoc-carrying call still reads correctly.
        "cd /repo\ngit commit -m x",
        "\tgit commit",
    };
    for (runs) |command| {
        try testing.expect(runsCommand(command, "git commit"));
    }

    const does_not = [_][]const u8{
        // The one the whole change is about.
        "echo {alpha,beta}",
        "grep -rn 'git commit' src/",
        "echo git commit",
        "git commitment --help",
        "git -C /repo commit",
        "git push",
        "",
    };
    for (does_not) |command| {
        try testing.expect(!runsCommand(command, "git commit"));
    }
}

/// A `Stop` payload shaped like the one Claude Code writes, with
/// `tasks` as the body of its background work list — including the
/// unbounded field written just before it, and the list written just
/// after, so the scoping is under test and not only the scan.
fn stopPayload(buffer: []u8, tasks: []const u8) []u8 {
    return std.fmt.bufPrint(buffer,
        \\{{"session_id":"abc","cwd":"/repo","hook_event_name":"Stop",
        \\"stop_hook_active":false,"last_assistant_message":"Done — see above.",
        \\"background_tasks":[{s}],"session_crons":[]}}
    , .{tasks}) catch unreachable;
}

test "a turn that parked on a subagent is not a turn that completed" {
    var buffer: [1024]u8 = undefined;
    const turn = souls.events[souls.indexOfKey("turn_complete").?];

    const waiting = stopPayload(&buffer,
        \\{"id":"t1","type":"subagent","status":"running","description":"Explore the code","agent_type":"Explore"}
    );
    try testing.expect(!allows(turn, waiting));

    // Pending counts too: the list is filtered to running and pending
    // before it is written, so being in it at all is the whole signal.
    const queued = stopPayload(&buffer,
        \\{"id":"t1","type":"subagent","status":"pending","description":"Explore the code"}
    );
    try testing.expect(!allows(turn, queued));

    // The turn that really did end — nothing running, or nothing but
    // work that goes on without it.
    try testing.expect(allows(turn, stopPayload(&buffer, "")));
    try testing.expect(allows(turn, stopPayload(&buffer,
        \\{"id":"t1","type":"shell","status":"running","command":"npm test"}
    )));
}

test "a task's own description cannot pass itself off as a running subagent" {
    // The scan reads keys, and a key inside a JSON string arrives with
    // its quotes escaped — which is why the text below is a shell
    // command in a description and not a second task.
    var buffer: [1024]u8 = undefined;
    const turn = souls.events[souls.indexOfKey("turn_complete").?];
    const disguised = stopPayload(&buffer,
        \\{"id":"t1","type":"shell","status":"running","description":"grep -rn '\"type\":\"subagent\"' src/"}
    );
    try testing.expect(allows(turn, disguised));
}

test "a payload with no background work in it draws" {
    // The tail was rolled past, or Claude Code never wrote the list:
    // either way this is the unknown case, and the unknown cases draw.
    var buffer: [256]u8 = undefined;
    const turn = souls.events[souls.indexOfKey("turn_complete").?];
    try testing.expect(allows(turn, writable(&buffer,
        \\{"hook_event_name":"Stop","stop_hook_active":false}
    )));
    try testing.expect(allows(turn, buffer[0..0]));

    // And a row that is not about a turn ending never asks: a commit
    // lands whether or not something else is still running.
    const commit = souls.events[souls.indexOfKey("commit_made").?];
    var wide: [1024]u8 = undefined;
    const running = stopPayload(&wide,
        \\{"id":"t1","type":"subagent","status":"running","description":"Explore the code"}
    );
    try testing.expect(allows(commit, running));
}

test "only the row that ends a turn reads the end of the payload" {
    for (souls.events) |event| {
        const keep = keepFor(event) orelse {
            try testing.expectEqual(@as(usize, 0), event.requiredCommand().len);
            try testing.expect(!event.yields_to_background);
            continue;
        };
        switch (keep) {
            .tail => try testing.expect(event.yields_to_background),
            .head => try testing.expect(event.requiredCommand().len > 0),
        }
    }
}

test "the rows that name a command are gated on it, and the rest are not" {
    var buffer: [1024]u8 = undefined;

    const commit = souls.events[souls.indexOfKey("commit_made").?];
    const pr = souls.events[souls.indexOfKey("pr_created").?];
    try testing.expect(allows(commit, payloadFor(&buffer, "git commit -m x")));
    try testing.expect(!allows(commit, payloadFor(&buffer, "echo {alpha,beta}")));
    try testing.expect(allows(pr, payloadFor(&buffer, "gh pr create --fill")));
    try testing.expect(!allows(pr, payloadFor(&buffer, "git commit -m x")));
    // The two rows share a hook event and a matcher, so the commit must
    // not answer for the PR either.
    try testing.expect(!allows(commit, payloadFor(&buffer, "gh pr create --fill")));

    // A row that is about a whole tool rather than one command has
    // nothing to check, and asks nothing of the payload.
    const failed = souls.events[souls.indexOfKey("tool_failed").?];
    try testing.expect(allows(failed, payloadFor(&buffer, "echo {alpha,beta}")));
    try testing.expect(allows(failed, buffer[0..0]));
}
