//! Both windows' widget trees.
//!
//! `settingsView` builds the app's shell window; `overlayView` builds
//! the screen that flashes over everything else. They share a model and
//! nothing else — the overlay has no controls at all, because its window
//! is click-through and could not receive a press if it wanted one.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

const app = @import("app.zig");
const config_mod = @import("config.zig");
const souls = @import("souls.zig");
const throttle = @import("throttle.zig");

const Model = app.Model;
const Msg = app.Msg;
pub const Ui = canvas.Ui(Msg);
const Node = Ui.Node;

fn ink(rgb: [3]u8) canvas.Color {
    return canvas.Color.rgb8(rgb[0], rgb[1], rgb[2]);
}

// ------------------------------------------------------------ overlay

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
    // The window outlives any one screen (see `declaredWindows`), so an
    // idle overlay paints literally nothing.
    if (!overlay.active) return ui.column(.{ .grow = 1 }, .{});

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

// ----------------------------------------------------------- settings

pub fn settingsView(ui: *Ui, model: *const Model) Node {
    return ui.column(.{ .grow = 1 }, .{
        header(ui, model),
        ui.el(.separator, .{}, .{}),
        ui.row(.{ .grow = 1 }, .{
            catalogPane(ui, model),
            ui.el(.separator, .{}, .{}),
            detailPane(ui, model),
        }),
        ui.el(.separator, .{}, .{}),
        footer(ui, model),
    });
}

fn header(ui: *Ui, model: *const Model) Node {
    return ui.row(.{ .padding = 16, .gap = 12, .cross = .center }, .{
        ui.text(.{ .size = .heading }, "AI Souls"),
        // Claude Code is the only agent wired up so far; naming it here
        // is the honest version of a product name that does not.
        ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Claude Code"),
        ui.spacer(1),
        ui.el(.badge, .{
            .text = ui.fmt("{d} of {d} armed", .{ model.enabledCount(), souls.event_count }),
        }, .{}),
    });
}

fn catalogPane(ui: *Ui, model: *const Model) Node {
    var rows: [souls.event_count]Node = undefined;
    for (souls.events, 0..) |event, index| {
        const entry = &model.config.events[index];
        rows[index] = ui.listItem(.{
            .key = .{ .index = index },
            .selected = index == model.selected,
            .on_press = Msg{ .select = index },
            // A lit ember versus a dark one.
            .icon = if (entry.enabled) "circle-dot" else "moon",
            .semantics = .{
                .role = .listitem,
                .list_item_index = @intCast(index),
                .list_item_count = @intCast(souls.event_count),
            },
        }, event.label);
    }

    return ui.scroll(.{ .width = 236 }, .{
        ui.column(.{ .padding = 8, .gap = 2 }, .{rows[0..]}),
    });
}

fn detailPane(ui: *Ui, model: *const Model) Node {
    const event = model.selectedEvent();
    const entry = model.selectedSettings();

    const volume_fraction: f32 = @as(f32, @floatFromInt(entry.volume)) / 100.0;
    const duration_span: f32 = @floatFromInt(config_mod.max_duration_ms - config_mod.min_duration_ms);
    const duration_fraction: f32 =
        @as(f32, @floatFromInt(entry.duration_ms - config_mod.min_duration_ms)) / duration_span;

    return ui.scroll(.{ .grow = 1 }, .{
        ui.column(.{ .padding = 20, .gap = 16 }, .{
            ui.column(.{ .gap = 4 }, .{
                ui.text(.{ .size = .lg }, event.label),
                ui.text(.{
                    .wrap = true,
                    .style_tokens = .{ .foreground = .text_muted },
                }, event.blurb),
                ui.text(.{
                    .wrap = true,
                    .style_tokens = .{ .foreground = .text_muted },
                }, ui.fmt("hook: {s}{s}{s}", .{
                    event.hook_event,
                    if (event.matcher.len > 0) " · matcher " else "",
                    // `api_error`'s real matcher is an eight-way
                    // alternation; nobody needs to read that here.
                    if (event.matcher_label.len > 0) event.matcher_label else event.matcher,
                })),
                // Only the events with a window of their own. That no
                // screen ever draws over another is true of all of them
                // and belongs in the README, not on every row.
                if (event.throttle_ms == 0) ui.spacer(0) else ui.text(.{
                    .wrap = true,
                    .style_tokens = .{ .foreground = .text_muted },
                }, ui.fmt("This one arrives in bursts — at most one screen every {d}s.", .{
                    event.throttle_ms / 1000,
                })),
                // Counted, not numbered: the rank only means anything
                // against the other rows, and nobody is going to hold
                // sixteen integers in their head to read one of them.
                // Absent where the ranking cannot fire at all, rather
                // than promising something the platform will not do.
                if (!throttle.can_preempt) ui.spacer(0) else ui.text(.{
                    .wrap = true,
                    .style_tokens = .{ .foreground = .text_muted },
                }, ui.fmt("Wins against {d} of the other {d} events when two land at once.", .{
                    outrankedCount(event.priority),
                    souls.event_count - 1,
                })),
            }),

            ui.row(.{ .gap = 10, .cross = .center }, .{
                ui.el(.switch_control, .{
                    .checked = entry.enabled,
                    .on_toggle = Msg.toggle_enabled,
                    .semantics = .{ .label = "Show a screen for this event" },
                }, .{}),
                ui.text(.{ .grow = 1 }, if (entry.enabled)
                    "Armed — a hook will be installed for this."
                else
                    "Silent — no hook for this event."),
            }),

            ui.el(.separator, .{}, .{}),

            fieldLabel(ui, "Headline"),
            ui.textField(.{
                .text = entry.title.slice(),
                // The shipped headline is the event's own name; the
                // placeholder says so rather than inventing a third
                // string to explain it.
                .placeholder = event.default_title,
                .on_input = Ui.inputMsg(.title_edit),
                .semantics = .{ .label = "Headline" },
            }),

            fieldLabel(ui, "Subtitle"),
            ui.textField(.{
                .text = entry.subtitle.slice(),
                .placeholder = "(optional)",
                .on_input = Ui.inputMsg(.subtitle_edit),
                .semantics = .{ .label = "Subtitle" },
            }),

            ui.el(.separator, .{}, .{}),

            pickerRow(
                ui,
                "Style",
                entry.style.label(),
                Msg.cycle_style_back,
                Msg.cycle_style,
                swatch(ui, entry.style),
            ),
            pickerRow(
                ui,
                "Sound",
                entry.sound.label(),
                Msg.cycle_sound_back,
                Msg.cycle_sound,
                ui.spacer(0),
            ),

            sliderRow(
                ui,
                ui.fmt("Volume · {d}%", .{entry.volume}),
                volume_fraction,
                Ui.valueMsg(.volume_changed),
            ),
            // Cycling the sound deliberately leaves the duration alone —
            // it is the user's number once they have touched it — so
            // the label is where a sound that outlasts its screen owns
            // up to being cut off. "Reset to default" sizes it to fit.
            sliderRow(
                ui,
                if (entry.sound.durationMs() > entry.duration_ms) ui.fmt(
                    "On screen · {d}.{d:0>1}s — {s} runs {d}.{d:0>1}s and gets cut off",
                    .{
                        entry.duration_ms / 1000,
                        (entry.duration_ms % 1000) / 100,
                        entry.sound.label(),
                        entry.sound.durationMs() / 1000,
                        (entry.sound.durationMs() % 1000) / 100,
                    },
                ) else ui.fmt("On screen · {d}.{d:0>1}s", .{
                    entry.duration_ms / 1000,
                    (entry.duration_ms % 1000) / 100,
                }),
                duration_fraction,
                Ui.valueMsg(.duration_changed),
            ),

            ui.row(.{ .gap = 8 }, .{
                ui.button(.{ .variant = .secondary, .on_press = Msg.preview, .icon = "play" }, "Preview"),
                ui.button(.{ .variant = .ghost, .on_press = Msg.reset_event }, "Reset to default"),
            }),
        }),
    });
}

