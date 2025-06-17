const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");
const conpositor = @import("wayland").server.conpositor;

const ipc = @import("ipc.zig");

const LayerSurface = @import("layersurface.zig");
const Config = @import("config.zig");
const Session = @import("session.zig");
const Client = @import("client.zig");

const Monitor = @This();

const allocator = Config.allocator;

const TOTAL_LAYERS = 4;
const LAYERS_ABOVE_SHELL = [_]u32{ 3, 2 };

session: *Session,
output: *wlr.Output,
scene_output: *wlr.SceneOutput,
fullscreen_bg: *wlr.SceneRect,
window: wlr.Box,
mode: wlr.Box,
layers: [TOTAL_LAYERS]wl.list.Head(LayerSurface, .link) = undefined,
tag: u8 = 0,
link: wl.list.Link = undefined,
layout: u8 = 0,
state: wlr.Output.State,
ipc_status: wl.list.Head(conpositor.IpcOutputV1, null) = undefined,

frame_event: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(Listeners.frame),
deinit_event: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(Listeners.deinit),

const Listeners = struct {
    fn frame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const self: *Monitor = @fieldParentPtr("frame_event", listener);

        self.frame() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    fn deinit(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const self: *Monitor = @fieldParentPtr("deinit_event", listener);

        self.deinit();
    }
};

pub fn init(self: *Monitor, session: *Session, output_in: *wlr.Output) !void {
    var output = output_in;

    if (!output.initRender(session.wlr_allocator, session.renderer)) {
        return error.DisplayRenderInitFailed;
    }

    const fullscreen_bg = try session.layers.get(.LyrFS).createSceneRect(0, 0, session.config.getColor(false, .background));
    fullscreen_bg.node.setEnabled(false);

    const mode: wlr.Box = std.mem.zeroes(wlr.Box);

    self.state = wlr.Output.State.init();

    // const rule = (session.config.monitor_rules.get(std.mem.span(output.name)));
    self.state.setEnabled(true);
    // self.state.setScale(rule.scale.?);
    // self.state.setTransform(rule.transform.?);
    self.state.setAdaptiveSyncEnabled(true);
    // mode.x = rule.x.?;
    // mode.y = rule.y.?;

    if (output.preferredMode()) |pref_mode|
        self.state.setMode(pref_mode);

    _ = output.commitState(&self.state);

    const scene_output = try session.scene.createSceneOutput(output);
    _ = if (mode.x != 0 and mode.y != 0)
        try session.output_layout.add(output, mode.x, mode.y)
    else
        try session.output_layout.addAuto(output);

    self.* = .{
        .output = output,
        .session = session,
        .fullscreen_bg = fullscreen_bg,
        .scene_output = scene_output,
        .mode = mode,
        .window = mode,
        .state = self.state,
    };

    self.ipc_status.init();
    session.output_layout.getBox(output, &self.mode);

    std.log.info("Create monitor {s} at {}", .{ output.name, mode });

    for (&self.layers) |*layer|
        layer.init();

    output.events.frame.add(&self.frame_event);
    output.events.destroy.add(&self.deinit_event);

    if (!self.output.commitState(&self.state)) {
        std.log.info("fail create monitor {s} at {}", .{ output.name, mode });
    }
}

pub fn frame(self: *Monitor) !void {
    // TODO:Figure out why this skips
    //commit: {
    {
        // var iter = self.session.clients.iterator(.forward);
        // while (iter.next()) |client| {
        //     if (client.resize_serial != 0 and
        //         self.clientVisible(client) and
        //         !client.isStopped())
        //         break :commit;
        // }

        // self.output.commitState(self.state);
        _ = self.scene_output.commit(null);
    }

    var now: std.posix.timespec = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch
        @panic("CLOCK_MONOTONIC not supported");
    self.scene_output.sendFrameDone(&now);
}

pub fn close(self: *Monitor) !void {
    if (self.session.monitors.empty()) {
        self.session.selmon = null;
    } else {
        self.session.selmon = null;

        var iter = self.session.monitors.iterator(.forward);
        while (iter.next()) |monitor|
            if (self.session.selmon != self) {
                self.session.selmon = monitor;
                if (monitor.output.enabled) break;
            };
    }

    std.log.info("TODO: Monitor.close clients move", .{});
}

pub fn arrangeLayers(self: *Monitor) !void {
    var usable = self.mode;

    if (!self.output.enabled) return;

    for (0..4) |i|
        self.arrangeLayer(3 - i, &usable, true);

    if (!std.mem.eql(u8, std.mem.asBytes(&usable), std.mem.asBytes(&self.window))) {
        self.window = usable;
        try self.arrangeClients();
    }

    for (0..4) |i|
        self.arrangeLayer(3 - i, &usable, false);

    for (LAYERS_ABOVE_SHELL) |idx| {
        var iter = self.layers[idx].iterator(.reverse);
        while (iter.next()) |layersurface| {
            if (!self.session.input.locked and layersurface.surface.current.keyboard_interactive != .none and layersurface.mapped) {
                self.session.focusClear();
                self.session.exclusive_focus = layersurface.surface.surface;
                layersurface.notifyEnter(self.session.input.seat, self.session.input.seat.getKeyboard());
                return;
            }
        }
    }
}

pub fn clientVisible(self: *Monitor, client: *Client) bool {
    return (client.floating or
        self.session.config.getLayouts()[self.layout].container.has(client.container)) and
        client.monitor == self and self.tag == client.tag;
}

