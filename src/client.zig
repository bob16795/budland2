const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");

const Session = @import("session.zig");
const Monitor = @import("monitor.zig");

const Client = @This();

const Kind = enum {
    XDG,
    X11,
};

const ClientFrame = struct {
    sides: [4]*wlr.SceneRect,
    hide_title: bool,
};

pub const ClientSurface = union(Kind) {
    XDG: *wlr.XdgSurface,
    X11: *wlr.XwaylandSurface,

    pub fn format(
        self: *const ClientSurface,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self.*) {
            .XDG => |surface| try writer.print("{*}", .{surface}),
            .X11 => |surface| try writer.print("{*}", .{surface}),
        }
    }
};

const XDGClientEvents = extern struct {
    map_event: wl.Listener(void) = .init(Listeners.map),
    unmap_event: wl.Listener(void) = .init(Listeners.unmap),

    commit_event: wl.Listener(*wlr.Surface) = .init(Listeners.commit),
    resize_event: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(Listeners.resize),
    deinit_event: wl.Listener(*wlr.Surface) = .init(Listeners.deinit),
};

const X11ClientEvents = extern struct {
    map_event: wl.Listener(void) = .init(Listeners.xmap),
    unmap_event: wl.Listener(void) = .init(Listeners.xunmap),
    activate_event: wl.Listener(void) = .init(Listeners.xactivate),
    configure_event: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(Listeners.xconfigure),

    commit_event: wl.Listener(*wlr.Surface) = .init(Listeners.xcommit),
    resize_event: wl.Listener(*wlr.XwaylandSurface.event.Resize) = .init(Listeners.xresize),
    deinit_event: wl.Listener(void) = .init(Listeners.xdeinit),
};

const ClientEvents = extern union {
    x11: X11ClientEvents,
    xdg: XDGClientEvents,
};

client_id: u8 = 10,

session: *Session,
surface: ClientSurface,
events: ClientEvents,

scene: *wlr.SceneTree = undefined,
scene_surface: *wlr.SceneTree = undefined,

tag: usize = 0,
bounds: ?wlr.Box = null,
inner_bounds: ?wlr.Box = null,
prev_bounds: ?wlr.Box = null,
border: i32 = 0,
monitor: ?*Monitor = null,
managed: bool = false,
frame: ?ClientFrame = null,
fullscreen: bool = false,
container: u8 = 3,
floating: bool = false,

update_lock: std.Thread.Mutex = .{},

resize_serial: u32 = 0,

link: wl.list.Link = undefined,
focus_link: wl.list.Link = undefined,

// TODO: config
const TITLE_HEIGHT = 20;

