//! The banner's widget tree — the screen that flashes over everything
//! else. It has no controls at all, because its window is click-through
//! and could not receive a press if it wanted one.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

const app = @import("app.zig");
const souls = @import("souls.zig");

const Model = app.Model;
const Msg = app.Msg;
pub const Ui = canvas.Ui(Msg);
const Node = Ui.Node;

fn ink(rgb: [3]u8) canvas.Color {
    return canvas.Color.rgb8(rgb[0], rgb[1], rgb[2]);
}

/// The bar behind the headline. Dark enough to read against a bright
/// editor, translucent enough that you can still see what you were
/// doing.
const band_ink = canvas.Color.rgba8(6, 5, 5, 214);
const band_alpha: f32 = 214;

/// How many strips each soft edge is cut into.
///
/// Widget backgrounds take a flat `?Color` — there is no gradient fill
/// at this layer, and the `chrome` builder that does have one is
/// main-canvas only, so a real vertical gradient is not reachable from
/// a declared window. Stacking thin constant-alpha strips gets there:
/// over a ~26pt edge, 24 of them are about a point each, an alpha step
/// of 9/255, which is not resolvable by eye.
///
/// The strips MUST be plain layout boxes. Built out of `.panel` they
/// each draw that widget's border, and 48 hairlines through the fade
/// turn the gradient into a flat lighter block — which is exactly what
/// it looked like. Measured, ramping 0 -> 214 over four fat strips:
///
///     .panel                       0.09 [seam] 0.30 [seam] 0.52 ...
///     .panel, border set clear     0.10 [seam] 0.31 [seam] 0.53 ...
///     column                       0.10        0.31        0.53 ...
///
/// where each [seam] was one or two rows of a completely different
/// value — first bright, then dark once the border colour was cleared,
/// and gone entirely once the widget was.
const fade_steps = 24;

/// Souls screens shout.
///
/// Uppercased at RENDER time, not in the catalog, so the setting stays
/// whatever the user typed — the shout is a property of the screen, and
/// they get their text back verbatim if they ever want it elsewhere.
/// ASCII-only, so any UTF-8 sequence passes through untouched instead
/// of being mangled a byte at a time.
fn shout(ui: *Ui, text: []const u8) []const u8 {
    var buffer: [souls.max_title_bytes]u8 = undefined;
    const n = @min(text.len, buffer.len);
    for (text[0..n], 0..) |byte, index| buffer[index] = std.ascii.toUpper(byte);
    return ui.fmt("{s}", .{buffer[0..n]});
}

/// One end of the bar, dissolving over `steps` strips. `descending`
/// runs the ramp the other way for the bottom edge.
fn softEdge(ui: *Ui, out: []Node, edge: f32, descending: bool) Node {
    const steps: f32 = @floatFromInt(out.len);
    for (out, 0..) |*slot, index| {
        const step: f32 = @floatFromInt(index);
        // Sample at the strip's middle, and ease rather than ramp
        // linearly: a straight ramp still shows its two ends as creases.
        // Sample at the strip's middle, and ease rather than ramp
        // linearly: a straight ramp leaves a faint crease at both ends
        // of the fade, where the rate of change stops abruptly.
        const t = (step + 0.5) / steps;
        const eased = smoothstep(if (descending) 1 - t else t);
        slot.* = ui.column(.{
            .height = edge / steps,
            .style = .{
                .background = canvas.Color.rgba8(6, 5, 5, @intFromFloat(@round(band_alpha * eased))),
                .radius = 0,
            },
        }, .{});
    }
    return ui.column(.{ .height = edge }, .{out});
}

fn smoothstep(t: f32) f32 {
    const x = std.math.clamp(t, 0, 1);
    return x * x * (3 - 2 * x);
}

pub fn overlayView(ui: *Ui, model: *const Model) Node {
    const overlay = &model.overlay;
    // The window is there before the screen starts and stays through
    // the fade-out's end, so an idle overlay paints literally nothing.
    if (!overlay.active) return blankView(ui);

    const entry = &overlay.entry;
    const opacity = overlay.opacity();
    const drift = overlay.driftY();
    const edge = app.bandSoftEdge(model.screen_width, model.screen_height);

    const headline = ui.text(.{
        .size = .display,
        .text_alignment = .center,
        .style = .{ .foreground = ink(entry.style.ink()) },
        .transform = canvas.Affine.translate(0, drift),
    }, shout(ui, entry.title.slice()));

    const caption = if (entry.subtitle.len == 0)
        ui.spacer(0)
    else
        ui.text(.{
            .text_alignment = .center,
            .style = .{ .foreground = canvas.Color.rgb8(0x9A, 0x92, 0x86) },
            .transform = canvas.Affine.translate(0, drift * 0.5),
        }, entry.subtitle.slice());

    var top_strips: [fade_steps]Node = undefined;
    var bottom_strips: [fade_steps]Node = undefined;

    // The window IS the bar (see `app.bandHeight`): the solid core grows
    // into whatever the two soft edges leave, and the type centres in
    // the core, which is centred in the bar because the edges match.
    return ui.column(.{ .grow = 1, .opacity = opacity }, .{
        softEdge(ui, top_strips[0..], edge, false),
        ui.column(.{
            .grow = 1,
            .main = .center,
            .cross = .center,
            .gap = 10,
            .style = .{ .background = band_ink, .radius = 0 },
        }, .{ headline, caption }),
        softEdge(ui, bottom_strips[0..], edge, true),
    });
}

/// Nothing at all — what the shell band paints in opaque mode, where
/// the declared window draws the banner instead.
pub fn blankView(ui: *Ui) Node {
    return ui.column(.{ .grow = 1 }, .{});
}

/// The opaque-mode window's tree: the same banner over a constant
/// charcoal floor. That window has no see-through to give, so the floor
/// stands in for the desktop the soft edges dissolve into — and like
/// the window clear it replaces, it does not fade with the ink.
pub fn opaqueOverlayView(ui: *Ui, model: *const Model) Node {
    return ui.column(.{
        .grow = 1,
        .style = .{ .background = canvas.Color.rgb8(0x12, 0x11, 0x10), .radius = 0 },
    }, .{overlayView(ui, model)});
}
