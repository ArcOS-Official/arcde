// SPDX-FileCopyrightText: © 2021 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const TextInput = @This();

const std = @import("std");
const assert = std.debug.assert;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const util = @import("util.zig");

const InputRelay = @import("InputRelay.zig");
const Seat = @import("Seat.zig");

const log = std.log.scoped(.input);

link: wl.list.Link,

wlr_text_input: *wlr.TextInputV3,

enable: wl.Listener(void) = .init(handleEnable),
commit: wl.Listener(void) = .init(handleCommit),
disable: wl.Listener(void) = .init(handleDisable),
destroy: wl.Listener(void) = .init(handleDestroy),

pub fn create(wlr_text_input: *wlr.TextInputV3) !void {
    const seat: *Seat = @ptrCast(@alignCast(wlr_text_input.seat.data));

    const text_input = try util.gpa.create(TextInput);

    log.debug("new text input on seat {s}", .{seat.wlr_seat.name});

    text_input.* = .{
        .link = undefined,
        .wlr_text_input = wlr_text_input,
    };

    seat.relay.text_inputs.append(text_input);

    wlr_text_input.events.enable.add(&text_input.enable);
    wlr_text_input.events.commit.add(&text_input.commit);
    wlr_text_input.events.disable.add(&text_input.disable);
    wlr_text_input.events.destroy.add(&text_input.destroy);

    // Objects created after the surface already has keyboard focus would
    // otherwise never receive enter (focus() only runs on focus changes),
    // so every later enable/commit would look "unfocused" to wlroots and to
    // us. Send enter immediately when this client owns the focused surface.
    if (seat.focused.surface()) |surface| {
        if (wlr_text_input.resource.getClient() == surface.resource.getClient()) {
            wlr_text_input.sendEnter(surface);
        }
    }
}

fn handleEnable(listener: *wl.Listener(void)) void {
    const text_input: *TextInput = @fieldParentPtr("enable", listener);
    const seat: *Seat = @ptrCast(@alignCast(text_input.wlr_text_input.seat.data));

    const focused = text_input.wlr_text_input.focused_surface != null;
    if (!focused) {
        // Some clients (e.g. Chromium) enable before processing the enter event.
        log.debug("text input enabled without focus, tracking anyway", .{});
    }

    // Only one text input per seat may be enabled at a time (protocol).
    if (seat.relay.text_input) |currently_enabled| {
        if (text_input != currently_enabled) {
            const old_focused = currently_enabled.wlr_text_input.focused_surface != null;
            if (focused and !old_focused) {
                // The tracked input went stale (e.g. its surface lost focus
                // without a disable); hand over to the focused object so IME
                // keeps working for the focused surface.
                log.debug("text input enable handed over to focused object", .{});
                seat.relay.disableTextInput();
            } else {
                // Keep the current one: an eager background client must not
                // steal IME state from the focused surface.
                log.debug("client enabled more than one text input on a single seat, ignoring request", .{});
                return;
            }
        }
    }

    seat.relay.text_input = text_input;

    if (seat.relay.input_method) |input_method| {
        input_method.sendActivate();
        seat.relay.sendInputMethodState();
    }
}

fn handleCommit(listener: *wl.Listener(void)) void {
    const text_input: *TextInput = @fieldParentPtr("commit", listener);
    const seat: *Seat = @ptrCast(@alignCast(text_input.wlr_text_input.seat.data));

    if (seat.relay.text_input != text_input) {
        // Not enabled (stale client state or race with focus change).
        // Debug, not err: without this every keystroke in a text field with
        // no input method running spammed the log.
        log.debug("inactive text input commit ignored", .{});
        return;
    }

    if (seat.relay.input_method != null) {
        seat.relay.sendInputMethodState();
    }
}

fn handleDisable(listener: *wl.Listener(void)) void {
    const text_input: *TextInput = @fieldParentPtr("disable", listener);
    const seat: *Seat = @ptrCast(@alignCast(text_input.wlr_text_input.seat.data));

    if (seat.relay.text_input == text_input) {
        seat.relay.disableTextInput();
    }
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const text_input: *TextInput = @fieldParentPtr("destroy", listener);
    const seat: *Seat = @ptrCast(@alignCast(text_input.wlr_text_input.seat.data));

    if (seat.relay.text_input == text_input) {
        seat.relay.disableTextInput();
    }

    text_input.enable.link.remove();
    text_input.commit.link.remove();
    text_input.disable.link.remove();
    text_input.destroy.link.remove();

    text_input.link.remove();
    util.gpa.destroy(text_input);
}
