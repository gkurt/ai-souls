//! Claude Souls — Dark Souls screens for Claude Code.
//!
//! One binary, three jobs (see `cli.zig`). This file is the app: it
//! resolves the paths and the display size that `update` is not allowed
//! to look up, declares the shell window and the tray item, and wires
//! the two views onto the `UiApp` loop.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const platform = native_sdk.platform;

const app = @import("app.zig");
const cli = @import("cli.zig");
const paths_mod = @import("paths.zig");
const screen = @import("screen.zig");
const souls = @import("souls.zig");
const views = @import("views.zig");

// The UiApp contract: these names are what the runtime and the tooling
// look for on the app root.
pub const Model = app.Model;
pub const Msg = app.Msg;
pub const Effects = app.Effects;
pub const update = app.update;
pub const AppUi = views.Ui;

const SoulsApp = native_sdk.UiApp(Model, Msg);

const app_name = "claude-souls";
const display_name = "Claude Souls";
const bundle_id = "dev.native_sdk.claude-souls";

const settings_width: f32 = 900;
const settings_height: f32 = 640;

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
};

const shell_views = [_]native_sdk.ShellView{.{
    .label = app.canvas_label,
    .kind = .gpu_surface,
    .fill = true,
    .role = "Settings canvas",
    .accessibility_label = "Claude Souls settings",
    .gpu_pixel_format = .bgra8_unorm,
    .gpu_present_mode = .timer,
    .gpu_alpha_mode = .@"opaque",
    .gpu_color_space = .srgb,
    .gpu_vsync = true,
}};

const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = app.settings_window_label,
    .title = display_name,
    .width = settings_width,
    .height = settings_height,
    .min_width = 780,
    .min_height = 520,
    .restore_state = false,
    .restore_policy = .center_on_primary,
    // Closing the window must not stop the hooks from firing — the app
    // lives in the tray and the window comes back from there.
    .close_policy = .hide,
    .views = &shell_views,
}};

const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------- theming

/// The app owns its palette: a Souls-adjacent charcoal register, and a
/// display rung sized for the overlay headline rather than for a hero
/// numeral.
fn tokens(model: *const Model) canvas.DesignTokens {
    var design = canvas.DesignTokens.theme(.{
        .color_scheme = .dark,
        .pack = .geist,
    });

    design.colors.background = canvas.Color.rgb8(0x12, 0x11, 0x10);
    design.colors.surface = canvas.Color.rgb8(0x1A, 0x18, 0x16);
    design.colors.surface_subtle = canvas.Color.rgb8(0x21, 0x1E, 0x1B);
    design.colors.surface_pressed = canvas.Color.rgb8(0x2B, 0x27, 0x22);
    design.colors.border = canvas.Color.rgb8(0x35, 0x30, 0x2A);
    design.colors.text = canvas.Color.rgb8(0xE8, 0xE1, 0xD4);
    design.colors.text_muted = canvas.Color.rgb8(0x93, 0x8B, 0x7C);
    design.colors.accent = canvas.Color.rgb8(0xC9, 0xA2, 0x27);
    design.colors.accent_text = canvas.Color.rgb8(0x14, 0x12, 0x0E);
    design.colors.focus_ring = canvas.Color.rgb8(0xC9, 0xA2, 0x27);
    design.colors.destructive = canvas.Color.rgb8(0x8B, 0x14, 0x14);

    // Only the overlay uses the display rung, so it can be sized for a
    // full-width banner. Scale with the screen, then keep it sane.
    design.typography.display_size = std.math.clamp(model.screen_width * 0.055, 40, 104);

    return design;
}

// --------------------------------------------------- windows and views

/// The overlay window is declared for the whole life of the app, not
/// just while a screen is playing.
///
/// The SDK's model is presence-is-visibility, and declaring it on
/// demand is the obvious shape — but a canvas window is created
/// ordered-out and only revealed on its first present, and on the Win32
/// host that reveal lands ~2.5s late (the host's deferred-show safety
/// deadline). A 2.6s screen would spend its whole life invisible and
/// flash once as it died. Holding one window open and letting the view
/// be EMPTY when idle pays that latency once, at startup, and every
/// screen after it is instant.
///
/// An idle overlay is a fully transparent, click-through, borderless
/// window that paints nothing, so nothing about it is observable.
fn declaredWindows(
    model: *const Model,
    scratch: *SoulsApp.WindowsScratch,
) []const SoulsApp.WindowDescriptor {
    scratch.windows[0] = .{
        .label = app.overlay_window_label,
        .canvas_label = app.overlay_canvas_label,
        .title = display_name,
        .x = 0,
        .y = 0,
        .width = model.screen_width,
        .height = model.screen_height,
        .resizable = false,
        // No caption, no frame — Windows also requires a chromeless
        // style before it will accept a transparent surface.
        .titlebar = .chromeless,
        .transparent = model.overlay_transparent,
        .always_on_top = true,
        // The whole point: clicks land on whatever is underneath.
        .click_through = true,
        // And it must never steal focus from the editor you are typing
        // into when it appears.
        .activate_on_show = false,
    };
    return scratch.windows[0..1];
}

