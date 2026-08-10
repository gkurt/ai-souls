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
//! to look up, declares the band as the app's one shell window, and
//! wires the banner view onto the `UiApp` loop.

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
const console = @import("console.zig");
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

/// The banner's window title. Never drawn — the window is chromeless
/// and, after `overlay_style`, absent from the taskbar and Alt+Tab. It
/// exists to be FINDABLE: it is how `overlay_style` names the right
/// HWND, and how `dismissOthers` hunts the banners of other processes.
///
/// Two of them, because opaque mode draws in a second, declared window
/// (see `declaredWindows`) that has to be nameable without also naming
/// the empty shell band sitting underneath it.
const screen_window_title = "AI Souls Screen";
const opaque_window_title = "AI Souls Overlay";

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

const app_permissions = [_][]const u8{
    native_sdk.security.permission_view,
};

/// The shell window's label — `app.zon`'s startup window, which the
/// scene's first window adopts when it loads.
const shell_window_label = "main";

const band_views = [_]native_sdk.ShellView{.{
    .label = app.overlay_canvas_label,
    .kind = .gpu_surface,
    .fill = true,
    .role = "Banner",
    .accessibility_label = "AI Souls screen",
    .gpu_pixel_format = .bgra8_unorm,
    .gpu_present_mode = .timer,
    // The other half of the window's `transparent`: pixels the view
    // does not ink reach through to the desktop.
    .gpu_alpha_mode = .premultiplied,
    .gpu_color_space = .srgb,
    .gpu_vsync = true,
}};

/// The band, sized for the display the banner is about to draw on.
///
/// The manifest's copy of this window carries the flags the host fixes
/// at create time — chromeless, transparent, topmost, click-through,
/// non-activating — because the host creates the startup window before
/// any of this code runs. What the SCENE contributes is the size: it is
/// re-applied when the scene loads, and it is the one thing the
/// manifest cannot know, because it depends on the display.
fn bandWindow(display: screen.Display) native_sdk.ShellWindow {
    return .{
        .label = shell_window_label,
        .title = screen_window_title,
        .width = display.width,
        .height = app.bandHeight(display.width, display.height),
        .resizable = false,
        .restore_state = false,
        .titlebar = .chromeless,
        .transparent = true,
        .always_on_top = true,
        .click_through = true,
        .activate_on_show = false,
        .close_policy = .quit,
        .views = &band_views,
    };
}

// ------------------------------------------------------------- theming

/// A display rung sized for the banner headline, the serif on it, and
/// the charcoal an opaque-mode window clears to.
fn tokens(model: *const Model) canvas.DesignTokens {
    var design = canvas.DesignTokens.theme(.{
        .color_scheme = .dark,
        .pack = .geist,
    });

    // The transparent band never shows this; the opaque-mode window is
    // exactly this behind the banner's own translucent ink.
    design.colors.background = canvas.Color.rgb8(0x12, 0x11, 0x10);

    design.typography.font_id = serif_font_id;

    // The whole banner is measured off the display rung — see
    // `app.bandHeight`.
    design.typography.display_size = app.headlineSize(model.screen_width);

    return design;
}

// --------------------------------------------------- windows and views

/// The opaque-mode fallback window — the ONLY window this app still
/// declares from the model.
///
/// The band's shell window is transparent by manifest, and the manifest
/// is comptime: no process can undo it. So when `AI_SOULS_OPAQUE=1`
/// says this machine cannot present a layered window, the banner draws
/// in this second, opaque window instead, and the shell band paints
/// nothing — invisible glass with a solid banner over it.
///
/// In transparent mode (everyone else) this declares nothing, and the
/// process has exactly one window.
fn declaredWindows(
    model: *const Model,
    scratch: *SoulsApp.WindowsScratch,
) []const SoulsApp.WindowDescriptor {
    if (model.overlay_transparent) return scratch.windows[0..0];
    scratch.windows[0] = .{
        .label = app.overlay_window_label,
        .canvas_label = app.opaque_canvas_label,
        // Distinct from the shell band's title, so the watchers can
        // tell the two apart.
        .title = opaque_window_title,
        // Declared, and applied by neither host: Win32 passes
        // CW_USEDEFAULT to CreateWindowExW, and macOS takes the size
        // while leaving the origin to AppKit. `overlay_style` moves the
        // window on both — see `bandFrame`.
        .x = 0,
        .y = app.bandTop(model.screen_width, model.screen_height),
        .width = model.screen_width,
        .height = app.bandHeight(model.screen_width, model.screen_height),
        .resizable = false,
        .titlebar = .chromeless,
        .transparent = false,
        .always_on_top = true,
        // The whole point: clicks land on whatever is underneath.
        .click_through = true,
        // And it must never steal focus from the editor you are typing
        // into when it appears.
        .activate_on_show = false,
    };
    return scratch.windows[0..1];
}

