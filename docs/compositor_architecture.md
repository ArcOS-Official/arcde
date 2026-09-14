# Compositor architecture

The compositor is a monolithic wayland compositor based on wlroots.

The compositor is the main heart of this project where it stays on the compositor thread
, the extrnally availble and IPC mutable state is handled by a State object with
it's own thread, UI for the shell has it's own thread.

The compositor thread is the usual wlroots compositor except for one fact, it
is interface based (for testing reasons) as the compositor itself is technically just
a monad since it's just a struct with a specific interface called the control interface,
that interface is what lets the logic part control the actual engine. The logic part
is just a function that looks something similar to this `fn handle(event: Event, controller: *Controller)`
where `Event` is just a union of all possible events that this supports and the Controller
is a vtable that lets you control where windows and stuff. The controller interface is basically
everything that wlroots lets you do, resize windows, move windows, take images of the current surface
(aka copy it weather it's the current output or just the surface of a window). In a testing environment
The handle function will be called by the tests and will be given a fake controller to see how it
modifies state.

The state thread is very simple, it has a snapshot system just like the one in the
GUIDELINES.md example that lets the entire system be aware of the state of the outside world.

The UI thread is also simple, it's a bunch of widgets that are rendered on top of
everything (and at the bottom of everything) where it uses some API similar to xdg
layershell for exclusive zones that take away from the space that windows are able
to take (in tiling mode as there are no size or position limitations in floating mode)
and has a custom dvui backend to let it directly render on top of the windows.
