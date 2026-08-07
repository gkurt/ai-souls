//! Primary display size, in the logical points window geometry uses.
//!
//! Read once in `main` and carried in the model, because the overlay is
//! positioned at (0, 0) with the display's own size and `update` may not
//! ask the OS anything.

const std = @import("std");
const builtin = @import("builtin");

pub const Size = struct {
    width: f32,
    height: f32,
};

/// A middle-of-the-road desktop, used when the platform has no answer.
/// The overlay is click-through and transparent, so being wrong here
/// costs a slightly off-centre banner and nothing else.
pub const fallback: Size = .{ .width = 1440, .height = 900 };

const windows_api = struct {
    const sm_cxscreen: c_int = 0;
    const sm_cyscreen: c_int = 1;

    extern "user32" fn GetSystemMetrics(index: c_int) callconv(.winapi) c_int;
    extern "user32" fn GetDpiForSystem() callconv(.winapi) c_uint;
};

const macos_api = struct {
    extern "c" fn CGMainDisplayID() u32;
    extern "c" fn CGDisplayPixelsWide(display: u32) usize;
    extern "c" fn CGDisplayPixelsHigh(display: u32) usize;
};

pub fn primary() Size {
    return switch (builtin.os.tag) {
        .windows => windowsPrimary(),
        .macos => macosPrimary(),
        else => fallback,
    };
}

fn windowsPrimary() Size {
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

fn macosPrimary() Size {
    const display = macos_api.CGMainDisplayID();
    const width = macos_api.CGDisplayPixelsWide(display);
    const height = macos_api.CGDisplayPixelsHigh(display);
    if (width == 0 or height == 0) return fallback;
    // Quartz reports the display mode's point size, which is already
    // the unit AppKit window frames use.
    return .{
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    };
}

test "the primary display is a plausible size" {
    const size = primary();
    try std.testing.expect(size.width >= 320 and size.width <= 30_000);
    try std.testing.expect(size.height >= 240 and size.height <= 30_000);
}
