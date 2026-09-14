// Single shared SDL event pump for the shell's layer-shell windows (bar +
// hub). SDL owns one process-wide event queue, so one pump must serve all
// windows: dispatch by target window. App-level quit has no target: mirror
// it to both windows so they share one lifetime (otherwise only the bar
// would close and the hub surface would linger with its last frame).
// Other target-less events (e.g. the refresh wakeup) go to the bar,
// matching the backend's "global events are managed by the primary window"
// convention.
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
