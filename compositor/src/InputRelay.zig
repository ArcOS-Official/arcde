// SPDX-FileCopyrightText: © 2021 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const InputRelay = @This();

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const TextInput = @import("TextInput.zig");
const InputPopup = @import("InputPopup.zig");
const Seat = @import("Seat.zig");
const Keyboard = @import("Keyboard.zig");

const log = std.log.scoped(.input);

/// List of all text input objects for the seat.
/// Multiple text input objects may be created per seat, even multiple from the same client.
/// However, only one text input per seat may be enabled at a time.
text_inputs: wl.list.Head(TextInput, .link),

/// The input method currently in use for this seat.
/// Only one input method per seat may be used at a time and if one is
/// already in use new input methods are ignored.
input_method: ?*wlr.InputMethodV2 = null,
input_popups: wl.list.Head(InputPopup, .link),
/// The currently enabled text input for the currently focused surface.
/// May be non-null even when there is no input method; in that case commits
/// are simply tracked and no state is forwarded anywhere.
text_input: ?*TextInput = null,

input_method_commit: wl.Listener(void) = .init(handleInputMethodCommit),
grab_keyboard: wl.Listener(*wlr.InputMethodV2.KeyboardGrab) = .init(handleInputMethodGrabKeyboard),
input_method_destroy: wl.Listener(void) = .init(handleInputMethodDestroy),
input_method_new_popup: wl.Listener(*wlr.InputPopupSurfaceV2) = .init(handleInputMethodNewPopup),

grab_keyboard_destroy: wl.Listener(void) = .init(handleInputMethodGrabKeyboardDestroy),

pub fn init(relay: *InputRelay) void {
    relay.* = .{ .text_inputs = undefined, .input_popups = undefined };

    relay.text_inputs.init();
    relay.input_popups.init();
}

pub fn newInputMethod(relay: *InputRelay, input_method: *wlr.InputMethodV2) void {
    const seat: *Seat = @fieldParentPtr("relay", relay);

    log.debug("new input method on seat {s}", .{seat.wlr_seat.name});

    // Only one input_method can be bound to a seat.
    if (relay.input_method != null) {
        log.info("seat {s} already has an input method", .{seat.wlr_seat.name});
        input_method.sendUnavailable();
        return;
    }

    relay.input_method = input_method;

    input_method.events.commit.add(&relay.input_method_commit);
    input_method.events.grab_keyboard.add(&relay.grab_keyboard);
    input_method.events.destroy.add(&relay.input_method_destroy);
    input_method.events.new_popup_surface.add(&relay.input_method_new_popup);

    {
        var it = server.input_manager.devices.iterator(.forward);
        while (it.next()) |device| {
            if (device.seat != seat) continue;
            const vkb = device.wlr_device.getVirtualKeyboard() orelse continue;
            if (vkb.resource.getClient() == input_method.resource.getClient()) {
                const keyboard: *Keyboard = @fieldParentPtr("device", device);
                if (keyboard.group) |group| {
                    group.input_method = true;
                }
            }
        }
    }

    // Text-input enter events are sent on keyboard focus changes and for
    // newly created text inputs (see TextInput.create), independent of
    // whether an input method exists. So at this point matching clients may
    // already have focus and may even have an enabled text input tracked in
    // relay.text_input. Only fill the gaps: enter anyone missing focus, then
    // activate the already-enabled input if there is one.
    if (seat.focused.surface()) |surface| {
        var it = relay.text_inputs.iterator(.forward);
        while (it.next()) |text_input| {
            if (text_input.wlr_text_input.focused_surface != null) continue;
            if (text_input.wlr_text_input.resource.getClient() == surface.resource.getClient()) {
                text_input.wlr_text_input.sendEnter(surface);
            }
        }
        if (relay.text_input) |_| {
            input_method.sendActivate();
            relay.sendInputMethodState();
        }
    }
}

fn handleInputMethodCommit(listener: *wl.Listener(void)) void {
    const relay: *InputRelay = @fieldParentPtr("input_method_commit", listener);
    const input_method = relay.input_method.?;

    if (!input_method.client_active) return;
    const text_input = relay.text_input orelse return;

    if (input_method.current.preedit.text) |preedit_text| {
        text_input.wlr_text_input.sendPreeditString(
            preedit_text,
            input_method.current.preedit.cursor_begin,
            input_method.current.preedit.cursor_end,
        );
    }

    if (input_method.current.commit_text) |commit_text| {
        text_input.wlr_text_input.sendCommitString(commit_text);
    }

    if (input_method.current.delete.before_length != 0 or
        input_method.current.delete.after_length != 0)
    {
        text_input.wlr_text_input.sendDeleteSurroundingText(
            input_method.current.delete.before_length,
            input_method.current.delete.after_length,
        );
    }

    text_input.wlr_text_input.sendDone();
}