pub fn focusedClient(self: *Monitor) ?*Client {
    var iter = self.session.focus_clients.iterator(.forward);

    return focused: while (iter.next()) |client| {
        if (client.monitor == self and self.clientVisible(client))
            break :focused client;
    } else null;
}

pub fn arrangeClients(self: *Monitor) !void {
    const containers = self.session.config.getContainers();
    const layouts = self.session.config.getLayouts();

    const usage: []bool = try allocator.alloc(bool, containers.len);
    defer allocator.free(usage);

    const solved: []bool = try allocator.alloc(bool, containers.len);
    defer allocator.free(solved);
    for (solved) |*s| s.* = false;

    {
        var iter = self.session.focus_clients.iterator(.forward);
        while (iter.next()) |client| {
            if (client.monitor == self) {
                const visible = self.clientVisible(client);
                client.scene.node.setEnabled(visible);

                if (!client.floating and visible) {
                    client.hide_frame = solved[client.container];
                    solved[client.container] = true;
                } else {
                    client.hide_frame = false;
                }
            }
        }
    }

    for (solved, 0..) |u, u_idx| {
        if (u) {
            for (containers) |con| {
                usage[con.id] = con.has(@intCast(u_idx)) or usage[con.id];
            }
        }
    }

    var iter = self.session.clients.iterator(.forward);
    while (iter.next()) |client| {
        if (client.monitor == self) {
            const visible = self.clientVisible(client);

            if (!client.floating and visible) {
                const border = if (client.frame.kind == .hide) 0 else client.border;

                const new = layouts[self.layout].getSize(client.container, self.window, border, usage);

                if (border != 0) {
                    client.frame.kind = if (new.y == self.window.y)
                        .border
                    else
                        .title;
                }

                try client.resize(new);
            }
        }
    }

    iter = self.session.clients.iterator(.forward);
    while (iter.next()) |client|
        try client.updateFrame();

    // TODO: activate fullscreen

    try self.session.input.motionNotify(0, null, 0, 0, 0, 0);
}

fn arrangeLayer(self: *Monitor, idx: usize, usable: *wlr.Box, exclusive: bool) void {
    const full_area = self.mode;

    var iter = self.layers[idx].iterator(.forward);
    while (iter.next()) |layersurface| {
        const wlr_layer_surface = layersurface.surface;
        const state = &wlr_layer_surface.current;

        if (exclusive != (state.exclusive_zone > 0))
            continue;

        if (!layersurface.mapped)
            return;

        layersurface.scene.configure(&full_area, usable);
        layersurface.popups.node.setPosition(
            layersurface.scene_tree.node.x,
            layersurface.scene_tree.node.y,
        );
        layersurface.bounds.x = layersurface.scene_tree.node.x;
        layersurface.bounds.y = layersurface.scene_tree.node.y;
    }
}

pub fn setTag(self: *Monitor, tag: usize) !void {
    if (self.tag == tag)
        return;

    const old = self.tag;

    self.tag = tag;
    try self.arrangeClients();

    var iter = self.ipc_status.iterator(.forward);
    while (iter.next()) |resource| {
        inline for (.{ old, self.tag }) |id| {
            resource.sendTag(
                @intCast(id),
                self.session.config.tags.items[id],
                if (self.tag == id) .active else .none,
                0,
                0,
            );
        }

        resource.sendFrame();
    }
}

pub fn deinit(self: *Monitor) void {
    self.frame_event.link.remove();
    self.deinit_event.link.remove();

    self.link.remove();
    if (self.session.selmon == self)
        self.session.selmon = null;

    allocator.destroy(self);
}

pub fn addIpc(self: *Monitor, resource: *conpositor.IpcOutputV1) void {
    const tags = self.session.config.getTags();
    const layouts = self.session.config.getLayouts();

    // TODO: send containers
    // const containers = self.session.config.getContainers();

    resource.sendTags(@intCast(tags.len));

    for (tags, 0..) |tag, id| {
        resource.sendTag(
            @intCast(id),
            tag,
            if (self.tag == id) .active else .none,
            0,
            0,
        );
    }
    resource.sendLayout(
        @intCast(self.layout),
        layouts[self.layout].name,
    );

    if (self.focusedClient()) |focus| {
        resource.sendFocus(
            @ptrCast(focus.getLabel().ptr),
            focus.icon orelse "",
            @ptrCast(focus.getTitle().ptr),
            @ptrCast(focus.getAppId().ptr),
        );
    } else {
        resource.sendClearFocus();
    }

    resource.sendFrame();

    self.ipc_status.append(resource);
}

pub fn sendFocus(self: *Monitor) void {
    var iter = self.ipc_status.iterator(.forward);
    while (iter.next()) |resource| {
        if (self.focusedClient()) |focus| {
            resource.sendFocus(
                @ptrCast(focus.getLabel().ptr),
                focus.icon orelse "",
                @ptrCast(focus.getTitle().ptr),
                @ptrCast(focus.getAppId().ptr),
            );
        } else {
            resource.sendClearFocus();
        }

        resource.sendFrame();
    }
}

pub fn setLayout(self: *Monitor, layout: usize) !void {
    if (self.layout == layout)
        return;

    self.layout = layout;
    try self.arrangeClients();

    var iter = self.ipc_status.iterator(.forward);
    while (iter.next()) |resource| {
        resource.sendLayout(
            @intCast(self.layout),
            self.session.config.layouts.items[self.layout].name,
        );
        resource.sendFrame();
    }
}
