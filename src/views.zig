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

const Model = app.Model;
const Msg = app.Msg;
pub const Ui = canvas.Ui(Msg);
const Node = Ui.Node;

fn ink(rgb: [3]u8) canvas.Color {
    return canvas.Color.rgb8(rgb[0], rgb[1], rgb[2]);
}

// ------------------------------------------------------------ overlay

/// The band behind the headline. Dark enough to read against a bright
/// editor, translucent enough that you can still see what you were
/// doing.
const band_ink = canvas.Color.rgba8(6, 5, 5, 214);
const band_edge = canvas.Color.rgba8(0, 0, 0, 0);

pub fn overlayView(ui: *Ui, model: *const Model) Node {
    const overlay = &model.overlay;
    // The window outlives any one screen (see `declaredWindows`), so an
    // idle overlay paints literally nothing.
    if (!overlay.active) return ui.column(.{ .grow = 1 }, .{});

    const entry = &model.config.events[overlay.event_index];
    const opacity = overlay.opacity();
    const drift = overlay.driftY();
    const band_height = @max(150, @min(320, model.screen_height * 0.26));

    const headline = ui.text(.{
        .size = .display,
        .text_alignment = .center,
        .style = .{ .foreground = ink(entry.style.ink()) },
        .transform = canvas.Affine.translate(0, drift),
    }, entry.title.slice());

    const caption = if (entry.subtitle.len == 0)
        ui.spacer(0)
    else
        ui.text(.{
            .text_alignment = .center,
            .style = .{ .foreground = canvas.Color.rgb8(0x9A, 0x92, 0x86) },
            .transform = canvas.Affine.translate(0, drift * 0.5),
        }, entry.subtitle.slice());

    // Hairlines above and below the band: the Souls screens are framed,
    // not just tinted.
    const rule_color = canvas.Color.rgba8(
        entry.style.ink()[0],
        entry.style.ink()[1],
        entry.style.ink()[2],
        90,
    );

    const band = ui.column(.{
        .height = band_height,
        .main = .center,
        .cross = .center,
        .gap = 10,
        .padding = 24,
        .opacity = opacity,
        .style = .{ .background = band_ink, .radius = 0 },
    }, .{
        ui.el(.separator, .{ .style = .{ .background = rule_color } }, .{}),
        ui.spacer(1),
        headline,
        caption,
        ui.spacer(1),
        ui.el(.separator, .{ .style = .{ .background = rule_color } }, .{}),
    });

    return ui.column(.{
        .grow = 1,
        .main = .center,
        .cross = .stretch,
        .style = .{ .background = band_edge },
    }, .{band});
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
        ui.text(.{ .size = .heading }, "Claude Souls"),
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
                    .style_tokens = .{ .foreground = .text_muted },
                }, ui.fmt("hook: {s}{s}{s}", .{
                    event.hook_event,
                    if (event.matcher.len > 0) " · matcher " else "",
                    event.matcher,
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
                .placeholder = "YOU DIED",
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
            sliderRow(
                ui,
                ui.fmt("On screen · {d}.{d:0>1}s", .{
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
