const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");
const cairo = @import("cairo");

const CairoBuffer = @import("cairobuffer.zig");
const Session = @import("session.zig");
const Monitor = @import("monitor.zig");
const Config = @import("config.zig");

const Client = @This();

const allocator = Config.allocator;

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

    pub fn init(kind: FrameKind, color: *const [4]f32, client: *Client) !ClientFrame {
        const shadow_scene = client.session.layers.get(.LyrFloatShadows);

        var border_tree = try client.scene.createSceneTree();
        var shadow_tree = try shadow_scene.createSceneTree();

        var sides: [4]*wlr.SceneRect = undefined;
        for (&sides) |*side| {
            side.* = try border_tree.createSceneRect(0, 0, color);
            side.*.node.data = @intFromPtr(client);
        }

        var shadow: [2]*wlr.SceneRect = undefined;
        for (&shadow) |*side| {
            side.* = try shadow_tree.createSceneRect(0, 0, &.{ 0, 0, 0, 0.5 });
            side.*.node.data = @intFromPtr(client);
        }

        const title_buffer = try CairoBuffer.create(allocator, 10, 10, 1.0);
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
            .XDG => |surface| try writer.print("{*} {}", .{ surface, surface.role }),
            .X11 => |surface| try writer.print("{*}", .{surface}),
        }
    }
};

