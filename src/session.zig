const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");
const xcb = @import("xcb");

const Config = @import("config.zig");
const Monitor = @import("monitor.zig");
const Client = @import("client.zig");
const Input = @import("input.zig");
const LayerSurface = @import("layersurface.zig");

const Session = @This();

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

pub const SessionError = error{
    ServerCreateFailed,
    BackendCreateFailed,
    RendererCreateFailed,
    AllocatorCreateFailed,
    XwaylandCreateFailed,
    RenderInitFailed,
    BackendStartFailed,
    AddSocketFailed,
    SessionNotSetup,
    OutOfMemory,
} || Config.ConfigError;

config: *Config,

wayland_data: ?struct {
    server: *wl.Server,
    backend: *wlr.Backend,
    scene: *wlr.Scene,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
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
    xwayland: *wlr.Xwayland,
} = null,
input: Input = undefined,

monitors: wl.list.Head(Monitor, .link) = undefined,
clients: wl.list.Head(Client, .link) = undefined,
focus_clients: wl.list.Head(Client, .focus_link) = undefined,
exclusive_focus: ?*wlr.Surface = null,

selmon: ?*Monitor = null,

layout_change_event: wl.Listener(*wlr.OutputLayout) = .init(Listeners.layoutChange),
xwayland_ready_event: wl.Listener(void) = .init(Listeners.xwayland_ready),

new_output_event: wl.Listener(*wlr.Output) = .init(Listeners.newOutput),
new_layer_surface_event: wl.Listener(*wlr.LayerSurfaceV1) = .init(Listeners.new_layer_surface),
new_xdg_surface_event: wl.Listener(*wlr.XdgSurface) = .init(Listeners.new_xdg_surface),
new_xwayland_surface_event: wl.Listener(*wlr.XwaylandSurface) = .init(Listeners.new_xwayland_surface),
new_toplevel_decoration_event: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(Listeners.new_toplevel_decoration),
output_manager_apply_event: wl.Listener(*wlr.OutputConfigurationV1) = .init(Listeners.outputManagerApply),
output_manager_test_event: wl.Listener(*wlr.OutputConfigurationV1) = .init(Listeners.outputManagerTest),

const FOCUS_ORDER = [_]Layer{
    .LyrBlock, .LyrOverlay, .LyrTop, .LyrFS, .LyrFloat, .LyrTile, .LyrBottom, .LyrBg,
};

