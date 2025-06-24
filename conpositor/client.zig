const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");
const cairo = @import("cairo");

const CairoBuffer = @import("cairobuffer.zig");
const Session = @import("session.zig");
const Monitor = @import("monitor.zig");
const Config = @import("config.zig");

const Client = @This();

const ClientError = cairo.Error || error{TODO};

const allocator = Config.allocator;

const SurfaceKind = enum { XDG, X11 };
const FrameKind = enum { hide, border, title };

const ClientFrame = struct {
    kind: FrameKind = .hide,
    is_init: bool = false,

    title_buffer: *CairoBuffer = undefined,

    shadow: [2]*wlr.SceneRect = undefined,
    shadow_tree: *wlr.SceneTree = undefined,
    border_tree: *wlr.SceneTree = undefined,
    sides: [4]*wlr.SceneRect = undefined,
    buffer_scene: *wlr.SceneBuffer = undefined,

    pub fn init(kind: FrameKind, color: *const [4]f32, client: *Client) !ClientFrame {
        const shadow_scene = client.session.layers.get(.LyrFloatShadows);

        var shadow_tree = try shadow_scene.createSceneTree();
        shadow_tree.node.data = @intFromPtr(client);

        var border_tree = try client.scene.createSceneTree();
        border_tree.node.data = @intFromPtr(client);

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

        const title_buffer = try CairoBuffer.create(allocator, 0, 0, 1.0);
        const locked = title_buffer.base.lock();

        shadow_tree.node.setEnabled(false);

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

        client.dirty.title = true;
    }

    pub fn fullscreen(listener: *wl.Listener(void)) void {
        const events: *ClientEvents = @fieldParentPtr("fullscreen_event", listener);
        const client: *Client = @fieldParentPtr("events", events);

        client.setFullscreen(true);
    }
};

client_id: u8 = 10,

session: *Session,
surface: ClientSurface,
events: ClientEvents = .{},
active: bool = false,

scene: *wlr.SceneTree = undefined,
scene_surface: *wlr.SceneTree = undefined,
popup_surface: *wlr.SceneTree = undefined,

container_bounds: wlr.Box = std.mem.zeroes(wlr.Box),
floating_bounds: wlr.Box = std.mem.zeroes(wlr.Box),
label: ?[:0]const u8 = null,
icon: ?[:0]const u8 = null,
monitor: ?*Monitor = null,
managed: bool,
fullscreen: bool = false,
frame: ClientFrame = .{},
visible: bool = true,
hide_frame: bool = false,

resize_serial: ?u32 = null,

link: wl.list.Link = undefined,
focus_link: wl.list.Link = undefined,

dirty: packed struct {
    size: bool = true,
    floating: bool = true,
    frame: bool = true,
    title: bool = true,
    visible: bool = true,
    container: bool = true,
    top: bool = true,
} = .{},

// properties
container: u8 = 0,
floating: bool = true,
tag: u8 = 0,
border: i32 = 0,

// TODO: move this to config
const SHADOW_SIZE = 10;

pub fn getBounds(self: *Client) wlr.Box {
    if (self.floating)
        return self.floating_bounds
    else
        return self.container_bounds;
}

pub fn getInnerBounds(self: *Client) wlr.Box {
    const title_height = self.session.config.getTitleHeight();
    const bounds = self.getBounds();

    return switch (self.frame.kind) {
        .hide => .{
            .x = 0,
            .y = 0,
            .width = bounds.width,
            .height = bounds.height,
        },
        .border => .{
            .x = self.border,
            .y = self.border,
            .width = bounds.width - self.border - self.border,
            .height = bounds.height - self.border - self.border,
        },
        .title => .{
            .x = self.border,
            .y = self.border + title_height + self.border,
            .width = bounds.width - self.border - self.border,
            .height = bounds.height - self.border - title_height - self.border - self.border,
        },
    };
}

