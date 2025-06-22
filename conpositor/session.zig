const wl = @import("wayland").server.wl;
const conpositor = @import("wayland").server.conpositor;
const wlr = @import("wlroots");
const std = @import("std");
const xcb = @import("xcb");

const c = @import("c.zig");

const Config = @import("config.zig");
const Monitor = @import("monitor.zig");
const Client = @import("client.zig");
const Input = @import("input.zig");
const LayerSurface = @import("layersurface.zig");
const IpcOutput = @import("ipc.zig");

const Session = @This();

const allocator = Config.allocator;

pub const Layer = enum {
    LyrBg,
    LyrBottom,
    LyrTop,
    LyrOverlay,

    LyrTileShadows,
    LyrTile,
    LyrFloatShadows,
    LyrFloat,
    LyrFS,
    LyrDragIcon,
    LyrBlock,
};

const CycleDir = enum { forward, backward };
const NetAtom = enum { window_type_dialog, window_type_splash, window_type_toolbar, window_type_utility };

pub const SessionError = error{
    ServerCreateFailed,
    BackendCreateFailed,
    RendererCreateFailed,
    AllocatorCreateFailed,
    XwaylandCreateFailed,
    GlobalCreateFailed,
    RenderInitFailed,
    BackendStartFailed,
    AddSocketFailed,
    SessionNotSetup,
    OutOfMemory,
    Unexpected,
} || Config.ConfigError;

config: Config,

server: *wl.Server,
backend: *wlr.Backend,
scene: *wlr.Scene,
renderer: *wlr.Renderer,
wlr_allocator: *wlr.Allocator,
output_layout: *wlr.OutputLayout,
output_manager: *wlr.OutputManagerV1,
layers: std.EnumArray(Layer, *wlr.SceneTree),
xdg_activation: *wlr.XdgActivationV1,

idle_notifier: *wlr.IdleNotifierV1,
idle_inhibit_manager: *wlr.IdleInhibitManagerV1,
layer_shell: *wlr.LayerShellV1,
xdg_shell: *wlr.XdgShell,
session_lock_manager: *wlr.SessionLockManagerV1,

xdg_decoration_manager: *wlr.XdgDecorationManagerV1,
compositor: *wlr.Compositor,
xwayland: ?*wlr.Xwayland,
net_atoms: std.EnumArray(NetAtom, c.xcb_atom_t),

input: Input = undefined,

monitors: wl.list.Head(Monitor, .link) = undefined,
clients: wl.list.Head(Client, .link) = undefined,
focus_clients: wl.list.Head(Client, .focus_link) = undefined,
exclusive_focus: ?*wlr.Surface = null,

focusedMonitor: ?*Monitor = null,

layout_change_event: wl.Listener(*wlr.OutputLayout) = .init(Listeners.layoutChange),
xwayland_ready_event: wl.Listener(void) = .init(Listeners.xwayland_ready),

new_output_event: wl.Listener(*wlr.Output) = .init(Listeners.newOutput),
new_layer_surface_event: wl.Listener(*wlr.LayerSurfaceV1) = .init(Listeners.new_layer_surface),
new_xdg_toplevel_event: wl.Listener(*wlr.XdgToplevel) = .init(Listeners.new_xdg_toplevel),
new_xdg_popup_event: wl.Listener(*wlr.XdgPopup) = .init(Listeners.new_xdg_popup),
new_xdg_surface_event: wl.Listener(*wlr.XdgSurface) = .init(Listeners.new_xdg_surface),
new_xwayland_surface_event: wl.Listener(*wlr.XwaylandSurface) = .init(Listeners.new_xwayland_surface),
new_toplevel_decoration_event: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(Listeners.new_toplevel_decoration),
output_manager_apply_event: wl.Listener(*wlr.OutputConfigurationV1) = .init(Listeners.outputManagerApply),
output_manager_test_event: wl.Listener(*wlr.OutputConfigurationV1) = .init(Listeners.outputManagerTest),

const STACKING_ORDER = [_]Layer{
    .LyrBg,
    .LyrBottom,

    .LyrTileShadows,
    .LyrTile,
    .LyrFloatShadows,
    .LyrFloat,
    .LyrFS,
    .LyrDragIcon,
    .LyrBlock,

    .LyrTop,
    .LyrOverlay,
};

