//! AI Souls — Dark Souls screens for your coding agent.
//!
//! Claude Code is the only agent wired up today, but nothing on disk is
//! named after it any more: the binary, the config directory and the
//! hook entries are all `ai-souls`. A pre-rename install is adopted on
//! first run (`Paths.adoptLegacyConfig`) and its hooks are still
//! recognised for removal (`hooks.our_binaries`).
//!
//! One binary, several jobs (see `cli.zig`). This file is the app: it
//! resolves the paths and the display size that `update` is not allowed
//! to look up, declares the shell window, and wires
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
const config_mod = @import("config.zig");
const overlay_style = @import("overlay_style.zig");
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

/// The on-disk identity: the binary's name, the tray/bundle key, and
/// the prefix `hooks.zig` recognises its own entries by.
const app_name = "ai-souls";
const bundle_id = "dev.native_sdk.ai-souls";

/// What a person sees.
const display_name = "AI Souls";

/// The overlay's window title. Never drawn — the window is chromeless
/// and, after `overlay_style`, absent from the taskbar and Alt+Tab. It
/// exists to be DISTINCT from the settings window's title, because that
/// is how `overlay_style` finds the right HWND.
const overlay_window_title = "AI Souls Overlay";
const overlay_window_title_w = std.unicode.utf8ToUtf16LeStringLiteral(overlay_window_title);

/// The settings window's title, for the same reason: a screen process
/// finds it by title to put it away. `FindWindowExW` matches the whole
/// title, so this and `overlay_window_title` never collide despite the
/// prefix.
const settings_window_title_w = std.unicode.utf8ToUtf16LeStringLiteral(display_name);

// ---------------------------------------------------------------- type
//
// EB Garamond, bundled rather than borrowed from the OS: a system serif
// would be a different face on macOS, and the whole point of the screen
// is that it looks the same everywhere. SIL Open Font License; the
// licence ships next to the file.
//
// It lives under `src/` rather than in `assets/` because `@embedFile`
// cannot reach outside the module root — and because that is the true
// distinction here: the sounds are loaded from disk at runtime, this is
// compiled into the binary.
const serif_ttf = @embedFile("fonts/EBGaramond-Regular.ttf");
const serif_font_id: canvas.FontId = canvas.min_registered_font_id;

const app_fonts = [_]SoulsApp.FontRegistration{.{
    .id = serif_font_id,
    .name = "EBGaramond-Regular.ttf",
    .ttf = serif_ttf,
}};

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
    .accessibility_label = "AI Souls settings",
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
    // Closing the settings window ends the process. The hooks do not
    // depend on it — each one starts its own.
    .close_policy = .quit,
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

    // App-wide, because the SDK resolves faces from tokens and tokens
    // are per-model, not per-window: there is no way to serif only the
    // overlay. Which is fine — a Souls app in Geist would be the odd
    // one out, not the settings pane in Garamond.
    design.typography.font_id = serif_font_id;

    // Only the overlay uses the display rung, and the whole banner is
    // measured off it (see `app.bandHeight`).
    design.typography.display_size = app.headlineSize(model.screen_width);

    return design;
}

// --------------------------------------------------- windows and views

