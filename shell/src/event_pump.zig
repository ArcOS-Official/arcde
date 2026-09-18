// Single shared SDL event pump for the shell's layer-shell windows (bar +
// hub [+ background wallpaper]). SDL owns one process-wide event queue,
// so one pump must serve all windows: dispatch by target window.
// App-level quit has no target: mirror it to every window so they share
// one lifetime (otherwise only the bar would close and the other surfaces
// would linger with their last frame). Other target-less events (e.g. the
// refresh wakeup) go to the bar, matching the backend's "global events
// are managed by the primary window" convention.
//
// Lives in its own module (instead of main.zig) so the headless
// input-funnel test drives the exact dispatch the live shell uses.
pub fn pumpEvents(backend_bar: anytype, win_bar: anytype, backend_hub: anytype, win_hub: anytype) !void {
    // Backends arrive as pointers; decl access needs the struct type.
    const C = @TypeOf(backend_bar.*).c;
    var ev: C.SDL_Event = undefined;
    while (C.SDL_PollEvent(&ev)) {
        if (ev.type == C.SDL_EVENT_QUIT) {
            _ = try backend_bar.addEvent(win_bar, ev);
            _ = try backend_hub.addEvent(win_hub, ev);
            continue;
        }
        const t_ = C.SDL_GetWindowFromEvent(&ev);
        if (t_ == null or t_ == backend_bar.window) {
            _ = try backend_bar.addEvent(win_bar, ev);
        } else if (t_ == backend_hub.window) {
            _ = try backend_hub.addEvent(win_hub, ev);
        } else {
            _ = try backend_bar.addEvent(win_bar, ev);
        }
    }
}

/// Three-window variant for when the background wallpaper surface exists.
/// Same dispatch as pumpEvents, plus routing to the background window by
/// target; quit mirrors to all three. Background requires non-null
/// backends; callers without wallpaper keep using pumpEvents.
pub fn pumpEvents3(
    backend_bar: anytype,
    win_bar: anytype,
    backend_hub: anytype,
    win_hub: anytype,
    backend_bg: anytype,
    win_bg: anytype,
) !void {
    const C = @TypeOf(backend_bar.*).c;
    var ev: C.SDL_Event = undefined;
    while (C.SDL_PollEvent(&ev)) {
        if (ev.type == C.SDL_EVENT_QUIT) {
            _ = try backend_bar.addEvent(win_bar, ev);
            _ = try backend_hub.addEvent(win_hub, ev);
            _ = try backend_bg.addEvent(win_bg, ev);
            continue;
        }
        const t_ = C.SDL_GetWindowFromEvent(&ev);
        if (t_ == null or t_ == backend_bar.window) {
            _ = try backend_bar.addEvent(win_bar, ev);
        } else if (t_ == backend_hub.window) {
            _ = try backend_hub.addEvent(win_hub, ev);
        } else if (t_ == backend_bg.window) {
            _ = try backend_bg.addEvent(win_bg, ev);
        } else {
            _ = try backend_bar.addEvent(win_bar, ev);
        }
    }
}
