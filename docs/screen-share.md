# Screen share

How a screen-share request travels in arc, and where each piece lives.

## The path an app takes

```
app ──org.freedesktop.portal.ScreenCast──▶ xdg-desktop-portal (frontend)
                                                │  org.freedesktop.impl.portal.ScreenCast
                                                ▼
                                          nshell (Portal.zig)
                                                │  bank: share_configured
                                                ▼
                                              nile
                                          ShareScene → ShareRender → ShareStream
                                                │  PipeWire node
                                                ▼
                                              app (pw consumer)
```

`xdg-desktop-portal` is the frontend apps talk to; the backend behind it is
nshell. Which backend handles which interface is decided by the descriptors
in `$prefix/share/xdg-desktop-portal/*.portal`: ours is `scripts/arc.portal`
(installed as `arc.portal`), which advertises
`org.freedesktop.impl.portal.ScreenCast` under `UseIn=arc`. Only ScreenCast
is advertised, so every other portal interface keeps going to whatever
handles it for the rest of the `UseIn` list.

## Who owns what

The **compositor owns the stream end to end**. nshell is only the D-Bus
frontend: it shows the picker and the config menu, sends the resulting
`share_configured`, and then goes idle until the user presses Stop.

This is the important structural decision. It means:

- The shared image is built by us, not read back from the screen.
- Nothing outside the compositor process can pull a frame, so a redacted
  screen cannot leak through a side channel.
- The shell does no per-frame work at all, so a share cannot cost the
  compositor anything the user notices.

## Pieces

- **`shell/src/Portal.zig`** — the D-Bus service. Owns the bus name
  `org.freedesktop.impl.portal.desktop.arc` and the object at
  `/org/freedesktop/impl/portal/ScreenCast`. Implements the version-6 impl
  interface: `CreateSession`, `SelectSources`, `Start`, plus `Session.Close`
  objects, and the `AvailableSourceTypes` / `AvailableCursorModes` /
  `version` properties.
- **`compositor/src/Share.zig`** — session state. Answers `share_select`
  with the list of windows that may be hidden, applies `share_configured`,
  and owns `Window.share_hidden`.
- **`compositor/src/ShareScene.zig`** — builds the outgoing image. A private
  `wlr.Scene` that mirrors the real one layer by layer, except that a
  share-hidden window contributes an opaque black `SceneRect` instead of its
  buffers. The user's own screen is untouched: it keeps using
  `wlr_scene_output`.
- **`compositor/src/ShareRender.zig`** — replays that scene into a
  `wlr.RenderPass`. Walks the composed tree's own children rather than
  `forEachBuffer`, because the latter skips rects — and the rects are the
  whole point of hiding a window.
- **`compositor/src/ShareBuffer.zig`** — a pointer-backed `wlr.Buffer`,
  since PipeWire owns the memory the compositor renders into.
- **`compositor/src/ShareStream.zig`** + **`pipewire_share.c`** — the
  `pw_stream` producer. Calls back into `ShareRender` to fill each
  dequeued buffer directly, so there is no intermediate frame copy.
- **`shell/src/State.zig`** — the picker model (`share_views`), the config
  menu state, and the bank requests.

## Hiding a window

`Window.share_hidden` is deliberately **not** `rendering_requested.hidden`.
That flag is the wm's animation-scoped visibility (workspace switches, close
fades) and is ANDed with `state == .mapped` at every use site, so reusing it
would have disabled the user's own screen as well as the share.

Instead `share_hidden` is read only when composing the outgoing frame. A
hidden window stays fully visible, clickable and typable for the person at
the machine; the recipient sees a black box at its rectangle, covering
whatever is behind it. Popups belonging to a hidden window are dropped too,
or a menu would float above the black box and give it away.

## Cadence

The composed image is rebuilt at most every 33ms (30fps) and only when an
output reports damage, so an idle desktop rebuilds nothing. The PipeWire
graph is paced by the same interval. Both caps live in `ShareScene.zig` /
`ShareStream.zig`; keep them in step.

## Threading

