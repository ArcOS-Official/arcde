// Module-root shim so the input-funnel suite can live in shell/test/.
// Zig modules confine relative imports to the root file's directory, so a
// root inside shell/test/ could not reach ../src/*.zig. This root pulls
// the real suite (shell/test/input_funnel.zig) into a module rooted at
// shell/, keeping a single copy of the State/HubUi types.
//
// Remove together with shell/test/input_funnel.zig (kept out of commits
// on request).
comptime {
    _ = @import("test/input_funnel.zig");
}