fn handleInputMethodDestroy(listener: *wl.Listener(void)) void {
    const relay: *InputRelay = @fieldParentPtr("input_method_destroy", listener);

    relay.input_method_commit.link.remove();
    relay.grab_keyboard.link.remove();
    relay.input_method_destroy.link.remove();
    relay.input_method_new_popup.link.remove();
    relay.input_method = null;

    // Text-input focus follows keyboard focus, not input-method lifetime,
    // so keep focused_surface/enter state and any enabled text input intact.
    // Just hide input-method popups; they belong to the dead client and will
    // be destroyed through their own listeners anyway.
    var it = relay.input_popups.iterator(.forward);
    while (it.next()) |popup| popup.update();
}

fn handleInputMethodGrabKeyboard(
    listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab),
    keyboard_grab: *wlr.InputMethodV2.KeyboardGrab,
) void {
    const relay: *InputRelay = @fieldParentPtr("grab_keyboard", listener);
    const seat: *Seat = @fieldParentPtr("relay", relay);

    const active_keyboard = seat.wlr_seat.getKeyboard();
    keyboard_grab.setKeyboard(active_keyboard);

    keyboard_grab.events.destroy.add(&relay.grab_keyboard_destroy);
}

fn handleInputMethodNewPopup(
    listener: *wl.Listener(*wlr.InputPopupSurfaceV2),
    wlr_popup: *wlr.InputPopupSurfaceV2,
) void {
    const relay: *InputRelay = @fieldParentPtr("input_method_new_popup", listener);

    InputPopup.create(wlr_popup, relay) catch {
        log.err("out of memory", .{});
        return;
    };
}

fn handleInputMethodGrabKeyboardDestroy(listener: *wl.Listener(void)) void {
    const relay: *InputRelay = @fieldParentPtr("grab_keyboard_destroy", listener);
    const input_method = relay.input_method.?;
    const keyboard_grab = input_method.keyboard_grab.?;
    relay.grab_keyboard_destroy.link.remove();

    if (keyboard_grab.keyboard) |keyboard| {
        input_method.seat.keyboardNotifyModifiers(&keyboard.modifiers);
    }
}

pub fn disableTextInput(relay: *InputRelay) void {
    assert(relay.text_input != null);
    relay.text_input = null;

    if (relay.input_method) |input_method| {
        {
            var it = relay.input_popups.iterator(.forward);
            while (it.next()) |popup| popup.update();
        }
        input_method.sendDeactivate();
        input_method.sendDone();
    }
}

pub fn sendInputMethodState(relay: *InputRelay) void {
    const input_method = relay.input_method.?;
    const wlr_text_input = relay.text_input.?.wlr_text_input;

    // TODO Send these events only if something changed.
    // On activation all events must be sent for all active features.

    if (wlr_text_input.active_features.surrounding_text) {
        if (wlr_text_input.current.surrounding.text) |text| {
            input_method.sendSurroundingText(
                text,
                wlr_text_input.current.surrounding.cursor,
                wlr_text_input.current.surrounding.anchor,
            );
        }
    }

    input_method.sendTextChangeCause(wlr_text_input.current.text_change_cause);

    if (wlr_text_input.active_features.content_type) {
        input_method.sendContentType(
            wlr_text_input.current.content_type.hint,
            wlr_text_input.current.content_type.purpose,
        );
    }

    {
        var it = relay.input_popups.iterator(.forward);
        while (it.next()) |popup| popup.update();
    }

    input_method.sendDone();
}

pub fn focus(relay: *InputRelay, new_focus: ?*wlr.Surface) void {
    // Send leave events. Skip inputs already focused on the new surface so
    // this stays idempotent (newInputMethod also ensures enter state).
    {
        var it = relay.text_inputs.iterator(.forward);
        while (it.next()) |text_input| {
            if (text_input.wlr_text_input.focused_surface) |surface| {
                if (surface == new_focus) continue;
                text_input.wlr_text_input.sendLeave();
            }
        }
    }

    // Clear currently enabled text input, but keep it if its client still
    // owns the new focus: an enable that raced ahead of the enter event
    // (Chromium does this) must survive the focus change.
    if (relay.text_input) |text_input| {
        const keep = if (new_focus) |surface| blk: {
            if (text_input.wlr_text_input.focused_surface == surface) break :blk true;
            // Early enable arrived before enter was sent.
            break :blk text_input.wlr_text_input.resource.getClient() == surface.resource.getClient();
        } else false;
        if (!keep) relay.disableTextInput();
    }

    // Send enter events following keyboard focus, independent of whether an
    // input method is bound. No text input for the new surface should be
    // enabled yet as well-behaved clients wait for enter, but buggy ones may
    // have enabled early -- handled above.
    if (new_focus) |surface| {
        var it = relay.text_inputs.iterator(.forward);
        while (it.next()) |text_input| {
            if (text_input.wlr_text_input.focused_surface != null) continue;
            if (text_input.wlr_text_input.resource.getClient() == surface.resource.getClient()) {
                text_input.wlr_text_input.sendEnter(surface);
            }
        }
    }
}
