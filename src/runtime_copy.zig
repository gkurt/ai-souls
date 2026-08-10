//! The copy of ourselves that installed hooks actually run.
//!
//! A hook names its command by absolute path, and every path a package
//! manager hands us is temporary in some way. npm's global prefix is
//! versioned, so upgrading moves the binary and leaves eight hooks
//! pointing at a file that is gone. npx is worse: it unpacks into a
//! cache directory that npm deletes on its own schedule.
//!
//! Neither failure says anything. Our hooks are `async` with a five
//! second timeout, so Claude Code swallows the error and the screens
//! simply stop appearing.
//!
//! So `install` copies the binary — and the sounds, so the copy is a
//! whole working install rather than a launcher — into
//! `~/.ai-souls/bin` and points the hooks THERE. That path is ours. It
//! survives an upgrade, an `npm uninstall -g`, and an npx cache being
//! collected ten minutes later.
//!
//! Not a symlink: Windows needs a privilege or developer mode for those,
//! and the whole point is a path that outlives its target.

const std = @import("std");
const paths_mod = @import("paths.zig");
const souls = @import("souls.zig");

pub const Error = error{
    NoHomeDirectory,
    /// The binary could not be copied and there is no usable copy from
    /// a previous install to fall back on.
    CopyFailed,
};

pub const Outcome = enum {
    /// A copy was made or refreshed.
    copied,
    /// The copy already matched the binary we are running.
    current,
    /// The copy is a DIFFERENT build and could not be replaced —
    /// almost always because a running app is holding it open, which
    /// Windows will not let anyone overwrite. The hooks still work;
    /// they just run the older program until the app is quit and
    /// `install` is run again. Worth saying out loud.
    kept_stale,
    /// We ARE the copy — someone ran `~/.ai-souls/bin/ai-souls` itself.
    self,
};

/// Make `paths.runtime_exe` be this binary, and return what that took.
pub fn sync(io: std.Io, paths: *const paths_mod.Paths) Error!Outcome {
    if (paths.runtime_exe.isEmpty() or paths.exe.isEmpty()) return Error.NoHomeDirectory;
    if (std.mem.eql(u8, paths.exe.slice(), paths.runtime_exe.slice())) return .self;

    const cwd = std.Io.Dir.cwd();
    const stamp = sourceStamp(io, paths) orelse return Error.CopyFailed;

    // The fast path is also the safe one. Re-running `install` at the
    // same version must not try to overwrite a copy that might be
    // RUNNING — Windows refuses to replace the image of a live process,
    // and there would be nothing to gain from it anyway.
    if (stampMatches(io, paths, stamp) and exists(io, paths.runtime_exe.slice())) return .current;

    cwd.createDirPath(io, paths.runtime_dir.slice()) catch return Error.CopyFailed;
    cwd.copyFile(
        paths.exe.slice(),
        cwd,
        paths.runtime_exe.slice(),
        io,
        .{ .make_path = true },
    ) catch {
        // An existing copy is better than a failed install: it is the
        // previous version of the same program, and the hooks it
        // answers still work.
        if (exists(io, paths.runtime_exe.slice())) return .kept_stale;
        return Error.CopyFailed;
    };

    copySounds(io, paths);
    cwd.writeFile(io, .{ .sub_path = paths.runtime_stamp.slice(), .data = stamp.text() }) catch {};
    return .copied;
}

/// Take the copy away again. Best-effort: `uninstall` has already done
/// the part that matters, and a locked file on Windows is not worth
/// failing over.
pub fn remove(io: std.Io, paths: *const paths_mod.Paths) void {
    if (paths.runtime_dir.isEmpty()) return;
    // Never delete the ground we are standing on.
    if (std.mem.eql(u8, paths.exe.slice(), paths.runtime_exe.slice())) return;
    std.Io.Dir.cwd().deleteTree(io, paths.runtime_dir.slice()) catch {};
}