const FOCUS_ORDER = blk: {
    var tmp = STACKING_ORDER;
    std.mem.reverse(Layer, &tmp);
    break :blk tmp;
};

const Listeners = struct {
    pub fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const self: *Session = @fieldParentPtr("new_output_event", listener);
        if (!wlr_output.initRender(self.wlr_allocator, self.renderer)) return;

        Monitor.create(self, wlr_output) catch {
            std.log.err("failed to allocate new monitor", .{});
            wlr_output.destroy();
            return;
        };

        self.updateMons() catch |err| {
            std.log.err("failed to update monitors {s}", .{@errorName(err)});
        };
    }

    pub fn outputManagerTest(listener: *wl.Listener(*wlr.OutputConfigurationV1), output_configuration: *wlr.OutputConfigurationV1) void {
        const self: *Session = @fieldParentPtr("output_manager_test_event", listener);

        self.outputManagerApply(true, output_configuration) catch |err| {
            std.log.err("failed to update monitors {s}", .{@errorName(err)});
        };
    }

    pub fn outputManagerApply(listener: *wl.Listener(*wlr.OutputConfigurationV1), output_configuration: *wlr.OutputConfigurationV1) void {
        const self: *Session = @fieldParentPtr("output_manager_apply_event", listener);

        self.outputManagerApply(false, output_configuration) catch |err| {
            std.log.err("failed to update monitors {s}", .{@errorName(err)});
        };
    }

    pub fn xwayland_ready(listener: *wl.Listener(void)) void {
        const self: *Session = @fieldParentPtr("xwayland_ready_event", listener);

        self.xwayland_ready(self.xwayland.?) catch |err| {
            std.log.err("failed to init server xwayland {}", .{err});
        };
        self.input.xwayland_ready(self.xwayland.?);
    }

    pub fn new_toplevel_decoration(listener: *wl.Listener(*wlr.XdgToplevelDecorationV1), decoration: *wlr.XdgToplevelDecorationV1) void {
        _ = listener;

        _ = decoration.setMode(.server_side);
    }

    pub fn new_layer_surface(listener: *wl.Listener(*wlr.LayerSurfaceV1), xdg_layer_surface: *wlr.LayerSurfaceV1) void {
        const self: *Session = @fieldParentPtr("new_layer_surface_event", listener);

        self.newLayerSurfaceClient(xdg_layer_surface) catch |err| {
            std.log.err("failed to init layer surface {}", .{err});
        };
    }

    pub fn new_xdg_popup(listener: *wl.Listener(*wlr.XdgPopup), xdg_surface: *wlr.XdgPopup) void {
        const self: *Session = @fieldParentPtr("new_xdg_popup_event", listener);

        std.log.info("{*} {}", .{ xdg_surface.base, xdg_surface.base.role });

        self.newClient(.{ .XDG = xdg_surface.base }) catch |err| {
            std.log.err("failed to init client {}", .{err});
        };
    }

    pub fn new_xdg_toplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_surface: *wlr.XdgToplevel) void {
        const self: *Session = @fieldParentPtr("new_xdg_toplevel_event", listener);

        std.log.info("{*} {}", .{ xdg_surface.base, xdg_surface.base.role });

        self.newClient(.{ .XDG = xdg_surface.base }) catch |err| {
            std.log.err("failed to init client {}", .{err});
        };
    }

    pub fn new_xdg_surface(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
        const self: *Session = @fieldParentPtr("new_xdg_surface_event", listener);

        std.log.info("{*} {}", .{ xdg_surface, xdg_surface.role });

        self.newClient(.{ .XDG = xdg_surface }) catch |err| {
            std.log.err("failed to init client {}", .{err});
        };
    }

    pub fn new_xwayland_surface(listener: *wl.Listener(*wlr.XwaylandSurface), xwayland_surface: *wlr.XwaylandSurface) void {
        const self: *Session = @fieldParentPtr("new_xwayland_surface_event", listener);

        self.newClient(.{ .X11 = xwayland_surface }) catch |err| {
            std.log.err("failed to init client {}", .{err});
        };
    }

    pub fn layoutChange(listener: *wl.Listener(*wlr.OutputLayout), _: *wlr.OutputLayout) void {
        const self: *Session = @fieldParentPtr("layout_change_event", listener);

        self.updateMons() catch |err| {
            std.log.err("failed to init client {}", .{err});
        };
    }
};

