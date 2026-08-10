//! The two things about the overlay window that the SDK's descriptor
//! cannot say. This is the only place in the app that touches an HWND,
//! and it is entirely best-effort: every failure path just leaves the
//! window as the SDK made it.
//!
//! **It must not appear in the taskbar or Alt+Tab.** The overlay is a
//! borderless top-level window, which on Win32 means `WS_POPUP` with no
//! owner — and the shell gives one of those a taskbar button and an
//! Alt+Tab entry like any other app. For a banner that exists to flash
//! past and be ignored, both are wrong. The cure is `WS_EX_TOOLWINDOW`,
//! which `WindowDescriptor` does not expose.
//!
//! **It must be vertically centred.** `WindowDescriptor` has `x` and
//! `y`, but the Win32 host passes `CW_USEDEFAULT` for both to
//! `CreateWindowExW` and never applies them, so every window it makes
//! lands wherever the shell puts it — for a `WS_POPUP`, the top-left
//! corner. The bar has to be moved after the fact or it sits across the
//! top of the screen instead of through the middle.
//!
//! Why a thread: the window does not exist until the runtime creates
//! it, which happens inside `runner.runWithOptions`, and there is no
//! window-created hook to hang this off. So one detached thread waits
//! for the window to appear and retires the moment it has fixed it.
//! It polls fast enough to win the race against the host's first
//! reveal, and handles the case where it does not.
//!
//! macOS needs none of this: `activate_on_show = false` on a
//! `NSFloatingWindow` is already invisible to Mission Control and the
//! app switcher.

const std = @import("std");
const builtin = @import("builtin");