/// The same band `declaredWindows` asks for, on the display it is meant
/// for, in the space macOS places windows in: AppKit's global points,
/// whose origin is the bottom-left corner of the primary display. So the
/// descriptor's `y` — a drop from the top of the display — has to be
/// measured back up from that display's own bottom edge instead.
fn bandFrame(display: screen.Display) overlay_style.Frame {
    const height = app.bandHeight(display.width, display.height);
    const top = app.bandTop(display.width, display.height);
    return .{
        .x = display.x,
        .y = display.y + display.height - top - height,
        .width = display.width,
        .height = height,
    };
}

fn windowView(ui: *AppUi, model: *const Model, window_label: []const u8) AppUi.Node {
    if (std.mem.eql(u8, window_label, app.overlay_window_label)) {
        return views.overlayView(ui, model);
    }
    return mainView(ui, model);
}

/// The main canvas: the band itself — except in opaque mode, where the
/// declared window draws the banner and this transparent one must not
/// paint a second copy underneath it.
fn mainView(ui: *AppUi, model: *const Model) AppUi.Node {
    if (!model.overlay_transparent) return views.blankView(ui);
    return views.overlayView(ui, model);
}

// --------------------------------------------------------------- entry

pub fn initialModel(
    paths: paths_mod.Paths,
    display: screen.Display,
    opaque_overlay: bool,
    entry: config_mod.EventSettings,
) Model {
    return .{
        .paths = paths,
        .screen_width = display.width,
        .screen_height = display.height,
        .overlay_transparent = !opaque_overlay,
        .entry = entry,
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
    // Every verb has said everything it is going to say by now, so the
    // console we may have borrowed to say it in goes back as we found it.
    console.restore();
    const entry: config_mod.EventSettings = switch (mode) {
        .handled_ok => return,
        // Exit rather than returning an error: the verb already printed
        // something a human can act on, and a Zig error trace stapled
        // underneath it would only be noise.
        .handled_failed => std.process.exit(1),
        .run_screen => |entry| entry,
    };

    // Before the window exists, because the scene and `adopt` both have
    // to know where to put it, and `update` may not ask the OS anything.
    const display = screen.active();

    // Getting this far with a banner already up means the throttle
    // decided this screen outranks it (see `throttle.zig`), so the
    // incumbent comes down now rather than being drawn over. First,
    // because the glass should be clear before ours is revealed. Both
    // titles, because an opaque-mode process wears the second.
    overlay_style.dismissOthers(screen_window_title);
    overlay_style.dismissOthers(opaque_window_title);
    // A banner is not an app: no Dock tile, no app switcher entry, and
    // never the thing you are typing into.
    overlay_style.hideFromSwitcher();

    const opaque_overlay = if (init.environ_map.get("AI_SOULS_OPAQUE") orelse
        init.environ_map.get("CLAUDE_SOULS_OPAQUE")) |value|
        !std.mem.eql(u8, value, "0")
    else
        false;

    // The window this waits for does not exist yet — it fixes what the
    // descriptor cannot express. See `overlay_style` for why none of it
    // can be done declaratively.
    const band = bandFrame(display);
    if (opaque_overlay) {
        overlay_style.adopt(opaque_window_title, band);
        // The shell band is empty glass in this mode, but a chromeless
        // popup still gets a taskbar button on Windows.
        overlay_style.excludeFromTaskbar(screen_window_title);
    } else {
        overlay_style.adopt(screen_window_title, band);
    }

    const shell_windows = [_]native_sdk.ShellWindow{bandWindow(display)};
    const app_state = try SoulsApp.create(std.heap.page_allocator, .{
        .name = app_name,
        .scene = .{ .windows = &shell_windows },
        .canvas_label = app.overlay_canvas_label,
        .fonts = &app_fonts,
        .tokens_fn = tokens,
        .view = mainView,
        .window_view = windowView,
        .windows_fn = declaredWindows,
        .update_fx = app.update,
        .init_fx = app.init,
    });
    defer app_state.destroy();
    app_state.model = initialModel(
        paths,
        display,
        opaque_overlay,
        entry,
    );

    try runner.runWithOptions(app_state.app(), .{
        .app_name = app_name,
        .window_title = screen_window_title,
        .bundle_id = bundle_id,
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(
            0,
            0,
            display.width,
            app.bandHeight(display.width, display.height),
        ),
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
    _ = @import("console.zig");
    _ = @import("overlay_style.zig");
    _ = @import("hooks.zig");
    _ = @import("paths.zig");
    _ = @import("runtime_copy.zig");
    _ = @import("screen.zig");
    _ = @import("souls.zig");
    _ = @import("throttle.zig");
    _ = @import("views.zig");
    _ = @import("tests.zig");
}