pub fn deinit(self: *Session) void {
    self.server.destroyClients();

    self.config.deinit();

    self.xwayland.?.destroy();
    self.xwayland = null;

    self.backend.destroy();

    self.renderer.destroy();
    self.wlr_allocator.destroy();

    self.scene.tree.node.destroy();

    self.server.destroy();
}

fn outputManagerApply(self: *Session, is_test: bool, output_configuration: *wlr.OutputConfigurationV1) !void {
    std.log.info("monitor manager apply test: {}", .{is_test});

    var ok = true;

    var iter = output_configuration.heads.iterator(.forward);
    while (iter.next()) |config_head| {
        const wlr_output = config_head.state.output;
        const monitor: *Monitor = @ptrFromInt(wlr_output.data);

        var state = wlr.Output.State.init();
        defer state.finish();

        state.setEnabled(config_head.state.enabled);

        if (config_head.state.enabled) {
            if (config_head.state.mode) |mode|
                state.setMode(mode)
            else
                state.setCustomMode(
                    config_head.state.custom_mode.width,
                    config_head.state.custom_mode.height,
                    config_head.state.custom_mode.refresh,
                );

            if (monitor.mode.x != config_head.state.x or
                monitor.mode.y != config_head.state.y)
            {
                const layout_output = try self.output_layout.add(monitor.output, config_head.state.x, config_head.state.y);
                monitor.scene_output.setPosition(layout_output.x, layout_output.y);
            }

            state.setTransform(config_head.state.transform);
            state.setScale(config_head.state.scale);
            state.setAdaptiveSyncEnabled(config_head.state.adaptive_sync_enabled);
        }

        ok = ok and
            if (is_test)
            wlr_output.testState(&state)
        else
            wlr_output.commitState(&state);

        std.log.info("move monitor {*}, {} {}", .{ monitor, monitor.mode, monitor.window });
    }

    if (ok) {
        output_configuration.sendSucceeded();
    } else {
        output_configuration.sendFailed();
    }

    output_configuration.destroy();

    try self.updateMons();
}

fn newLayerSurfaceClient(self: *Session, surface: *wlr.LayerSurfaceV1) !void {
    std.log.info("new layer surface {*}", .{surface});

    try LayerSurface.create(self, surface);
}

fn newClient(self: *Session, surface: Client.ClientSurface) !void {
    std.log.info("process xdg surface create for {}", .{surface});

    try Client.init(self, surface);
}

