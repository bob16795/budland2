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
position: wlr.Box,
window: wlr.Box = .{
    .x = 0,
    .y = 0,
    .width = 0,
    .height = 0,
},
mode: wlr.Box = .{
    .x = 0,
    .y = 0,
    .width = 0,
    .height = 0,
},
layers: [TOTAL_LAYERS]wl.list.Head(LayerSurface, .link) = undefined,
tag: usize = 0,
link: wl.list.Link = undefined,
layout: usize = 0,
layout_symbol: []const u8 = "{???}",

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

    std.log.info("Create monitor", .{});

    if (!output.initRender(data.allocator, data.renderer)) {
        return error.DisplayRenderInitFailed;
    }

    var state = wlr.Output.State.init();
    defer state.finish();

    const fullscreen_bg = try data.layers.get(.LyrFS).createSceneRect(0, 0, &session.config.colors[0][1]);
    fullscreen_bg.node.setEnabled(false);

    const scene_output = try data.scene.createSceneOutput(output);

    // TODO: config
    const position: ?wlr.Box = null;

    const output_data = if (position) |pos|
        try data.output_layout.add(output, pos.x, pos.y)
    else
        try data.output_layout.addAuto(output);

    var output_box = std.mem.zeroes(wlr.Box);
    output_data.layout.getBox(output, &output_box);

    self.* = .{
        .output = output,
        .session = session,
        .fullscreen_bg = fullscreen_bg,
        .scene_output = scene_output,
        .position = position orelse output_box,
        .mode = output_box,
    };

    for (&self.layers) |*layer|
        layer.init();

    output.events.frame.add(&self.frame_event);
    output.events.destroy.add(&self.deinit_event);
}

pub fn frame(self: *Monitor) !void {
    const scene_output = self.session.wayland_data.?.scene.getSceneOutput(self.output).?;

    commit: {
        var iter = self.session.clients.iterator(.forward);
        while (iter.next()) |client| {
            if (client.resize_serial != 0 and
                !client.floating and
                client.monitor == self and
                !client.isStopped())
                break :commit;
        }

        _ = scene_output.commit(null);
    }

    var now: std.posix.timespec = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch
        @panic("CLOCK_MONOTONIC not supported");
    scene_output.sendFrameDone(&now);
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
        var iter = self.layers[idx].iterator(.forward);
        while (iter.next()) |layersurface| {
            if (!self.session.input.locked and @intFromEnum(layersurface.surface.current.keyboard_interactive) != 0 and layersurface.mapped) {
                try self.session.focus(null, false);
                self.session.exclusive_focus = layersurface;
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
    var iter = self.session.clients.iterator(.forward);
    while (iter.next()) |client| {
        const visible = self.clientVisible(client);
        client.scene.node.setEnabled(visible);

        if (!client.floating) {
            usage[client.container] = true;
            solved[client.container] = true;
        }
    }

    var done = false;
    while (!done) {
        done = true;

        outer: for (config.containers.items, 0..) |container, idx| {
            inner: for (container.children) |c| {
                if (!solved[c.id]) {
                    done = false;
                    continue :outer;
                }

                if (usage[c.id]) {
                    usage[idx] = true;
                    break :inner;
                }
            }

            solved[idx] = true;
        }
    }

    iter = self.session.clients.iterator(.forward);
    while (iter.next()) |client| {
        if (!client.floating) {
            const new = config.layouts.items[self.layout].getSize(client.container, self.window, usage);
            client.resize(new, true) catch {};
        }
    }

    // iter = self.session.clients.iterator(.forward);
    // if (self.client.container) |container| {
    //     // TODO: stack
    // }

    // const client = self.focusedClient();
    // TODO: activate fullscreen

    // const config = self.session.config;
    // self.layout_symbol = if (self.layout > config.layouts[])
    self.layout_symbol = "[???]";

    self.session.input.motionNotify(0, null, 0, 0, 0, 0) catch {};
}

fn arrangeLayer(self: *Monitor, idx: usize, usable: *wlr.Box, exclusive: bool) void {
    const full_area = self.mode;

    var iter = self.layers[idx].iterator(.forward);
    while (iter.next()) |layersurface| {
        const wlr_layer_surface = layersurface.surface;
        const state = &wlr_layer_surface.current;

        if (!layersurface.mapped) continue;

        if (exclusive != (state.exclusive_zone > 0))
            continue;

        layersurface.scene.configure(&full_area, usable);
        layersurface.popups.node.setPosition(
            layersurface.scene_tree.node.x,
            layersurface.scene_tree.node.x,
        );
    }
}

pub fn deinit(self: *Monitor) void {
    self.frame_event.link.remove();
    self.deinit_event.link.remove();

    self.link.remove();
    if (self.session.selmon == self)
        self.session.selmon = null;

    self.session.config.allocator.destroy(self);
}
