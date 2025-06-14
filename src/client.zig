const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");
const cairo = @import("cairo");

const CairoBuffer = @import("cairobuffer.zig");
const Session = @import("session.zig");
const Monitor = @import("monitor.zig");

const Client = @This();

const SurfaceKind = enum { XDG, X11 };
const FrameKind = enum { hide, border, title };

const ClientFrame = struct {
    kind: FrameKind = .hide,
    is_init: bool = false,

    title_buffer: *CairoBuffer = undefined,

    shadow: [2]*wlr.SceneRect = undefined,
    shadow_tree: *wlr.SceneTree = undefined,
    sides: [4]*wlr.SceneRect = undefined,
    buffer_scene: *wlr.SceneBuffer = undefined,
    border_tree: *wlr.SceneTree = undefined,

    pub fn init(kind: FrameKind, color: [4]f32, client: *Client) !ClientFrame {
        const shadow_scene = client.session.wayland_data.?.layers.get(.LyrFloatShadows);

        var border_tree = try client.scene.createSceneTree();
        var shadow_tree = try shadow_scene.createSceneTree();

        var sides: [4]*wlr.SceneRect = undefined;
        for (&sides) |*side| {
            side.* = try border_tree.createSceneRect(0, 0, &color);
            side.*.node.data = @intFromPtr(client);
        }

        var shadow: [2]*wlr.SceneRect = undefined;
        for (&shadow) |*side| {
            side.* = try shadow_tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0.5 });
            side.*.node.data = @intFromPtr(client);
        }

        const title_buffer = try CairoBuffer.create(client.session.config.allocator, 10, 10, 1.0);
        const locked = title_buffer.base.lock();

        return .{
            .is_init = true,
            .kind = kind,
            .sides = sides,
            .shadow = shadow,
            .title_buffer = title_buffer,
            .buffer_scene = try client.scene.createSceneBuffer(locked),
            .shadow_tree = shadow_tree,
            .border_tree = border_tree,
        };
    }
};

pub const ClientSurface = union(SurfaceKind) {
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
    set_title_event: wl.Listener(void) = .init(Listeners.setTitle),

    resize_event: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(Listeners.resize),
    deinit_event: wl.Listener(*wlr.Surface) = .init(Listeners.deinit),
};