const logger = struct {
    fn readArg(vl: *std.builtin.VaList, comptime T: type) T {
        const T_size = @sizeOf(T);

        const is_float = switch (@typeInfo(T)) {
            .float => true,
            else => false,
        };

        if (is_float) {
            // Floating-point argument
            if (vl.fp_offset + 16 <= 128) {
                const reg_ptr = @as([*]u8, @ptrCast(vl.reg_save_area)) + vl.fp_offset;
                vl.fp_offset += 16;
                return @as(*const T, @ptrCast(@alignCast(reg_ptr))).*;
            } else {
                const ptr: *T = @ptrCast(@alignCast(vl.overflow_arg_area));
                vl.overflow_arg_area = @ptrFromInt(@intFromPtr(vl.overflow_arg_area) + T_size);
                return ptr.*;
            }
        } else {
            // Integer or pointer argument
            if (vl.gp_offset + 8 <= 48) {
                const reg_ptr = @as([*]u8, @ptrCast(vl.reg_save_area)) + vl.gp_offset;
                vl.gp_offset += 8;
                return @as(*const T, @ptrCast(@alignCast(reg_ptr))).*;
            } else {
                const ptr: *T = @ptrCast(@alignCast(vl.overflow_arg_area));
                vl.overflow_arg_area = @ptrFromInt(@intFromPtr(vl.overflow_arg_area) + T_size);
                return ptr.*;
            }
        }
    }

    pub fn log(importance: wlr.log.Importance, fmt: [*:0]const u8, args: *std.builtin.VaList) callconv(.C) void {
        var out = allocator.alloc(u8, std.mem.len(fmt) + 1024) catch unreachable;
        defer allocator.free(out);

        var out_idx: usize = 0;
        var in_idx: usize = 0;
        while (fmt[in_idx] != 0) {
            if (fmt[in_idx] == '%') {
                in_idx += 2;
                switch (fmt[(in_idx - 1)]) {
                    's' => out_idx += (std.fmt.bufPrint(out[out_idx..], "{s}", get_arg: {
                        const arg = readArg(args, [*:0]const u8);
                        break :get_arg .{arg[0..std.mem.len(arg)]};
                    }) catch &.{}).len,
                    'u' => {
                        out_idx += (std.fmt.bufPrint(
                            out[out_idx..],
                            "{}",
                            .{readArg(args, u64)},
                        ) catch &.{}).len;
                    },
                    'd' => {
                        if (fmt[in_idx + 1] == 'X') {
                            out_idx += (std.fmt.bufPrint(
                                out[out_idx..],
                                "{X}",
                                .{readArg(args, i64)},
                            ) catch &.{}).len;
                        } else {
                            out_idx += (std.fmt.bufPrint(
                                out[out_idx..],
                                "{}",
                                .{readArg(args, i64)},
                            ) catch &.{}).len;
                        }
                    },
                    'f' => out_idx += (std.fmt.bufPrint(
                        out[out_idx..],
                        "{}",
                        .{readArg(args, f64)},
                    ) catch &.{}).len,
                    'p' => out_idx += (std.fmt.bufPrint(
                        out[out_idx..],
                        "{?}",
                        .{readArg(args, ?*anyopaque)},
                    ) catch &.{}).len,
                    else => |ch| {
                        if (ch <= '9' and ch >= '0') {
                            while (fmt[in_idx] <= '9' and fmt[in_idx] >= '0') : (in_idx += 1) {}
                            const arg = readArg(args, usize);
                            out_idx += (std.fmt.bufPrint(
                                out[out_idx..],
                                "{x}",
                                .{arg},
                            ) catch &.{}).len;
                            out_idx += 1;
                        } else {
                            _ = readArg(args, *anyopaque);
                            out_idx += 0;
                            in_idx -= 1;
                        }
                    },
                }
            } else {
                out[out_idx] = fmt[in_idx];

                in_idx += 1;
                out_idx += 1;
            }
        }

        const zig_log = std.log.scoped(.WLR);

        switch (importance) {
            .err => zig_log.err("{s}", .{out[0..out_idx]}),
            .info => zig_log.warn("{s}", .{out[0..out_idx]}),
            .debug => zig_log.info("{s}", .{out[0..out_idx]}),
            .silent => zig_log.debug("{s}", .{out[0..out_idx]}),
            else => {},
        }
    }
};

