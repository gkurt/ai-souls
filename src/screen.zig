//! The display a banner is drawn on: its size in the logical points
//! window geometry uses, and where it sits.
//!
//! Read once in `main` and carried in the model, because the overlay
//! spans the display and `update` may not ask the OS anything. `main`
//! also turns it into the frame the banner is actually moved to, since
//! no host applies the one the descriptor asks for — see `bandFrame`.

const std = @import("std");
const builtin = @import("builtin");

pub const Display = struct {
    width: f32,
    height: f32,
    /// The display's bottom-left corner in the space macOS places windows
    /// in: AppKit's global points, whose origin is the bottom-left corner
    /// of the PRIMARY display and whose y grows upwards. Zero everywhere
    /// else, where the placement code reads the display itself (see
    /// `overlay_style.centre`).
    x: f32 = 0,
    y: f32 = 0,
};

/// A middle-of-the-road desktop, used when the platform has no answer.
/// The overlay is click-through and transparent, so being wrong here
/// costs a slightly off-centre banner and nothing else.
pub const fallback: Display = .{ .width = 1440, .height = 900 };

const windows_api = struct {
    const sm_cxscreen: c_int = 0;
    const sm_cyscreen: c_int = 1;

    extern "user32" fn GetSystemMetrics(index: c_int) callconv(.winapi) c_int;
    extern "user32" fn GetDpiForSystem() callconv(.winapi) c_uint;
};

const macos_api = struct {
    const Point = extern struct { x: f64, y: f64 };
    const Rect = extern struct { x: f64, y: f64, width: f64, height: f64 };

    extern "c" fn CGMainDisplayID() u32;
    extern "c" fn CGDisplayBounds(display: u32) Rect;
    extern "c" fn CGGetDisplaysWithPoint(point: Point, max: u32, displays: [*]u32, count: *u32) i32;
    extern "c" fn CGEventCreate(source: ?*anyopaque) ?*anyopaque;
    extern "c" fn CGEventGetLocation(event: ?*anyopaque) Point;
    extern "c" fn CFRelease(object: *anyopaque) void;
};

pub fn active() Display {
    return switch (builtin.os.tag) {
        .windows => windowsPrimary(),
        .macos => macosActive(),
        else => fallback,
    };
}

fn windowsPrimary() Display {
    // GetSystemMetrics answers in physical pixels for a DPI-aware
    // process; window geometry is in logical points, so divide the
    // scale back out.
    const physical_w = windows_api.GetSystemMetrics(windows_api.sm_cxscreen);
    const physical_h = windows_api.GetSystemMetrics(windows_api.sm_cyscreen);
    if (physical_w <= 0 or physical_h <= 0) return fallback;

    const dpi = windows_api.GetDpiForSystem();
    const scale: f32 = if (dpi == 0) 1 else @as(f32, @floatFromInt(dpi)) / 96.0;
    if (scale <= 0) return fallback;

    return .{
        .width = @as(f32, @floatFromInt(physical_w)) / scale,
        .height = @as(f32, @floatFromInt(physical_h)) / scale,
    };
}

fn macosActive() Display {
    // The test binary links no macOS frameworks. `linkPlatform` in the
    // Native SDK's build graph runs against the app module only, and a
    // Debug `native test` gets a separate module that never sees it — so
    // referencing CoreGraphics here fails the test link with an
    // undefined `_CGMainDisplayID`. `is_test` is comptime, so this
    // returns before the extern is ever named.
    if (builtin.is_test) return fallback;

    const primary = macos_api.CGDisplayBounds(macos_api.CGMainDisplayID());
    if (primary.height <= 0) return fallback;

    const bounds = pointerDisplay() orelse primary;
    if (bounds.width <= 0 or bounds.height <= 0) return fallback;

    // Quartz reports the display mode's point size, which is already the
    // unit AppKit window frames use. It measures DOWN from the top-left
    // corner of the primary display, though, and AppKit places windows UP
    // from its bottom-left — so a display's own bottom edge sits at the
    // primary's height less this display's bottom in Quartz terms.
    return .{
        .width = @floatCast(bounds.width),
        .height = @floatCast(bounds.height),
        .x = @floatCast(bounds.x),
        .y = @floatCast(primary.height - (bounds.y + bounds.height)),
    };
}

/// The display the pointer is on, which is the one someone is working on.
/// A banner is decoration for a person: put it on the primary display and
/// on a laptop with an external monitor it flashes past on the screen
/// nobody is looking at. Null when CoreGraphics will not say, which the
/// caller reads as the primary.
fn pointerDisplay() ?macos_api.Rect {
    const event = macos_api.CGEventCreate(null) orelse return null;
    defer macos_api.CFRelease(event);

    var displays: [1]u32 = undefined;
    var count: u32 = 0;
    // Anything but kCGErrorSuccess, and `count` has not been written.
    if (macos_api.CGGetDisplaysWithPoint(
        macos_api.CGEventGetLocation(event),
        displays.len,
        &displays,
        &count,
    ) != 0) return null;
    if (count == 0) return null;
    return macos_api.CGDisplayBounds(displays[0]);
}

// On macOS this asserts the fallback rather than a real display, for the
// linking reason above. Windows tests hit the real GetSystemMetrics.
test "the active display is a plausible size" {
    const display = active();
    try std.testing.expect(display.width >= 320 and display.width <= 30_000);
    try std.testing.expect(display.height >= 240 and display.height <= 30_000);
}