const X11ClientEvents = extern struct {
    map_event: wl.Listener(void) = .init(Listeners.xmap),
    unmap_event: wl.Listener(void) = .init(Listeners.xunmap),
    activate_event: wl.Listener(void) = .init(Listeners.xactivate),
    configure_event: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(Listeners.xconfigure),
    set_title_event: wl.Listener(void) = .init(Listeners.xsetTitle),

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

bounds: wlr.Box = std.mem.zeroes(wlr.Box),
inner_bounds: wlr.Box = std.mem.zeroes(wlr.Box),
prev_bounds: wlr.Box = std.mem.zeroes(wlr.Box),
label: ?[*:0]const u8 = null,
icon: ?[*:0]const u8 = null,
monitor: ?*Monitor = null,
managed: bool = false,
fullscreen: bool = false,
frame: ClientFrame = .{},
hide_frame: bool = false,

resize_serial: u32 = 0,

link: wl.list.Link = undefined,
focus_link: wl.list.Link = undefined,

// properties
container: u8 = 0,
floating: bool = true,
tag: usize = 0,
border: i32 = 0,

// TODO: config
const SHADOW_SIZE = 10;

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

    pub fn setTitle(listener: *wl.Listener(void)) void {
        const events: *XDGClientEvents = @fieldParentPtr("set_title_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.updateFrame() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn xsetTitle(listener: *wl.Listener(void)) void {
        const events: *X11ClientEvents = @fieldParentPtr("set_title_event", listener);
        const client: *Client = @fieldParentPtr("events", @as(*ClientEvents, @ptrCast(events)));

        client.updateFrame() catch |ex| {
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
        (self.container == other.container and
            !self.floating and
            !other.floating and
            self.tag == other.tag and
            self.monitor == other.monitor);
}

pub fn updateFrame(self: *Client) !void {
    if (!self.frame.is_init)
        return;

    if (self.isStopped())
        return;

    if (self.hide_frame) {
        for (self.frame.sides) |side|
            side.node.setEnabled(false);
        for (self.frame.shadow) |shadow|
            shadow.node.setEnabled(false);
        self.frame.buffer_scene.node.setEnabled(false);

        return;
    }

    for (self.frame.shadow) |shadow|
        shadow.node.setEnabled(true);

    for (self.frame.sides) |side|
        side.node.setEnabled(self.frame.kind == .title or self.frame.kind == .border);

    self.frame.sides[0].node.setEnabled(self.frame.kind == .border);
    self.frame.buffer_scene.node.setEnabled(self.frame.kind == .title);

    self.scene.node.setPosition(self.bounds.x, self.bounds.y);
    self.scene.node.setPosition(self.bounds.x, self.bounds.y);
    self.frame.shadow_tree.node.setPosition(self.bounds.x + self.bounds.width, self.bounds.y + self.bounds.height);
    self.scene_surface.node.setPosition(self.inner_bounds.x, self.inner_bounds.y);
    self.frame.shadow[0].node.setPosition(0, -self.bounds.height + SHADOW_SIZE);
    self.frame.shadow[1].node.setPosition(-self.bounds.width + SHADOW_SIZE, 0);

    self.frame.shadow[0].setSize(SHADOW_SIZE, self.bounds.height);
    self.frame.shadow[1].setSize(self.bounds.width - SHADOW_SIZE, SHADOW_SIZE);

    if (self.frame.kind != .border and self.frame.kind != .title)
        return;

    const focused = if (self.session.selmon) |selmon|
        selmon.focusedClient() == self
    else
        false;

    const colors = self.session.config.colors;
    const window_palette = if (focused) colors[1] else colors[0];

    for (self.frame.sides) |side|
        side.setColor(&window_palette[0]);

    self.frame.sides[0].setSize(self.bounds.width, self.inner_bounds.y);
    self.frame.sides[1].setSize(self.bounds.width, self.bounds.height - self.inner_bounds.height - self.inner_bounds.y);
    self.frame.sides[2].setSize(self.inner_bounds.x, self.bounds.height);
    self.frame.sides[3].setSize(self.bounds.width - self.inner_bounds.width - self.inner_bounds.x, self.bounds.height);

    self.frame.sides[0].node.setPosition(0, 0);
    self.frame.sides[1].node.setPosition(0, self.inner_bounds.height + self.inner_bounds.y);
    self.frame.sides[2].node.setPosition(0, 0);
    self.frame.sides[3].node.setPosition(self.inner_bounds.width + self.inner_bounds.x, 0);

    if (self.frame.kind != .title)
        return;

    if (self.bounds.width == 0 and self.bounds.height == 0)
        return;

    var totalTabs: i32 = 0;

    {
        var iter = self.session.clients.iterator(.forward);
        while (iter.next()) |tabClient| {
            if (self.sharesTabs(tabClient))
                totalTabs += 1;
        }
    }

    const title_height = self.session.config.getTitleHeight();

    const total_width: i32 = self.bounds.width;
    const total_height: i32 = title_height + self.border * 2;
    const ftab_width: f64 = @as(f64, @floatFromInt(total_width)) / @as(f64, @floatFromInt(totalTabs));
    const title_pad = self.session.config.title_pad;

    self.frame.title_buffer = try self.frame.title_buffer.resize(
        @intCast(total_width),
        @intCast(total_height),
        if (self.monitor) |monitor| monitor.output.scale else self.frame.title_buffer.scale,
    );

    var context = try self.frame.title_buffer.beginContext();
    defer self.frame.title_buffer.endContext(&context);

    context.selectFontFace(self.session.config.font, .normal, .bold);
    context.setFontSize(@floatFromInt(self.session.config.font_size));

    var iter = self.session.clients.iterator(.forward);
    var current_tab: i32 = 0;
    while (iter.next()) |tab_client| {
        if (!self.sharesTabs(tab_client))
            continue;

        const tab_start: i32 = @intFromFloat(ftab_width * @as(f64, @floatFromInt(current_tab)));
        const tab_end: i32 = @intFromFloat(ftab_width * @as(f64, @floatFromInt(current_tab + 1)));
        const tab_width: i32 = tab_end - tab_start;

        const tab_palette = if (tab_client == self and focused) colors[1] else colors[0];

        const label = tab_client.getLabel() orelse "Unknown";
        const label_extents = context.textExtents(label.ptr);

        const label_y_bearing: i32 = @intFromFloat(label_extents.y_bearing);
        const label_height: i32 = @intFromFloat(label_extents.height);

        const icon = std.mem.span(tab_client.icon orelse "?");
        const icon_extents = context.textExtents(icon.ptr);
        const icon_width: i32 = @intFromFloat(icon_extents.width);
        const icon_height: i32 = @intFromFloat(icon_extents.height);
        const icon_y_bearing: i32 = @intFromFloat(icon_extents.y_bearing);

        var fade_pattern = try cairo.Pattern.createLinear(
            @floatFromInt(self.border + tab_start + tab_width - icon_width - title_pad - 30),
            @floatFromInt(self.border),
            @floatFromInt(self.border + tab_start + tab_width - icon_width - title_pad),
            0,
        );
        try fade_pattern.addColorStopRgba(0, tab_palette[2][2], tab_palette[2][1], tab_palette[2][0], tab_palette[2][3]);
        try fade_pattern.addColorStopRgba(1, tab_palette[1][2], tab_palette[1][1], tab_palette[1][0], tab_palette[1][3]);

        context.setOperator(.source);

        context.setSourceRgba(window_palette[0][2], window_palette[0][1], window_palette[0][0], window_palette[0][3]);
        context.rectangle(
            @floatFromInt(tab_start),
            @floatFromInt(0),
            @floatFromInt(tab_width),
            @floatFromInt(total_height),
        );
        context.fill();

        context.setSourceRgba(tab_palette[1][2], tab_palette[1][1], tab_palette[1][0], tab_palette[1][3]);
        context.rectangle(
            @floatFromInt(self.border + tab_start),
            @floatFromInt(self.border),
            @floatFromInt(tab_width - self.border),
            @floatFromInt(total_height - self.border * 2),
        );
        context.fill();

        context.moveTo(
            @floatFromInt(tab_start + self.border + title_pad),
            @floatFromInt(self.border + title_pad + @divTrunc(self.session.config.font_size - label_height, 2) - label_y_bearing),
        );
        context.setSource(&fade_pattern);
        context.textPath(label);
        context.fill();

        context.moveTo(
            @floatFromInt(tab_start + tab_width - title_pad - icon_width - self.border),
            @floatFromInt(self.border + title_pad + @divTrunc(self.session.config.font_size - icon_height, 2) - icon_y_bearing),
        );
        context.textPath(icon);
        context.setSourceRgba(tab_palette[2][2], tab_palette[2][1], tab_palette[2][0], tab_palette[2][3]);
        context.fill();

        current_tab += 1;
    }

    self.frame.buffer_scene.setBuffer(&self.frame.title_buffer.base);

    self.frame.buffer_scene.setSourceBox(&.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(self.frame.title_buffer.base.width),
        .height = @floatFromInt(self.frame.title_buffer.base.height),
    });

    self.frame.buffer_scene.node.setEnabled(true);
    self.frame.buffer_scene.setDestSize(total_width, total_height);
    // self.frame.buffer_scene.setDestSize(
    //     self.frame.title_buffer.unscaled_width,
    //     self.frame.title_buffer.unscaled_height,
    // );
}

pub fn init(self: *Client, session: *Session, target: ClientSurface) !void {
    self.monitor = null;

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

                    surface.role_data.popup.?.unconstrainFromBox(&client.bounds);

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

            if (surface.role_data.toplevel) |toplevel|
                toplevel.events.set_title.add(&self.events.xdg.set_title_event);

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

            self.* = .{
                .surface = new_surface,
                .session = session,
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
            surface.events.set_title.add(&self.events.x11.set_title_event);

            surface.events.request_activate.add(&self.events.x11.activate_event);
            surface.events.request_configure.add(&self.events.x11.configure_event);
            surface.events.request_resize.add(&self.events.x11.resize_event);

            surface.data = @intFromPtr(self);

            self.* = .{
                .surface = new_surface,
                .session = session,
                .managed = !surface.override_redirect,
                .events = self.events,
            };

            std.log.info("created x11 client", .{});
        },
    }
}

pub fn map(self: *Client) !void {
    std.log.info("map client {*}", .{self});

    self.scene = try self.session.wayland_data.?.layers.get(.LyrTile).createSceneTree();

    self.scene_surface = switch (self.surface) {
        .XDG => |surface| try self.scene.createSceneXdgSurface(surface),
        .X11 => |xsurface| if (xsurface.surface) |surface|
            try self.scene.createSceneSubsurfaceTree(surface)
        else
            return,
    };

    self.scene.node.data = @intFromPtr(self);
    self.scene_surface.node.data = @intFromPtr(self);

    self.scene.node.setEnabled(true);
    self.scene_surface.node.setEnabled(true);

    self.frame = try .init(if (self.managed) .border else .hide, self.session.config.colors[0][0], self);

    const surface = switch (self.surface) {
        .XDG => |surface| surface.surface,
        .X11 => |xsurface| xsurface.surface,
    };

    if (surface) |osurface| {
        osurface.data = @intFromPtr(self.scene);
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

    if (self.managed)
        try self.applyRules();

    std.log.info("map client {*} surf {}", .{ self, self.surface });

    switch (self.surface) {
        .X11 => {
            if (self.managed) {
                self.scene.node.setPosition(self.bounds.x, self.bounds.y);
            } else {
                self.scene.node.setPosition(self.bounds.x, self.bounds.y);
            }
        },
        .XDG => {
            self.scene.node.setPosition(self.bounds.x, self.bounds.y);
        },
    }

    self.monitor.?.arrangeClients();
}

pub fn applyRules(self: *Client) !void {
    const mon = self.session.selmon orelse self.session.monitors.first() orelse return;

    const appid = self.getAppId() orelse "broken";
    const title = self.getTitle() orelse "broken";

    var rule = self.session.config.client_title_rules.get(title);
    rule = self.session.config.client_class_rules.getOver(appid, rule);

    if (rule.icon) |icon| self.setIcon(icon);
    if (rule.tag) |tag| self.setTag(tag);
    if (rule.container) |container| self.setContainer(container);
    // if (rule.center) |center| self.center = center;
    if (rule.border) |border| self.setBorder(border);
    if (rule.floating) |floating| self.setFloating(floating);
    // if (rule.fullscreen) |fullscreen| self.fullscreen = fullscreen;
    if (rule.label) |label| self.setLabel(label);

    std.log.info("rule {s} {s}: {}", .{ appid, title, rule });

    try self.setMonitor(mon);
}

pub fn getAppId(self: *Client) ?[]const u8 {
    switch (self.surface) {
        .XDG => |surface| {
            const class = surface.role_data.toplevel.?.app_id orelse return null;

            return std.mem.span(class);
        },
        .X11 => |surface| {
            const class = surface.class orelse return null;

            return std.mem.span(class);
        },
    }
}

pub fn getTitle(self: *Client) ?[]const u8 {
    switch (self.surface) {
        .XDG => |surface| {
            const class = surface.role_data.toplevel.?.title orelse return null;

            return std.mem.span(class);
        },
        .X11 => |surface| {
            const class = surface.title orelse return null;

            return std.mem.span(class);
        },
    }
}

pub fn getLabel(self: *Client) ?[]const u8 {
    if (self.label) |label|
        return std.mem.span(label);

    return self.getTitle();
}

pub fn resize(self: *Client, in_target_bounds: ?wlr.Box, force: bool) !void {
    var target_bounds = in_target_bounds;

    if (target_bounds) |*target| {
        if (target.width < 20)
            target.width = 20;
        if (target.height < 20)
            target.height = 20;

        self.bounds = target.*;
    }

    const title_height = self.session.config.getTitleHeight();

    switch (self.frame.kind) {
        .hide => {
            self.inner_bounds.x = 0;
            self.inner_bounds.y = 0;
            self.inner_bounds.width = self.bounds.width;
            self.inner_bounds.height = self.bounds.height;
        },
        .border => {
            self.inner_bounds.x = self.border;
            self.inner_bounds.y = self.border;
            self.inner_bounds.width = self.bounds.width - self.border - self.border;
            self.inner_bounds.height = self.bounds.height - self.border - self.border;
        },
        .title => {
            self.inner_bounds.x = self.border;
            self.inner_bounds.y = self.border + title_height + self.border;
            self.inner_bounds.width = self.bounds.width - self.border - self.border;
            self.inner_bounds.height = self.bounds.height - self.border - title_height - self.border - self.border;
        },
    }

    _ = force;

    //TODO: frame?

    self.resize_serial = self.updateSize();

    try self.updateFrame();
}

pub inline fn setContainer(self: *Client, container: u8) void {
    if (self.container == container)
        return;

    self.container = container;

    if (self.monitor) |monitor|
        monitor.arrangeClients();
}

pub inline fn setBorder(self: *Client, border: i32) void {
    if (self.border == border)
        return;

    self.border = border;

    if (self.border == 0)
        self.frame.kind = .hide
    else
        self.frame.kind = .title;

    self.resize(self.bounds, true) catch {};
}

pub inline fn setIcon(self: *Client, icon: ?[*:0]const u8) void {
    if (self.icon) |old_icon|
        self.session.config.allocator.free(std.mem.span(old_icon));

    if (icon) |new_icon|
        self.icon = self.session.config.allocator.dupeZ(u8, std.mem.span(new_icon)) catch null
    else
        self.icon = null;

    self.updateFrame() catch {};
}

pub inline fn setLabel(self: *Client, label: ?[*:0]const u8) void {
    if (self.label) |old_label|
        self.session.config.allocator.free(std.mem.span(old_label));

    if (label) |new_label|
        self.label = self.session.config.allocator.dupeZ(u8, std.mem.span(new_label)) catch null
    else
        self.label = null;

    self.updateFrame() catch {};
}

pub inline fn setTag(self: *Client, tag: usize) void {
    if (self.tag == tag)
        return;

    self.tag = tag;

    if (self.monitor) |monitor|
        monitor.arrangeClients();
}

pub inline fn setFloating(self: *Client, floating: bool) void {
    if (self.floating == floating)
        return;

    // cant unfloat a window im moving
    if (self.session.input.cursor_mode != .normal)
        return;

    self.floating = floating;

    const layer: Session.Layer = if (self.floating) .LyrFloat else .LyrTile;
    self.scene.node.reparent(self.session.wayland_data.?.layers.get(layer));

    if (self.monitor) |monitor|
        monitor.arrangeClients();

    if (!self.frame.is_init)
        return;

    const shadow_layer: Session.Layer = if (self.floating) .LyrFloatShadows else .LyrTileShadows;
    self.frame.shadow_tree.node.reparent(self.session.wayland_data.?.layers.get(shadow_layer));

    if (self.border == 0)
        self.frame.kind = .hide
    else if (self.floating)
        self.frame.kind = .title
    else
        self.frame.kind = .title;
}

pub fn updateSize(self: *Client) u32 {
    if (self.surface == .X11) {
        self.surface.X11.configure(
            @intCast(self.inner_bounds.x),
            @intCast(self.inner_bounds.y),
            @intCast(@max(30, self.inner_bounds.width)),
            @intCast(@max(30, self.inner_bounds.height)),
        );

        return 0;
    }

    if (self.surface.XDG.role_data.toplevel == null) return 0;

    if (self.inner_bounds.width == self.surface.XDG.role_data.toplevel.?.current.width and
        self.inner_bounds.height == self.surface.XDG.role_data.toplevel.?.current.height)
        return 0;

    return self.surface.XDG.role_data.toplevel.?.setSize(self.inner_bounds.width, self.inner_bounds.height);
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
                .width = xsurface.width,
                .height = xsurface.height,
            };
        },
    }

    if ((self.monitor != null and
        !geom.empty() and
        (geom.width != self.inner_bounds.width or
            geom.height != self.inner_bounds.height)))
    {
        switch (self.surface) {
            .XDG => |surface| {
                try self.resize(self.bounds, false);

                if (self.resize_serial != 0 and self.resize_serial <= surface.current.configure_serial)
                    self.resize_serial = 0;
            },
            .X11 => |surface| {
                try self.resize(self.bounds, false);

                if (self.resize_serial != 0 and self.resize_serial <= surface.serial)
                    self.resize_serial = 0;
            },
        }
    }

    self.monitor.?.arrangeClients();
}