pub fn init() SessionError!Session {
    // wlr.log.init(.debug, &logger.log);

    const wl_server = try wl.Server.create();
    const loop = wl_server.getEventLoop();

    const backend = try wlr.Backend.autocreate(loop, null);
    const scene = try wlr.Scene.create();

    const renderer = try wlr.Renderer.autocreate(backend);
    try renderer.initWlShm(wl_server);

    const compositor = try wlr.Compositor.create(wl_server, 6, renderer);

    const layers = std.EnumArray(Layer, *wlr.SceneTree).init(.{
        .LyrBg = try scene.tree.createSceneTree(),
        .LyrBottom = try scene.tree.createSceneTree(),
        .LyrTileShadows = try scene.tree.createSceneTree(),
        .LyrTile = try scene.tree.createSceneTree(),
        .LyrFloatShadows = try scene.tree.createSceneTree(),
        .LyrFloat = try scene.tree.createSceneTree(),
        .LyrFS = try scene.tree.createSceneTree(),
        .LyrTop = try scene.tree.createSceneTree(),
        .LyrOverlay = try scene.tree.createSceneTree(),
        .LyrDragIcon = try scene.tree.createSceneTree(),
        .LyrBlock = try scene.tree.createSceneTree(),
    });

    try renderer.initServer(wl_server);

    const wlr_allocator = try wlr.Allocator.autocreate(backend, renderer);

    _ = try wlr.Subcompositor.create(wl_server);
    _ = try wlr.DataDeviceManager.create(wl_server);
    _ = try wlr.ExportDmabufManagerV1.create(wl_server);
    _ = try wlr.ScreencopyManagerV1.create(wl_server);
    _ = try wlr.DataControlManagerV1.create(wl_server);
    _ = try wlr.PrimarySelectionDeviceManagerV1.create(wl_server);
    _ = try wlr.Viewporter.create(wl_server);
    _ = try wlr.SinglePixelBufferManagerV1.create(wl_server);
    _ = try wlr.FractionalScaleManagerV1.create(wl_server, 1);
    _ = try wlr.Presentation.create(wl_server, backend);
    _ = try wlr.GammaControlManagerV1.create(wl_server);

    const xdg_activation = try wlr.XdgActivationV1.create(wl_server);

    const output_layout = try wlr.OutputLayout.create(wl_server);

    _ = try wlr.XdgOutputManagerV1.create(wl_server, output_layout);

    // todo: locked bg

    const xdg_shell = try wlr.XdgShell.create(wl_server, 5);

    const layer_shell = try wlr.LayerShellV1.create(wl_server, 4);
    const idle_notifier = try wlr.IdleNotifierV1.create(wl_server);
    const idle_inhibit_manager = try wlr.IdleInhibitManagerV1.create(wl_server);
    const session_lock_manager = try wlr.SessionLockManagerV1.create(wl_server);
    const xdg_decoration_manager = try wlr.XdgDecorationManagerV1.create(wl_server);

    const xwayland = try wlr.Xwayland.create(wl_server, compositor, false);
    const output_manager = try wlr.OutputManagerV1.create(wl_server);

    return .{
        .config = .{
            .font = .{ .face = try allocator.dupeZ(u8, "monospace") },
        },

        .server = wl_server,
        .backend = backend,
        .scene = scene,
        .renderer = renderer,
        .wlr_allocator = wlr_allocator,
        .output_layout = output_layout,
        .output_manager = output_manager,
        .layers = layers,
        .idle_notifier = idle_notifier,
        .idle_inhibit_manager = idle_inhibit_manager,
        .layer_shell = layer_shell,
        .session_lock_manager = session_lock_manager,
        .compositor = compositor,
        .xdg_shell = xdg_shell,
        .xdg_decoration_manager = xdg_decoration_manager,
        .xdg_activation = xdg_activation,
        .xwayland = xwayland,
        .net_atoms = .initUndefined(),
    };
}

pub fn attachEvents(self: *Session) SessionError!void {
    signal_session = self;

    self.monitors.init();
    self.clients.init();
    self.focus_clients.init();

    try self.input.init(self);

    try self.config.setupLua();

    _ = try wl.Global.create(self.server, conpositor.IpcManagerV1, 1, *Session, self, IpcOutput.managerBind);

    self.output_layout.events.change.add(&self.layout_change_event);

    self.backend.events.new_output.add(&self.new_output_event);

    self.xdg_shell.events.new_toplevel.add(&self.new_xdg_toplevel_event);
    self.xdg_shell.events.new_surface.add(&self.new_xdg_surface_event);
    self.xdg_shell.events.new_popup.add(&self.new_xdg_popup_event);

    self.layer_shell.events.new_surface.add(&self.new_layer_surface_event);

    self.xdg_decoration_manager.events.new_toplevel_decoration.add(&self.new_toplevel_decoration_event);

    self.xwayland.?.events.new_surface.add(&self.new_xwayland_surface_event);
    self.xwayland.?.events.ready.add(&self.xwayland_ready_event);

    self.output_manager.events.apply.add(&self.output_manager_apply_event);
    self.output_manager.events.@"test".add(&self.output_manager_test_event);
}

