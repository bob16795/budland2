const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");

const Session = @import("session.zig");

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
bounds: ?wlr.Box = null,
border: i32 = 0,

managed: bool = false,
frame: ?ClientFrame = null,
fullscreen: bool = false,
container: ?u8 = 0,

update_lock: std.Thread.Mutex = .{},

resize_serial: u32 = 0,

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

        client.deinit() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn deinit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const events: *XDGClientEvents = @fieldParentPtr("deinit_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.deinit() catch |ex| {
            @panic(@errorName(ex));
        };
    }
};

fn sharesTabs(self: *const Client, other: *Client) bool {
    return self == other or
        self.container == other.container;
}

pub fn updateTree(self: *Client, session: *Session) !void {
    self.update_lock.lock();
    defer self.update_lock.unlock();

    std.log.warn("TODO: check client stopped", .{});

    var geom = self.bounds orelse return;
    var child_geom = wlr.Box{
        .x = 0,
        .y = 0,
        .width = geom.width,
        .height = geom.height,
    };

    if (geom.width == 0 and geom.height == 0) {
        std.log.warn("TODO: zero size", .{});
        return;
    }

    var totalTabs: i32 = 0;
    for (session.clients.items) |tabClient| {
        if (!self.sharesTabs(tabClient))
            totalTabs += 1;
    }

    if (self.frame) |frame| {
        if (frame.hide_title) {
            // left border
            geom.width += self.border;
            geom.x -= self.border;
            child_geom.x += self.border;

            // right border
            geom.width += self.border;

            // top border
            geom.height += self.border;
            geom.y -= self.border;
            child_geom.y += self.border;

            // bottom border
            geom.y -= self.border;

            std.log.warn("TODO: frame no title", .{});
        } else {
            // left border
            geom.width += self.border;
            geom.x -= self.border;
            child_geom.x += self.border;

            // right border
            geom.width += self.border;

            // top border
            geom.height += self.border;
            geom.y -= self.border;
            child_geom.y += self.border;

            // bottom border
            geom.y -= self.border + TITLE_HEIGHT;

            std.log.warn("TODO: frame title", .{});
        }
    } else {
        // self.scene.node.setPosition(geom.x, geom.y);

        std.log.warn("TODO: no frame", .{});
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

            // surface.events.request_activate.add(&self.events.x11.activate_event);
            // surface.events.request_configure.add(&self.events.x11.configure_event);
            // surface.events.request_resize.add(&self.events.x11.resize_event);

            if (surface.role == .none) {
                self.* = .{
                    .surface = new_surface,
                    .session = session,
                    .managed = false,
                    .events = self.events,
                };

                std.log.info("created managed client", .{});

                return;
            }

            // TODO

            // surface.role_data.toplevel.?.events.request_resize.add(&self.events.xdg.resize_event);
            // surface.role_data.toplevel.?.events.add(&self.events.xdg.resize_event);
            // surface.role_data.toplevel.?.events.configure.add(&self.events.xdg.configure_event);

            std.log.info("created client", .{});

            self.* = .{
                .surface = new_surface,
                .session = session,
                .border = 1,
                .managed = true,
                .events = self.events,
            };
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

            std.log.info("created client", .{});

            self.* = .{
                .surface = new_surface,
                .session = session,
                .border = 1,
                .managed = !surface.override_redirect,
                .events = self.events,
            };
        },
    }
}

pub fn map(self: *Client) !void {
    std.log.info("map client {*}", .{self});

    var scene = try self.session.wayland_data.?.layers.get(.LyrTile).createSceneTree();
    // scene.node.setEnabled(self.surface != .XDG);

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

    std.log.info("map client {*} surf {}", .{ self, self.surface });

    scene.node.data = @intFromPtr(self);
    scene_surface.node.data = @intFromPtr(self);

    self.scene = scene;
    self.scene_surface = scene_surface;

    switch (self.surface) {
        .X11 => {
            if (self.managed) {
                self.bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
                const bounds = self.bounds.?;

                self.scene.node.reparent(self.session.wayland_data.?.layers.get(.LyrFloat));
                self.scene.node.setPosition(bounds.x + self.border, bounds.y + self.border);
            } else {
                self.bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
                const bounds = self.bounds.?;

                // TODO: apply rules
                self.scene.node.reparent(self.session.wayland_data.?.layers.get(.LyrFloat));
                self.scene.node.setPosition(bounds.x + self.border, bounds.y + self.border);
                // .c.wlr_scene_node_reparent(&client.scene.node, layers.get(.LyrFloat));
                // c.wlr_scene_node_set_position(&client.scene.node, client.geom.x + borderpx, client.geom.y + borderpx);
            }
        },
        .XDG => {
            self.bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            const bounds = self.bounds.?;

            self.scene.node.reparent(self.session.wayland_data.?.layers.get(.LyrTile));
            self.scene.node.setPosition(bounds.x + self.border, bounds.y + self.border);
        },
    }

    // TODO: finish

    try self.updateTree(self.session);
}

