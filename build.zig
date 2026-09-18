const std = @import("std");

const trim = std.mem.trim;
const whitespace = std.ascii.whitespace;

/// Version reported by `nile -version`. The unified repo has no per-compositor
/// git tags, so this is plain: the arc package version, no git describe.
const manifest_version = "0.1.0+arc";

const Scanner = @import("wayland").Scanner;
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_llvm = b.option(bool, "llvm", "Force use of Zig's LLVM backend and the lld linker");
    const use_lld = b.option(bool, "lld", "Use the lld linker");
    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const xwayland = b.option(
        bool,
        "xwayland",
        "Set to true to enable xwayland support in the compositor",
    ) orelse false;

    const test_step = b.step("test", "Run all tests");
    const check_step = b.step("check", "Check that everything compiles");

    // ---------------------------------------------------------------
    // bank — IPC protocol library (compositor <-> shell)
    // ---------------------------------------------------------------
    const bank_mod = b.addModule("bank", .{
        .root_source_file = b.path("bank/src/root.zig"),
        .target = target,
    });

    const bank_tests = b.addTest(.{ .root_module = bank_mod, .use_llvm = use_llvm, .use_lld = use_lld });
    test_step.dependOn(&b.addRunArtifact(bank_tests).step);
    check_step.dependOn(&bank_tests.step);

    {
        const bank_lib = b.addLibrary(.{
            .root_module = bank_mod,
            .name = "bank",
            .use_llvm = use_llvm,
        });
        b.installArtifact(bank_lib);

        inline for (.{ "server", "client" }) |name| {
            const exe_mod = b.createModule(.{
                .root_source_file = b.path("bank/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "bank", .module = bank_mod }},
            });
            const exe = b.addExecutable(.{ .name = "bank-" ++ name, .root_module = exe_mod, .use_llvm = use_llvm });
            b.installArtifact(exe);
            b.step("run-" ++ name, "Run bank " ++ name).dependOn(&b.addRunArtifact(exe).step);
        }
    }

    // ---------------------------------------------------------------
    // compositor — nile, a wlroots Wayland compositor
    // ---------------------------------------------------------------
    try buildCompositor(b, .{
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
        .strip = strip,
        .xwayland = xwayland,
        .bank_mod = bank_mod,
        .test_step = test_step,
        .check_step = check_step,
    });

    // ---------------------------------------------------------------
    // shell — nshell, the dvui layer-shell UI (bar + hub)
    // ---------------------------------------------------------------
    try buildShell(b, .{
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
        .use_lld = use_lld,
        .bank_mod = bank_mod,
        .test_step = test_step,
        .check_step = check_step,
    });
}

const CompositorOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: ?bool,
    use_lld: ?bool,
    strip: bool,
    xwayland: bool,
    bank_mod: *std.Build.Module,
    test_step: *std.Build.Step,
    check_step: *std.Build.Step,
};

