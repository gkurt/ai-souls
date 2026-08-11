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
//! **It must be vertically centred, and NO host applies the position it
//! is asked for.** `WindowDescriptor` has `x` and `y`; the Win32 host
//! passes `CW_USEDEFAULT` for both to `CreateWindowExW`, so every window
//! it makes lands wherever the shell puts it — for a `WS_POPUP`, the
//! top-left corner. macOS applies the size and not the origin, which is
//! invisible on one display and obvious on two: measured with a 1512x982
//! primary and a 1920x1080 beside it, a band asked for at (0, 387) was
//! created at (1920, 149) — on the other display, and hanging off the
//! right of it. So the bar is moved after the fact on both, or it sits
//! somewhere other than through the middle of the screen.
//!
//! Why a thread: the window does not exist until the runtime creates
//! it, which happens inside `runner.runWithOptions`, and there is no
//! window-created hook to hang this off. So one detached thread waits
//! for the window to appear and retires the moment it has fixed it.
//! It polls fast enough to win the race against the host's first
//! reveal, and handles the case where it does not.
//!
//! **No window this app declares may activate** — `activate_on_show =
//! false` on every one of them, the shell band's in `app.zon` as well,
//! because the host creates that one before any of this code runs. On
//! Windows that is the whole story. On macOS focus belongs to the APP
//! rather than to the window, and a launch brings a newly launched app
//! forward whatever its windows asked for, so the process itself has to
//! refuse the foreground: see `refuseForeground`.
//!
//! Why the main queue on macOS, and not a thread: AppKit may only be
//! asked about its windows from the thread that owns them. Everything
//! here that touches one is a poll re-armed with `dispatch_after_f`,
//! which is the same watcher with the run loop doing the waiting.
//!
//! The rest of what macOS needs is the app around the window. The host
//! asks for `NSApplicationActivationPolicyRegular` — a Dock tile, a
//! Cmd-Tab entry, and an app the system is free to bring to the front —
//! and a banner deserves none of the three. See `refuseForeground`.

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

    /// `NSApplicationActivationPolicyProhibited`: no Dock tile, no menu
    /// bar, no Cmd-Tab entry — and, the part that matters, a process
    /// that cannot be made the active app. Its documentation says such
    /// an app "may not create windows or be activated"; the banner is a
    /// window and it does draw, verified on screen. See
    /// `refuseForeground` for why nothing weaker is enough.
    const policy_prohibited: isize = 2;

    /// `NSRect`. Declared flat rather than as a `CGPoint` and a `CGSize`
    /// because the C ABI flattens it either way: four `CGFloat`s go in
    /// v0-v3 on arm64 and on the stack on x86_64, whichever way the
    /// struct is nested.
    const Rect = extern struct { x: f64, y: f64, width: f64, height: f64 };

    const Method = ?*anyopaque;
    /// `-[NSApplication setActivationPolicy:]`, as a function pointer.
    /// `method_setImplementation` takes an untyped `IMP`; declaring it
    /// as the exact signature of the one method this file replaces is
    /// the same discipline the `objc_msgSend` casts above follow.
    const PolicyImp = *const fn (Id, Sel, isize) callconv(.c) i8;

    extern fn objc_getClass(name: [*:0]const u8) Id;
    extern fn sel_registerName(name: [*:0]const u8) Sel;
    extern fn class_getInstanceMethod(class: Id, name: Sel) Method;
    extern fn method_setImplementation(method: Method, imp: *const anyopaque) ?*const anyopaque;
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

    fn msgCount(target: Id, name: [:0]const u8) usize {
        const send: *const fn (Id, Sel) callconv(.c) usize = @ptrCast(&objc_msgSend);
        return send(target, sel(name));
    }

    fn msgAtIndex(target: Id, name: [:0]const u8, index: usize) Id {
        const send: *const fn (Id, Sel, usize) callconv(.c) Id = @ptrCast(&objc_msgSend);
        return send(target, sel(name), index);
    }

    fn msgWithRectFlag(target: Id, name: [:0]const u8, rect: Rect, flag: bool) void {
        const send: *const fn (Id, Sel, Rect, i8) callconv(.c) void = @ptrCast(&objc_msgSend);
        send(target, sel(name), rect, @intFromBool(flag));
    }

    fn msgWithFlag(target: Id, name: [:0]const u8, flag: bool) void {
        const send: *const fn (Id, Sel, i8) callconv(.c) void = @ptrCast(&objc_msgSend);
        send(target, sel(name), @intFromBool(flag));
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

/// Where the band belongs, in the points the platform places windows in.
///
/// macOS is the only caller that reads it, so it is in AppKit's global
/// space: the origin is the BOTTOM-left corner of the primary display
/// and y grows upwards, which is why `main` hands over a flipped `y`
/// rather than the descriptor's own. Win32 has to work in physical
/// pixels and derives its own rect — see `centre`.
pub const Frame = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Start watching for the overlay window. Returns immediately.
///
/// `title` must be the banner window's title and must be unique to it —
/// this is how the window is found. Comptime, so a caller passes one
/// UTF-8 literal and each platform takes the encoding its own API
/// speaks.
///
/// `band` is where the window has to end up. Win32 is not given it:
/// `centre` reads the display and the window's own height in the physical
/// pixels those APIs speak, and that height is the one number it does not
/// get to invent.
pub fn adopt(comptime title: [:0]const u8, band: Frame) void {
    switch (builtin.os.tag) {
        .windows => adoptWin32(title),
        .macos => adoptMac(title, band),
        else => {},
    }
}

fn adoptWin32(comptime title: [:0]const u8) void {
    const wide = comptime std.unicode.utf8ToUtf16LeStringLiteral(title);
    const thread = std.Thread.spawn(.{}, watch, .{wide}) catch return;
    thread.detach();
}

fn adoptMac(title: [:0]const u8, band: Frame) void {
    banner_title = title;
    banner_frame = band;
    mac.dispatch_async_f(mac.main_queue, null, placeTick);
}

/// The banner's title and target frame, for the macOS watcher. A process
/// declares one overlay window and never moves it again, so there is
/// nothing to thread through the dispatch context.
var banner_title: [:0]const u8 = "";
var banner_frame: Frame = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
var place_attempts_left: usize = attempts;

fn placeTick(_: ?*anyopaque) callconv(.c) void {
    const nsapp = mac.app();
    if (nsapp == null) return;
    if (dressBanner(nsapp)) return;
    if (place_attempts_left == 0) return;
    place_attempts_left -= 1;
    mac.dispatch_after_f(
        mac.dispatch_time(mac.time_now, poll_interval_ms * std.time.ns_per_ms),
        mac.main_queue,
        null,
        placeTick,
    );
}

/// Give the banner the frame and the look the descriptor cannot ask for.
/// Returns true once there is nothing left to do. This is the macOS
/// counterpart of `apply` and `centre`, and it runs for the same reason.
///
/// It wants the window BEFORE it is visible: the host creates it
/// ordered-out and reveals it on its first present, and a change that
/// lands after that reveal is one the eye can catch.
fn dressBanner(nsapp: mac.Id) bool {
    const window = findWindow(nsapp, banner_title) orelse return false;
    mac.msgWithRectFlag(window, "setFrame:display:", .{
        .x = banner_frame.x,
        .y = banner_frame.y,
        .width = banner_frame.width,
        .height = banner_frame.height,
    }, true);
    // AppKit shadows every window, and a translucent one shows its own
    // shadow through itself: a black rim around all four sides of the
    // bar, heaviest exactly where the soft edge is trying to dissolve
    // into the desktop. The band draws its own edges and wants no help.
    mac.msgWithFlag(window, "setHasShadow:", false);
    return true;
}

/// Keep this process out of the foreground for its whole life — macOS.
/// The Win32 half of the same idea is a window style
/// (`WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`, in `apply` below); here it is
/// the whole PROCESS, because on macOS focus belongs to the app and not
/// to the window.
///
/// **`Prohibited`, not `Accessory`.** An accessory process has no Dock
/// tile and no Cmd-Tab entry, which is most of what a banner wants — but
/// it can still be brought to the front, and launching one from the app
/// you are working in does exactly that. Measured against NSWorkspace's
/// activation notifications: an accessory banner deactivated the app
/// that spawned it for the entire two seconds it was on screen. Nothing
/// in this process asks for that (no window here activates, and
/// `-[NSApplication activate]` neutered changes nothing) — the launch
/// itself is what brings a newly launched app forward. A prohibited
/// process cannot be made active at all, which is the only setting that
/// holds. The banner still draws: it is a borderless, click-through
/// canvas window with no keyboard and no menu bar to lose.
///
/// **Pinned, not set.** The host asks for `Regular` inside its own
/// init, which is after this runs and before the run loop exists — so a
/// policy merely set here is overwritten with time to spare for the
/// launch to take the keyboard. So `setActivationPolicy:` is replaced
/// with one that answers prohibited whoever asks and whatever they ask
/// for, and the host's own call is what puts it into effect. Nothing
/// here creates `NSApp`; the runtime still does that, a moment later,
/// exactly as it would have.
pub fn refuseForeground() void {
    if (builtin.os.tag != .macos) return;
    if (original_set_policy != null) return;
    const class = mac.objc_getClass("NSApplication");
    if (class == null) return;
    const method = mac.class_getInstanceMethod(class, mac.sel("setActivationPolicy:")) orelse return;
    original_set_policy = @ptrCast(@alignCast(mac.method_setImplementation(method, &prohibitedPolicyOnly)));
}

/// The original `-[NSApplication setActivationPolicy:]`, kept so the
/// replacement can do the work with the answer this process wants. Also
/// the "already done" flag: `refuseForeground` runs once per process.
var original_set_policy: ?mac.PolicyImp = null;

fn prohibitedPolicyOnly(target: mac.Id, name: mac.Sel, _: isize) callconv(.c) i8 {
    const original = original_set_policy orelse return 0;
    return original(target, name, mac.policy_prohibited);
}

/// Windows-only: keep the opaque-mode shell band out of the taskbar.
///
/// In that mode the banner draws in the DECLARED opaque window and the
/// transparent startup window underneath paints nothing — but a
/// chromeless `WS_POPUP` with no owner still gets a taskbar button for
/// the seconds it exists, and `apply` is what takes that away. macOS
/// needs no counterpart: the whole process is already out of the Dock
/// and the switcher (`refuseForeground`), and an invisible window has
/// nothing else to leak.
pub fn excludeFromTaskbar(comptime title: [:0]const u8) void {
    if (builtin.os.tag != .windows) return;
    adoptWin32(title);
}

/// This process's window with exactly this title, or null while there
/// is none. `[NSApp windows]` holds ordered-out windows too, which is
/// what makes this mean "as soon as it exists" — and `dressBanner`
/// wants the window BEFORE the host reveals it.
///
/// The title is matched WHOLE, like `FindWindowExW` does: the two
/// banner titles share their first two words.
fn findWindow(nsapp: mac.Id, title: [:0]const u8) mac.Id {
    const windows = mac.msgId(nsapp, "windows");
    if (windows == null) return null;

    const count = mac.msgCount(windows, "count");
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const window = mac.msgAtIndex(windows, "objectAtIndex:", index);
        if (window == null) continue;
        const window_title = mac.msgId(window, "title") orelse continue;
        const text = mac.msgCString(window_title, "UTF8String") orelse continue;
        if (!std.mem.eql(u8, std.mem.span(text), title)) continue;
        return window;
    }
    return null;
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