fn sharesTabs(self: *const Client, other: *Client) bool {
    return self == other or
        (self.container == other.container and
            !self.floating and
            !other.floating and
            self.tag == other.tag and
            self.monitor == other.monitor);
}

fn updateSize(self: *Client) !void {
    if (!self.frame.is_init)
        return;

    std.log.info("update size", .{});
    defer self.dirty.size = false;

    self.resize_serial = self.updateSizeSerial();

    if (self.isStopped())
        return;

    const inner_bounds = self.getInnerBounds();
    const bounds = self.getBounds();

    const clip: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = inner_bounds.width,
        .height = inner_bounds.height,
    };

    self.scene_surface.node.subsurfaceTreeSetClip(&clip);

    if (self.managed) {
        self.scene.node.setPosition(bounds.x, bounds.y);
        self.scene_surface.node.setPosition(inner_bounds.x, inner_bounds.y);
        self.popup_surface.node.setPosition(inner_bounds.x, inner_bounds.y);

        self.frame.shadow_tree.node.setPosition(bounds.x + bounds.width, bounds.y + bounds.height);
        self.frame.shadow[0].node.setPosition(0, -bounds.height + SHADOW_SIZE);
        self.frame.shadow[1].node.setPosition(-bounds.width + SHADOW_SIZE, 0);

        self.frame.shadow[0].setSize(SHADOW_SIZE, bounds.height);
        self.frame.shadow[1].setSize(bounds.width - SHADOW_SIZE, SHADOW_SIZE);
    } else {
        self.floating_bounds.x = self.surface.X11.x;
        self.floating_bounds.y = self.surface.X11.y;

        self.scene.node.reparent(self.session.layers.get(.LyrFloat));
        self.scene.node.setPosition(self.floating_bounds.x, self.floating_bounds.y);
    }

    self.frame.sides[0].setSize(bounds.width, inner_bounds.y);
    self.frame.sides[1].setSize(bounds.width, bounds.height - inner_bounds.height - inner_bounds.y);
    self.frame.sides[2].setSize(inner_bounds.x, bounds.height);
    self.frame.sides[3].setSize(bounds.width - inner_bounds.width - inner_bounds.x, bounds.height);

    self.frame.sides[0].node.setPosition(0, 0);
    self.frame.sides[1].node.setPosition(0, inner_bounds.height + inner_bounds.y);
    self.frame.sides[2].node.setPosition(0, 0);
    self.frame.sides[3].node.setPosition(inner_bounds.width + inner_bounds.x, 0);

    if (self.frame.kind == .title) {
        const title_height = self.session.config.getTitleHeight();
        const total_width: i32 = bounds.width;
        const total_height: i32 = title_height + self.border * 2;

        self.frame.buffer_scene.setDestSize(total_width, total_height);

        self.frame.title_buffer = try self.frame.title_buffer.resize(
            @intCast(total_width),
            @intCast(total_height),
            if (self.monitor) |monitor| monitor.output.scale else self.frame.title_buffer.scale,
        );

        try self.updateTitles();
    }

    try self.session.input.motionNotify(0);
}

fn updateFrame(self: *Client) !void {
    if (!self.frame.is_init)
        return;

    std.log.info("update frame", .{});
    defer self.dirty.frame = false;

    for (self.frame.shadow) |shadow|
        shadow.node.setEnabled(!self.hide_frame);
    self.frame.border_tree.node.setEnabled(self.frame.kind == .title or self.frame.kind == .border);
    self.frame.buffer_scene.node.setEnabled(self.frame.kind == .title);

    const border_color = self.session.config.getColor(self.active, .border);

    for (self.frame.sides) |side|
        side.setColor(border_color);
}