fn buildCompositor(b: *std.Build, opts: CompositorOptions) !void {
    const target = opts.target;
    const optimize = opts.optimize;
    const src_dir = "compositor/";

    const options = b.addOptions();
    options.addOption(bool, "xwayland", opts.xwayland);
    options.addOption([]const u8, "version", manifest_version);

    const scanner = Scanner.create(b, .{});

    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("staging/color-management/color-management-v1.xml");
    scanner.addSystemProtocol("staging/color-representation/color-representation-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("staging/tearing-control/tearing-control-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-foreign/xdg-foreign-unstable-v2.xml");

    scanner.addCustomProtocol(b.path(src_dir ++ "protocol/upstream/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path(src_dir ++ "protocol/upstream/wlr-output-power-management-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path(src_dir ++ "protocol/upstream/virtual-keyboard-unstable-v1.xml"));

    // Some of these versions may be out of date with what wlroots implements.
    // This is not a problem in practice though as long as nile successfully compiles.
    // These versions control Zig code generation and have no effect on anything internal
    // to wlroots. Therefore, the only thing that can happen due to a version being too
    // old is that nile fails to compile.
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);

    scanner.generate("xdg_wm_base", 2);
    scanner.generate("zwp_pointer_gestures_v1", 3);
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.generate("zwp_tablet_manager_v2", 1);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    scanner.generate("zxdg_importer_v2", 1);
    scanner.generate("zxdg_exporter_v2", 1);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("wp_tearing_control_manager_v1", 1);
    scanner.generate("wp_color_manager_v1", 2);
    scanner.generate("wp_color_representation_manager_v1", 1);

    scanner.generate("zwlr_output_power_manager_v1", 1);
    scanner.generate("zwlr_layer_shell_v1", 4);
    scanner.generate("zwp_virtual_keyboard_manager_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");

    // The wlroots module defined below is a plain wrapper around the C API,
    // so we need to ensure wlroots has access to the wayland API.
    const wlroots = b.dependency("wlroots", .{}).module("wlroots");
    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);

    // We need to ensure the wlroots include path obtained from pkg-config is
    // exposed to the wlroots module for @cImport() to work. This seems to be
    // the best way to do so with the current std.Build API.
    wlroots.resolved_target = target;
    const wlroots_pkgconf = "wlroots-0.20";
    wlroots.linkSystemLibrary(wlroots_pkgconf, .{});

    const flags = b.createModule(.{ .root_source_file = b.path(src_dir ++ "common/flags.zig") });
    const slotmap = b.createModule(.{ .root_source_file = b.path(src_dir ++ "common/slotmap.zig") });
    const floating_logic = b.createModule(.{ .root_source_file = b.path(src_dir ++ "common/floating_logic.zig") });
    const shell_domain = b.createModule(.{ .root_source_file = b.path(src_dir ++ "common/shell_domain.zig") });

    const translate_c: Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "c",
        .c_source_file = b.path(src_dir ++ "src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("libevdev", .{});
    translate_c.linkSystemLibrary("libinput", .{});

    {
        const nile = b.addExecutable(.{
            .name = "nile",
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_dir ++ "src/main.zig"),
                .target = target,
                .optimize = optimize,
                .strip = opts.strip,
                .link_libc = true,
            }),
            .use_llvm = opts.use_llvm,
            .use_lld = opts.use_lld orelse opts.use_llvm,
        });
        nile.root_module.addOptions("build_options", options);

        nile.root_module.linkSystemLibrary("libevdev", .{});
        nile.root_module.linkSystemLibrary("libinput", .{});
        nile.root_module.linkSystemLibrary("wayland-server", .{});
        nile.root_module.linkSystemLibrary(wlroots_pkgconf, .{});
        nile.root_module.linkSystemLibrary("xkbcommon", .{});
        nile.root_module.linkSystemLibrary("pixman-1", .{});

        nile.root_module.addImport("wayland", wayland);
        nile.root_module.addImport("xkbcommon", xkbcommon);
        nile.root_module.addImport("pixman", pixman);
        nile.root_module.addImport("wlroots", wlroots);
        nile.root_module.addImport("flags", flags);
        nile.root_module.addImport("slotmap", slotmap);
        nile.root_module.addImport("floating_logic", floating_logic);
        nile.root_module.addImport("shell_domain", shell_domain);
        nile.root_module.addImport("c", translate_c.mod);
        nile.root_module.addImport("bank", opts.bank_mod);

        nile.root_module.addCSourceFile(.{
            .file = b.path(src_dir ++ "src/wlroots_log_wrapper.c"),
            .flags = &.{ "-std=c99", "-O2" },
        });

        b.installArtifact(nile);
        opts.check_step.dependOn(&nile.step);

        const runner = b.addRunArtifact(nile);
        const run = b.step("run-compositor", "Run the compositor");
        run.dependOn(&runner.step);
    }

    // slotmap unit tests
    {
        const slotmap_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_dir ++ "common/slotmap.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = opts.use_llvm,
        });
        opts.test_step.dependOn(&b.addRunArtifact(slotmap_test).step);
        opts.check_step.dependOn(&slotmap_test.step);
    }

    // floating logic tests
    {
        const floating_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_dir ++ "common/floating_logic.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = opts.use_llvm,
        });
        opts.test_step.dependOn(&b.addRunArtifact(floating_test).step);
        opts.check_step.dependOn(&floating_test.step);
    }

    // shell focus-domain policy tests (pure predicates, no wlroots)
    {
        const shell_domain_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_dir ++ "common/shell_domain.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = opts.use_llvm,
        });
        opts.test_step.dependOn(&b.addRunArtifact(shell_domain_test).step);
        opts.check_step.dependOn(&shell_domain_test.step);
    }
}

const ShellOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: ?bool,
    use_lld: ?bool,
    bank_mod: *std.Build.Module,
    test_step: *std.Build.Step,
    check_step: *std.Build.Step,
};

