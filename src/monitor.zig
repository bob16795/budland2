const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");

const LayerSurface = @import("layersurface.zig");
const Config = @import("config.zig");
const Session = @import("session.zig");
const Client = @import("client.zig");

const Monitor = @This();

const TOTAL_LAYERS = 4;
const LAYERS_ABOVE_SHELL = [_]u32{ 3, 2 };

session: *Session,
output: *wlr.Output,
scene_output: *wlr.SceneOutput,
fullscreen_bg: *wlr.SceneRect,
window: wlr.Box,
mode: wlr.Box,
layers: [TOTAL_LAYERS]wl.list.Head(LayerSurface, .link) = undefined,
tag: usize = 0,
link: wl.list.Link = undefined,
layout: usize = 0,
layout_symbol: []const u8 = "{???}",
state: wlr.Output.State,

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
    const data = &(session.wayland_data orelse return error.SessionNotSetup);
    var output = output_in;

    if (!output.initRender(data.allocator, data.renderer)) {
        return error.DisplayRenderInitFailed;
    }

    const fullscreen_bg = try data.layers.get(.LyrFS).createSceneRect(0, 0, &session.config.colors[0][1]);
    fullscreen_bg.node.setEnabled(false);

    var mode: wlr.Box = std.mem.zeroes(wlr.Box);

    self.state = wlr.Output.State.init();

    const rule = (session.config.monitor_rules.get(std.mem.span(output.name)));
    self.state.setEnabled(true);
    self.state.setScale(rule.scale.?);
    self.state.setTransform(rule.transform.?);
    self.state.setAdaptiveSyncEnabled(true);
    mode.x = rule.x.?;
    mode.y = rule.y.?;

    if (output.preferredMode()) |pref_mode|
        self.state.setMode(pref_mode);

    _ = output.commitState(&self.state);

    const scene_output = try data.scene.createSceneOutput(output);
    _ = if (mode.x != 0 and mode.y != 0)
        try data.output_layout.add(output, mode.x, mode.y)
    else
        try data.output_layout.addAuto(output);

    self.* = .{
        .output = output,
        .session = session,
        .fullscreen_bg = fullscreen_bg,
        .scene_output = scene_output,
        .mode = mode,
        .window = mode,
        .state = self.state,
    };

    session.wayland_data.?.output_layout.getBox(output, &self.mode);

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
    commit: {
        var iter = self.session.clients.iterator(.forward);
        while (iter.next()) |client| {
            if (client.resize_serial != 0 and
                !client.floating and
                self.clientVisible(client) and
                !client.isStopped())
                break :commit;
        }

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

pub fn arrangeLayers(self: *Monitor) void {
    var usable = self.mode;

    if (!self.output.enabled) return;

    for (0..4) |i|
        self.arrangeLayer(3 - i, &usable, true);

    if (!std.mem.eql(u8, std.mem.asBytes(&usable), std.mem.asBytes(&self.window))) {
        self.window = usable;
        self.arrangeClients();
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
    return client.monitor == self and self.tag == client.tag;
}

pub fn focusedClient(self: *Monitor) ?*Client {
    var iter = self.session.focus_clients.iterator(.forward);

    return focused: while (iter.next()) |client| {
        if (client.monitor == self and self.clientVisible(client))
            break :focused client;
    } else null;
}

pub fn arrangeClients(self: *Monitor) void {
    const config = self.session.config;

    const usage: []bool = config.allocator.alloc(bool, config.containers.items.len) catch unreachable;
    defer config.allocator.free(usage);

    const solved: []bool = config.allocator.alloc(bool, config.containers.items.len) catch unreachable;
    defer config.allocator.free(solved);
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
            for (config.containers.items) |con| {
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

                const new = config.layouts.items[self.layout].getSize(client.container, self.window, border, usage);

                if (border != 0) {
                    client.frame.kind = if (new.y == self.window.y)
                        .border
                    else
                        .title;
                }

                client.resize(new, true) catch {};
            }
        }
    }

    iter = self.session.clients.iterator(.forward);
    while (iter.next()) |client|
        client.updateFrame() catch {};

    // TODO: activate fullscreen

    const config = self.session.config;
    self.layout_symbol = config.layouts.items[self.layout].name;

    self.session.input.motionNotify(0, null, 0, 0, 0, 0) catch {};
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

pub fn setTag(self: *Monitor, tag: usize) void {
    if (self.tag == tag)
        return;

    self.tag = tag;
    self.arrangeClients();
}

pub fn deinit(self: *Monitor) void {
    self.frame_event.link.remove();
    self.deinit_event.link.remove();

    self.link.remove();
    if (self.session.selmon == self)
        self.session.selmon = null;

    self.session.config.allocator.destroy(self);
}