fn updateTabs(self: *Client) !void {
    if (self.dirty.frame)
        try self.updateFrame();

    if (self.frame.kind != .title)
        return;

    const bounds = self.getBounds();

    if (bounds.width == 0 or bounds.height == 0)
        return;

    var tab_count: i32 = 0;
    var border_focus = false;
    {
        var iter = self.session.clients.iterator(.forward);
        while (iter.next()) |tab_client| {
            if (!self.sharesTabs(tab_client))
                continue;

            tab_count += 1;

            if (tab_client.active)
                border_focus = true;
        }
    }

    const title_height = self.session.config.getTitleHeight();

    const total_width: i32 = bounds.width;
    const total_height: i32 = title_height + self.border;
    const ftab_width: f64 = @as(f64, @floatFromInt(total_width)) / @as(f64, @floatFromInt(tab_count));
    const title_pad = self.session.config.getTitlePad();

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

        const icon = tab_client.icon orelse "?";
        const icon_extents = context.textExtents(icon.ptr);
        const icon_width: i32 = @intFromFloat(icon_extents.width);
        const icon_height: i32 = @intFromFloat(icon_extents.height);
        const icon_y_bearing: i32 = @intFromFloat(icon_extents.y_bearing);

        const fg = self.session.config.getColor(tab_focus, .foreground);
        const bg = self.session.config.getColor(tab_focus, .background);
        const border_color = self.session.config.getColor(tab_focus, .border);

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
            @floatFromInt(total_height - self.border),
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

    self.frame.buffer_scene.node.setEnabled(true);
}

fn updateTitles(self: *Client) !void {
    std.log.info("update title", .{});
    defer self.dirty.title = false;

    var iter = self.session.clients.iterator(.forward);
    while (iter.next()) |client|
        if (self.sharesTabs(client))
            try client.updateTabs();
}

pub fn updateVisible(self: *Client) !void {
    if (self.dirty.container) {
        if (self.monitor) |m|
            m.dirty.layout = true;
        return;
    }

    std.log.info("update visible", .{});
    defer self.dirty.visible = false;

    self.scene.node.setEnabled(self.visible);
    self.frame.shadow_tree.node.setEnabled(self.visible and self.managed);
}

pub fn updateFloating(self: *Client) !void {
    std.log.info("update floating", .{});
    defer self.dirty.floating = false;

    const shadow_layer: Session.Layer = if (self.floating) .LyrFloatShadows else .LyrTileShadows;
    self.frame.shadow_tree.node.reparent(self.session.layers.get(shadow_layer));

    const layer: Session.Layer = if (self.floating) .LyrFloat else .LyrTile;
    self.scene.node.reparent(self.session.layers.get(layer));

    try self.updateSize();
}

pub fn updateTop(self: *Client) !void {
    std.log.info("update top", .{});
    defer self.dirty.top = false;

    try self.updateFrame();

    self.frame.shadow_tree.node.raiseToTop();
    self.scene.node.raiseToTop();
}

pub fn cleanDirty(self: *Client) !void {
    if (self.dirty.visible)
        try self.updateVisible();

    if (!self.visible)
        return;

    if (self.dirty.floating)
        try self.updateFloating();

    if (self.dirty.frame)
        try self.updateFrame();

    if (self.dirty.title)
        try self.updateTitles();

    if (self.dirty.size)
        try self.updateSize();

    if (self.dirty.top)
        try self.updateTop();
}