fn windowView(ui: *AppUi, model: *const Model, window_label: []const u8) AppUi.Node {
    if (std.mem.eql(u8, window_label, app.overlay_window_label)) {
        return views.overlayView(ui, model);
    }
    return views.settingsView(ui, model);
}

// ------------------------------------------------------------- the tray

const tray_open_command = "tray.open";
const tray_quit_command = "tray.quit";

fn statusItem(
    model: *const Model,
    scratch: *SoulsApp.StatusItemScratch,
) SoulsApp.StatusItemState {
    scratch.items[0] = .{ .id = 1, .label = "Open Claude Souls", .command = tray_open_command };
    scratch.items[1] = .{ .id = 2, .label = "Quit", .command = tray_quit_command };
    const title = std.fmt.bufPrint(
        &scratch.title_buffer,
        "Souls {d}",
        .{model.enabledCount()},
    ) catch display_name;
    return .{ .title = title, .items = scratch.items[0..2] };
}

fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, tray_open_command)) return Msg.open_settings;
    if (std.mem.eql(u8, name, tray_quit_command)) return Msg.quit_app;
    return null;
}

// --------------------------------------------------------------- entry

pub fn initialModel(paths: paths_mod.Paths, size: screen.Size, opaque_overlay: bool) Model {
    return .{
        .paths = paths,
        .screen_width = size.width,
        .screen_height = size.height,
        .overlay_transparent = !opaque_overlay,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var paths = paths_mod.Paths.resolve(io, init.environ_map);
    resolveAssetsRoot(io, &paths);

    // The CLI verbs run before anything GUI exists — `fire` in
    // particular sits on Claude Code's critical path and must not pay
    // for a window system it will never use.
    const args = init.minimal.args.toSlice(arena) catch &[_][]const u8{};
    switch (cli.run(init.gpa, io, args, &paths)) {
        .handled_ok => return,
        // Exit rather than returning an error: the verb already printed
        // something a human can act on, and a Zig error trace stapled
        // underneath it would only be noise.
        .handled_failed => std.process.exit(1),
        .run_app => {},
    }

    const app_state = try SoulsApp.create(std.heap.page_allocator, .{
        .name = app_name,
        .scene = shell_scene,
        .canvas_label = app.canvas_label,
        .tokens_fn = tokens,
        .view = views.settingsView,
        .window_view = windowView,
        .windows_fn = declaredWindows,
        .status_item_fn = statusItem,
        .on_command = onCommand,
        .update_fx = app.update,
        .init_fx = app.init,
    });
    defer app_state.destroy();
    const opaque_overlay = if (init.environ_map.get("CLAUDE_SOULS_OPAQUE")) |value|
        !std.mem.eql(u8, value, "0")
    else
        false;
    app_state.model = initialModel(paths, screen.primary(), opaque_overlay);

    try runner.runWithOptions(app_state.app(), .{
        .app_name = app_name,
        .window_title = display_name,
        .bundle_id = bundle_id,
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, settings_width, settings_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

/// A dev run finds `assets/` in the working directory; a packaged
/// Windows or Linux build finds it next to the executable. macOS
/// resolves bundle-relative audio paths itself, so leaving the root
/// empty is right there too.
fn resolveAssetsRoot(io: std.Io, paths: *paths_mod.Paths) void {
    const exe_dir = paths_mod.parent(paths.exe.slice());
    if (exe_dir.len == 0) return;

    var buffer: [paths_mod.max_path_bytes]u8 = undefined;
    const probe = paths_mod.join(&buffer, exe_dir, souls.Sound.gong.path());
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, probe, .{})) |_| {
        paths.assets_root.set(exe_dir);
    } else |_| {}
}

test {
    _ = @import("app.zig");
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("hooks.zig");
    _ = @import("paths.zig");
    _ = @import("screen.zig");
    _ = @import("souls.zig");
    _ = @import("views.zig");
    _ = @import("tests.zig");
}
