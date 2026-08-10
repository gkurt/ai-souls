//! Where everything lives, resolved once in `main` and then carried in
//! the model as plain bytes.
//!
//! `update` must stay a pure function of model and message, so it never
//! reads the environment or asks the OS where it is — every path it
//! needs was already resolved before the loop started.

const std = @import("std");

pub const max_path_bytes = 512;

pub const PathText = struct {
    buffer: [max_path_bytes]u8 = @splat(0),
    len: usize = 0,

    pub fn set(self: *PathText, source: []const u8) void {
        const n = @min(source.len, max_path_bytes);
        @memcpy(self.buffer[0..n], source[0..n]);
        self.len = n;
    }

    pub fn slice(self: *const PathText) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn isEmpty(self: *const PathText) bool {
        return self.len == 0;
    }
};

/// Where settings lived before the product became AI Souls. Read once,
/// on the first run of a renamed build, and then never again.
pub const legacy_dir_name = ".claude-souls";
pub const dir_name = ".ai-souls";

/// The binary's own filename, extension and all.
pub const exe_name = if (@import("builtin").os.tag == .windows) "ai-souls.exe" else "ai-souls";

pub const Paths = struct {
    /// This binary, so the installed hooks can name it and the app can
    /// re-invoke itself for the settings.json merge.
    exe: PathText = .{},
    home: PathText = .{},
    /// `~/.ai-souls`
    app_dir: PathText = .{},
    /// `~/.ai-souls/config.txt`
    config: PathText = .{},
    /// `~/.ai-souls/fired.txt` — when each event last drew a screen.
    /// With nothing resident there is nowhere else to keep it; see
    /// `throttle.zig`.
    fired: PathText = .{},
    /// `~/.ai-souls/bin` — the copy of the binary that installed hooks
    /// run, with the sounds beside it. See `runtime_copy.zig` for why a
    /// hook must never name the package manager's own path.
    runtime_dir: PathText = .{},
    runtime_exe: PathText = .{},
    /// Which build is in `runtime_dir`, so re-installing the same one
    /// does not rewrite a binary that might be running.
    runtime_stamp: PathText = .{},
    /// `~/.claude-souls/config.txt`, carried only so the first run of a
    /// renamed build can adopt it.
    legacy_config: PathText = .{},
    /// `~/.claude/settings.json` — the global Claude Code settings the
    /// hooks are installed into.
    claude_settings: PathText = .{},
    /// Directory the bundled sounds resolve against ("" = the process
    /// working directory, which is what a dev run wants).
    assets_root: PathText = .{},

    pub fn resolve(io: std.Io, environ: *const std.process.Environ.Map) Paths {
        var paths: Paths = .{};

        var exe_buffer: [max_path_bytes]u8 = undefined;
        if (std.process.executablePath(io, &exe_buffer)) |written| {
            paths.exe.set(exe_buffer[0..written]);
        } else |_| {}

        const home = environ.get("HOME") orelse
            environ.get("USERPROFILE") orelse "";
        paths.home.set(home);

        var scratch: [max_path_bytes]u8 = undefined;
        var dir_buffer: [max_path_bytes]u8 = undefined;
        if (home.len > 0) {
            paths.app_dir.set(join(&scratch, home, dir_name));
            paths.config.set(join(&scratch, paths.app_dir.slice(), "config.txt"));
            paths.fired.set(join(&scratch, paths.app_dir.slice(), "fired.txt"));
            paths.runtime_dir.set(join(&scratch, paths.app_dir.slice(), "bin"));
            const runtime_dir = join(&dir_buffer, paths.app_dir.slice(), "bin");
            paths.runtime_exe.set(join(&scratch, runtime_dir, exe_name));
            paths.runtime_stamp.set(join(&scratch, runtime_dir, "installed.txt"));
            // A separate buffer for each base: `join`'s base may not
            // live in the buffer it is writing into.
            const legacy_dir = join(&dir_buffer, home, legacy_dir_name);
            paths.legacy_config.set(join(&scratch, legacy_dir, "config.txt"));
            const claude_dir = join(&dir_buffer, home, ".claude");
            paths.claude_settings.set(join(&scratch, claude_dir, "settings.json"));
        }

        return paths;
    }

    /// What an installed hook should name as its command.
    ///
    /// The copy under `~/.ai-souls/bin`, because that path is ours and
    /// outlives whatever a package manager did — see `runtime_copy.zig`.
    /// Falls back to the running binary only when there is no home
    /// directory to put a copy in, which is a case `install` rejects
    /// before it ever gets here.
    pub fn hookCommand(self: *const Paths) []const u8 {
        if (!self.runtime_exe.isEmpty()) return self.runtime_exe.slice();
        return self.exe.slice();
    }

    /// Adopt a pre-rename `~/.claude-souls/config.txt` if this install
    /// has none of its own.
    ///
    /// A copy, not a move: the old build may still be installed, and
    /// leaving its directory intact means nothing is destroyed by trying
    /// the new one. Best-effort throughout — a failure here just means
    /// starting from the compiled defaults, which is what a genuinely
    /// new install does anyway.
    pub fn adoptLegacyConfig(self: *const Paths, io: std.Io) bool {
        if (self.config.isEmpty() or self.legacy_config.isEmpty()) return false;
        const cwd = std.Io.Dir.cwd();
        if (cwd.access(io, self.config.slice(), .{})) |_| return false else |_| {}

        var buffer: [64 * 1024]u8 = undefined;
        const text = cwd.readFile(io, self.legacy_config.slice(), &buffer) catch return false;
        cwd.createDirPath(io, self.app_dir.slice()) catch {};
        cwd.writeFile(io, .{ .sub_path = self.config.slice(), .data = text }) catch return false;
        return true;
    }

    /// Resolve a bundle-relative asset ("assets/sounds/gong.mp3") into
    /// the absolute path the audio player should try first.
    ///
    /// Returns the relative path unchanged when no root was found. That
    /// is a last resort, not a mode: it only resolves if the process
    /// happens to have been started from the right directory, which is
    /// exactly the accident this is meant to stop relying on.
    pub fn asset(self: *const Paths, buffer: []u8, relative: []const u8) []const u8 {
        if (self.assets_root.isEmpty()) return relative;
        const joined = join(buffer, self.assets_root.slice(), relative);
        // The catalog spells its paths with forward slashes and the
        // root came from Win32, so the join can produce a mixed path.
        // Media Foundation's source resolver treats its argument as a
        // URL first, and a stray '/' is where that goes wrong.
        if (@import("builtin").os.tag == .windows) {
            for (buffer[0..joined.len]) |*byte| {
                if (byte.* == '/') byte.* = '\\';
            }
        }
        return joined;
    }
};