fn buildShell(b: *std.Build, opts: ShellOptions) !void {
    const target = opts.target;
    const optimize = opts.optimize;
    const src_dir = "shell/src";

    // The DVUI fork lives in the ui/ submodule: SDL3 backend only.
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .@"use-llvm" = opts.use_llvm,
    });

    // System sd-bus API via translateC (shell/src/sd_bus.h -> <systemd/sd-bus.h>).
    // Imported as `@import("sd_bus")` by shell/src/Dbus.zig; linked as -lsystemd.
    const sd_bus_tc = b.addTranslateC(.{
        .root_source_file = b.path(src_dir ++ "/sd_bus.h"),
        .target = target,
        .optimize = optimize,
    });
    // <systemd/sd-bus.h> pulls in glibc <fcntl.h>. With optimizations on,
    // glibc activates its _FORTIFY_SOURCE open/openat wrappers, which
    // translate-c cannot handle (bits/fcntl2.h __open_too_many_args errors).
    // Disable fortify for the translation only; the final link is unaffected.
    sd_bus_tc.defineCMacro("_FORTIFY_SOURCE", "0");
    const sd_bus_mod = sd_bus_tc.createModule();
    // Declarations only: must not pull -lc into the libc-free headless test
    // binaries. Final binaries link libc + systemd via their own modules.
    sd_bus_mod.link_libc = false;

    // Layer-shell wrapper, vendored at shell/layershell (was the
    // dvui_layer_shell package): it is built against the arc dvui fork and
    // its own wayland client bindings here.
    const ls_scanner = Scanner.create(b, .{});
    ls_scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    ls_scanner.generate("wl_compositor", 5);
    ls_scanner.generate("wl_seat", 8);
    ls_scanner.generate("wl_output", 4);
    ls_scanner.generate("xdg_wm_base", 7);
    const wlr_protocols_base_path = trim(u8, b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wlr-protocols" }), &whitespace);
    ls_scanner.addCustomProtocol(.{ .cwd_relative = b.pathJoin(&.{ wlr_protocols_base_path, "/unstable/wlr-layer-shell-unstable-v1.xml" }) });
    ls_scanner.generate("zwlr_layer_shell_v1", 4);
    const ls_wayland = b.createModule(.{ .root_source_file = ls_scanner.result });

    const layershell_mod = b.createModule(.{
        .root_source_file = b.path("shell/layershell/layer_shell.zig"),
        .target = target,
        .optimize = optimize,
    });
    layershell_mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    layershell_mod.addImport("backend", dvui_dep.module("sdl3"));
    layershell_mod.addImport("wayland", ls_wayland);
    layershell_mod.linkSystemLibrary("wayland-client", .{});

    const tabler_dep = b.dependency("tabler_zig", .{
        .target = target,
        .optimize = optimize,
        // wire_dvui=false so the tabler module uses our dvui instance:
        // shared types (dvui.Size) and the per-window TVG cache.
        .wire_dvui = false,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path(src_dir ++ "/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    exe_mod.addImport("sd_bus", sd_bus_mod);
    const exe = b.addExecutable(.{
        .name = "nshell",
        .root_module = exe_mod,
        .use_llvm = opts.use_llvm,
        .use_lld = opts.use_lld,
    });

    const tabler_mod = tabler_dep.module("tabler");
    tabler_mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    exe_mod.addImport("tabler", tabler_mod);
    exe_mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    exe_mod.addImport("layershell", layershell_mod);
    exe_mod.addImport("bank", opts.bank_mod);

    b.installArtifact(exe);
    opts.check_step.dependOn(&exe.step);

    const run_step = b.step("run-shell", "Run the shell");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const shell_tests = b.addTest(.{
        .root_module = exe_mod,
        .use_lld = opts.use_lld,
        .use_llvm = opts.use_llvm,
    });
    // The shell test binary exercises Dbus.zig code paths; it gets sd_bus
    // (declarations-only) even though exe_mod links the real thing.
    shell_tests.root_module.addImport("sd_bus", sd_bus_mod);
    opts.test_step.dependOn(&b.addRunArtifact(shell_tests).step);
    opts.check_step.dependOn(&shell_tests.step);

    // Headless State tests: State returns real dvui types, but the link-light
    // shim (shell/src/dvui_shim.zig) keeps SDL/C objects out of the link.
    const dvui_shim = b.createModule(.{
        .root_source_file = b.path(src_dir ++ "/dvui_shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    const state_test_module = b.createModule(.{
        .root_source_file = b.path(src_dir ++ "/test_state.zig"),
        .target = target,
        .optimize = optimize,
    });
    state_test_module.addImport("bank", opts.bank_mod);
    state_test_module.addImport("dvui", dvui_shim);
    state_test_module.addImport("sd_bus", sd_bus_mod);
    const state_tests = b.addTest(.{
        .root_module = state_test_module,
        .use_llvm = opts.use_llvm,
        .use_lld = opts.use_lld,
    });
    opts.test_step.dependOn(&b.addRunArtifact(state_tests).step);
    opts.check_step.dependOn(&state_tests.step);

    // Headless Launcher parser tests — link-light via dvui_shim.
    const launcher_test_module = b.createModule(.{
        .root_source_file = b.path(src_dir ++ "/Launcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    launcher_test_module.addImport("dvui", dvui_shim);
    const launcher_tests = b.addTest(.{
        .root_module = launcher_test_module,
        .use_llvm = opts.use_llvm,
        .use_lld = opts.use_lld,
    });
    opts.test_step.dependOn(&b.addRunArtifact(launcher_tests).step);
    opts.check_step.dependOn(&launcher_tests.step);

    // Headless HubUi logic tests (JSON scenarios in shell/test) — link-light
    // via dvui_shim; @import("tabler") resolves to the tabler shim.
    const tabler_shim = b.createModule(.{
        .root_source_file = b.path(src_dir ++ "/tabler_shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    tabler_shim.addImport("dvui", dvui_shim);
    const hub_test_module = b.createModule(.{
        .root_source_file = b.path(src_dir ++ "/test_hub_ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    hub_test_module.addImport("bank", opts.bank_mod);
    hub_test_module.addImport("dvui", dvui_shim);
    hub_test_module.addImport("tabler", tabler_shim);
    hub_test_module.addImport("sd_bus", sd_bus_mod);
    const hub_tests = b.addTest(.{
        .root_module = hub_test_module,
        .use_llvm = opts.use_llvm,
        .use_lld = opts.use_lld,
    });
    opts.test_step.dependOn(&b.addRunArtifact(hub_tests).step);
    opts.check_step.dependOn(&hub_tests.step);

    // Headless icon/search bench — link-light via dvui_shim (no GUI link).
    const bench_module = b.createModule(.{
        .root_source_file = b.path(src_dir ++ "/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_module.addImport("dvui", dvui_shim);
    const bench_exe = b.addExecutable(.{
        .name = "bench-icons",
        .root_module = bench_module,
        .use_llvm = opts.use_llvm,
        .use_lld = opts.use_lld,
    });
    const bench_step = b.step("bench", "Run Launcher icon/search bench (no GUI)");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);

    const bench_net_module = b.createModule(.{
        .root_source_file = b.path(src_dir ++ "/bench_net.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_net_module.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    bench_net_module.addImport("sd_bus", sd_bus_mod);
    const bench_net_exe = b.addExecutable(.{
        .name = "bench-net",
        .root_module = bench_net_module,
        .use_llvm = opts.use_llvm,
        .use_lld = opts.use_lld,
    });
    const bench_net_step = b.step("bench-net", "Run NetworkManager/BlueZ bench (needs system bus)");
    bench_net_step.dependOn(&b.addRunArtifact(bench_net_exe).step);

    // Input-funnel checks for the shell focus domain (kept per request;
    // see shell/test/input_funnel.zig — remove, don't commit). Real dvui
    // + SDL backend on dummy drivers, no compositor or D-Bus: fake
    // OS-level input goes through the live pump dispatch into hubFrame
    // and must land in the text entries.
    const funnel_mod = b.createModule(.{
        .root_source_file = b.path("shell/input_funnel_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    funnel_mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));
    funnel_mod.addImport("sdl-backend", dvui_dep.module("sdl3"));
    funnel_mod.addImport("bank", opts.bank_mod);
    funnel_mod.addImport("tabler", tabler_mod);
    funnel_mod.addImport("sd_bus", sd_bus_mod);
    funnel_mod.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    const funnel_tests = b.addTest(.{
        .root_module = funnel_mod,
        .use_llvm = opts.use_llvm,
        .use_lld = opts.use_lld,
    });
    opts.test_step.dependOn(&b.addRunArtifact(funnel_tests).step);
    opts.check_step.dependOn(&funnel_tests.step);
    const funnel_step = b.step("test-input-funnel", "Run shell input-funnel checks (headless)");
    funnel_step.dependOn(&b.addRunArtifact(funnel_tests).step);
}