pub fn configure(self: *Client, event: *wlr.XwaylandSurface.event.Configure) !void {
    if (self.monitor == null)
        return;
    if (self.surface != .X11)
        return;

    if (self.floating or !self.managed)
        try self.resize(.{ .x = event.x, .y = event.y, .width = event.width, .height = event.height }, false);

    self.monitor.?.arrangeClients();
}

pub fn activate(self: *Client) !void {
    if (self.surface != .X11)
        return;

    self.surface.X11.activate(true);
}

pub fn unmap(self: *Client) !void {
    self.link.remove();
    self.focus_link.remove();

    if (self == self.session.input.grab_client) {
        self.session.input.cursor_mode = .normal;
    }

    self.scene.node.destroy();

    std.log.info("unmap {*}", .{self});

    if (self.frame.is_init) {
        std.log.info("{}", .{self.frame.title_buffer.base.n_locks});
        self.frame.title_buffer.base.unlock();
        self.frame.title_buffer.deinit();

        self.frame.shadow_tree.node.destroy();
    }

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
                    try self.session.focusClient(self, true);
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

    if (self.monitor) |m| m.arrangeClients();

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
            // std.log.warn("TODO: check client stopped", .{});
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

pub fn setMonitor(self: *Client, target_monitor: ?*Monitor) !void {
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
        self.setTag(new.tag);

        // self.setFullscreen(self.isfullscreen);

        new.arrangeClients();
    }

    try self.session.focusClient(self, true);
    try self.updateFrame();
}
