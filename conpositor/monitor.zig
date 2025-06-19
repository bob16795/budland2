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
layout: u8 = 0,
link: wl.list.Link = undefined,
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

pub fn create(session: *Session, output_in: *wlr.Output) !void {
    var output = output_in;

    if (!output.initRender(session.wlr_allocator, session.renderer)) {
        return error.DisplayRenderInitFailed;
    }

    const fullscreen_bg = try session.layers.get(.LyrFS).createSceneRect(0, 0, session.config.getColor(false, .background));
    fullscreen_bg.node.setEnabled(false);

    var state = wlr.Output.State.init();
    defer state.finish();

    // const rule = (session.config.monitor_rules.get(std.mem.span(output.name)));
    state.setEnabled(true);
    state.setScale(1.0);
    state.setTransform(.normal);
    state.setAdaptiveSyncEnabled(true);

    if (output.preferredMode()) |pref_mode| {
        state.setMode(pref_mode);
    }

    if (!output.commitState(&state)) {
        std.log.err("initial output commit with preferred mode failed, trying all modes", .{});

        var iter = output.modes.iterator(.forward);
        while (iter.next()) |mode| {
            state.setMode(mode);
            if (output.commitState(&state)) {
                std.log.info("initial output commit succeeded with mode {}x{}@{}mHz", .{
                    mode.width,
                    mode.height,
                    mode.refresh,
                });
                break;
            } else {
                std.log.err("initial output commit failed with mode {}x{}@{}mHz", .{
                    mode.width,
                    mode.height,
                    mode.refresh,
                });
            }
        }
    }

    std.log.info("Create monitor {s}", .{output.name});

    const scene_output = try session.scene.createSceneOutput(output);

    const result: *Monitor = try allocator.create(Monitor);
    output.data = @intFromPtr(result);

    result.* = .{
        .session = session,
        .output = output,
        .fullscreen_bg = fullscreen_bg,
        .scene_output = scene_output,
        .mode = std.mem.zeroes(wlr.Box),
        .window = std.mem.zeroes(wlr.Box),
    };
    for (&result.layers) |*layer|
        layer.init();

    result.ipc_status.init();

    output.events.frame.add(&result.frame_event);
    output.events.destroy.add(&result.deinit_event);

    session.monitors.append(result);

    _ = try session.output_layout.add(result.output, result.mode.x, result.mode.y);
    result.scene_output.setPosition(result.mode.x, result.mode.y);

    try session.updateMons();
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
    // const containers = self.session.config.getContainers();
    const layouts = self.session.config.getLayouts();

    // TODO: dynamic/packed allocation?
    var usage: [256]bool = .{false} ** 256;

    {
        var iter = self.session.focus_clients.iterator(.forward);
        while (iter.next()) |client| {
            if (client.monitor == self) {
                const visible = self.clientVisible(client);
                client.setVisible(visible);

                if (!client.floating and visible) {
                    client.hide_frame = usage[client.container];
                    usage[client.container] = true;
                } else {
                    client.hide_frame = false;
                    try client.setFrame(.title);
                }
            }
        }
    }

    var iter = self.session.clients.iterator(.forward);
    while (iter.next()) |client| {
        if (client.monitor == self) {
            const visible = self.clientVisible(client);

            if (!client.floating and visible) {
                const border = if (client.frame.kind == .hide) 0 else client.border;

                const new = layouts[self.layout].getSize(client.container, self.window, border, &usage);

                if (border != 0) {
                    try client.setFrame(if (new.y == self.window.y)
                        .border
                    else
                        .title);
                }

                try client.resize(new);
            }
        }
    }

    iter = self.session.clients.iterator(.forward);
    while (iter.next()) |client|
        try client.updateFrame();

    // TODO: update fullscreen state

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

pub fn setTag(self: *Monitor, tag: u8) !void {
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

pub fn setLayout(self: *Monitor, layout: i32) !void {
    if (self.layout == layout)
        return;

    if (self.session.config.layouts.items.len == 0)
        return;

    var new_layout: i32 = layout;
    while (new_layout < 0)
        new_layout += @intCast(self.session.config.layouts.items.len);
    new_layout = @mod(new_layout, @as(i32, @intCast(self.session.config.layouts.items.len)));
    self.layout = @intCast(new_layout);

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