/// Platform-correct path join into a caller-owned buffer. Truncates
/// rather than failing: every consumer treats an over-long path as a
/// missing one.
///
/// `base` and `leaf` must not overlap `buffer` — build into a fresh
/// buffer when the base came out of the one you are writing into.
pub fn join(buffer: []u8, base: []const u8, leaf: []const u8) []const u8 {
    const separator: u8 = if (@import("builtin").os.tag == .windows) '\\' else '/';
    var written: usize = 0;
    written += copy(buffer, written, base);
    if (base.len > 0 and base[base.len - 1] != '/' and base[base.len - 1] != '\\') {
        written += copy(buffer, written, &[_]u8{separator});
    }
    written += copy(buffer, written, leaf);
    return buffer[0..written];
}

fn copy(buffer: []u8, at: usize, source: []const u8) usize {
    if (at >= buffer.len) return 0;
    const n = @min(source.len, buffer.len - at);
    @memcpy(buffer[at .. at + n], source[0..n]);
    return n;
}

/// The directory part of a path, or "" when there is none.
pub fn parent(path: []const u8) []const u8 {
    var index = path.len;
    while (index > 0) {
        index -= 1;
        if (path[index] == '/' or path[index] == '\\') return path[0..index];
    }
    return "";
}

test "join inserts exactly one separator" {
    var buffer: [max_path_bytes]u8 = undefined;
    const sep = if (@import("builtin").os.tag == .windows) "\\" else "/";
    try std.testing.expectEqualStrings(
        "a" ++ sep ++ "b",
        join(&buffer, "a", "b"),
    );
    try std.testing.expectEqualStrings(
        "a/b",
        join(&buffer, "a/", "b"),
    );
}