const Listeners = struct {
    pub fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const session: *Session = @fieldParentPtr("new_output_event", listener);
        const data = &session.wayland_data.?;
        if (!wlr_output.initRender(data.allocator, data.renderer)) return;

        const monitor = session.config.allocator.create(Monitor) catch {
            std.log.err("failed to allocate new output", .{});
            wlr_output.destroy();
            return;
        };

        monitor.init(session, wlr_output) catch {
            std.log.err("failed to allocate new output", .{});
            wlr_output.destroy();
            return;
        };

        wlr_output.data = @intFromPtr(monitor);
        session.monitors.append(monitor);

        session.updateMons() catch |err| {
            std.log.err("failed to init client {}", .{err});
        };
    }

    pub fn outputManagerTest(listener: *wl.Listener(*wlr.OutputConfigurationV1), output_configuration: *wlr.OutputConfigurationV1) void {
        const self: *Session = @fieldParentPtr("output_manager_apply_event", listener);

        self.outputManagerApply(true, output_configuration);
    }

    pub fn outputManagerApply(listener: *wl.Listener(*wlr.OutputConfigurationV1), output_configuration: *wlr.OutputConfigurationV1) void {
        const self: *Session = @fieldParentPtr("output_manager_apply_event", listener);

        self.outputManagerApply(false, output_configuration);
    }

    pub fn xwayland_ready(listener: *wl.Listener(void)) void {
        const self: *Session = @fieldParentPtr("xwayland_ready_event", listener);

        const wayland_data = self.wayland_data.?;

        self.input.xwayland_ready(wayland_data.xwayland);
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

    pub fn new_xdg_surface(listener: *wl.Listener(*wlr.XdgSurface), xdg_surface: *wlr.XdgSurface) void {
        const self: *Session = @fieldParentPtr("new_xdg_surface_event", listener);

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

pub fn init(config: *Config) Session {
    return .{
        .config = config,
    };
}

pub fn deinit(self: *Session) void {
    const wayland_data = self.wayland_data.?;

    wayland_data.xwayland.destroy();
}

fn outputManagerApply(self: *Session, is_test: bool, output_configuration: *wlr.OutputConfigurationV1) void {
    std.log.info("output manager apply test: {}", .{is_test});

    var ok = true;

    var iter = output_configuration.heads.iterator(.forward);
    while (iter.next()) |config_head| {
        const wlr_output = config_head.state.output;
        const monitor: *Monitor = @ptrFromInt(wlr_output.data);

        defer if (is_test) {
            ok = ok and wlr_output.testState(&monitor.state);
        } else {
            ok = ok and wlr_output.commitState(&monitor.state);
        };

        monitor.state.setEnabled(config_head.state.enabled);
        if (!config_head.state.enabled) continue;
        if (config_head.state.mode) |mode|
            monitor.state.setMode(mode)
        else
            monitor.state.setCustomMode(
                config_head.state.custom_mode.width,
                config_head.state.custom_mode.height,
                config_head.state.custom_mode.refresh,
            );

        if (monitor.mode.x != config_head.state.x or monitor.mode.y != config_head.state.y)
            _ = monitor.session.wayland_data.?.output_layout.add(monitor.output, config_head.state.x, config_head.state.y) catch {};

        monitor.state.setTransform(config_head.state.transform);
        monitor.state.setScale(config_head.state.scale);
        monitor.state.setAdaptiveSyncEnabled(config_head.state.adaptive_sync_enabled);
    }

    output_configuration.destroy();

    self.updateMons() catch |err| {
        std.log.err("FAILED TO UPDATE MONS {}", .{err});
    };
}

fn newLayerSurfaceClient(self: *Session, surface: *wlr.LayerSurfaceV1) !void {
    std.log.info("new layer surface {*}", .{surface});

    if (surface.output == null)
        surface.output = if (self.selmon != null) self.selmon.?.output else null;

    if (surface.output == null) {
        std.log.info("cancel new layer surface {*} no outputs", .{surface});

        surface.destroy();

        return;
    }

    const layer_surface = try self.config.allocator.create(LayerSurface);
    try layer_surface.init(self, surface);

    std.log.info("tracking surface {*}", .{layer_surface});
}

fn newClient(self: *Session, surface: Client.ClientSurface) !void {
    std.log.info("process xdg surface create for {}", .{surface});

    const client = try self.config.allocator.create(Client);
    try client.init(self, surface);
    //try client.updateTree(self);

    self.clients.append(client);
    self.focus_clients.append(client);
    std.log.info("tracking client {*}", .{client});
}

const logger = struct {
    var allocator: std.mem.Allocator = undefined;

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

pub fn launch(self: *Session) SessionError!void {
    self.monitors.init();
    self.clients.init();
    self.focus_clients.init();

    logger.allocator = self.config.allocator;

    wlr.log.init(.debug, &logger.log);

    const wl_server = try wl.Server.create();
    const loop = wl_server.getEventLoop();
    const backend = try wlr.Backend.autocreate(loop, null);

    const scene = try wlr.Scene.create();

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

    const renderer = try wlr.Renderer.autocreate(backend);

    try renderer.initServer(wl_server);

    const allocator = try wlr.Allocator.autocreate(backend, renderer);

    const compositor = try wlr.Compositor.create(wl_server, 6, renderer);
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
    output_layout.events.change.add(&self.layout_change_event);

    _ = try wlr.XdgOutputManagerV1.create(wl_server, output_layout);
    backend.events.new_output.add(&self.new_output_event);

    const idle_notifier = try wlr.IdleNotifierV1.create(wl_server);
    const idle_inhibit_manager = try wlr.IdleInhibitManagerV1.create(wl_server);
    // TODO: events

    const layer_shell = try wlr.LayerShellV1.create(wl_server, 4);
    layer_shell.events.new_surface.add(&self.new_layer_surface_event);

    // todo: locked bg

    const xdg_shell = try wlr.XdgShell.create(wl_server, 4);
    xdg_shell.events.new_surface.add(&self.new_xdg_surface_event);

    const session_lock_manager = try wlr.SessionLockManagerV1.create(wl_server);
    const xdg_decoration_manager = try wlr.XdgDecorationManagerV1.create(wl_server);
    xdg_decoration_manager.events.new_toplevel_decoration.add(&self.new_toplevel_decoration_event);

    const xwayland = try wlr.Xwayland.create(wl_server, compositor, false);

    xwayland.events.new_surface.add(&self.new_xwayland_surface_event);
    xwayland.events.ready.add(&self.xwayland_ready_event);

    const output_manager = try wlr.OutputManagerV1.create(wl_server);
    output_manager.events.apply.add(&self.output_manager_apply_event);
    output_manager.events.@"test".add(&self.output_manager_test_event);

    var buf: [11]u8 = undefined;
    const socket = try wl_server.addSocketAuto(&buf);
    std.log.info("WAYLAND_DISPLAY: {s}", .{socket});
    std.log.info("DISPLAY: {s}", .{xwayland.display_name});

    self.config.wayland_display = try std.fmt.allocPrint(self.config.allocator, "{s}", .{socket});
    self.config.xwayland_display = try std.fmt.allocPrint(self.config.allocator, "{s}", .{xwayland.display_name});

    self.wayland_data = .{
        .server = wl_server,
        .backend = backend,
        .scene = scene,
        .renderer = renderer,
        .allocator = allocator,
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
    };

    try self.input.init(self);

    if (std.posix.getenv("HOME")) |home_dir| {
        const path = try std.mem.concat(self.config.allocator, u8, &.{
            home_dir,
            "/.config/",
            "/budland/budland.conf",
        });
        defer self.config.allocator.free(path);

        try self.config.sourcePath(path);
    }

    if (self.wayland_data) |data| {
        try data.backend.start();

        try self.config.event(.startup);

        self.selmon = self.getObjectsAt(self.input.cursor.x, self.input.cursor.y).monitor;
        self.input.cursor.setXcursor(self.input.xcursor_manager, "default");

        data.server.run();
    } else return error.SessionNotSetup;
}

fn updateMons(self: *Session) !void {
    std.log.info("update monitors", .{});

    const config = try wlr.OutputConfigurationV1.create();

    {
        var iter = self.monitors.iterator(.forward);
        while (iter.next()) |monitor| {
            if (monitor.output.enabled)
                continue;

            const config_head = try wlr.OutputConfigurationV1.Head.create(config, monitor.output);
            config_head.state.enabled = false;

            self.wayland_data.?.output_layout.remove(monitor.output);
            try monitor.close();

            // monitor.window = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            // monitor.mode = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        }
    }

    {
        var iter = self.monitors.iterator(.forward);
        while (iter.next()) |monitor| {
            if (monitor.output.enabled and
                self.wayland_data.?.output_layout.get(monitor.output) == null)
                _ = try self.wayland_data.?.output_layout.addAuto(monitor.output);
        }
    }

    var sgeom: wlr.Box = undefined;
    self.wayland_data.?.output_layout.getBox(null, &sgeom);

    {
        var iter = self.monitors.iterator(.forward);
        while (iter.next()) |monitor| {
            if (!monitor.output.enabled)
                continue;

            const config_head = try wlr.OutputConfigurationV1.Head.create(config, monitor.output);

            self.wayland_data.?.output_layout.getBox(monitor.output, &monitor.mode);
            monitor.window = monitor.mode;

            monitor.scene_output.setPosition(monitor.mode.x, monitor.mode.y);

            // if (monitor.lock_surface) |lock_surface| {
            //     const scene_tree = @as(*wlr.SceneTree, @ptrCast(@alignCast(self.wayland_data.?.lock_surface.surface.*.data)));
            //     scene_tree.node.setPosition(monitor.mode.x, monitor.mode.y);
            //     lock_surface.configure(monitor.mode.width, monitor.mode.height);
            // }

            monitor.arrangeLayers();
            monitor.arrangeClients();

            // if ((c = focustop(m)) && c->isfullscreen)
            // resize(c, m->m, 0);

            config_head.state.enabled = true;
            config_head.state.mode = monitor.output.current_mode;
            config_head.state.x = monitor.mode.x;
            config_head.state.y = monitor.mode.y;
        }
    }

    if (self.selmon) |selected| {
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

            // if (selected.lock_surface) |lock_surface|
            // client.notifyEnter(lock_surface.surface, self.input.seat.getKeyboard());
        }
    }

    self.input.cursor.move(null, 0, 0);

    self.wayland_data.?.output_manager.setConfiguration(config);
}

const ViewAtResult = struct {
    toplevel: *Client,
    sx: f64,
    sy: f64,
};

pub fn getClient(session: *Session, surface: *wlr.Surface) ?*Client {
    const root_surface = surface.getRootSurface();

    if (wlr.XwaylandSurface.tryFromWlrSurface(root_surface)) |x_surface|
        return @ptrFromInt(x_surface.data);

    if (wlr.LayerSurfaceV1.tryFromWlrSurface(root_surface)) |layer_surface|
        return @ptrFromInt(layer_surface.data);

    var vxdg_surface = wlr.XdgSurface.tryFromWlrSurface(root_surface);
    while (vxdg_surface) |*xdg_surface| {
        switch (xdg_surface.*.role) {
            .popup => {
                if (xdg_surface.*.role_data.popup.?.parent) |parent| {
                    if (wlr.XdgSurface.tryFromWlrSurface(parent)) |parent_surface|
                        vxdg_surface = parent_surface
                    else
                        return session.getClient(parent);
                } else return null;
            },
            .toplevel => {
                return @ptrFromInt(xdg_surface.*.data);
            },
            .none => return null,
        }
    }

    return null;
}

pub fn viewAt(session: *Session, lx: f64, ly: f64) ?ViewAtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;

    if (session.wayland_data.?.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
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
    std.log.info("Quitting budland", .{});
    self.wayland_data.?.server.terminate();
}

pub fn focusClient(self: *Session, client: *Client, lift: bool) !void {
    const input = self.input;

    if (input.locked)
        return;

    const old_focus = input.seat.keyboard_state.focused_surface;

    if (lift)
        client.scene.node.raiseToTop();

    if (client.getSurface() == old_focus)
        return;

    client.focus_link.remove();
    self.focus_clients.prepend(client);

    self.selmon = client.monitor;
    if (client.surface == .X11) {
        client.surface.X11.restack(null, .above);
    }
    // client_restack_surface(client.?);

    //TODO: color

    if (old_focus != null and (client.getSurface() != old_focus)) {
        if (old_focus.? == self.exclusive_focus)
            return;

        const old_client: ?*Client = self.getClient(old_focus.?);
        if (old_client) |old|
            old.activateSurface(false);
    }

    try self.input.motionNotify(0, null, 0, 0, 0, 0);

    client.notifyEnter(input.seat, input.seat.getKeyboard());
    client.activateSurface(true);
}

pub fn focusClear(self: *Session) void {
    const input = self.input;

    if (input.locked) return;

    const old_focus = input.seat.keyboard_state.focused_surface;

    if (old_focus) |old| {
        const old_client: ?*Client = self.getClient(old);
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
    const wayland_data = self.wayland_data.?;

    var result: ObjectData = .{};

    for (FOCUS_ORDER) |layer_id| {
        const layer = wayland_data.layers.get(layer_id);
        const node = layer.node.at(x, y, &result.surface_x, &result.surface_y);

        if (node != null and node.?.type == .buffer) {
            const scene_buffer = wlr.SceneBuffer.fromNode(node.?);

            if (wlr.SceneSurface.tryFromBuffer(scene_buffer)) |scene_surface|
                result.surface = scene_surface.surface;
            // if (c.wlr_scene_surface_from_buffer(c.wlr_scene_buffer_from_node(node))) |tmp| {
            //     surface = tmp.*.surface;
            // }
        }

        var pnode = node;
        while (pnode != null and result.client == null) : (pnode = &pnode.?.parent.?.node) {
            result.client = @as(?*Client, @ptrFromInt(pnode.?.data));
            result.layer_surface = @as(?*LayerSurface, @ptrFromInt(pnode.?.data));

            if (result.client != null and result.client.?.client_id != 10)
                result.client = null;

            if (result.layer_surface != null and result.layer_surface.?.surface_id != 25)
                result.layer_surface = null;

            if (pnode.?.parent == null) break;
        }
    }

    result.monitor = if (self.wayland_data.?.output_layout.outputAt(x, y)) |output|
        @as(?*Monitor, @ptrFromInt(output.data))
    else
        null;

    return result;
}