pub fn launch(self: *Session) SessionError!void {
    const signals = [_]i32{ std.c.SIG.CHLD, std.c.SIG.INT, std.c.SIG.TERM, std.c.SIG.PIPE };

    inline for (signals) |sig| {
        _ = std.c.sigaction(sig, &.{
            .flags = std.c.SA.RESTART,
            .handler = .{ .handler = &handleSignal },
            .mask = std.posix.sigemptyset(),
        }, null);
    }

    var buf: [11]u8 = undefined;
    const socket = try self.server.addSocketAuto(&buf);

    _ = c.setenv("WAYLAND_DISPLAY", socket, 1);
    _ = c.setenv("DISPLAY", self.xwayland.?.display_name, 1);

    try self.config.sourcePath("init.lua");

    try self.backend.start();

    _ = try self.config.sendEvent(?*anyopaque, .startup, null);

    if (self.getObjectsAt(self.input.cursor.x, self.input.cursor.y).monitor) |monitor|
        try self.focusMonitor(monitor);

    self.input.cursor.setXcursor(self.input.xcursor_manager, "default");

    self.server.run();
}

pub fn updateMons(self: *Session) !void {
    std.log.info("update monitors", .{});

    const config = try wlr.OutputConfigurationV1.create();

    {
        var iter = self.monitors.iterator(.forward);
        while (iter.next()) |monitor| {
            if (monitor.output.enabled)
                continue;

            const config_head = try wlr.OutputConfigurationV1.Head.create(config, monitor.output);

            config_head.state.enabled = false;

            self.output_layout.remove(monitor.output);
            try monitor.close();
            monitor.mode = std.mem.zeroes(wlr.Box);
            monitor.window = std.mem.zeroes(wlr.Box);
        }
    }

    {
        var iter = self.monitors.iterator(.forward);
        while (iter.next()) |monitor| {
            if (monitor.output.enabled and
                self.output_layout.get(monitor.output) == null)
            {
                const layout_output = try self.output_layout.addAuto(monitor.output);
                monitor.scene_output.setPosition(layout_output.x, layout_output.y);
            }
        }
    }

    var sgeom: wlr.Box = undefined;
    self.output_layout.getBox(null, &sgeom);

    {
        var iter = self.monitors.iterator(.forward);
        while (iter.next()) |monitor| {
            if (!monitor.output.enabled)
                continue;

            const config_head = try wlr.OutputConfigurationV1.Head.create(config, monitor.output);

            self.output_layout.getBox(monitor.output, &monitor.mode);
            monitor.window = monitor.mode;

            try monitor.arrangeLayers();

            // TODO: update fullscreen client

            config_head.state.enabled = true;
            config_head.state.mode = monitor.output.current_mode;
            config_head.state.x = monitor.mode.x;
            config_head.state.y = monitor.mode.y;
        }
    }

    if (self.focusedMonitor) |selected| {
        if (selected.output.enabled) {
            var iter = self.clients.iterator(.forward);
            while (iter.next()) |client| {
                if (client.monitor == null and client.isMapped()) {
                    try client.setMonitor(selected);
                }
            }

            if (selected.focusedClient()) |client|
                try self.focusClient(client, false)
            else
                self.focusClear();
        }
    }

    self.output_manager.setConfiguration(config);
}

pub fn focusedClient(self: *Session) ?*Client {
    const selected = self.focusedMonitor orelse return null;

    return selected.focusedClient();
}

pub fn getSurfaceObjects(self: *Session, surface: *wlr.Surface) ObjectData {
    const root_surface = surface.getRootSurface();

    if (wlr.XwaylandSurface.tryFromWlrSurface(root_surface)) |x_surface|
        return .{
            .client = @ptrFromInt(x_surface.data),
        };

    if (wlr.LayerSurfaceV1.tryFromWlrSurface(root_surface)) |layer_surface|
        return .{
            .layer_surface = @ptrFromInt(layer_surface.data),
        };

    var vxdg_surface = wlr.XdgSurface.tryFromWlrSurface(root_surface);
    while (vxdg_surface) |*xdg_surface| {
        switch (xdg_surface.*.role) {
            .popup => {
                if (xdg_surface.*.role_data.popup.?.parent) |parent| {
                    if (wlr.XdgSurface.tryFromWlrSurface(parent)) |parent_surface|
                        vxdg_surface = parent_surface
                    else
                        return self.getSurfaceObjects(parent);
                } else return .{};
            },
            .toplevel => {
                return .{
                    .client = @ptrFromInt(xdg_surface.*.data),
                };
            },
            .none => return .{},
        }
    }

    return .{};
}

