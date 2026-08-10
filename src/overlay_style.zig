//! The things about a banner that the SDK's descriptor cannot say. This
//! is the only place in the app that touches an HWND or sends an
//! Objective-C message, and it is entirely best-effort: every failure
//! path just leaves the window as the SDK made it.
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
//! **On macOS the WINDOW needs none of that — the PROCESS does.** The
//! descriptor's `activate_on_show = false` keeps the banner's own reveal
//! passive, and the AppKit host honours it. But the app around it is
//! still an ordinary foreground app: the host asks for
//! `NSApplicationActivationPolicyRegular`, which is a Dock tile and a
//! Cmd-Tab entry, and the settings window — always created, because
//! `app.zon` declares it — activates the app when its own first frame
//! reveals it. A hook's banner therefore took focus from whatever you
//! were typing into. Both are undone in a screen process only; see
//! `hideFromSwitcher` and the macOS half of `hideSettings`. The settings
//! app itself still activates like any app, because someone asked for it.

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

/// AppKit, reached the way the SDK's own host reaches it. There is no
/// Objective-C in this project and no need for any: three messages to
/// `NSApp` and two to a window is the whole job.
const mac = struct {
    const Id = ?*anyopaque;
    const Sel = ?*anyopaque;

    /// `NSApplicationActivationPolicyAccessory`: no Dock tile, no menu
    /// bar, no Cmd-Tab entry — and windows still draw. Deliberately not
    /// `Prohibited`, which documents itself as unable to create windows
    /// at all, and the banner IS a window.
    const policy_accessory: isize = 1;

    extern fn objc_getClass(name: [*:0]const u8) Id;
    extern fn sel_registerName(name: [*:0]const u8) Sel;
    /// Never called through this declaration. arm64 has no variadic
    /// `objc_msgSend`, so every call site casts it to the exact
    /// signature of the message it is sending — that is the supported
    /// way to use it, not a trick.
    extern fn objc_msgSend() callconv(.c) void;

    /// `dispatch_get_main_queue()` is a macro over this symbol, so there
    /// is nothing to call — the queue is the address.
    const main_queue: *anyopaque = @extern(*anyopaque, .{ .name = "_dispatch_main_q" });
    const Work = *const fn (?*anyopaque) callconv(.c) void;
    extern fn dispatch_async_f(queue: *anyopaque, context: ?*anyopaque, work: Work) void;
    extern fn dispatch_after_f(when: u64, queue: *anyopaque, context: ?*anyopaque, work: Work) void;
    extern fn dispatch_time(base: u64, delta: i64) u64;
    const time_now: u64 = 0;

    fn sel(name: [:0]const u8) Sel {
        return sel_registerName(name.ptr);
    }

    fn app() Id {
        return msgId(objc_getClass("NSApplication"), "sharedApplication");
    }

    fn msgId(target: Id, name: [:0]const u8) Id {
        const send: *const fn (Id, Sel) callconv(.c) Id = @ptrCast(&objc_msgSend);
        return send(target, sel(name));
    }

    fn msgVoid(target: Id, name: [:0]const u8) void {
        const send: *const fn (Id, Sel) callconv(.c) void = @ptrCast(&objc_msgSend);
        send(target, sel(name));
    }

    /// A `BOOL` is a signed char, so it is read as one: any value but 0
    /// and 1 in a Zig `bool` would be undefined.
    fn msgFlag(target: Id, name: [:0]const u8) bool {
        const send: *const fn (Id, Sel) callconv(.c) i8 = @ptrCast(&objc_msgSend);
        return send(target, sel(name)) != 0;
    }

    fn msgCount(target: Id, name: [:0]const u8) usize {
        const send: *const fn (Id, Sel) callconv(.c) usize = @ptrCast(&objc_msgSend);
        return send(target, sel(name));
    }

    fn msgAtIndex(target: Id, name: [:0]const u8, index: usize) Id {
        const send: *const fn (Id, Sel, usize) callconv(.c) Id = @ptrCast(&objc_msgSend);
        return send(target, sel(name), index);
    }

    fn msgWithId(target: Id, name: [:0]const u8, argument: Id) void {
        const send: *const fn (Id, Sel, Id) callconv(.c) void = @ptrCast(&objc_msgSend);
        send(target, sel(name), argument);
    }

    fn msgWithInteger(target: Id, name: [:0]const u8, argument: isize) void {
        const send: *const fn (Id, Sel, isize) callconv(.c) i8 = @ptrCast(&objc_msgSend);
        _ = send(target, sel(name), argument);
    }

    fn msgCString(target: Id, name: [:0]const u8) ?[*:0]const u8 {
        const send: *const fn (Id, Sel) callconv(.c) ?[*:0]const u8 = @ptrCast(&objc_msgSend);
        return send(target, sel(name));
    }
};

/// How long to keep looking before giving up. The window is created
/// during startup, so this only ever runs out if something went wrong.
const attempts = 400;
const poll_interval_ms = 25;

/// Start watching for the overlay window. Returns immediately.
///
/// `title` must be the overlay's window title and must be unique to it
/// — this is how the window is found, so the overlay does not share the
/// settings window's title. Comptime, so a caller passes one UTF-8
/// literal and each platform takes the encoding its own API speaks.
pub fn adopt(comptime title: [:0]const u8) void {
    switch (builtin.os.tag) {
        .windows => {
            const wide = comptime std.unicode.utf8ToUtf16LeStringLiteral(title);
            const thread = std.Thread.spawn(.{}, watch, .{wide}) catch return;
            thread.detach();
        },
        else => {},
    }
}

