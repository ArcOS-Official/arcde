# dvui-layer-shell — Wayland layer-shell for dvui (SDL3)

Wayland-only library that puts a `dvui.App` on a `zwlr_layer_shell_v1` surface. Forces `SDL_VIDEODRIVER=wayland` and panics with a diagnostic if no Wayland compositor is available. Transparency uses dvui's own `StartOptions.transparent` (no duplicate field).

## Install — drop into any dvui project

```sh
zig fetch --save git+https://github.com/<you>/dvui-layer-shell-example#<commit>
# or for local dev:
zig fetch --save --overwrite ../path/to/dvui-layer-shell-example
```

`build.zig.zon` (replace hash with the one `zig fetch` prints):

```zig
.dependencies = .{
    .dvui_layer_shell = .{
        .url = "git+https://github.com/<you>/dvui-layer-shell-example#...",
        .hash = "...",
    },
    .dvui = .{ /* same dvui you already use, backend .sdl3 */ },
},
```

`build.zig`:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});
const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });
const ls_dep = b.dependency("dvui_layer_shell", .{ .target = target, .optimize = optimize });

const exe = b.addExecutable(.{
    .name = "myapp",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
exe.root_module.addImport("dvui", dvui_dep.module("dvui_sdl3"));
exe.root_module.addImport("dvui-layer-shell", ls_dep.module("dvui-layer-shell"));
b.installArtifact(exe);
```

Requires `wayland-protocols` + `wlr-protocols` + `pkg-config` at build time and `wayland-client` at link time (already handled by the library's `build.zig`).

## Usage

### 1) Drop-in replacement for `dvui.App.main`

```zig
const dvui = @import("dvui");
const layer_shell = @import("dvui-layer-shell");

pub const dvui_app: dvui.App = .{
    .config = .{ .options = .{
        .title = "My bar",
        .size = .{ .w = 800, .h = 600 },
        .transparent = true,
    } },
    .frameFn = frame,
};
pub const layer_shell_opts: layer_shell.LayerShellOpts = .{
    .anchors = .{ .top, .left, .right, null }, // top bar
    .layer = .top,
    .exclusive_zone = 600,
    .namespace = "my-bar",
};
pub const main = layer_shell.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

fn frame() !dvui.App.Result {
    dvui.label(@src(), "hello", .{}, .{});
    return .ok;
}
```

`layer_shell.main` reads `dvui_app` + `layer_shell_opts` (`dvui_layer_opts` / `layer_opts` aliases also accepted) from your root file.

### 2) Function call — keep your own `main`

```zig
pub fn main(init: std.process.Init) !u8 {
    const app: dvui.App = .{ .config = .{ .options = .{ .title = "My bar", .transparent = true } }, .frameFn = frame };
    const opts: layer_shell.LayerShellOpts = .{ .layer = .overlay, .anchors = .{null,null,null,null} };
    return try layer_shell.run(init, app, opts);
}
```

### 3) Low-level manual loop

```zig
const ctx = try layer_shell.initWindow(.{
    .io = init.io, .title = "My bar", .size = .{ .w = 800, .h = 600 }, .transparent = true,
}, .{ .anchors = .{ .top, null, null, null } }, init.gpa);
defer ctx.backend.deinit();
defer ctx.waylandCtx.deinit(init.gpa);
// ... your dvui.Window loop (see src/main_manual.zig)
```

`LayerShellOpts` fields: `anchors: [4]?Anchor` (`top/left/right/bottom`), `center`, `padding: [4]i32` (top/right/bottom/left margins), `layer: .background/.bottom/.top/.overlay`, `exclusive_zone: i32`, `keyboard_interactivity`, `namespace: [:0]const u8`. Window size comes from `dvui.App` / `InitOptions.size` (0 on an anchored axis means fill).

### Centering

Per the protocol, omitting an axis centers on it. `center` forces this explicitly by clearing anchors on that axis:

| Want | Config |
|---|---|
| Floating centered overlay | `.center = .both` (or all-null `anchors`) |
| Top bar, horizontally centered | `.anchors = .{ .top, null, null, null }, .center = .horizontal` |
| Side panel, vertically centered | `.anchors = .{ null, .left, null, null }, .center = .vertical` |
| Top bar, full width | `.anchors = .{ .top, .left, .right, null }` |

Helpers: `LayerShellOpts.centered()`, `.topCentered()`, `.leftCentered()`.

```zig
pub const layer_shell_opts: layer_shell.LayerShellOpts = .{
    .center = .both, // floating overlay, resizable/movable at runtime
    .layer = .overlay,
    .namespace = "my-overlay",
};
```

## Move / resize after launch

The layer-surface is double-buffered — all setters apply + commit immediately and are safe to call any frame from the main thread:

```zig
// App path: grab the live surface inside frameFn
fn frame() !dvui.App.Result {
    if (layer_shell.wayland()) |wl| {
        if (dvui.button(@src(), "Wider", .{}, .{})) wl.setSize(1000, 600); // or wl.resize(...)
        if (dvui.button(@src(), "Move", .{}, .{})) wl.moveTo(32, 32);      // anchor top-left + margins as x/y
        if (dvui.button(@src(), "Nudge", .{}, .{})) wl.moveBy(20, 0);
        if (dvui.button(@src(), "Center", .{}, .{})) wl.setCenter(.both);  // .horizontal / .vertical / .both
        if (dvui.button(@src(), "Dock top", .{}, .{})) wl.setAnchor(.{ .top = true, .left = true, .right = true });
        wl.reposition(.{ .width = 800, .height = 600 }); // atomic move+resize, one commit (no flicker)
        wl.setMargins(.{ 8, 8, 8, 8 });
        wl.setExclusiveZone(0);
    }
    return .ok;
}

// Manual path: you already own the handle
// ctx.waylandCtx.setSize(800, 600);
// ctx.waylandCtx.moveTo(100, 100);
// ctx.waylandCtx.setCenter(.horizontal);
```

Notes: `layer`/`namespace` are fixed at creation. Margins only offset anchored edges, so `moveTo`/`moveBy` anchor to top-left first when the surface is centered. Size `0` on an axis lets the compositor pick (requires opposite anchors on that axis); the compositor's `configure` reply updates the SDL window automatically. See `src/main.zig` for a live demo (center X/Y/Both, nudge, preset sizes).

## Examples

* `src/main.zig` — App on layer-shell (recommended).
* `src/main_manual.zig` — manual `initWindow` + `dvui.Window` loop.

```
zig build run                 # runs App example
WAYLAND_DISPLAY=1 zig build run  # panics: Wayland required but SDL_Init failed ...
```