pub fn init(session: *Session, target: ClientSurface) !void {
    switch (target) {
        .XDG => |surface| {
            if (surface.role == .popup) {
                const objects = session.getSurfaceObjects(surface.surface);

                if (surface.role_data.popup.?.parent == null or
                    (objects.client == null and objects.layer_surface == null))
                    return;

                const parent = @as(?*wlr.SceneTree, @ptrFromInt(surface.role_data.popup.?.parent.?.data)) orelse
                    if (objects.client) |client|
                        client.popup_surface
                    else if (objects.layer_surface) |layer_surface|
                        layer_surface.scene_tree
                    else
                        unreachable;

                const new_surface = try parent.createSceneXdgSurface(surface);
                surface.surface.data = @intFromPtr(new_surface);
                new_surface.node.raiseToTop();

                if ((objects.client != null and objects.client.?.monitor == null) or
                    (objects.layer_surface != null and objects.layer_surface.?.monitor == null))
                    return;

                var box = if (objects.client) |client|
                    client.monitor.?.window
                else if (objects.layer_surface) |layer_surface|
                    layer_surface.monitor.?.mode
                else
                    unreachable;

                box.x -= if (objects.client) |client|
                    client.getInnerBounds().x
                else if (objects.layer_surface) |layer_surface|
                    layer_surface.bounds.x
                else
                    unreachable;
                box.y -= if (objects.client) |client|
                    client.getInnerBounds().y
                else if (objects.layer_surface) |layer_surface|
                    layer_surface.bounds.y
                else
                    unreachable;

                surface.role_data.popup.?.unconstrainFromBox(&box);

                return;
            } else if (surface.role == .none)
                return;

            const client = try allocator.create(Client);
            surface.data = @intFromPtr(client);

            client.* = .{ .surface = target, .session = session, .managed = true };

            std.log.info("add xdg surface {*} to {*}", .{ target.XDG, client });

            const toplevel = surface.role_data.toplevel orelse @panic("toplevel null");

            _ = toplevel.setWmCapabilities(.{ .fullscreen = true });

            surface.surface.events.commit.add(&client.events.commit_event);
            surface.surface.events.map.add(&client.events.map_event);
            surface.surface.events.unmap.add(&client.events.unmap_event);
            surface.surface.events.destroy.add(&client.events.deinit_event);

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
    // const surface = self.getSurface();
    const monitor = self.monitor orelse return;
    if (self == monitor.focusedClient())
        return;

    // self.setUrgent()
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
    self.popup_surface = try self.scene.createSceneTree();

    self.scene.node.data = @intFromPtr(self);
    self.scene_surface.node.data = @intFromPtr(self);

    self.scene.node.setEnabled(false);
    self.scene_surface.node.setEnabled(true);

    var geom: wlr.Box = undefined;
    switch (self.surface) {
        .XDG => |xdg| {
            xdg.getGeometry(&geom);
        },
        .X11 => |x11| {
            geom = .{
                .x = x11.x,
                .y = x11.y,
                .width = x11.width,
                .height = x11.height,
            };
        },
    }

    self.frame = try .init(if (self.managed)
        if (self.floating) .title else .border
    else
        .hide, self.session.config.getColor(false, .border), self);

    self.popup_surface.node.raiseToTop();

    self.session.clients.append(self);
    self.session.focus_clients.append(self);

    if (self.managed) {
        geom = self.applyBounds(geom, true);
    }

    std.log.info("map client {*} surf {}", .{ self, self.surface });

    if (self.managed)
        try self.session.focusClient(self, true)
    else
        self.activateSurface(true);

    self.setFloatingSize(geom);
    self.setContainerSize(geom);
    self.setVisible(true);

    if (self.managed)
        try self.applyRules();

    self.setMonitor(self.session.focusedMonitor orelse
        self.session.monitors.first() orelse
        return error.fdsa);

    if (self.monitor) |m|
        m.dirty.layout = true;

    try self.cleanDirty();
}

pub fn applyRules(self: *Client) !void {
    self.setBorder(0);
    self.setFloating(true);
    self.setIcon("?");
    try self.session.config.applyRules(self);
}

pub fn getAppId(self: *Client) [:0]const u8 {
    switch (self.surface) {
        .XDG => |surface| return std.mem.span(surface.role_data.toplevel.?.app_id) orelse "No appid",
        .X11 => |surface| return std.mem.span(surface.class) orelse return "No appid",
    }
}

pub fn getTitle(self: *Client) [:0]const u8 {
    switch (self.surface) {
        .XDG => |surface| return std.mem.span(surface.role_data.toplevel.?.title) orelse "No title",
        .X11 => |surface| return std.mem.span(surface.title) orelse "No title",
    }
}

pub fn getLabel(self: *Client) [:0]const u8 {
    if (self.label) |label|
        return label;

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

    var setxy = false;
    switch (self.surface) {
        .X11 => |surface| {
            if (surface.size_hints) |hints| {
                // base size
                if (base) {
                    if (hints.flags & 0b100000000 != 0) {
                        result.width = hints.base_width + x_border;

                        result.height = hints.base_height + y_border;
                    }

                    // new position
                    if (hints.flags & 0b101 != 0) {
                        result.x = hints.x - x_start;

                        result.y = hints.y + y_start;

                        setxy = true;
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

    if (!setxy) {
        result.x = bounds.x + @divTrunc((bounds.width - result.width), 2);
        result.y = bounds.y + @divTrunc((bounds.height - result.height), 2);
    }

    return result;
}

pub fn raiseToTop(self: *Client) void {
    self.dirty.top = true;
}

pub fn setVisible(self: *Client, visible: bool) void {
    if (visible == self.visible)
        return;

    self.visible = visible;
    self.dirty.visible = true;
}

pub fn setFloatingSize(self: *Client, in_target_bounds: wlr.Box) void {
    self.floating_bounds = self.applyBounds(in_target_bounds, false);
    if (self.floating)
        self.dirty.size = true;
}

pub fn setContainerSize(self: *Client, in_target_bounds: wlr.Box) void {
    self.container_bounds = self.applyBounds(in_target_bounds, false);
    if (!self.floating)
        self.dirty.size = true;
}

pub inline fn setContainer(self: *Client, container: u8) void {
    if (self.container == container)
        return;

    self.container = container;

    self.dirty.container = true;

    std.log.info("set container: {}", .{self.container});

    if (!self.floating) {
        var iter = self.session.clients.iterator(.forward);
        while (iter.next()) |client| {
            if (self.sharesTabs(client))
                client.dirty.title = true;
        }

        if (self.monitor) |m|
            m.dirty.layout = true;
    }
}

pub inline fn setFrame(self: *Client, frame: FrameKind) void {
    if (self.frame.kind == frame)
        return;

    if (self.managed)
        self.frame.kind = frame
    else
        self.frame.kind = .hide;

    self.dirty.frame = true;
}

pub inline fn setBorder(self: *Client, border: i32) void {
    if (self.border == border)
        return;

    self.border = border;
    self.dirty.frame = true;
}

pub inline fn setIcon(self: *Client, icon: ?[:0]const u8) void {
    if (self.icon) |old_icon|
        allocator.free(old_icon);

    if (icon) |new_icon|
        self.icon = allocator.dupeZ(u8, new_icon) catch null
    else
        self.icon = null;

    self.dirty.title = true;
}

pub inline fn setLabel(self: *Client, label: ?[:0]const u8) void {
    if (self.label) |old_label|
        allocator.free(old_label);

    if (label) |new_label|
        self.label = allocator.dupeZ(u8, new_label) catch null
    else
        self.label = null;

    self.dirty.title = true;
}

pub inline fn setTag(self: *Client, tag: u8) void {
    if (self.tag == tag)
        return;

    self.tag = tag;

    if (self.monitor) |m|
        m.dirty.layout = true;
}

pub inline fn setFullscreen(self: *Client, fullscreen: bool) void {
    _ = self;
    _ = fullscreen;

    return;
}

pub inline fn setFloating(self: *Client, floating: bool) void {
    if (self.floating == floating)
        return;

    // cant unfloat a window im moving
    if (self.session.input.cursor_mode != .normal and
        self.session.input.cursor_mode != .pressed and
        self.floating == true)
        return;

    self.floating = floating;
    self.dirty.floating = true;

    if (self.monitor) |m|
        m.dirty.layout = true;

    if (!self.frame.is_init)
        return;

    if (self.floating)
        self.setFrame(.title);
}

pub fn updateSizeSerial(self: *Client) ?u32 {
    const bounds = self.getBounds();
    const inner_bounds = self.getInnerBounds();

    const inner: wlr.Box = .{
        .x = bounds.x + inner_bounds.x,
        .y = bounds.y + inner_bounds.y,
        .width = inner_bounds.width,
        .height = inner_bounds.height,
    };

    if (self.surface == .X11) {
        self.surface.X11.configure(
            @intCast(inner.x),
            @intCast(inner.y),
            @intCast(inner.width),
            @intCast(inner.height),
        );

        return null;
    }

    if (self.surface.XDG.role_data.toplevel == null) return null;

    if (inner.width == self.surface.XDG.role_data.toplevel.?.current.width and
        inner.height == self.surface.XDG.role_data.toplevel.?.current.height)
        return null;

    return self.surface.XDG.role_data.toplevel.?.setSize(inner.width, inner.height);
}

pub fn commit(self: *Client) !void {
    if (self.resize_serial != null and self.resize_serial.? <= self.surface.XDG.current.configure_serial)
        self.resize_serial = null;
}

pub fn configure(self: *Client, event: *wlr.XwaylandSurface.event.Configure) !void {
    if (self.monitor == null)
        return;

    if (self.floating or !self.managed)
        self.setFloatingSize(.{
            .x = event.x,
            .y = event.y,
            .width = event.width,
            .height = event.height,
        })
    else if (self.monitor) |m|
        m.dirty.layout = true;
}

pub fn activate(self: *Client) !void {
    if (self.surface != .X11)
        return;

    if (self.monitor) |monitor|
        monitor.sendFocus();

    self.surface.X11.activate(true);
}

pub fn unmap(self: *Client) !void {
    if (self == self.session.input.grab_client)
        _ = try self.session.input.endDrag();

    std.log.info("unmap {*}", .{self});

    if (self.monitor) |m| {
        m.dirty.tabs = true;
        m.dirty.layout = true;
    }

    try self.clearMonitor();

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
        if (self.getSurface() == self.session.input.seat.keyboard_state.focused_surface) unfocus: {
            if (self.session.focusedClient()) |top| {
                try self.session.focusClient(top, false);
                break :unfocus;
            }

            self.session.focusClear();
        }
    }

    self.link.remove();
    self.focus_link.remove();

    self.scene.node.destroy();

    self.setIcon(null);
    self.setLabel(null);
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
    self.dirty.frame = true;
    self.active = active;

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

pub fn setMonitor(self: *Client, target_monitor: *Monitor) void {
    const old_monitor = self.monitor;

    if (old_monitor == target_monitor)
        return;

    self.monitor = target_monitor;

    if (old_monitor) |old| {
        self.getSurface().sendLeave(old.output);

        old.dirty.layout = true;

        self.setFloatingSize(.{
            .x = self.floating_bounds.x - old.mode.x + target_monitor.mode.x,
            .y = self.floating_bounds.y - old.mode.y + target_monitor.mode.y,
            .width = self.floating_bounds.width,
            .height = self.floating_bounds.height,
        });
    } else {
        self.setFloatingSize(.{
            .x = self.floating_bounds.x + target_monitor.mode.x,
            .y = self.floating_bounds.y + target_monitor.mode.y,
            .width = self.floating_bounds.width,
            .height = self.floating_bounds.height,
        });
    }

    self.getSurface().sendEnter(target_monitor.output);

    self.setTag(target_monitor.tag);

    self.setFullscreen(self.fullscreen);

    target_monitor.dirty.layout = true;
}

pub fn clearMonitor(self: *Client) !void {
    const old_monitor = self.monitor;

    if (old_monitor == null)
        return;

    self.monitor = null;

    if (old_monitor) |old| {
        self.getSurface().sendLeave(old.output);

        old.dirty.layout = true;
    }

    try self.session.focusClient(self, true);
}
