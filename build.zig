const std = @import("std");
const Scanner = @import("wayland").Scanner;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("staging/tearing-control/tearing-control-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");

    scanner.addCustomProtocol(b.path("protocol/conpositor-ipc-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));

    // Some of these versions may be out of date with what wlroots implements.
    // This is not a problem in practice though as long as tinywl successfully compiles.
    // These versions control Zig code generation and have no effect on anything internal
    // to wlroots. Therefore, the only thing that can happen due to a version being too
    // old is that tinywl fails to compile.
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
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("wp_tearing_control_manager_v1", 1);

    scanner.generate("zwlr_layer_shell_v1", 4);

    scanner.generate("conpositor_ipc_manager_v1", 1);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");
    const wlroots = b.dependency("wlroots", .{}).module("wlroots");
    const cairo = b.dependency("cairo", .{}).module("cairo");

    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);

    // We need to ensure the wlroots include path obtained from pkg-config is
    // exposed to the wlroots module for @cImport() to work. This seems to be
    // the best way to do so with the current std.Build API.
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary("wlroots-0.18", .{});

    const conpositor = b.addExecutable(.{
        .name = "conpositor",
        .root_source_file = b.path("conpositor/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    conpositor.linkLibC();

    conpositor.root_module.addImport("wayland", wayland);
    conpositor.root_module.addImport("xkbcommon", xkbcommon);
    conpositor.root_module.addImport("wlroots", wlroots);
    conpositor.root_module.addImport("cairo", cairo);
    conpositor.root_module.addImport("pixman", pixman);

    conpositor.linkSystemLibrary("wayland-server");
    conpositor.linkSystemLibrary("xkbcommon");
    conpositor.linkSystemLibrary("pixman-1");

    b.installArtifact(conpositor);

    // IPC utility
    const conpositormsg = b.addExecutable(.{
        .name = "conpositor-msg",
        .root_source_file = b.path("conpositormsg/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    conpositormsg.linkLibC();

    conpositormsg.root_module.addImport("wayland", wayland);

    conpositormsg.linkSystemLibrary("wayland-client");

    b.installArtifact(conpositormsg);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(conpositor);
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // IPC util run step
    const run_msg = b.addRunArtifact(conpositormsg);
    run_msg.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_msg.addArgs(args);
    }

    const run_msg_step = b.step("runmsg", "Run the app");
    run_msg_step.dependOn(&run_msg.step);

    // Creates a step for unit testing. This only builds the test executable
    const conpositor_unit_tests = b.addTest(.{
        .root_source_file = b.path("conpositor/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_conpositor_unit_tests = b.addRunArtifact(conpositor_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_conpositor_unit_tests.step);
}