/// The overlay window, declared for as long as the process lives —
/// which for a screen process is the length of one banner.
///
/// It used to be held open permanently by a resident app, on the belief
/// that a canvas window takes ~2.5s to reveal. That is not what the host
/// does. A canvas window is created ordered-out and shown on its first
/// successful present; the deferred-show deadline is only a safety net
/// for a window that never presents, and it is 1s, not 2.5. Measured on
/// Win32, SDK 0.8.1, five runs: window created 115-211 ms after the
/// request and VISIBLE at 191-318 ms, median 275 ms — the deadline is
/// never reached. Cheap enough that a screen can be a whole process,
/// which is what let the resident app go.
///
/// It is only as tall as the banner, not as tall as the display — see
/// `app.bandHeight`, where that turns out to be the whole framerate
/// budget.
fn declaredWindows(
    model: *const Model,
    scratch: *SoulsApp.WindowsScratch,
) []const SoulsApp.WindowDescriptor {
    scratch.windows[0] = .{
        .label = app.overlay_window_label,
        .canvas_label = app.overlay_canvas_label,
        .title = overlay_window_title,
        // Declared for the platforms that honour it. The Win32 host
        // passes CW_USEDEFAULT to CreateWindowExW and drops these on
        // the floor, so `overlay_style` re-centres the window there.
        .x = 0,
        .y = app.bandTop(model.screen_width, model.screen_height),
        .width = model.screen_width,
        .height = app.bandHeight(model.screen_width, model.screen_height),
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

// --------------------------------------------------------------- entry

pub fn initialModel(
    paths: paths_mod.Paths,
    size: screen.Size,
    opaque_overlay: bool,
    screen_only: ?config_mod.EventSettings,
) Model {
    return .{
        .paths = paths,
        .screen_width = size.width,
        .screen_height = size.height,
        .overlay_transparent = !opaque_overlay,
        .screen_only = screen_only,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var paths = paths_mod.Paths.resolve(io, init.environ_map);
    resolveAssetsRoot(io, &paths);
    // Before anything reads the config: an upgrade from a build that
    // spelled itself claude-souls should keep its settings.
    _ = paths.adoptLegacyConfig(io);

    // The CLI verbs run before anything GUI exists — `fire` in
    // particular sits on Claude Code's critical path and must not pay
    // for a window system it will never use.
    const args = init.minimal.args.toSlice(arena) catch &[_][]const u8{};
    const mode = cli.run(init.gpa, io, args, &paths);
    const screen_only: ?config_mod.EventSettings = switch (mode) {
        .handled_ok => return,
        // Exit rather than returning an error: the verb already printed
        // something a human can act on, and a Zig error trace stapled
        // underneath it would only be noise.
        .handled_failed => std.process.exit(1),
        .run_app => null,
        .run_screen => |entry| entry,
    };

    // The overlay window does not exist yet — this waits for it, then
    // fixes the two things the descriptor cannot express. See
    // `overlay_style` for why neither can be done declaratively.
    overlay_style.adopt(overlay_window_title_w);
    // This process exists to draw one banner. The settings window is
    // still the shell window the SDK insists on, so it is pushed out of
    // sight rather than opening over the very screen we were asked for.
    if (screen_only != null) overlay_style.hideSettings(settings_window_title_w);

    const app_state = try SoulsApp.create(std.heap.page_allocator, .{
        .name = app_name,
        .scene = shell_scene,
        .canvas_label = app.canvas_label,
        .fonts = &app_fonts,
        .tokens_fn = tokens,
        .view = views.settingsView,
        .window_view = windowView,
        .windows_fn = declaredWindows,
        .update_fx = app.update,
        .init_fx = app.init,
    });
    defer app_state.destroy();
    const opaque_overlay = if (init.environ_map.get("AI_SOULS_OPAQUE") orelse
        init.environ_map.get("CLAUDE_SOULS_OPAQUE")) |value|
        !std.mem.eql(u8, value, "0")
    else
        false;
    app_state.model = initialModel(
        paths,
        screen.primary(),
        opaque_overlay,
        screen_only,
    );

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

/// Find the directory `assets/sounds/*.mp3` actually lives in, and pin
/// it as an ABSOLUTE path.
///
/// This has to be absolute. The fallback is the manifest-relative
/// `assets/sounds/gong.mp3`, which every platform audio backend
/// resolves against the process working directory — so the sounds work
/// when the binary is launched from the project root and fail with
/// "that sound could not be played" from anywhere else, including from
/// a shortcut, from Explorer, and from a hook-spawned parent.
///
/// Everything probed here is derived from the executable's own path, so
/// the answer does not depend on where the app was started from:
///
///   - `<exe dir>`                  a packaged Windows or Linux build
///   - `<exe dir>/../Resources`     inside a macOS .app bundle
///   - `<exe dir>/..`, `../..`      `zig-out/bin` back up to the source
///                                  tree, which is what `native build`
///                                  leaves behind
fn resolveAssetsRoot(io: std.Io, paths: *paths_mod.Paths) void {
    const exe_dir = paths_mod.parent(paths.exe.slice());
    if (exe_dir.len == 0) return;

    const up_one = paths_mod.parent(exe_dir);
    const up_two = paths_mod.parent(up_one);

    var resources_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    const resources = if (up_one.len > 0)
        paths_mod.join(&resources_buffer, up_one, "Resources")
    else
        "";

    const candidates = [_][]const u8{ exe_dir, resources, up_one, up_two };

    const cwd = std.Io.Dir.cwd();
    var probe_buffer: [paths_mod.max_path_bytes]u8 = undefined;
    for (candidates) |root| {
        if (root.len == 0) continue;
        // `gong.mp3` stands in for the whole bank: they ship together.
        const probe = paths_mod.join(&probe_buffer, root, souls.Sound.gong.path());
        if (cwd.access(io, probe, .{})) |_| {
            paths.assets_root.set(root);
            return;
        } else |_| {}
    }
}

test {
    _ = @import("app.zig");
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("overlay_style.zig");
    _ = @import("hooks.zig");
    _ = @import("paths.zig");
    _ = @import("runtime_copy.zig");
    _ = @import("screen.zig");
    _ = @import("souls.zig");
    _ = @import("views.zig");
    _ = @import("tests.zig");
}