/// How many catalog rows this rank strictly beats. Ties are not wins —
/// two screens of equal rank leave each other alone — so this counts
/// the same way `throttle.outranks` decides.
fn outrankedCount(priority: u8) usize {
    var beaten: usize = 0;
    for (souls.events) |other| {
        if (other.priority < priority) beaten += 1;
    }
    return beaten;
}

fn fieldLabel(ui: *Ui, text: []const u8) Node {
    return ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, text);
}

fn swatch(ui: *Ui, style: souls.Style) Node {
    return ui.el(.panel, .{
        .width = 22,
        .height = 22,
        .style = .{ .background = ink(style.ink()), .radius = 4 },
        .semantics = .{ .label = "Style colour" },
    }, .{});
}

fn pickerRow(
    ui: *Ui,
    label: []const u8,
    value: []const u8,
    back: Msg,
    forward: Msg,
    trailing: Node,
) Node {
    return ui.row(.{ .gap = 10, .cross = .center }, .{
        ui.text(.{ .width = 60, .style_tokens = .{ .foreground = .text_muted } }, label),
        ui.button(.{
            .size = .sm,
            .variant = .outline,
            .icon = "chevron-left",
            .on_press = back,
            .semantics = .{ .label = "Previous" },
        }, ""),
        ui.text(.{ .width = 96, .text_alignment = .center }, value),
        ui.button(.{
            .size = .sm,
            .variant = .outline,
            .icon = "chevron-right",
            .on_press = forward,
            .semantics = .{ .label = "Next" },
        }, ""),
        trailing,
        ui.spacer(1),
    });
}

fn sliderRow(ui: *Ui, label: []const u8, fraction: f32, on_value: Ui.ValueMsgFn) Node {
    return ui.column(.{ .gap = 6 }, .{
        fieldLabel(ui, label),
        ui.el(.slider, .{
            .value = std.math.clamp(fraction, 0, 1),
            .on_value = on_value,
            .semantics = .{ .label = label },
        }, .{}),
    });
}

fn footer(ui: *Ui, model: *const Model) Node {
    return ui.column(.{ .padding = 12, .gap = 8 }, .{
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.button(.{
                .variant = .primary,
                .disabled = model.hooks_busy,
                .on_press = Msg.install_hooks,
                .icon = "save",
            }, "Write hooks"),
            ui.button(.{
                .variant = .outline,
                .disabled = model.hooks_busy,
                .on_press = Msg.uninstall_hooks,
            }, "Remove all hooks"),
            ui.spacer(1),
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "~/.claude/settings.json"),
        }),
        ui.el(.status_bar, .{
            .text = if (model.status.len > 0)
                model.status.slice()
            else
                "Settings save themselves. Write hooks after changing which events are armed.",
        }, .{}),
    });
}
