const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");

const Session = @import("session.zig");
const Monitor = @import("monitor.zig");

const LayerSurface = @This();

const LayerSurfaceEvents = struct {
    map_event: wl.Listener(void) = .init(Listeners.map),
    unmap_event: wl.Listener(void) = .init(Listeners.unmap),
    commit_event: wl.Listener(*wlr.Surface) = .init(Listeners.commit),
    deinit_event: wl.Listener(*wlr.Surface) = .init(Listeners.deinit),
};

surface_id: u8 = 25,

session: *Session,
monitor: *Monitor,
events: LayerSurfaceEvents,

surface: *wlr.LayerSurfaceV1,
scene: *wlr.SceneLayerSurfaceV1,
scene_tree: *wlr.SceneTree,
popups: *wlr.SceneTree,
mapped: bool,

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

        surface.deinit() catch |ex| {
            @panic(@errorName(ex));
        };
    }
};

pub fn init(self: *LayerSurface, session: *Session, surf: *wlr.LayerSurfaceV1) !void {
    self.events = .{};

    const wayland_data = session.wayland_data orelse unreachable;

    surf.data = @intFromPtr(self);

    surf.surface.events.map.add(&self.events.map_event);
    surf.surface.events.unmap.add(&self.events.unmap_event);
    surf.surface.events.commit.add(&self.events.commit_event);
    surf.surface.events.destroy.add(&self.events.deinit_event);

    const monitor: *Monitor = @ptrFromInt(surf.output.?.data);
    const parent_scene = wayland_data.layers.get(@enumFromInt(@intFromEnum(surf.pending.layer)));
    const scene = try parent_scene.createSceneLayerSurfaceV1(surf);
    const scene_tree = scene.tree;
    const popups = try parent_scene.createSceneTree();

    self.* = .{
        .surface = surf,
        .scene = scene,
        .scene_tree = scene_tree,
        .popups = popups,
        .session = session,
        .mapped = true,
        .events = self.events,
        .monitor = monitor,
    };

    scene_tree.node.data = @intFromPtr(self);

    try monitor.layers[@intCast(@intFromEnum(surf.pending.layer))].append(self);

    const old_state = surf.current;
    surf.current = surf.pending;
    self.mapped = true;
    self.monitor.arrange();
    surf.current = old_state;
}

pub fn map(self: *LayerSurface) !void {
    self.surface.surface.sendEnter(self.monitor.output);
    // motionnotify(0, null, 0, 0, 0, 0);
}

pub fn commit(self: *LayerSurface) !void {
    if (self.surface.output) |output| {
        self.monitor = @ptrFromInt(output.data);
    } else return;

    const wayland_data = self.session.wayland_data orelse unreachable;
    const lyr = wayland_data.layers.get(@enumFromInt(@intFromEnum(self.surface.current.layer)));
    if (lyr != self.scene_tree.node.parent) {
        self.scene_tree.node.reparent(lyr);
        self.popups.node.reparent(lyr);
    }

    if (@intFromEnum(self.surface.current.layer) < 2)
        self.popups.node.reparent(wayland_data.layers.get(.LyrTop));

    if (@as(u32, @bitCast(self.surface.current.committed)) == 0 and self.mapped == self.surface.surface.mapped)
        return;
}

pub fn unmap(self: *LayerSurface) !void {
    std.log.warn("TODO: unmap layer surf {*}", .{self});
}

pub fn deinit(self: *LayerSurface) !void {
    std.log.info("deinit {*}", .{self});

    const list = &self.monitor.layers[@intCast(@intFromEnum(self.surface.pending.layer))];

    for (list.items, 0..) |client, idx| {
        if (@intFromPtr(client) == @intFromPtr(self)) {
            const removed_surface = list.swapRemove(idx);

            self.events.map_event.link.remove();
            self.events.unmap_event.link.remove();
            self.events.deinit_event.link.remove();
            self.events.commit_event.link.remove();

            self.session.config.allocator.destroy(removed_surface);

            return;
        }
    }

    self.monitor.arrange();

    std.log.warn("deinit {*}, couldnt find window in list", .{self});
}