const ViewAtResult = struct {
    toplevel: *Client,
    sx: f64,
    sy: f64,
};

pub fn viewAt(session: *Session, lx: f64, ly: f64) ?ViewAtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;

    if (session.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
        if (node.type != .buffer) return null;

        const scene_buffer = wlr.SceneBuffer.fromNode(node);
        const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

        var it: ?*wlr.SceneTree = node.parent;
        while (it) |n| : (it = n.node.parent) {
            if (@as(?*Client, @ptrFromInt(n.node.data))) |toplevel| {
                return ViewAtResult{
                    .toplevel = toplevel,
                    .surface = scene_surface.surface,
                    .sx = sx,
                    .sy = sy,
                };
            }
        }
    }
}

pub fn quit(self: *Session) void {
    std.log.info("Quitting conpositor", .{});
    self.server.terminate();
}

pub fn focusClient(self: *Session, client: *Client, lift: bool) !void {
    const input = self.input;

    if (input.locked)
        return;

    const old_focus = input.seat.keyboard_state.focused_surface;

    if (lift or !client.floating) {
        client.frame.shadow_tree.node.raiseToTop();
        client.scene.node.raiseToTop();
    }

    if (client.getSurface() == old_focus)
        return;

    if (client.managed) {
        client.focus_link.remove();
        self.focus_clients.prepend(client);
        if (client.surface == .X11)
            client.surface.X11.restack(null, .above);
    }

    if (old_focus != null and (client.getSurface() != old_focus)) {
        if (old_focus.? == self.exclusive_focus)
            return;

        const old_client: ?*Client = self.getSurfaceObjects(old_focus.?).client;
        if (old_client) |old|
            old.activateSurface(false);
    }

    try self.input.motionNotify(0);
    client.notifyEnter(input.seat, input.seat.getKeyboard());
    client.activateSurface(true);
}

pub fn focusClear(self: *Session) void {
    const input = self.input;

    if (input.locked) return;

    const old_focus = input.seat.keyboard_state.focused_surface;

    if (old_focus) |old| {
        const old_client: ?*Client = self.getSurfaceObjects(old).client;
        if (old_client) |old_focus_client|
            old_focus_client.activateSurface(false);
    }

    self.input.seat.keyboardNotifyClearFocus();
}

pub const ObjectData = struct {
    client: ?*Client = null,
    layer_surface: ?*LayerSurface = null,

    surface: ?*wlr.Surface = null,
    surface_x: f64 = 0.0,
    surface_y: f64 = 0.0,

    monitor: ?*Monitor = null,
};

pub fn getObjectsAt(self: *Session, x: f64, y: f64) ObjectData {
    var result: ObjectData = .{};

    for (FOCUS_ORDER) |layer_id| {
        const layer = self.layers.get(layer_id);
        const node = layer.node.at(x, y, &result.surface_x, &result.surface_y);

        if (node != null and node.?.type == .buffer) {
            const scene_buffer = wlr.SceneBuffer.fromNode(node.?);

            if (wlr.SceneSurface.tryFromBuffer(scene_buffer)) |scene_surface|
                result.surface = scene_surface.surface;
        }

        var pnode = node;
        while (pnode != null and result.client == null) : (pnode = &pnode.?.parent.?.node) {
            result.client = @as(?*Client, @ptrFromInt(pnode.?.data));
            result.layer_surface = @as(?*LayerSurface, @ptrFromInt(pnode.?.data));

            if (result.client != null and result.client.?.client_id != 10)
                result.client = null;

            if (result.layer_surface != null and result.layer_surface.?.surface_id != 25)
                result.layer_surface = null;
        }
    }

    result.monitor = if (self.output_layout.outputAt(x, y)) |output|
        @as(?*Monitor, @ptrFromInt(output.data))
    else
        null;

    return result;
}

