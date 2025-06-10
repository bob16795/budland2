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
layers: [TOTAL_LAYERS]std.ArrayList(*LayerSurface),
tags: std.DynamicBitSet,

frame_event: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(renderMonitor),
destroy_event: wl.Listener(*wlr.Output) = wl.Listener(*wlr.Output).init(deinit),

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
        .layers = .{
            std.ArrayList(*LayerSurface).init(session.config.allocator),
        } ** TOTAL_LAYERS,
        .tags = try std.DynamicBitSet.initEmpty(session.config.allocator, session.config.tags.items.len),
        .fullscreen_bg = fullscreen_bg,
        .scene_output = scene_output,
        .position = position orelse output_box,
        .mode = output_box,
    };

    output.events.frame.add(&self.frame_event);
    output.events.destroy.add(&self.destroy_event);
}

fn renderMonitor(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const monitor: *Monitor = @fieldParentPtr("frame_event", listener);

    const scene_output = monitor.session.wayland_data.?.scene.getSceneOutput(monitor.output).?;
    _ = scene_output.commit(null);

    var now: std.posix.timespec = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch
        @panic("CLOCK_MONOTONIC not supported");
    scene_output.sendFrameDone(&now);
}

pub fn close(self: *Monitor) !void {
    if (self.session.monitors.items.len == 0) {
        self.session.selmon = null;
    } else {
        self.session.selmon = null;
        for (self.session.monitors.items) |m|
            if (self.session.selmon != self) {
                self.session.selmon = m;
                if (m.output.enabled) break;
            };
    }

    std.log.info("TODO: Monitor.close clients move", .{});
}

pub fn arrange(self: *Monitor) void {
    var usable = self.mode;
    const layers_above_shell = [_]u32{ 3, 4 };

    for (self.session.clients.items) |client| {
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

    for (self.layers[idx].items) |layersurface| {
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

fn deinit(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
    const monitor: *Monitor = @fieldParentPtr("destroy_event", listener);

    for (monitor.layers) |layer|
        for (layer.items) |sublayer|
            sublayer.deinit() catch {};
}