const Listeners = struct {
    pub fn map(listener: *wl.Listener(void)) void {
        const events: *XDGClientEvents = @fieldParentPtr("map_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.map() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn xmap(listener: *wl.Listener(void)) void {
        const events: *X11ClientEvents = @fieldParentPtr("map_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.map() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn commit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const events: *XDGClientEvents = @fieldParentPtr("commit_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.commit() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn xcommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const events: *X11ClientEvents = @fieldParentPtr("commit_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.commit() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn xresize(listener: *wl.Listener(*wlr.XwaylandSurface.event.Resize), _: *wlr.XwaylandSurface.event.Resize) void {
        const events: *X11ClientEvents = @fieldParentPtr("resize_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.resize(null, false) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn resize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), _: *wlr.XdgToplevel.event.Resize) void {
        const events: *XDGClientEvents = @fieldParentPtr("resize_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.resize(null, false) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn unmap(listener: *wl.Listener(void)) void {
        const events: *XDGClientEvents = @fieldParentPtr("unmap_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.unmap() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn xunmap(listener: *wl.Listener(void)) void {
        const events: *X11ClientEvents = @fieldParentPtr("unmap_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.unmap() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn xactivate(listener: *wl.Listener(void)) void {
        const events: *X11ClientEvents = @fieldParentPtr("activate_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.activate() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn xconfigure(listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure), event: *wlr.XwaylandSurface.event.Configure) void {
        const events: *X11ClientEvents = @fieldParentPtr("configure_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.configure(event) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn xdeinit(listener: *wl.Listener(void)) void {
        const events: *X11ClientEvents = @fieldParentPtr("deinit_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.deinit();
    }

    pub fn deinit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const events: *XDGClientEvents = @fieldParentPtr("deinit_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.deinit();
    }
};

fn sharesTabs(self: *const Client, other: *Client) bool {
    return self == other or
        self.container == other.container;
}

pub fn updateTree(self: *Client, session: *Session) !void {
    if (self.isStopped()) return;

    if (self.monitor) |monitor|
        monitor.arrangeClients();

    self.update_lock.lock();
    defer self.update_lock.unlock();

    const geom = self.bounds orelse return;
    if (geom.width == 0 and geom.height == 0)
        return;

    var totalTabs: i32 = 0;

    {
        var iter = session.clients.iterator(.forward);
        while (iter.next()) |tabClient| {
            if (!self.sharesTabs(tabClient))
                totalTabs += 1;
        }
    }
}

pub fn init(self: *Client, session: *Session, target: ClientSurface) !void {
    switch (target) {
        .XDG => |surface| {
            self.events = .{ .xdg = .{} };

            std.log.info("add xdg surface {*} to {*}", .{ target.XDG, self });

            const new_surface: ClientSurface = .{
                .XDG = surface,
            };

            if (surface.role == .popup) {
                if (session.getClient(surface.surface)) |client| {
                    if (surface.role_data.popup.?.parent == null)
                        return error.noPopupParent;

                    const scene_tree: *wlr.SceneTree = @ptrFromInt(surface.role_data.popup.?.parent.?.data);

                    std.log.warn("TODO: setup client monitor", .{});

                    const bounds = client.bounds orelse wlr.Box{ .x = 0, .y = 0, .width = 0, .height = 0 };

                    surface.role_data.popup.?.unconstrainFromBox(&bounds);

                    self.* = .{
                        .surface = new_surface,
                        .scene_surface = scene_tree,
                        .session = session,
                        .managed = false,
                        .events = self.events,
                    };

                    std.log.info("created popup", .{});
                } else return error.ParentNotClient;

                return;
            }

            surface.surface.events.map.add(&self.events.xdg.map_event);
            surface.surface.events.unmap.add(&self.events.xdg.unmap_event);
            surface.surface.events.destroy.add(&self.events.xdg.deinit_event);

            if (surface.role == .none) {
                self.* = .{
                    .surface = new_surface,
                    .session = session,
                    .managed = true,
                    .events = self.events,
                };

                std.log.info("created managed client", .{});

                return;
            }

            // TODO

            // surface.role_data.toplevel.?.events.request_resize.add(&self.events.xdg.resize_event);
            // surface.role_data.toplevel.?.events.add(&self.events.xdg.resize_event);
            // surface.role_data.toplevel.?.events.configure.add(&self.events.xdg.configure_event);

            self.* = .{
                .surface = new_surface,
                .session = session,
                .border = 1,
                .managed = true,
                .events = self.events,
            };

            std.log.info("created client", .{});

            return;
        },
        .X11 => |surface| {
            self.events = .{ .x11 = .{} };

            std.log.info("add x11 surface {*} to {*}", .{ target.X11, self });

            const new_surface: ClientSurface = .{
                .X11 = surface,
            };

            // https://github.com/swaywm/wlroots/blob/0855cdacb2eeeff35849e2e9c4db0aa996d78d10/include/wlr/xwayland.h#L143

            surface.events.associate.add(&self.events.x11.map_event);
            surface.events.dissociate.add(&self.events.x11.unmap_event);
            surface.events.destroy.add(&self.events.x11.deinit_event);

            surface.events.request_activate.add(&self.events.x11.activate_event);
            surface.events.request_configure.add(&self.events.x11.configure_event);
            surface.events.request_resize.add(&self.events.x11.resize_event);

            surface.data = @intFromPtr(self);

            self.* = .{
                .surface = new_surface,
                .session = session,
                .border = 1,
                .managed = !surface.override_redirect,
                .events = self.events,
            };

            std.log.info("created x11 client", .{});
        },
    }
}

pub fn map(self: *Client) !void {
    std.log.info("map client {*}", .{self});

    var scene = try self.session.wayland_data.?.layers.get(.LyrTile).createSceneTree();

    var scene_surface = switch (self.surface) {
        .XDG => |surface| try scene.createSceneXdgSurface(surface),
        .X11 => |xsurface| if (xsurface.surface) |surface|
            try scene.createSceneSubsurfaceTree(surface)
        else
            return,
    };

    const surface = switch (self.surface) {
        .XDG => |surface| surface.surface,
        .X11 => |xsurface| xsurface.surface,
    };

    if (surface) |osurface| {
        osurface.data = @intFromPtr(scene);
        switch (self.surface) {
            .XDG => osurface.events.commit.add(&self.events.xdg.commit_event),
            .X11 => osurface.events.commit.add(&self.events.x11.commit_event),
        }
    }

    switch (self.surface) {
        .XDG => |xdg| {
            var geom: wlr.Box = undefined;
            xdg.getGeometry(&geom);
            self.bounds = geom;
        },
        .X11 => |xsurface| {
            self.bounds = .{
                .x = xsurface.x,
                .y = xsurface.y,
                .width = xsurface.width,
                .height = xsurface.height,
            };
        },
    }

    std.log.info("map client {*} surf {}", .{ self, self.surface });

    scene.node.data = @intFromPtr(self);
    scene_surface.node.data = @intFromPtr(self);

    self.scene = scene;
    self.scene_surface = scene_surface;

    switch (self.surface) {
        .X11 => {
            if (self.managed) {
                const bounds = self.bounds.?;

                self.scene.node.reparent(self.session.wayland_data.?.layers.get(.LyrFloat));
                self.scene.node.setPosition(bounds.x + self.border, bounds.y + self.border);
            } else {
                const bounds = self.bounds.?;

                // TODO: apply rules
                self.scene.node.reparent(self.session.wayland_data.?.layers.get(.LyrFloat));
                self.scene.node.setPosition(bounds.x + self.border, bounds.y + self.border);
            }
        },
        .XDG => {
            const bounds = self.bounds.?;

            self.scene.node.reparent(self.session.wayland_data.?.layers.get(.LyrTile));
            self.scene.node.setPosition(bounds.x + self.border, bounds.y + self.border);
        },
    }

    // TODO: finish

    try self.updateTree(self.session);
}

pub fn resize(self: *Client, in_target_bounds: ?wlr.Box, force: bool) !void {
    var target_bounds = in_target_bounds;

    if (target_bounds) |*target| {
        if (target.width <= 0)
            target.width = if (self.bounds) |b| b.width else 20;
        if (target.height <= 0)
            target.height = if (self.bounds) |b| b.height else 20;
    }

    var title_height: i32 = 0;
    var inner_bounds: wlr.Box = undefined;
    if (!force) {
        switch (self.surface) {
            .XDG => |xdg| {
                xdg.getGeometry(&inner_bounds);
            },
            .X11 => |xsurface| {
                inner_bounds = .{
                    .x = xsurface.x,
                    .y = xsurface.y,
                    .width = xsurface.width,
                    .height = xsurface.height,
                };
            },
        }
    } else {
        inner_bounds = target_bounds.?;
    }

    const defaultxy = std.mem.zeroes(wlr.Box);

    const bounds: wlr.Box = if (force) get_box: {
        if (self.frame) |frame| {
            title_height = if (frame.hide_title) self.border else self.border + TITLE_HEIGHT;

            inner_bounds = .{
                .x = self.border,
                .y = self.border,
                .width = target_bounds.?.width - self.border - self.border,
                .height = target_bounds.?.height - self.border - title_height,
            };
        } else {
            inner_bounds = .{
                .x = 0,
                .y = 0,
                .width = target_bounds.?.width,
                .height = target_bounds.?.height,
            };
        }

        break :get_box target_bounds.?;
    } else if (self.frame) |frame| get_box: {
        title_height = if (frame.hide_title) self.border else self.border + TITLE_HEIGHT;

        inner_bounds.x = self.border;
        inner_bounds.y = title_height;

        break :get_box .{
            .x = (self.bounds orelse defaultxy).x,
            .y = (self.bounds orelse defaultxy).y,
            .width = inner_bounds.width + (self.border + self.border),
            .height = inner_bounds.height + (self.border + title_height),
        };
    } else get_box: {
        inner_bounds.x = 0;
        inner_bounds.y = 0;

        break :get_box .{
            .x = (self.bounds orelse defaultxy).x,
            .y = (self.bounds orelse defaultxy).y,
            .width = inner_bounds.width,
            .height = inner_bounds.height,
        };
    };

    if (inner_bounds.width == 0 or inner_bounds.height == 0)
        return;

    self.bounds = bounds;
    self.inner_bounds = inner_bounds;

    //TODO: frame?

    self.scene.node.setPosition(self.bounds.?.x, self.bounds.?.y);
    self.scene_surface.node.setPosition(self.inner_bounds.?.x, self.inner_bounds.?.y);

    if (self.frame) |frame| {
        frame.sides[0].setSize(self.inner_bounds.?.width, self.border + title_height);
        frame.sides[1].setSize(self.inner_bounds.?.width, self.border);
        frame.sides[2].setSize(self.border, self.inner_bounds.?.height);
        frame.sides[3].setSize(self.border, self.inner_bounds.?.height);

        frame.sides[0].node.setPosition(0, 0);
        frame.sides[1].node.setPosition(0, self.inner_bounds.?.height);
        frame.sides[2].node.setPosition(0, 0);
        frame.sides[3].node.setPosition(self.inner_bounds.?.width, self.border);
    }

    self.resize_serial = self.updateSize();
}

pub fn updateSize(self: *Client) u32 {
    if (self.surface == .X11) {
        self.surface.X11.configure(
            @intCast(self.inner_bounds.?.x),
            @intCast(self.inner_bounds.?.y),
            @intCast(self.inner_bounds.?.width),
            @intCast(self.inner_bounds.?.height),
        );

        return 0;
    }

    if (self.inner_bounds.?.width == self.surface.XDG.role_data.toplevel.?.current.width and
        self.inner_bounds.?.height == self.surface.XDG.role_data.toplevel.?.current.height)
        return 0;

    return self.surface.XDG.role_data.toplevel.?.setSize(@intCast(self.inner_bounds.?.width), self.inner_bounds.?.height);
}

pub fn commit(self: *Client) !void {
    var geom: wlr.Box = undefined;
    switch (self.surface) {
        .XDG => |xdg| {
            xdg.getGeometry(&geom);
        },
        .X11 => |xsurface| {
            geom = .{
                .x = xsurface.x,
                .y = xsurface.y,
                .width = xsurface.height,
                .height = xsurface.width,
            };
        },
    }

    if (self.bounds == null or self.inner_bounds == null or
        (self.monitor != null and
            !geom.empty() and
            (geom.width != self.inner_bounds.?.width or
                geom.height != self.inner_bounds.?.height)))
    {
        switch (self.surface) {
            .XDG => |surface| {
                try self.resize(self.bounds, true);

                if (self.resize_serial != 0 and self.resize_serial <= surface.current.configure_serial)
                    self.resize_serial = 0;
            },
            .X11 => |surface| {
                try self.resize(self.bounds, true);

                if (self.resize_serial != 0 and self.resize_serial <= surface.serial)
                    self.resize_serial = 0;
            },
        }
    }
}

pub fn configure(self: *Client, event: *wlr.XwaylandSurface.event.Configure) !void {
    if (self.monitor == null)
        return;
    if (self.surface != .X11)
        return;

    if (self.floating or !self.managed)
        try self.resize(.{ .x = event.x, .y = event.y, .width = event.width, .height = event.height }, false)
    else
        self.monitor.?.arrangeClients();
}

pub fn activate(self: *Client) !void {
    if (self.surface != .X11)
        return;

    self.surface.X11.activate(true);
}

pub fn unmap(self: *Client) !void {
    // TODO: ungrab

    switch (self.surface) {
        .XDG => |surface| {
            self.events.xdg.commit_event.link.remove();
            _ = surface;
        },
        .X11 => |surface| {
            _ = surface;
            if (self.managed) {
                std.log.warn("TODO: unmap managed x11 windows", .{});
            } else {
                // TODO: remove exclusive focus
                if (self.getSurface() == self.session.input.seat.keyboard_state.focused_surface)
                    try self.session.focus(self, true);
            }
        },
    }
}

pub fn deinit(self: *Client) void {
    switch (self.surface) {
        .XDG => {
            self.events.xdg.map_event.link.remove();
            self.events.xdg.unmap_event.link.remove();
            self.events.xdg.deinit_event.link.remove();
        },
        .X11 => {
            self.events.x11.map_event.link.remove();
        },
    }

    self.link.remove();
    self.focus_link.remove();
    self.session.config.allocator.destroy(self);
}

pub fn getSurface(self: *Client) *wlr.Surface {
    return switch (self.surface) {
        .X11 => |surface| surface.surface.?,
        .XDG => |surface| surface.surface,
    };
}

pub fn isMapped(self: *Client) bool {
    return switch (self.surface) {
        .X11 => |surface| surface.surface.?.mapped,
        .XDG => |surface| surface.surface.mapped,
    };
}

pub fn isStopped(self: *Client) bool {
    return switch (self.surface) {
        .X11 => false,
        .XDG => {
            std.log.warn("TODO: check client stopped", .{});
            return false;
        },
    };
}

pub fn notifyEnter(self: *Client, seat: *wlr.Seat, kb: ?*wlr.Keyboard) void {
    if (kb) |keyb| {
        seat.keyboardNotifyEnter(self.getSurface(), &keyb.keycodes, &keyb.modifiers);
    } else {
        seat.keyboardNotifyEnter(self.getSurface(), &.{}, null);
    }
}

pub fn activateSurface(self: *Client, active: bool) void {
    switch (self.surface) {
        .X11 => |surface| surface.activate(active),
        .XDG => |surface| _ = surface.role_data.toplevel.?.setActivated(active),
    }
}

pub fn close(self: *Client) void {
    switch (self.surface) {
        .X11 => |surface| surface.close(),
        .XDG => |surface| surface.role_data.toplevel.?.sendClose(),
    }
}

pub fn setMonitor(self: *Client, target_monitor: ?*Monitor, tag: ?usize) !void {
    const old_monitor = self.monitor;

    if (old_monitor == target_monitor)
        return;

    self.monitor = target_monitor;
    self.prev_bounds = self.bounds;

    if (old_monitor) |old| {
        self.getSurface().sendLeave(old.output);
        old.arrangeClients();
    }

    if (target_monitor) |new| {
        try self.resize(self.bounds, false);
        self.getSurface().sendEnter(new.output);
        if (tag) |new_tag|
            self.tag = new_tag;

        self.tag = new.tag;

        // self.setFullscreen(self.isfullscreen);

        new.arrangeClients();
    }

    try self.session.focus(self, true);
}