pub fn focusStack(self: *Session, dir: CycleDir) !void {
    const sel = self.focusedClient() orelse return;

    if (sel.fullscreen)
        return;

    const selmon = sel.monitor orelse return;

    const target = switch (dir) {
        .forward => blk: {
            const IterType = wl.list.Head(Client, .link).Iterator(.forward);
            var iter: IterType = .{ .head = &sel.link, .current = &sel.link };
            while (iter.next()) |client| {
                if (&client.link == &self.clients.link)
                    continue;
                if (selmon.clientVisible(client) and
                    client.container == sel.container and
                    client.floating == sel.floating)
                    break :blk client;
            }

            return;
        },
        .backward => blk: {
            const IterType = wl.list.Head(Client, .link).Iterator(.reverse);
            var iter: IterType = .{ .head = &sel.link, .current = &sel.link };
            while (iter.next()) |client| {
                if (&client.link == &self.clients.link)
                    continue;
                if (selmon.clientVisible(client) and
                    client.container == sel.container and
                    client.floating == sel.floating)
                    break :blk client;
            }

            return;
        },
    };

    try self.focusClient(target, true);
}

pub fn reloadColors(self: *Session) !void {
    // var iter = self.monitors.iterator(.forward);
    // while (iter.next()) |monitor|
    //     try monitor.arrangeLayers();
    var iter = self.clients.iterator(.forward);
    while (iter.next()) |client|
        try client.updateFrame();
}

pub fn addIpc(self: *Session, resource: *conpositor.IpcSessionV1) void {
    _ = self;
    _ = resource;
}

var signal_session: ?*Session = null;

pub fn handleSignal(signo: i32) callconv(.c) void {
    const session = signal_session orelse return;

    if (signo == std.c.SIG.CHLD) {
        var info: std.os.linux.siginfo_t = undefined;
        var tmp: u32 = 0;

        while (std.os.linux.waitid(.ALL, 0, &info, std.c.W.EXITED | std.c.W.NOHANG | std.c.W.NOWAIT) == 0 and
            info.fields.common.first.piduid.pid != 0 and
            (session.xwayland == null or info.fields.common.first.piduid.pid != session.xwayland.?.server.?.pid))
            _ = std.os.linux.waitpid(info.fields.common.first.piduid.pid, &tmp, 0);
    } else if (signo == std.c.SIG.INT or signo == std.c.SIG.TERM) {
        session.server.terminate();
    }
}

fn getAtom(xc: *c.xcb_connection_t, name: [:0]const u8) c.xcb_atom_t {
    var atom: c.xcb_atom_t = 0;
    const cookie = c.xcb_intern_atom(xc, 0, @intCast(name.len), name);
    const reply = c.xcb_intern_atom_reply(xc, cookie, null);
    if (reply != 0)
        atom = reply.*.atom;
    c.free(reply);

    return atom;
}

fn xwayland_ready(self: *Session, xwayland: *wlr.Xwayland) !void {
    const xc = c.xcb_connect(xwayland.display_name, null) orelse return;
    defer c.xcb_disconnect(xc);
    if (c.xcb_connection_has_error(xc) != 0) {
        std.log.info("xcb_connect_failed", .{});
    }

    self.net_atoms.set(.window_type_dialog, getAtom(xc, "_NET_WM_WINDOW_TYPE_DIALOG"));
    self.net_atoms.set(.window_type_splash, getAtom(xc, "_NET_WM_WINDOW_TYPE_SPLASH"));
    self.net_atoms.set(.window_type_toolbar, getAtom(xc, "_NET_WM_WINDOW_TYPE_TOOLBAR"));
    self.net_atoms.set(.window_type_utility, getAtom(xc, "_NET_WM_WINDOW_TYPE_UTILITY"));
}

pub fn focusMonitor(self: *Session, monitor: *Monitor) !void {
    if (self.focusedMonitor == monitor) return;
    if (!monitor.output.enabled) return;

    self.focusedMonitor = monitor;
}