/// Take this process out of the Dock and the app switcher — macOS, and
/// a screen process only.
///
/// The Win32 half of this is a window style (`WS_EX_TOOLWINDOW`, in
/// `apply` below) and so belongs to the banner whichever mode it is in.
/// The macOS half is the whole PROCESS's activation policy, which is why
/// it cannot be done in `adopt`: a settings app that dropped out of the
/// Dock and lost its menu bar would be a worse app. A banner has neither
/// to lose.
pub fn hideFromSwitcher() void {
    if (builtin.os.tag != .macos) return;
    // Queued rather than done here: `NSApp` does not exist until the
    // runtime creates it inside `runner.runWithOptions`, and AppKit is
    // the main thread's. A block queued now runs on the first turn of
    // the run loop — after the host has asked for the policy we are
    // replacing, and before any window has presented.
    mac.dispatch_async_f(mac.main_queue, null, becomeAccessory);
}

fn becomeAccessory(_: ?*anyopaque) callconv(.c) void {
    const nsapp = mac.app();
    if (nsapp == null) return;
    mac.msgWithInteger(nsapp, "setActivationPolicy:", mac.policy_accessory);
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
///
/// macOS does the same with `orderOut:`, which is `SW_HIDE`'s exact
/// counterpart — no delegate, no close, the window simply leaves the
/// glass — and it gives back the activation that window's own reveal
/// took. Both platforms have to WAIT for the window to be visible
/// before hiding it: the host reveals it on its first frame, and a hide
/// that lands earlier is undone by that reveal.
pub fn hideSettings(comptime title: [:0]const u8) void {
    switch (builtin.os.tag) {
        .windows => {
            const wide = comptime std.unicode.utf8ToUtf16LeStringLiteral(title);
            const thread = std.Thread.spawn(.{}, watchHide, .{wide}) catch return;
            thread.detach();
        },
        .macos => {
            settings_title = title;
            // A main-queue poll rather than a thread: AppKit may only be
            // asked about its windows from the main thread. See
            // `hideFromSwitcher` for why this cannot run before the
            // runtime is up.
            mac.dispatch_async_f(mac.main_queue, null, hideTick);
        },
        else => {},
    }
}

/// The settings window's exact title, for the macOS watcher. A screen
/// process runs one banner and calls `hideSettings` once, so there is
/// nothing to thread through the dispatch context.
var settings_title: [:0]const u8 = "";
var hide_attempts_left: usize = attempts;

fn hideTick(_: ?*anyopaque) callconv(.c) void {
    const nsapp = mac.app();
    if (nsapp == null) return;
    // Every tick, not just the one that finds the window: the reveal we
    // are chasing activates the app, and a banner must never be the
    // active app. Handing focus straight back is the closest thing to
    // never having taken it — the host's activation is not ours to
    // suppress at the source.
    if (mac.msgFlag(nsapp, "isActive")) mac.msgVoid(nsapp, "deactivate");
    if (orderOutSettings(nsapp)) return;
    if (hide_attempts_left == 0) return;
    hide_attempts_left -= 1;
    mac.dispatch_after_f(
        mac.dispatch_time(mac.time_now, poll_interval_ms * std.time.ns_per_ms),
        mac.main_queue,
        null,
        hideTick,
    );
}

/// Order the settings window off the glass. Returns true once there is
/// nothing left to do — which is only ever after hiding it, so a
/// process that never showed one keeps handing focus back until it
/// runs out of attempts or exits with its banner.
///
/// The title is matched WHOLE, like `FindWindowExW` does: a banner's own
/// title starts with the same two words.
fn orderOutSettings(nsapp: mac.Id) bool {
    const windows = mac.msgId(nsapp, "windows");
    if (windows == null) return false;

    const count = mac.msgCount(windows, "count");
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const window = mac.msgAtIndex(windows, "objectAtIndex:", index);
        if (window == null) continue;
        if (!mac.msgFlag(window, "isVisible")) continue;
        const title = mac.msgId(window, "title") orelse continue;
        const text = mac.msgCString(title, "UTF8String") orelse continue;
        if (!std.mem.eql(u8, std.mem.span(text), settings_title)) continue;
        mac.msgWithId(window, "orderOut:", null);
        return true;
    }
    return false;
}

/// Whether this platform can take another process's banner down, which
/// is what makes `Event.priority` mean anything — see `throttle.zig`.
///
/// Win32 only. The mechanism below leans entirely on `FindWindowExW`
/// being able to name a window in someone else's process, and AppKit
/// has no equivalent that does not go through Accessibility. Where this
/// is false the throttle keeps its absolute floor, so a screen is
/// missed rather than drawn over another one.
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
pub fn dismissOthers(comptime title: [:0]const u8) void {
    if (builtin.os.tag != .windows) return;
    const wide = comptime std.unicode.utf8ToUtf16LeStringLiteral(title);

    const own_pid = win.GetCurrentProcessId();
    var hwnd: win.HWND = win.FindWindowExW(null, null, null, wide);
    while (hwnd != null) {
        // Read the next handle BEFORE the window's process dies: an
        // enumeration anchored on a destroyed window starts over.
        const next = win.FindWindowExW(null, hwnd, null, wide);
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