test "resolve builds every path from a home directory" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    const home = if (@import("builtin").os.tag == .windows) "C:\\Users\\ashen" else "/home/ashen";
    try environ.put("HOME", home);
    try environ.put("USERPROFILE", home);

    const paths = Paths.resolve(std.testing.io, &environ);

    // The regression this guards: `claude_settings` used to be joined
    // out of the same scratch buffer it was being written into.
    try std.testing.expect(std.mem.endsWith(u8, paths.claude_settings.slice(), "settings.json"));
    try std.testing.expect(std.mem.indexOf(u8, paths.claude_settings.slice(), ".claude") != null);
    try std.testing.expect(std.mem.endsWith(u8, paths.config.slice(), "config.txt"));
    // The throttle's record sits beside the settings, not beside the
    // binary: it belongs to the person, not to the install.
    try std.testing.expect(std.mem.startsWith(u8, paths.fired.slice(), paths.app_dir.slice()));
    try std.testing.expect(std.mem.endsWith(u8, paths.fired.slice(), "fired.txt"));
    // The copy hooks run lives under our directory, not the package
    // manager's, and it is a file inside the directory beside it.
    try std.testing.expect(std.mem.startsWith(u8, paths.runtime_dir.slice(), paths.app_dir.slice()));
    try std.testing.expect(std.mem.startsWith(u8, paths.runtime_exe.slice(), paths.runtime_dir.slice()));
    try std.testing.expect(std.mem.startsWith(u8, paths.runtime_stamp.slice(), paths.runtime_dir.slice()));
    try std.testing.expect(std.mem.endsWith(u8, paths.runtime_exe.slice(), exe_name));
    try std.testing.expectEqualStrings(paths.runtime_exe.slice(), paths.hookCommand());
    try std.testing.expect(std.mem.startsWith(u8, paths.app_dir.slice(), home));
    // ".ai-souls" and ".claude" are different directories, and the
    // hooks go in neither of the app's own.
    try std.testing.expect(std.mem.indexOf(u8, paths.claude_settings.slice(), dir_name) == null);
    try std.testing.expect(std.mem.indexOf(u8, paths.claude_settings.slice(), legacy_dir_name) == null);
    try std.testing.expect(std.mem.indexOf(u8, paths.app_dir.slice(), dir_name) != null);
    // The pre-rename config is still addressable, and is not the one we
    // read by default.
    try std.testing.expect(std.mem.indexOf(u8, paths.legacy_config.slice(), legacy_dir_name) != null);
    try std.testing.expect(!std.mem.eql(u8, paths.config.slice(), paths.legacy_config.slice()));
}

test "a resolved asset is absolute and single-separator" {
    var paths: Paths = .{};
    const root = if (@import("builtin").os.tag == .windows)
        "C:\\Program Files\\AI Souls"
    else
        "/opt/ai-souls";
    paths.assets_root.set(root);

    var buffer: [max_path_bytes]u8 = undefined;
    const resolved = paths.asset(&buffer, "assets/sounds/gong.mp3");

    try std.testing.expect(std.mem.startsWith(u8, resolved, root));
    try std.testing.expect(std.mem.endsWith(u8, resolved, "gong.mp3"));
    if (@import("builtin").os.tag == .windows) {
        // The mixed-separator path is what Media Foundation refuses.
        try std.testing.expect(std.mem.indexOfScalar(u8, resolved, '/') == null);
    }
}

test "with no assets root the relative path survives untouched" {
    const paths: Paths = .{};
    var buffer: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "assets/sounds/gong.mp3",
        paths.asset(&buffer, "assets/sounds/gong.mp3"),
    );
}

test "parent trims the last segment" {
    try std.testing.expectEqualStrings("/home/x", parent("/home/x/config.txt"));
    try std.testing.expectEqualStrings("C:\\Users\\x", parent("C:\\Users\\x\\config.txt"));
    try std.testing.expectEqualStrings("", parent("config.txt"));
}