const X11ClientEvents = struct {
    activate_event: wl.Listener(void) = .init(X11ClientEvents.activate),
    associate_event: wl.Listener(void) = .init(X11ClientEvents.associate),
    dissociate_event: wl.Listener(void) = .init(X11ClientEvents.dissociate),
    configure_event: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(X11ClientEvents.configure),
    set_hints_event: wl.Listener(void) = .init(X11ClientEvents.setHints),
    deinit_event: wl.Listener(void) = .init(X11ClientEvents.deinit),

    pub fn activate(listener: *wl.Listener(void)) void {
        const xevents: *X11ClientEvents = @fieldParentPtr("activate_event", listener);
        const events: *ClientEvents = @fieldParentPtr("xevents", xevents);
        const client: *Client = @fieldParentPtr("events", events);

        client.activate() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn associate(listener: *wl.Listener(void)) void {
        const xevents: *X11ClientEvents = @fieldParentPtr("associate_event", listener);
        const events: *ClientEvents = @fieldParentPtr("xevents", xevents);
        const client: *Client = @fieldParentPtr("events", events);

        client.associate() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn dissociate(listener: *wl.Listener(void)) void {
        const xevents: *X11ClientEvents = @fieldParentPtr("dissociate_event", listener);
        const events: *ClientEvents = @fieldParentPtr("xevents", xevents);
        const client: *Client = @fieldParentPtr("events", events);

        client.dissociate() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn configure(listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure), event: *wlr.XwaylandSurface.event.Configure) void {
        const xevents: *X11ClientEvents = @fieldParentPtr("configure_event", listener);
        const events: *ClientEvents = @fieldParentPtr("xevents", xevents);
        const client: *Client = @fieldParentPtr("events", events);

        client.configure(event) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn setHints(listener: *wl.Listener(void)) void {
        const xevents: *X11ClientEvents = @fieldParentPtr("set_hints_event", listener);
        const events: *ClientEvents = @fieldParentPtr("xevents", xevents);
        const client: *Client = @fieldParentPtr("events", events);

        client.setHints() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn deinit(listener: *wl.Listener(void)) void {
        const xevents: *X11ClientEvents = @fieldParentPtr("deinit_event", listener);
        const events: *ClientEvents = @fieldParentPtr("xevents", xevents);
        const client: *Client = @fieldParentPtr("events", events);

        client.deinit();
    }
};

const ClientEvents = struct {
    commit_event: wl.Listener(*wlr.Surface) = .init(ClientEvents.commit),
    map_event: wl.Listener(void) = .init(ClientEvents.map),
    unmap_event: wl.Listener(void) = .init(ClientEvents.unmap),
    deinit_event: wl.Listener(*wlr.Surface) = .init(ClientEvents.deinit),
    set_title_event: wl.Listener(void) = .init(ClientEvents.setTitle),
    fullscreen_event: wl.Listener(void) = .init(ClientEvents.fullscreen),
    xevents: X11ClientEvents = .{},

    pub fn commit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const events: *ClientEvents = @fieldParentPtr("commit_event", listener);
        const client: *Client = @fieldParentPtr("events", events);

        client.commit() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn map(listener: *wl.Listener(void)) void {
        const events: *ClientEvents = @fieldParentPtr("map_event", listener);
        const client: *Client = @fieldParentPtr("events", events);

        client.map() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn unmap(listener: *wl.Listener(void)) void {
        const events: *ClientEvents = @fieldParentPtr("unmap_event", listener);
        const client: *Client = @fieldParentPtr("events", events);

        client.unmap() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn deinit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const events: *ClientEvents = @fieldParentPtr("deinit_event", listener);
        const client: *Client = @fieldParentPtr("events", events);

        client.deinit();
    }

    pub fn setTitle(listener: *wl.Listener(void)) void {
        const events: *ClientEvents = @fieldParentPtr("set_title_event", listener);
        const client: *Client = @fieldParentPtr("events", events);

        client.updateFrame() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn fullscreen(listener: *wl.Listener(void)) void {
        const events: *ClientEvents = @fieldParentPtr("fullscreen_event", listener);
        const client: *Client = @fieldParentPtr("events", events);

        client.setFullscreen(true) catch |ex| {
            @panic(@errorName(ex));
        };
    }
};

client_id: u8 = 10,

session: *Session,
surface: ClientSurface,
events: ClientEvents = .{},

scene: *wlr.SceneTree = undefined,
scene_surface: *wlr.SceneTree = undefined,

bounds: wlr.Box = std.mem.zeroes(wlr.Box),
inner_bounds: wlr.Box = std.mem.zeroes(wlr.Box),
prev_bounds: wlr.Box = std.mem.zeroes(wlr.Box),
label: ?[*:0]const u8 = null,
icon: ?[*:0]const u8 = null,
monitor: ?*Monitor = null,
managed: bool,
fullscreen: bool = false,
frame: ClientFrame = .{},
hide_frame: bool = false,

resize_serial: u32 = 0,

link: wl.list.Link = undefined,
focus_link: wl.list.Link = undefined,

// properties
container: u8 = 0,
floating: bool = true,
tag: u8 = 0,
border: i32 = 0,

// TODO: move this to config
const SHADOW_SIZE = 10;

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

    const clip: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = self.inner_bounds.width,
        .height = self.inner_bounds.height,
    };

    self.scene_surface.node.subsurfaceTreeSetClip(&clip);

    if (self.hide_frame) {
        for (self.frame.sides) |side|
            side.node.setEnabled(false);
        for (self.frame.shadow) |shadow|
            shadow.node.setEnabled(false);
        self.frame.buffer_scene.node.setEnabled(false);
    } else {
        for (self.frame.shadow) |shadow|
            shadow.node.setEnabled(true);
        for (self.frame.sides) |side|
            side.node.setEnabled(self.frame.kind == .title or self.frame.kind == .border);
        self.frame.sides[0].node.setEnabled(self.frame.kind == .border);
        self.frame.buffer_scene.node.setEnabled(self.frame.kind == .title);
    }

    if (self.managed) {
        const layer: Session.Layer = if (self.floating) .LyrFloat else .LyrTile;
        self.scene.node.reparent(self.session.layers.get(layer));

        const shadow_layer: Session.Layer = if (self.floating) .LyrFloatShadows else .LyrTileShadows;
        self.frame.shadow_tree.node.reparent(self.session.layers.get(shadow_layer));

        self.scene.node.setPosition(self.bounds.x, self.bounds.y);
        self.scene_surface.node.setPosition(self.inner_bounds.x, self.inner_bounds.y);

        self.frame.shadow_tree.node.setPosition(self.bounds.x + self.bounds.width, self.bounds.y + self.bounds.height);
        self.frame.shadow[0].node.setPosition(0, -self.bounds.height + SHADOW_SIZE);
        self.frame.shadow[1].node.setPosition(-self.bounds.width + SHADOW_SIZE, 0);

        self.frame.shadow[0].setSize(SHADOW_SIZE, self.bounds.height);
        self.frame.shadow[1].setSize(self.bounds.width - SHADOW_SIZE, SHADOW_SIZE);
    } else {
        self.bounds.x = self.surface.X11.x;
        self.bounds.y = self.surface.X11.y;

        self.scene.node.reparent(self.session.layers.get(.LyrFloat));
        self.scene.node.setPosition(self.bounds.x, self.bounds.y);
    }

    if (self.frame.kind != .border and self.frame.kind != .title)
        return;

    const border_color =
        if (self.session.selmon) |selmon|
            self.session.config.getColor(selmon.focusedClient() == self, .border)
        else
            self.session.config.getColor(false, .border);

    for (self.frame.sides) |side|
        side.setColor(border_color);

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
    const title_pad = self.session.config.getTitlePad();

    self.frame.title_buffer = try self.frame.title_buffer.resize(
        @intCast(total_width),
        @intCast(total_height),
        if (self.monitor) |monitor| monitor.output.scale else self.frame.title_buffer.scale,
    );

    var context = try self.frame.title_buffer.beginContext();
    defer self.frame.title_buffer.endContext(&context);

    const font = self.session.config.getFont();
    context.selectFontFace(@ptrCast(font.face), .normal, .bold);
    const size: f64 = @floatFromInt(font.size);
    context.setFontSize(size);

    var iter = self.session.clients.iterator(.forward);
    var current_tab: i32 = 0;
    while (iter.next()) |tab_client| {
        if (!self.sharesTabs(tab_client))
            continue;

        const tab_start: i32 = @intFromFloat(ftab_width * @as(f64, @floatFromInt(current_tab)));
        const tab_end: i32 = @intFromFloat(ftab_width * @as(f64, @floatFromInt(current_tab + 1)));
        const tab_width: i32 = tab_end - tab_start;

        const tab_focus = tab_client == self;

        const label = tab_client.getLabel();
        const label_extents = context.textExtents(label.ptr);

        const label_y_bearing: i32 = @intFromFloat(label_extents.y_bearing);
        const label_height: i32 = @intFromFloat(label_extents.height);

        const icon = std.mem.span(tab_client.icon orelse "?");
        const icon_extents = context.textExtents(icon.ptr);
        const icon_width: i32 = @intFromFloat(icon_extents.width);
        const icon_height: i32 = @intFromFloat(icon_extents.height);
        const icon_y_bearing: i32 = @intFromFloat(icon_extents.y_bearing);

        const fg = self.session.config.getColor(tab_focus, .foreground);
        const bg = self.session.config.getColor(tab_focus, .background);

        var fade_pattern = try cairo.Pattern.createLinear(
            @floatFromInt(self.border + tab_start + tab_width - icon_width - title_pad - 30),
            @floatFromInt(self.border),
            @floatFromInt(self.border + tab_start + tab_width - icon_width - title_pad),
            0,
        );
        try fade_pattern.addColorStopRgba(1, bg[2], bg[1], bg[0], bg[3]);
        try fade_pattern.addColorStopRgba(0, fg[2], fg[1], fg[0], fg[3]);

        context.setOperator(.source);

        context.setSourceRgba(border_color[2], border_color[1], border_color[0], border_color[3]);
        context.rectangle(
            @floatFromInt(tab_start),
            @floatFromInt(0),
            @floatFromInt(tab_width + 1),
            @floatFromInt(total_height),
        );
        context.fill();

        context.setSourceRgba(bg[2], bg[1], bg[0], bg[3]);
        context.rectangle(
            @floatFromInt(self.border + tab_start),
            @floatFromInt(self.border),
            @floatFromInt(tab_width - self.border - self.border),
            @floatFromInt(total_height - self.border - self.border),
        );
        context.fill();

        context.moveTo(
            @floatFromInt(tab_start + self.border + title_pad),
            @floatFromInt(self.border + title_pad + @divTrunc(font.size - label_height, 2) - label_y_bearing),
        );
        context.setSource(&fade_pattern);
        context.textPath(label);
        context.fill();

        context.moveTo(
            @floatFromInt(tab_start + tab_width - title_pad - icon_width - self.border),
            @floatFromInt(self.border + title_pad + @divTrunc(font.size - icon_height, 2) - icon_y_bearing),
        );
        context.textPath(icon);
        context.setSourceRgba(fg[2], fg[1], fg[0], fg[3]);
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

    self.frame.buffer_scene.setDestSize(total_width, total_height);
    self.frame.buffer_scene.node.setEnabled(true);
}

pub fn setVisible(self: *Client, visible: bool) void {
    self.scene.node.setEnabled(visible);
    self.frame.shadow_tree.node.setEnabled(visible and self.managed);
}

pub fn init(session: *Session, target: ClientSurface) !void {
    switch (target) {
        .XDG => |surface| {
            if (surface.role == .popup) {
                if (surface.role_data.popup.?.parent == null)
                    return;

                client_check: {
                    const client = session.getClient(surface.surface) orelse break :client_check;
                    const new_surface = try client.scene_surface.createSceneXdgSurface(surface);
                    surface.surface.data = @intFromPtr(new_surface);

                    var box =
                        if (client.monitor) |parent_mon|
                            parent_mon.window
                        else
                            break :client_check;
                    box.x -= client.bounds.x;
                    box.y -= client.bounds.y;

                    surface.role_data.popup.?.unconstrainFromBox(&client.bounds);

                    return;
                }

                std.log.err("failed to create client", .{});

                return;
            } else if (surface.role == .none)
                return;

            const client = try allocator.create(Client);
            surface.data = @intFromPtr(client);

            client.* = .{ .surface = target, .session = session, .managed = true };

            std.log.info("add xdg surface {*} to {*}", .{ target.XDG, client });

            surface.surface.events.commit.add(&client.events.commit_event);
            surface.surface.events.map.add(&client.events.map_event);
            surface.surface.events.unmap.add(&client.events.unmap_event);
            surface.surface.events.destroy.add(&client.events.deinit_event);

            const toplevel = surface.role_data.toplevel orelse @panic("toplevel null");
            toplevel.events.set_title.add(&client.events.set_title_event);
            toplevel.events.request_fullscreen.add(&client.events.fullscreen_event);

            std.log.info("created client", .{});

            return;
        },
        .X11 => |surface| {
            const client = try allocator.create(Client);
            surface.data = @intFromPtr(client);

            client.* = .{ .surface = target, .session = session, .managed = !surface.override_redirect };

            std.log.info("add x11 surface {*} to {*}", .{ target.X11, client });

            // used for reference when comparing to xcb names
            // https://github.com/swaywm/wlroots/blob/0855cdacb2eeeff35849e2e9c4db0aa996d78d10/include/wlr/xwayland.h#L143

            surface.events.associate.add(&client.events.xevents.associate_event);
            surface.events.dissociate.add(&client.events.xevents.dissociate_event);
            surface.events.request_activate.add(&client.events.xevents.activate_event);
            surface.events.request_configure.add(&client.events.xevents.configure_event);
            surface.events.set_hints.add(&client.events.xevents.set_hints_event);
            surface.events.set_title.add(&client.events.set_title_event);
            surface.events.destroy.add(&client.events.xevents.deinit_event);
            surface.events.request_fullscreen.add(&client.events.fullscreen_event);

            std.log.info("created x11 client", .{});
        },
    }
}

pub fn associate(self: *Client) !void {
    self.getSurface().events.map.add(&self.events.map_event);
    self.getSurface().events.unmap.add(&self.events.unmap_event);
}

pub fn dissociate(self: *Client) !void {
    self.events.map_event.link.remove();
    self.events.unmap_event.link.remove();
}

pub fn setHints(self: *Client) !void {
    // TODO: implement
    // const surface = self.getSurface();

    // if (surface == self.session.selmon.?.focusedClient())
    //     return;

    _ = self;
}

pub fn map(self: *Client) !void {
    std.log.info("map client {*}", .{self});

    self.scene = try self.session.layers.get(.LyrTile).createSceneTree();

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

    self.monitor = self.session.selmon orelse self.session.monitors.first() orelse return;

    var geom: wlr.Box = undefined;
    switch (self.surface) {
        .XDG => |xdg| {
            xdg.getGeometry(&geom);
        },
        .X11 => |x11| {
            if (self.managed) {
                geom = .{
                    .x = 0,
                    .y = 0,
                    .width = 0,
                    .height = 0,
                };
            } else {
                geom = .{
                    .x = x11.x,
                    .y = x11.y,
                    .width = x11.width,
                    .height = x11.height,
                };
            }
        },
    }

    if (self.managed)
        try self.applyRules();

    self.frame = try .init(if (self.managed)
        if (self.floating) .title else .border
    else
        .hide, self.session.config.getColor(false, .border), self);

    if (self.managed)
        geom = self.applyBounds(geom, true);

    std.log.info("map client {*} surf {}", .{ self, self.surface });

    self.session.clients.append(self);
    self.session.focus_clients.append(self);

    if (self.managed)
        try self.session.focusClient(self, true)
    else
        self.activateSurface(true);

    if (self.floating)
        try self.resize(geom)
    else if (self.monitor) |m|
        try m.arrangeClients();

    try self.updateFrame();
}

pub fn applyRules(self: *Client) !void {
    try self.setBorder(0);
    try self.setFloating(true);
    try self.setIcon("?");
    try self.session.config.applyRules(self);
}

pub fn getAppId(self: *Client) []const u8 {
    switch (self.surface) {
        .XDG => |surface| {
            const class = surface.role_data.toplevel.?.app_id orelse return "No appid";

            return std.mem.span(class);
        },
        .X11 => |surface| {
            const class = surface.class orelse return "No appid";

            return std.mem.span(class);
        },
    }
}

pub fn getTitle(self: *Client) []const u8 {
    switch (self.surface) {
        .XDG => |surface| {
            const title = surface.role_data.toplevel.?.title orelse return "No title";

            return std.mem.span(title);
        },
        .X11 => |surface| {
            const title = surface.title orelse return "No title";

            return std.mem.span(title);
        },
    }
}

pub fn getLabel(self: *Client) []const u8 {
    if (self.label) |label|
        return std.mem.span(label);

    return self.getTitle();
}

pub fn applyBounds(self: *Client, bounds: wlr.Box, base: bool) wlr.Box {
    var result = bounds;

    const title_height = self.session.config.getTitleHeight();
    const x_start = if (self.frame.kind == .hide)
        0
    else
        self.border;
    const x_border = x_start + if (self.frame.kind == .hide)
        0
    else
        self.border;
    const y_start = if (self.frame.kind == .hide)
        0
    else if (self.frame.kind == .border)
        self.border
    else
        self.border + title_height + self.border;
    const y_border = y_start + if (self.frame.kind == .hide)
        0
    else
        self.border;

    switch (self.surface) {
        .X11 => |surface| {
            if (surface.size_hints) |hints| {
                // base size
                if (base) {
                    if (hints.flags & 0b100000000 != 0) {
                        result.width = hints.base_width + x_border;

                        result.height = hints.base_height + y_border;
                    }

                    // x position
                    if (hints.flags & 0b101 != 0) {
                        result.x = hints.x - x_start;

                        result.y = hints.y + y_start;
                    }

                    // size
                    if (hints.flags & 0b1010 != 0) {
                        result.width = hints.width + x_border;

                        result.height = hints.height + y_border;
                    }
                }

                // min size
                if (hints.flags & 0b10000 != 0) {
                    result.width = @max(
                        result.width,
                        hints.min_width + x_border,
                    );

                    result.height = @max(
                        result.height,
                        hints.min_height + y_border,
                    );
                }

                // max size
                if (hints.flags & 0b100000 != 0) {
                    result.width = @min(
                        result.width,
                        @min(hints.max_width, 10000000) + x_border,
                    );

                    result.height = @min(
                        result.height,
                        @min(hints.max_height, 10000000) + y_border,
                    );
                }
            }
        },
        .XDG => |surface| {
            _ = surface;
            // TODO: do this right
            // if (surface.role_data.toplevel) |toplevel| {
            //     result.width = @max(
            //         result.width,
            //         toplevel.current.min_width + x_border,
            //     );

            //     if (toplevel.current.max_width != 0)
            //         result.width = @min(
            //             result.width,
            //             toplevel.current.max_width + x_border,
            //         );

            //     result.height = @max(
            //         result.height,
            //         toplevel.current.min_height + y_border,
            //     );

            //     if (toplevel.current.max_height != 0)
            //         result.height = @min(
            //             result.height,
            //             toplevel.current.max_height + y_border,
            //         );
            // }
        },
    }

    result.width = @max(result.width, 20 + x_border);
    result.height = @max(result.height, 20 + y_border);

    return result;
}

pub fn resize(self: *Client, in_target_bounds: wlr.Box) !void {
    self.inner_bounds = self.applyBounds(in_target_bounds, false);

    self.bounds = self.applyBounds(in_target_bounds, false);

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

    self.resize_serial = self.updateSize();

    try self.updateFrame();
}

pub inline fn setContainer(self: *Client, container: u8) !void {
    if (self.container == container)
        return;

    self.container = container;

    std.log.info("set container: {}", .{self.container});

    if (self.monitor) |m|
        try m.arrangeClients();
}

pub inline fn setFrame(self: *Client, frame: FrameKind) !void {
    if (self.frame.kind == frame)
        return;

    if (self.managed)
        self.frame.kind = frame
    else
        self.frame.kind = .hide;

    try self.resize(self.bounds);
}

pub inline fn setBorder(self: *Client, border: i32) !void {
    if (self.border == border)
        return;

    self.border = border;

    try self.resize(self.bounds);
}

pub inline fn setIcon(self: *Client, icon: ?[*:0]const u8) !void {
    if (self.icon) |old_icon|
        allocator.free(std.mem.span(old_icon));

    if (icon) |new_icon|
        self.icon = allocator.dupeZ(u8, std.mem.span(new_icon)) catch null
    else
        self.icon = null;

    try self.updateFrame();
}

pub inline fn setLabel(self: *Client, label: ?[*:0]const u8) !void {
    if (self.label) |old_label|
        allocator.free(std.mem.span(old_label));

    if (label) |new_label|
        self.label = allocator.dupeZ(u8, std.mem.span(new_label)) catch null
    else
        self.label = null;

    try self.updateFrame();
}

pub inline fn setTag(self: *Client, tag: u8) !void {
    if (self.tag == tag)
        return;

    self.tag = tag;

    if (self.monitor) |m|
        try m.arrangeClients();
}

pub inline fn setFullscreen(self: *Client, fullscreen: bool) !void {
    _ = self;
    _ = fullscreen;

    return;
}

pub inline fn setFloating(self: *Client, floating: bool) !void {
    if (self.floating == floating)
        return;

    // cant unfloat a window im moving
    if (self.session.input.cursor_mode != .normal and
        self.session.input.cursor_mode != .pressed and
        self.floating == true)
        return;

    self.floating = floating;

    if (self.monitor) |m|
        try m.arrangeClients();

    if (!self.frame.is_init)
        return;

    if (self.floating)
        try self.setFrame(.title);
}

pub fn updateSize(self: *Client) u32 {
    const inner: wlr.Box = .{
        .x = self.bounds.x + self.inner_bounds.x,
        .y = self.bounds.y + self.inner_bounds.y,
        .width = self.inner_bounds.width,
        .height = self.inner_bounds.height,
    };

    if (self.surface == .X11) {
        self.surface.X11.configure(
            @intCast(inner.x),
            @intCast(inner.y),
            @intCast(inner.width),
            @intCast(inner.height),
        );

        return 0;
    }

    if (self.surface.XDG.role_data.toplevel == null) return 0;

    if (inner.width == self.surface.XDG.role_data.toplevel.?.current.width and
        inner.height == self.surface.XDG.role_data.toplevel.?.current.height)
        return 0;

    return self.surface.XDG.role_data.toplevel.?.setSize(inner.width, inner.height);
}

pub fn commit(self: *Client) !void {
    if (self.getSurface().mapped)
        try self.resize(self.bounds);

    switch (self.surface) {
        .XDG => |surface| {
            if (self.resize_serial != 0 and self.resize_serial <= surface.current.configure_serial)
                self.resize_serial = 0;
        },
        .X11 => {
            self.resize_serial = 0;
        },
    }
}

pub fn configure(self: *Client, event: *wlr.XwaylandSurface.event.Configure) !void {
    if (self.monitor == null)
        return;

    if (self.floating or !self.managed)
        try self.resize(.{
            .x = event.x,
            .y = event.y,
            .width = event.width,
            .height = event.height,
        })
    else if (self.monitor) |m|
        try m.arrangeClients();
}

pub fn activate(self: *Client) !void {
    if (self.surface != .X11)
        return;

    if (self.monitor) |monitor|
        monitor.sendFocus();

    self.surface.X11.activate(true);
}

pub fn unmap(self: *Client) !void {
    if (self == self.session.input.grab_client) {
        self.session.input.cursor_mode = .normal;
    }

    std.log.info("unmap {*}", .{self});

    try self.setMonitor(null);

    if (self.frame.is_init) {
        std.log.info("{}", .{self.frame.title_buffer.base.n_locks});
        self.frame.title_buffer.base.unlock();
        self.frame.title_buffer.deinit();

        self.frame.shadow_tree.node.destroy();

        self.frame.is_init = false;
    }

    if (!self.managed) {
        if (self.getSurface() == self.session.exclusive_focus)
            self.session.exclusive_focus = null;
        // TODO: remove exclusive focus if needed
        if (self.getSurface() == self.session.input.seat.keyboard_state.focused_surface) unfocus: {
            if (self.session.selmon) |selmon| {
                if (selmon.focusedClient()) |top| {
                    try self.session.focusClient(top, false);
                    break :unfocus;
                }
            }

            self.session.focusClear();
        }
    }

    self.link.remove();
    self.focus_link.remove();

    self.scene.node.destroy();

    const objects = self.session.getObjectsAt(
        self.session.input.cursor.x,
        self.session.input.cursor.y,
    );

    if (objects.client) |client|
        try self.session.focusClient(client, true);

    if (self.session.selmon) |selmon|
        selmon.sendFocus();

    try self.setIcon(null);
    try self.setLabel(null);
}

pub fn deinit(self: *Client) void {
    self.events.set_title_event.link.remove();
    self.events.fullscreen_event.link.remove();

    switch (self.surface) {
        .XDG => {
            self.events.deinit_event.link.remove();
            self.events.commit_event.link.remove();
            self.events.map_event.link.remove();
            self.events.unmap_event.link.remove();
        },
        .X11 => {
            self.events.xevents.deinit_event.link.remove();
            self.events.xevents.activate_event.link.remove();
            self.events.xevents.associate_event.link.remove();
            self.events.xevents.dissociate_event.link.remove();
            self.events.xevents.configure_event.link.remove();
            self.events.xevents.set_hints_event.link.remove();
        },
    }

    allocator.destroy(self);
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
        try old.arrangeClients();

        self.getSurface().sendLeave(old.output);
    }

    if (target_monitor) |new| {
        self.getSurface().sendEnter(new.output);
        try self.setTag(new.tag);

        try self.resize(self.bounds);

        try self.setFullscreen(self.fullscreen);

        try new.arrangeClients();
    }

    try self.session.focusClient(self, true);
    try self.updateFrame();
}
