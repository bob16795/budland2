const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");

const LayerSurface = @import("layersurface.zig");
const Config = @import("config.zig");
const Session = @import("session.zig");

const Monitor = @This();

const TOTAL_LAYERS = 4;

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
tags: std.DynamicBitSet,
link: wl.list.Link = undefined,

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
        .tags = try std.DynamicBitSet.initEmpty(session.config.allocator, session.config.tags.items.len),
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
    _ = scene_output.commit(null);

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

pub fn arrange(self: *Monitor) void {
    var usable = self.mode;
    const layers_above_shell = [_]u32{ 3, 4 };

    var iter = self.session.clients.iterator(.forward);
    while (iter.next()) |client| {
        client.scene.node.setEnabled(true);
    }

    // TODO: fstack
    // const client: ?*Client = self.clients);
    // self.fullscreen_bg.node.setEnabled(client != null and client.?.isfullscreen);

    if (!self.output.enabled) return;

    _ = layers_above_shell;

    for (0..4) |i|
        self.arrangelayer(3 - i, &usable, true);

    if (!std.mem.eql(u8, std.mem.asBytes(&usable), std.mem.asBytes(&self.window))) {
        self.window = usable;
        // arrange(self);
    }

    for (0..4) |i|
        self.arrangelayer(3 - i, &usable, false);

    std.log.warn("TODO: finish arrange monitors", .{});
}

fn arrangelayer(self: *Monitor, idx: usize, usable: *wlr.Box, exclusive: bool) void {
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