const win = struct {
    const HWND = ?*anyopaque;
    const BOOL = i32;

    const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

    const sm_cxscreen: i32 = 0;
    const sm_cyscreen: i32 = 1;
    const hwnd_topmost: HWND = @ptrFromInt(std.math.maxInt(usize));
    const swp_noactivate: u32 = 0x0010;
    const swp_noownerzorder: u32 = 0x0200;

    const gwl_exstyle: i32 = -20;
    const ws_ex_toolwindow: usize = 0x0000_0080;
    const ws_ex_appwindow: usize = 0x0004_0000;
    const ws_ex_noactivate: usize = 0x0800_0000;
    const sw_hide: i32 = 0;
    const sw_shownoactivate: i32 = 4;

    extern "user32" fn FindWindowExW(parent: HWND, after: HWND, class: ?[*:0]const u16, title: ?[*:0]const u16) callconv(.winapi) HWND;
    extern "user32" fn GetWindowThreadProcessId(hwnd: HWND, pid: *u32) callconv(.winapi) u32;
    extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: i32) callconv(.winapi) usize;
    extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: i32, value: usize) callconv(.winapi) usize;
    extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(.winapi) BOOL;
    extern "user32" fn ShowWindow(hwnd: HWND, command: i32) callconv(.winapi) BOOL;
    extern "user32" fn GetWindowRect(hwnd: HWND, rect: *Rect) callconv(.winapi) BOOL;
    extern "user32" fn GetSystemMetrics(index: i32) callconv(.winapi) i32;
    extern "user32" fn SetWindowPos(hwnd: HWND, after: HWND, x: i32, y: i32, cx: i32, cy: i32, flags: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn OpenProcess(access: u32, inherit: BOOL, pid: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn TerminateProcess(process: ?*anyopaque, code: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(object: ?*anyopaque) callconv(.winapi) BOOL;
    const process_terminate: u32 = 0x0001;
    // Zig 0.16 moved sleeping onto the `Io` interface, which this
    // thread has no business holding. Win32 has the primitive.
    extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
};

/// How long to keep looking before giving up. The window is created
/// during startup, so this only ever runs out if something went wrong.
const attempts = 400;
const poll_interval_ms = 25;

/// Start watching for the overlay window. Returns immediately.
///
/// `title` must be the overlay's window title and must be unique to it
/// — this is how the window is found, so the overlay does not share the
/// settings window's title.
pub fn adopt(title: [:0]const u16) void {
    switch (builtin.os.tag) {
        .windows => {
            const thread = std.Thread.spawn(.{}, watch, .{title}) catch return;
            thread.detach();
        },
        else => {},
    }
}

/// Put the settings window away as soon as it exists — a screen process,
/// which the CLI uses to start an app for someone who asked only for a
/// banner.
///
/// A plain `SW_HIDE` rather than the SDK's `closeWindow`, because a
/// runtime-initiated close is a real `DestroyWindow`: the Win32 host's
/// `close_policy = .hide` hook is on `WM_CLOSE` and explicitly documents
/// that programmatic closes bypass it, so asking the SDK to close this
/// window ends the process. Measured exactly that — `window_closed`
/// followed immediately by `stop`.
///
/// Hiding behind the host's back leaves it believing the window is on
/// the glass. That costs nothing here: the permanent overlay window is
/// always visible, so the host's occlusion heuristic already keeps the
/// app awake, and the tray's Open item goes through `showWindow`, which
/// puts it back either way.
pub fn hideSettings(title: [:0]const u16) void {
    switch (builtin.os.tag) {
        .windows => {
            const thread = std.Thread.spawn(.{}, watchHide, .{title}) catch return;
            thread.detach();
        },
        else => {},
    }
}

/// Whether this platform can take another process's banner down, which
/// is what makes `Event.priority` mean anything — see `throttle.zig`.
///
/// Win32 only, for now. The mechanism below leans entirely on
/// `FindWindowExW` being able to name a window in someone else's
/// process; AppKit has no equivalent that does not go through
/// Accessibility, and macOS has not had a banner watched on it yet.
/// Where this is false the throttle keeps its absolute floor, so a
/// screen is missed rather than drawn over another one.
pub const can_dismiss = builtin.os.tag == .windows;

/// Take down every banner belonging to ANOTHER copy of this app, so the
/// one about to be drawn has the glass to itself.
///
/// Called on the way into a screen process, once, before the window
/// exists. Whatever is still up at that moment has already lost the
/// argument — `fire` consulted the throttle first, and the only way it
/// got this far with a banner standing is that it outranks it.
///
/// Synchronous, unlike the two watchers above: the point is for the old
/// screen to be gone before the new one is revealed ~275ms later, and
/// three `FindWindowExW` calls do not need a thread.
///
/// It terminates rather than closing. The pid comes from a live window
/// carrying our own private title, so there is no pid-reuse hazard to
/// worry about, and a `WM_CLOSE` the host chose to ignore would leave
/// the loser's sound playing under the winner's. Exit code 0: that
/// process is some hook's `ai-souls fire`, still being waited on by
/// Claude Code, and its screen being superseded is not a failure.
pub fn dismissOthers(title: [:0]const u16) void {
    if (builtin.os.tag != .windows) return;

    const own_pid = win.GetCurrentProcessId();
    var hwnd: win.HWND = win.FindWindowExW(null, null, null, title.ptr);
    while (hwnd != null) {
        // Read the next handle BEFORE the window's process dies: an
        // enumeration anchored on a destroyed window starts over.
        const next = win.FindWindowExW(null, hwnd, null, title.ptr);
        var pid: u32 = 0;
        _ = win.GetWindowThreadProcessId(hwnd, &pid);
        if (pid != 0 and pid != own_pid) {
            // Hidden first, because it is instant and it works even if
            // this process may not open the other one.
            _ = win.ShowWindow(hwnd, win.sw_hide);
            if (win.OpenProcess(win.process_terminate, 0, pid)) |process| {
                _ = win.TerminateProcess(process, 0);
                _ = win.CloseHandle(process);
            }
        }
        hwnd = next;
    }
}

fn watch(title: [:0]const u16) void {
    var remaining: usize = attempts;
    while (remaining > 0) : (remaining -= 1) {
        if (findOwnWindow(title)) |hwnd| {
            apply(hwnd);
            centre(hwnd);
            return;
        }
        win.Sleep(poll_interval_ms);
    }
}

fn watchHide(title: [:0]const u16) void {
    var remaining: usize = attempts;
    while (remaining > 0) : (remaining -= 1) {
        if (findOwnWindow(title)) |hwnd| {
            // Only once it is actually up: hiding a window the host has
            // not shown yet is undone by the reveal that follows.
            if (win.IsWindowVisible(hwnd) != 0) {
                _ = win.ShowWindow(hwnd, win.sw_hide);
                return;
            }
        }
        win.Sleep(poll_interval_ms);
    }
}

/// The first top-level window with this title belonging to THIS
/// process. The pid check matters: a second copy of the app, or a
/// leftover from a previous run, would otherwise be restyled instead.
fn findOwnWindow(title: [:0]const u16) win.HWND {
    const own_pid = win.GetCurrentProcessId();
    var hwnd: win.HWND = win.FindWindowExW(null, null, null, title.ptr);
    while (hwnd != null) {
        var pid: u32 = 0;
        _ = win.GetWindowThreadProcessId(hwnd, &pid);
        if (pid == own_pid) return hwnd;
        hwnd = win.FindWindowExW(null, hwnd, null, title.ptr);
    }
    return null;
}

fn apply(hwnd: win.HWND) void {
    const current = win.GetWindowLongPtrW(hwnd, win.gwl_exstyle);
    if (current & win.ws_ex_toolwindow != 0) return;

    // `WS_EX_NOACTIVATE` keeps the banner out of Alt+Tab as well, and
    // stops it taking focus from the editor being typed into;
    // `WS_EX_APPWINDOW` is cleared because it would force the taskbar
    // button back on.
    const wanted = (current | win.ws_ex_toolwindow | win.ws_ex_noactivate) & ~win.ws_ex_appwindow;

    // The shell reads these bits when a window is shown. Usually this
    // wins the race and the window has never been shown, so nothing
    // flickers; if it did not, the hide/show is what makes the taskbar
    // let go.
    const was_visible = win.IsWindowVisible(hwnd) != 0;
    if (was_visible) _ = win.ShowWindow(hwnd, win.sw_hide);
    _ = win.SetWindowLongPtrW(hwnd, win.gwl_exstyle, wanted);
    if (was_visible) _ = win.ShowWindow(hwnd, win.sw_shownoactivate);
}

/// Span the display and sit the bar through the middle of it.
///
/// Everything here is in PHYSICAL pixels, which is what these APIs
/// speak in a per-monitor-DPI-aware process — the SDK's manifest
/// declares that awareness, so no scaling belongs in this function. The
/// height is whatever the host already made the window (it DOES apply
/// the descriptor's size, just not its position), so the one number
/// this file does not get to invent is the one `app.bandHeight` owns.
fn centre(hwnd: win.HWND) void {
    var rect: win.Rect = undefined;
    if (win.GetWindowRect(hwnd, &rect) == 0) return;
    const height = rect.bottom - rect.top;
    if (height <= 0) return;

    const screen_width = win.GetSystemMetrics(win.sm_cxscreen);
    const screen_height = win.GetSystemMetrics(win.sm_cyscreen);
    if (screen_width <= 0 or screen_height <= 0) return;

    _ = win.SetWindowPos(
        hwnd,
        // Re-assert topmost while moving: a plain move can drop a
        // window out of the topmost band on some shells.
        win.hwnd_topmost,
        0,
        @divTrunc(screen_height - height, 2),
        screen_width,
        height,
        win.swp_noactivate | win.swp_noownerzorder,
    );
}

test "the wanted style adds tool-window and drops app-window" {
    // Pure bit arithmetic, so it is checkable on every host.
    const before = win.ws_ex_appwindow | 0x0000_0008;
    const after = (before | win.ws_ex_toolwindow | win.ws_ex_noactivate) & ~win.ws_ex_appwindow;
    try std.testing.expect(after & win.ws_ex_toolwindow != 0);
    try std.testing.expect(after & win.ws_ex_noactivate != 0);
    try std.testing.expect(after & win.ws_ex_appwindow == 0);
    // Unrelated bits the SDK set (layered, topmost, transparent) survive.
    try std.testing.expect(after & 0x0000_0008 != 0);
}