`Portal.zig` runs on **its own thread** (via `io.async` in `main.zig`), not
on `State.worker`. `Start` answers synchronously, so the call blocks while
the picker is open, and `sd_bus_process` cannot be pumped from inside a
message handler. Keeping notifications (`Notif.zig`) on the worker means a
picker sitting open for 25s never stalls notification delivery.

Everything else is on the compositor's main thread: the wlroots renderer and
the scene graph are not thread-safe, and the render callback runs inside
`pshare_dispatch`, driven from a timer on the Wayland event loop.

`State.deinit` waits on `portal_done` before freeing the model, because the
portal thread holds a pointer to it.

## Matching a monitor

The picker shows bank outputs (compositor-side `Output.name`, which is
`wlr_output.name`). The recipient never sees that name: the compositor
resolves the source from the id it was given, so the portal no longer needs
to match a `wl_output` by name the way the old capture path did.

## Limits (deliberate, v1)

- Monitors and windows only; no virtual monitors (`AvailableSourceTypes`
  is `MONITOR | WINDOW`). Anything else is refused with response 2.
- One share at a time; a new share closes the previous session with
  `Closed`.
- Streams are capped at 1920x1080. A 5K or rotated output would otherwise
  ask PipeWire for a ~50MB buffer per frame.
- Cursor mode is fixed at hidden. The composed scene does not paint cursors.
- A rotated output is streamed sideways: the compositor's `transform` is
  logged, not undone.
- No `pipewire-serial` in the stream properties (node id only).
- Compositor code has no headless harness in this repo, so scene
  composition, rendering and the PipeWire producer are compile-verified
  only. `compositor/src/share_geom.zig` is the exception: its geometry is
  pure and unit tested.

## Testing

Suite:

```sh
zig build -Dllvm test
```

Note `-Dllvm`: without it, Zig 0.16's bundled LLD rejects `R_X86_64_PC64`
relocations in the `.sframe` section that GCC 16 puts in the system CRT
objects, and nothing links.

Talking to the portal directly, bypassing backend selection entirely — the
most reliable way to test, and the only one that works while another desktop
is running:

```sh
busctl --user introspect org.freedesktop.impl.portal.desktop.arc \
    /org/freedesktop/impl/portal/ScreenCast
gdbus call --session --dest org.freedesktop.impl.portal.desktop.arc \
    --object-path /org/freedesktop/impl/portal/ScreenCast \
    --method org.freedesktop.impl.portal.ScreenCast.SelectSources "{}"
```

### Verifying the image without any desktop session

`scripts/verify-share.sh` proves the whole pipeline on its own terms: it
starts a private `dbus-daemon`, runs nile headless, opens a test window
(alacritty/kitty/glxgears), and drives the compositor over the bank socket.

```sh
zig build -Dllvm
scripts/verify-share.sh              # image checks
scripts/verify-share.sh --with-bus   # also poke the portal on the private bus
```

It asserts, in order: the compositor answers, `share_select` yields
`configure_share` with the windows actually on that output, `share_snapshot`
returns a correctly-sized non-blank frame, **the window's own rectangle goes
black when hidden and comes back when unhidden**, and `share_stop` yields
`share_stopped`. Frames are written as `share-visible.ppm` /
`share-hidden.ppm` for eyeballing.

The image check uses the `share_snapshot` bank request, which renders
through exactly the same `ShareScene` + `ShareRender` path a live stream
uses — so a black box that fails to draw, a buffer that fails to import, or
an empty scene all show up as wrong pixels, without needing PipeWire.

Exit status is 0 only if every check passed.

### If another desktop session is running

`xdg-desktop-portal` is a **per-user** service and picks its backends **once,
at frontend startup**, from `XDG_CURRENT_DESKTOP`. So in a session nested
inside, say, Plasma:

- Plasma's portal already owns ScreenCast and will answer with Plasma's
  picker, capturing from kwin rather than from nile.
- Exporting `XDG_CURRENT_DESKTOP=arc` from `launch-arc` does **not** help:
  the frontend is already running and will not re-select.
- Stopping `xdg-desktop-portal-kde` is per-user, so it breaks that
  desktop's portals everywhere, not just in the nested session.

Use the `busctl`/`gdbus` route above, or run arc from a separate TTY with no
other desktop session. `launch-arc` does not set `XDG_CURRENT_DESKTOP`
itself.