/// What identifies a build, for deciding whether the copy is stale.
///
/// Size and where it came from, not a version string: the version in
/// `app.zon` does not change between two development builds, and the
/// point of the check is only ever "is this the same file".
pub const Stamp = struct {
    size: u64,
    source: []const u8,
    buffer: [paths_mod.max_path_bytes + 32]u8 = @splat(0),
    len: usize = 0,

    fn render(self: *Stamp) void {
        const written = std.fmt.bufPrint(&self.buffer, "{d} {s}\n", .{ self.size, self.source }) catch "";
        self.len = written.len;
    }

    pub fn text(self: *const Stamp) []const u8 {
        return self.buffer[0..self.len];
    }
};

fn sourceStamp(io: std.Io, paths: *const paths_mod.Paths) ?Stamp {
    const info = std.Io.Dir.cwd().statFile(io, paths.exe.slice(), .{}) catch return null;
    var stamp: Stamp = .{ .size = info.size, .source = paths.exe.slice() };
    stamp.render();
    if (stamp.len == 0) return null;
    return stamp;
}

fn stampMatches(io: std.Io, paths: *const paths_mod.Paths, stamp: Stamp) bool {
    var buffer: [paths_mod.max_path_bytes + 32]u8 = undefined;
    const found = std.Io.Dir.cwd().readFile(io, paths.runtime_stamp.slice(), &buffer) catch return false;
    return std.mem.eql(
        u8,
        std.mem.trim(u8, found, " \t\r\n"),
        std.mem.trim(u8, stamp.text(), " \t\r\n"),
    );
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// The bank, so a copy left behind by an uninstalled npm package is
/// still a working install rather than a mute one. Best-effort: silent
/// screens beat a failed install.
fn copySounds(io: std.Io, paths: *const paths_mod.Paths) void {
    if (paths.assets_root.isEmpty()) return;
    const cwd = std.Io.Dir.cwd();
    inline for (@typeInfo(souls.Sound).@"enum".fields) |field| {
        const sound: souls.Sound = @enumFromInt(field.value);
        if (sound != .none) {
            var source_buffer: [paths_mod.max_path_bytes]u8 = undefined;
            var dest_buffer: [paths_mod.max_path_bytes]u8 = undefined;
            const source = paths.asset(&source_buffer, sound.path());
            const dest = paths_mod.join(&dest_buffer, paths.runtime_dir.slice(), sound.path());
            cwd.copyFile(source, cwd, dest, io, .{ .make_path = true }) catch {};
        }
    }
}

// -------------------------------------------------------------- tests

test "a stamp is the size and the source, and compares as text" {
    var one: Stamp = .{ .size = 5_912_576, .source = "/opt/ai-souls/vendor/darwin-arm64/ai-souls" };
    one.render();
    try std.testing.expectEqualStrings(
        "5912576 /opt/ai-souls/vendor/darwin-arm64/ai-souls\n",
        one.text(),
    );

    // A rebuild of a different size is a different stamp, and so is the
    // same size arriving from a different install.
    var bigger: Stamp = .{ .size = 5_912_577, .source = one.source };
    bigger.render();
    try std.testing.expect(!std.mem.eql(u8, one.text(), bigger.text()));

    var elsewhere: Stamp = .{ .size = one.size, .source = "/usr/local/lib/node_modules/ai-souls/x" };
    elsewhere.render();
    try std.testing.expect(!std.mem.eql(u8, one.text(), elsewhere.text()));
}

test "a stamp for an absurd path does not overflow its buffer" {
    const long = "/" ++ ("x" ** (paths_mod.max_path_bytes * 2));
    var stamp: Stamp = .{ .size = 1, .source = long };
    stamp.render();
    // bufPrint failed, which the caller reads as "no stamp" rather than
    // as a match against a truncated one.
    try std.testing.expectEqual(@as(usize, 0), stamp.len);
}
