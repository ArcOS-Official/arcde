# NEWCOMMERS.md — how to find your way around arc

Read this once, then keep `GUIDELINES.md` open. The rules there (comment
ratio, `zig fmt` before every commit, no TODOs in commits, snapshot-based
threading) apply to every directory in this tree.

## The four parts and how they talk

```
compositor (nile)  ──serves──▶  bank sockets  ──consumed by──▶  shell (nshell)
        │                                                          │
        └──────────── renders layer surfaces ◀────────────────────┘
                          (shell draws with ui/, the DVUI fork)
```

The bank is the only channel between compositor and shell. No shared memory,
no D-Bus between them. If you change a message in `bank/src/protocols.zig`,
the compositor's server (`compositor/src/Bank.zig`) and the shell's client
(`shell/src/State.zig`) are the two places that must follow.

## Where to start reading

1. `bank/src/root.zig` — transport: an 8-byte header, per-message optional
   deflate, request ids matched to replies, unsolicited pushes. ~1200 lines
   with tests included; the whole protocol surface is this plus
   `bank/src/protocols.zig`.
2. `bank/src/protocols.zig` — the typed `Request`/`Event` unions and their
   wire encoding. `Message.kind` is the only discriminant; nothing hides a
   status code inside the payload.
3. `docs/compositor_architecture.md` — the three threads (compositor, state,
   UI) and the control-interface idea in one page.
4. `compositor/src/Nile.zig` — the public function API. Everything a window
   manager used to do over Wayland protocols is a function call here.
5. `shell/src/State.zig` — the shell's snapshot system: a worker thread owns
   the bank connection, UI reads copies. This file is the pattern the rest
   of the shell copies.

## The compositor (compositor/)

- `src/main.zig` — entrypoint, argument parsing, the global `server`.
- `src/Server.zig` — wlroots setup, wayland globals.
- `src/WindowManager.zig`, `src/Window.zig`, `src/Workspace.zig`,
  `src/Output.zig`, `src/Seat.zig` — the state machines. Windows and seats
  are stored in slotmaps (`common/slotmap.zig`); `Window.Ref` is a
  generational key, use it — not pointers — for anything long-lived.
- `src/Compositor.zig` — the event interface: `handle(event, controller)`.
  The logic layer never touches wlroots directly; tests drive `handle` with
  a fake controller.
- `src/Bank.zig` — answers bank requests (window lists, thumbnails) and
  broadcasts changes. Thumbnail captures are composited previews; they never
  read back from clients.
- `src/c.h` + `wlroots_log_wrapper.c` — the C boundary (libinput,
  libevdev, wlroots logging).
- `doc/nile-api.md` — the function API and the migration table from the
  old river protocols.

Sources moved from the old `nile/` directory to `compositor/src/` when the
repos merged; git history starts at the merge.

## The shell (shell/)

- `src/main.zig` — two layer-shell surfaces (bar + hub) sharing one SDL
  event pump, since SDL has one process-wide queue.
- `src/State.zig` — worker thread, request queue, snapshot adoption,
  window-output thumbnails. The `Action` union is everything the UI thread
  can ask the worker to send.
- `src/HubUi.zig` — the hub's modes (clock, launcher, windows, network,
  control center) and its animations. The JSON scenarios in `shell/test/`
  drive it headlessly.
- `src/Activity.zig`, `Net.zig`, `Media.zig`, `Power.zig` — worker
  subsystems. Activity polls PipeWire (`pw-dump`) for mic/camera/share
  indicators and watches the download dir. Net/Media/Power talk to
  D-Bus (`src/Dbus.zig`, sd-bus declarations only in `src/sd_bus.h`).
- `src/Launcher.zig` — desktop-entry search and launching.
- `layershell/` — vendored layer-shell wrapper (was the `dvui_layer_shell`
  package), wired to the ui fork.
- `src/dvui_shim.zig`, `src/tabler_shim.zig` — link-light stubs that let
  the headless tests compile without SDL or the icon pipeline.

## The ui fork (ui/)

A submodule. `ui/FORK.md` records the upstream commit
(`ecffdbf85beea10e9cbabcb370c60619b75e4282`, dvui 0.5.0-dev) and lists every
local change: SDL3-only build, pruned backend enum, SDL backend with the
sdl2/sdl3 split folded away, no wasm dialogs, AccessKit SDL3 paths only.

The rule from `docs/ui/dvui_fork_spec.md` still governs: a change belongs in
the fork if it changes DVUI's fundamental behavior (layout, placement,
rendering); it belongs in the shell if it's a convention (36px controls,
tokens, glass style, icon defaults). When in doubt, keep the fork
recognizable as upstream plus small deliberate edits.

The shell uses `dvui_sdl3` and the raw `sdl3` backend module from the fork.
There is no second GUI layer on top.

## Building and testing

```
git submodule update --init       # after clone
zig build -Dllvm=true             # nile, nshell, bank-server, bank-client
zig build -Dllvm=true test         # everything
zig build -Dllvm=true check        # typecheck only
```

`-Dllvm=true` avoids sframe relocation failures with newer binutils.
System requirements: wlroots-0.20, wayland, wayland-protocols, xkbcommon
(>= 1.12), libevdev, libinput, pixman, systemd headers, pkg-config.

Test suites and what they cover:

| Suite | Runs | Notes |
|---|---|---|
| bank | `bank/src/root.zig` tests | client-server over real sockets in /tmp |
| slotmap, floating logic | `compositor/common/` | pure data structures |
| state, launcher, hub UI | `shell/src/test_*.zig` | headless via `dvui_shim`; hub tests replay `shell/test/*.json` |
| ui | inside `ui/`, `zig build test` | full dvui suite on SDL3 |

## Things that will bite you

- Sockets live under `/tmp/arcos/`. Stale sockets after a crash make the
  shell's next connect fail; it retries every 1.5 s, so usually you just
  watch it reconnect.
- The compositor's `Nile.dirtyWindowing()` / `dirtyRendering()` flush on the
  next idle — mutations are recorded, not applied. If your windowing change
  does nothing, check you actually marked something dirty.
- `zig fmt` everything before committing; the comment budget in
  `GUIDELINES.md` is enforced by review, not tooling, so count as you write.
- The shell UI thread only reads snapshots. If you find yourself calling a
  worker-side function from a widget, route it through `State.Action` and
  the request queue instead.
- `capture_window` / `capture_output` in the protocol are compositor-side
  thumbnail renders for the switcher and share tiles. There is no
  screen-capture session tracking anymore — that protocol never worked and
  was removed from all three peers; don't re-add it from old commits.

## A first task that exercises the loop

Add a label to the control center: find `activitySection` in
`shell/src/HubUi.zig`, note how it copies a snapshot
(`state.activity.snapshotCopy`), reads counts, and pushes `Action`s on
stop-button clicks. Check `docs/ui/ui_spec.md` for the spacing token, run
`zig build -Dllvm=true test`, then `git -C ui log --oneline` to see how the
submodule's history stays separate from this repo's.