pub fn resize(self: *Client, target_bounds: ?wlr.Box, force: bool) !void {
    _ = force;
    if (target_bounds) |bnds|
        self.bounds = bnds;

    const bounds = self.bounds orelse return;

    // std.log.info("resize bnds: {?}", .{bounds});

    const view_bounds: wlr.Box = if (self.frame) |frame| get_box: {
        const title_height = if (frame.hide_title) self.border else self.border + TITLE_HEIGHT;

        break :get_box .{
            .x = self.border,
            .y = self.border + title_height,
            .width = bounds.width - (self.border + self.border),
            .height = bounds.height - (self.border + title_height),
        };
    } else .{
        .x = bounds.x,
        .y = bounds.y,
        .width = bounds.width,
        .height = bounds.height,
    };

    //TODO: frame?

    switch (self.surface) {
        .X11 => |surface| {
            surface.configure(
                @intCast(view_bounds.x),
                @intCast(view_bounds.y),
                @intCast(view_bounds.width),
                @intCast(view_bounds.height),
            );
            self.resize_serial = 0;
        },
        .XDG => |surface| {
            self.resize_serial = surface.role_data.toplevel.?.setSize(@intCast(view_bounds.width), view_bounds.height);
        },
    }
}

pub fn commit(self: *Client) !void {
    // TODO: check mon

    switch (self.surface) {
        .XDG => |surface| {
            try self.resize(self.bounds, true);

            if (self.resize_serial != 0 and self.resize_serial <= surface.current.configure_serial)
                self.resize_serial = 0;
        },
        else => {
            std.log.warn("TODO: commit non xdg", .{});
        },
    }
}

pub fn configure(self: *Client, event: *wlr.XwaylandSurface.event.Configure) !void {
    _ = self;
    _ = event;

    std.log.warn("TODO: configure x11", .{});
}

pub fn activate(self: *Client) !void {
    _ = self;

    std.log.warn("TODO: activate x11", .{});
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
                // if (client_surface(client) == seat.keyboard_state.focused_surface)
                //     focusclient(client, true);
                std.log.warn("TODO: unmap unmanaged x11 windows", .{});
            }
        },
    }
}

pub fn deinit(self: *Client) !void {
    switch (self.surface) {
        .XDG => {
            self.events.xdg.map_event.link.remove();
            self.events.xdg.unmap_event.link.remove();
            self.events.xdg.deinit_event.link.remove();
        },
        .X11 => {
            self.events.x11.map_event.link.remove();
            // self.events.x11.unmap_event.link.remove();
            // self.events.x11.unmap_event.link.remove();
        },
    }

    for (self.session.clients.items, 0..) |client, idx| {
        if (@intFromPtr(client) == @intFromPtr(self)) {
            const removed_client = self.session.clients.swapRemove(idx);
            self.session.config.allocator.destroy(removed_client);

            return;
        }
    }

    std.log.warn("deinit {*}, couldnt find window in list", .{self});
}

pub fn getSurface(self: *Client) *wlr.Surface {
    return switch (self.surface) {
        .X11 => |surface| surface.surface.?,
        .XDG => |surface| surface.surface,
    };
}

pub fn notifyEnter(self: *Client, seat: *wlr.Seat, kb: ?*wlr.Keyboard) void {
    if (kb) |keyb| {
        seat.keyboardNotifyEnter(self.getSurface(), &keyb.keycodes, &keyb.modifiers);
    } else {
        seat.keyboardNotifyEnter(self.getSurface(), &.{}, null);
    }
}
