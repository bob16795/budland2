const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");

const Session = @import("session.zig");
const Monitor = @import("monitor.zig");
const Config = @import("config.zig");

const LayerSurface = @This();

const allocator = Config.allocator;

const LayerSurfaceEvents = struct {
    map_event: wl.Listener(void) = .init(Listeners.map),
    unmap_event: wl.Listener(void) = .init(Listeners.unmap),
    commit_event: wl.Listener(*wlr.Surface) = .init(Listeners.commit),
    deinit_event: wl.Listener(*wlr.Surface) = .init(Listeners.deinit),
};

surface_id: u8 = 25,

session: *Session,
monitor: ?*Monitor,
events: LayerSurfaceEvents = .{},

surface: *wlr.LayerSurfaceV1,
scene: *wlr.SceneLayerSurfaceV1,
scene_tree: *wlr.SceneTree,
popups: *wlr.SceneTree,
mapped: bool,
link: wl.list.Link = undefined,
bounds: wlr.Box = std.mem.zeroes(wlr.Box),

const Listeners = struct {
    pub fn map(listener: *wl.Listener(void)) void {
        const events: *LayerSurfaceEvents = @fieldParentPtr("map_event", listener);
        const surface: *LayerSurface = @fieldParentPtr("events", events);

        surface.map() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn commit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const events: *LayerSurfaceEvents = @fieldParentPtr("commit_event", listener);
        const surface: *LayerSurface = @fieldParentPtr("events", events);

        surface.commit() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn unmap(listener: *wl.Listener(void)) void {
        const events: *LayerSurfaceEvents = @fieldParentPtr("unmap_event", listener);
        const surface: *LayerSurface = @fieldParentPtr("events", events);

        surface.unmap() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn deinit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const events: *LayerSurfaceEvents = @fieldParentPtr("deinit_event", listener);
        const surface: *LayerSurface = @fieldParentPtr("events", events);

        surface.deinit();
    }
};

pub fn create(session: *Session, surf: *wlr.LayerSurfaceV1) !void {
    const monitor: *Monitor = if (surf.output) |output|
        @as(*Monitor, @ptrFromInt(output.data))
    else
        session.focusedMonitor orelse {
            surf.destroy();
            return;
        };

    const parent_scene = session.layers.get(@enumFromInt(@intFromEnum(surf.pending.layer)));
    const popups = try parent_scene.createSceneTree();
    const scene = try parent_scene.createSceneLayerSurfaceV1(surf);
    const scene_tree = scene.tree;

    surf.output = monitor.output;

    const result = try allocator.create(LayerSurface);
    scene_tree.node.data = @intFromPtr(result);
    surf.data = @intFromPtr(result);

    result.* = .{
        .surface = surf,
        .session = session,
        .monitor = monitor,
        .scene = scene,
        .scene_tree = scene_tree,
        .popups = popups,
        .mapped = false,
    };

    surf.surface.events.map.add(&result.events.map_event);
    surf.surface.events.unmap.add(&result.events.unmap_event);
    surf.surface.events.commit.add(&result.events.commit_event);
    surf.surface.events.destroy.add(&result.events.deinit_event);

    monitor.layers[@intCast(@intFromEnum(surf.pending.layer))].append(result);

    const old_state = surf.current;
    surf.current = surf.pending;
    result.mapped = true;
    try monitor.arrangeLayers();
    surf.current = old_state;

    std.log.info("tracking surface {*} as {*}", .{ surf, result });
}

pub fn map(self: *LayerSurface) !void {
    try self.session.input.motionNotify(0);
}

pub fn commit(self: *LayerSurface) !void {
    if (self.surface.output) |output| {
        self.monitor = @ptrFromInt(output.data);
    } else return;

    if (self.monitor == null)
        return;

    const lyr = self.session.layers.get(@enumFromInt(@intFromEnum(self.surface.current.layer)));
    if (lyr != self.scene_tree.node.parent) {
        self.scene_tree.node.reparent(lyr);
        self.popups.node.reparent(lyr);
        self.link.remove();
        self.monitor.?.layers[@intCast(@intFromEnum(self.surface.current.layer))].append(self);
    }

    if (@intFromEnum(self.surface.current.layer) < 2)
        self.popups.node.reparent(self.session.layers.get(.LyrTop));

    if (@as(u32, @bitCast(self.surface.current.committed)) == 0 and self.mapped == self.surface.surface.mapped)
        return;
    self.mapped = self.surface.surface.mapped;

    if (self.monitor) |m|
        try m.arrangeLayers();
}

pub fn notifyEnter(self: *LayerSurface, seat: *wlr.Seat, kb: ?*wlr.Keyboard) void {
    if (kb) |keyb| {
        seat.keyboardNotifyEnter(self.surface.surface, &keyb.keycodes, &keyb.modifiers);
    } else {
        seat.keyboardNotifyEnter(self.surface.surface, &.{}, null);
    }
}

pub fn unmap(self: *LayerSurface) !void {
    self.mapped = false;
    self.scene_tree.node.setEnabled(false);

    if (self.session.exclusive_focus == self.surface.surface)
        self.session.exclusive_focus = null;

    self.monitor = @ptrFromInt(self.surface.output.?.data);
    if (self.monitor) |m|
        try m.arrangeLayers();

    try self.session.input.motionNotify(0);
}

pub fn deinit(self: *LayerSurface) void {
    std.log.info("deinit {*}", .{self});

    self.link.remove();

    if (self.monitor) |m|
        m.arrangeLayers() catch {};

    self.events.map_event.link.remove();
    self.events.unmap_event.link.remove();
    self.events.deinit_event.link.remove();
    self.events.commit_event.link.remove();

    allocator.destroy(self);
}
