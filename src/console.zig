//! Where the CLI's output goes on Windows.
//!
//! Release builds are GUI-subsystem — a console-subsystem binary would
//! flash a terminal window behind every banner — and Windows does not
//! attach a GUI process to the console that launched it. Nothing is
//! wrong with the writes: they have nowhere to land. The same build that
//! prints perfectly well into a pipe therefore ran every verb in total
//! silence from a terminal, which is how `install` came to report
//! nothing at all.
//!
//! So: keep the handle we were given when it is a pipe or a file, because
//! that is a redirect and `ai-souls status > file` has to keep working.
//! Otherwise borrow the console that launched us and write to `CONOUT$`.
//!
//! Nothing here creates a console. `AttachConsole` joins one that already
//! exists, so a hook's screen never flashes a terminal — and a screen
//! prints nothing anyway.

const std = @import("std");
const builtin = @import("builtin");

const win = struct {
    const HANDLE = ?*anyopaque;
    const invalid_handle: HANDLE = @ptrFromInt(std.math.maxInt(usize));

    /// `ATTACH_PARENT_PROCESS`
    const parent_process: u32 = 0xFFFF_FFFF;
    /// Already attached to a console — which means there is one to write
    /// to, so `CONOUT$` is still the answer.
    const error_access_denied: u32 = 5;

    const file_type_unknown: u32 = 0x0000;
    const file_type_disk: u32 = 0x0001;
    const file_type_pipe: u32 = 0x0003;

    const generic_read: u32 = 0x8000_0000;
    const generic_write: u32 = 0x4000_0000;
    const share_read: u32 = 0x0000_0001;
    const share_write: u32 = 0x0000_0002;
    const open_existing: u32 = 3;
    const std_output: u32 = 0xFFFF_FFF5; // (DWORD)-11
    const codepage_utf8: u32 = 65001;

    extern "kernel32" fn AttachConsole(process_id: u32) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn GetFileType(file: HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn SetStdHandle(which: u32, handle: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleOutputCP(codepage: u32) callconv(.winapi) i32;
    extern "kernel32" fn CreateFileW(
        path: [*:0]const u16,
        access: u32,
        share: u32,
        security: ?*anyopaque,
        creation: u32,
        flags: u32,
        template: HANDLE,
    ) callconv(.winapi) HANDLE;
};

/// The file every CLI verb prints to. Resolved once per process by
/// `cli.say`; everywhere but Windows it is plain stdout.
pub fn out() std.Io.File {
    const inherited = std.Io.File.stdout();
    if (builtin.os.tag != .windows) return inherited;
    if (isRedirect(inherited.handle)) return inherited;

    // Not a redirect, so either we were handed console handles we are not
    // attached to and cannot use, or nothing at all. Both want the same
    // answer.
    if (win.AttachConsole(win.parent_process) == 0 and
        win.GetLastError() != win.error_access_denied) return inherited;

    const conout = win.CreateFileW(
        std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"),
        win.generic_read | win.generic_write,
        win.share_read | win.share_write,
        null,
        win.open_existing,
        0,
        null,
    );
    if (conout == null or conout == win.invalid_handle) return inherited;
    // So that anything else in the process asking for stdout — a panic
    // trace, the runtime's own trace output — lands in the same place.
    _ = win.SetStdHandle(win.std_output, conout);
    speakUtf8();
    return .{ .handle = conout.?, .flags = .{ .nonblocking = false } };
}

/// The code page we found the console on, once we have changed it.
var borrowed_codepage: ?u32 = null;

/// A console decodes what it is written using its own code page, and the
/// default on an English install is 437 — where every em dash in these
/// messages arrives as three pieces of nonsense. Ours is UTF-8, so say
/// so. Only for a console we went looking for: a redirect carries bytes,
/// and Claude Code reading a hook's stdout wants them untouched.
fn speakUtf8() void {
    const previous = win.GetConsoleOutputCP();
    if (previous == 0 or previous == win.codepage_utf8) return;
    if (win.SetConsoleOutputCP(win.codepage_utf8) == 0) return;
    borrowed_codepage = previous;
}

/// Put the console back the way we found it, once the CLI has finished
/// printing. The code page belongs to the shell we borrowed, not to us,
/// and it outlives this process — `main` calls this as the verbs return.
pub fn restore() void {
    if (builtin.os.tag != .windows) return;
    const previous = borrowed_codepage orelse return;
    borrowed_codepage = null;
    _ = win.SetConsoleOutputCP(previous);
}

/// Was our stdout pointed somewhere by whoever started us? A pipe is a
/// parent reading us (`npx`'s launcher, Claude Code capturing a hook,
/// `$(...)`), a disk file is `>`. Either way it is not ours to redirect.
fn isRedirect(handle: win.HANDLE) bool {
    if (handle == null or handle == win.invalid_handle) return false;
    return switch (win.GetFileType(handle)) {
        win.file_type_disk, win.file_type_pipe => true,
        // A character device is a console (usable only while attached to
        // it) or something like NUL. `CONOUT$` is the better bet.
        else => false,
    };
}

test "an unset stdout handle is not a redirect" {
    // The case that made this module necessary: a GUI-subsystem process
    // launched from a terminal has no usable handle, and every verb's
    // output went nowhere.
    try std.testing.expect(!isRedirect(null));
    try std.testing.expect(!isRedirect(win.invalid_handle));
}

test "GetFileType answers for the handle this process was given" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // The test runner's stdout is a pipe or a file, never a console, so
    // this is the redirect path — the one that must keep `ai-souls
    // status > file` intact.
    const kind = win.GetFileType(std.Io.File.stdout().handle);
    try std.testing.expect(kind == win.file_type_pipe or
        kind == win.file_type_disk or
        kind == win.file_type_unknown);
}
