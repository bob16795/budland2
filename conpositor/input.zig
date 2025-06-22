const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");
const xkb = @import("xkbcommon");
const cairo = @import("cairo");

const Session = @import("session.zig");
const Client = @import("client.zig");
const Config = @import("config.zig");

const Input = @This();

const allocator = Config.allocator;

// TODO: move to config
const REPEAT_RATE = 50;
const REPEAT_DELAY = 300;

const CursorMode = enum {
    normal,
    pressed,
    lua,
};

const InputEvents = struct {
    cursor_motion_event: wl.Listener(*wlr.Pointer.event.Motion) = .init(Listeners.cursor_motion),
    cursor_motion_absolute_event: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(Listeners.cursor_motion_absolute),
    cursor_button_event: wl.Listener(*wlr.Pointer.event.Button) = .init(Listeners.cursor_button),
    cursor_axis_event: wl.Listener(*wlr.Pointer.event.Axis) = .init(Listeners.cursor_axis),
    cursor_frame_event: wl.Listener(*wlr.Cursor) = .init(Listeners.cursor_frame),

    request_set_cursor_event: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(Listeners.request_set_cursor),
    set_cursor_shape_event: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) = .init(Listeners.set_cursor_shape),

    new_input_event: wl.Listener(*wlr.InputDevice) = .init(Listeners.new_input),
};

fn cleanMask(mask: wlr.Keyboard.ModifierMask) wlr.Keyboard.ModifierMask {
    var result = mask;
    result.caps = false;

    return mask;
}

const Keyboard = struct {
    session: *Session,

    keyboard: *wlr.Keyboard,
    key_repeat_source: *wl.EventSource = undefined,
    keysyms: []const xkb.Keysym = &.{},
    modifier_mask: wlr.Keyboard.ModifierMask = .{},
    link: wl.list.Link = undefined,

    key_event: wl.Listener(*wlr.Keyboard.event.Key) = .init(Listeners.keyboard.key),
    modifiers_event: wl.Listener(*wlr.Keyboard) = .init(Listeners.keyboard.modifiers),
    destroy_event: wl.Listener(*wlr.InputDevice) = .init(Listeners.keyboard.destroy),

    pub fn handleKey(session: *Session, xkb_state: *xkb.State, mods: wlr.Keyboard.ModifierMask, keycode: xkb.Keycode, comptime shifted: bool) !bool {
        const keymap = xkb_state.getKeymap();
        const layout_index = xkb_state.keyGetLayout(keycode);

        const level = xkb_state.keyGetLevel(
            keycode,
            layout_index,
        );

        const keysyms = if (shifted)
            keymap.keyGetSymsByLevel(
                keycode,
                layout_index,
                level,
            )
        else
            keymap.keyGetSymsByLevel(
                keycode,
                layout_index,
                0,
            );

        const consumed = xkb_state.keyGetConsumedMods2(keycode, .xkb);
        const modifier_mask: wlr.Keyboard.ModifierMask = if (shifted)
            @bitCast(@as(u32, @bitCast(mods)) & ~consumed)
        else
            mods;

        for (keysyms) |sym| {
            if (@import("builtin").mode == .Debug and
                @intFromEnum(sym) == xkb.Keysym.Escape and
                modifier_mask.alt and modifier_mask.shift)
            {
                session.quit();
                return true;
            }

            if (try session.config.keyBind(.{ .mods = cleanMask(modifier_mask), .key = sym }))
                return true;
        }

        return false;
    }

    pub fn key(self: *Keyboard, key_data: *wlr.Keyboard.event.Key) !void {
        const keycode = key_data.keycode + 8;

        const modifier_mask = self.keyboard.getModifiers();

        self.session.idle_notifier.notifyActivity(self.session.input.seat);

        const skip = (self.session.input.locked or key_data.state != .pressed);

        const handled = if (skip)
            false
        else
            (try handleKey(self.session, self.keyboard.xkb_state.?, modifier_mask, keycode, false) or
                try handleKey(self.session, self.keyboard.xkb_state.?, modifier_mask, keycode, true));

        const keysyms = self.keyboard.xkb_state.?.keyGetSyms(keycode);
        if (handled and self.keyboard.repeat_info.delay > 0) {
            self.modifier_mask = modifier_mask;
            self.keysyms = keysyms;
            try self.key_repeat_source.timerUpdate(self.keyboard.repeat_info.delay);
        } else {
            self.keysyms = &.{};
            try self.key_repeat_source.timerUpdate(0);
        }

        if (handled)
            return;

        self.session.input.seat.setKeyboard(self.keyboard);
        self.session.input.seat.keyboardNotifyKey(key_data.time_msec, key_data.keycode, key_data.state);
    }

    pub fn modifiers(self: *Keyboard) !void {
        self.session.input.seat.setKeyboard(self.keyboard);
        self.session.input.seat.keyboardNotifyModifiers(&self.keyboard.modifiers);
    }

    pub fn deinit(self: *Keyboard) !void {
        self.key_repeat_source.remove();
        self.link.remove();
        self.key_event.link.remove();
        self.modifiers_event.link.remove();
        self.destroy_event.link.remove();

        allocator.destroy(self);
    }
};

const Listeners = struct {
    pub fn cursor_motion(listener: *wl.Listener(*wlr.Pointer.event.Motion), motion: *wlr.Pointer.event.Motion) void {
        const events: *InputEvents = @fieldParentPtr("cursor_motion_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.cursor_motion(motion) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn cursor_motion_absolute(listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), motion: *wlr.Pointer.event.MotionAbsolute) void {
        const events: *InputEvents = @fieldParentPtr("cursor_motion_absolute_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.cursor_motion_absolute(motion) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn cursor_button(listener: *wl.Listener(*wlr.Pointer.event.Button), button: *wlr.Pointer.event.Button) void {
        const events: *InputEvents = @fieldParentPtr("cursor_button_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.cursor_button(button) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn cursor_axis(listener: *wl.Listener(*wlr.Pointer.event.Axis), axis: *wlr.Pointer.event.Axis) void {
        const events: *InputEvents = @fieldParentPtr("cursor_axis_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.cursor_axis(axis) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn cursor_frame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const events: *InputEvents = @fieldParentPtr("cursor_frame_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.cursor_frame() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn new_input(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const events: *InputEvents = @fieldParentPtr("new_input_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.new_input(device) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn set_cursor_shape(listener: *wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape), event: *wlr.CursorShapeManagerV1.event.RequestSetShape) void {
        const events: *InputEvents = @fieldParentPtr("set_cursor_shape_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.set_cursor_shape(event) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub fn request_set_cursor(listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor), event: *wlr.Seat.event.RequestSetCursor) void {
        const events: *InputEvents = @fieldParentPtr("request_set_cursor_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.request_set_cursor(event) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    pub const keyboard = struct {
        pub fn key(listener: *wl.Listener(*wlr.Keyboard.event.Key), key_data: *wlr.Keyboard.event.Key) void {
            const self: *Keyboard = @fieldParentPtr("key_event", listener);

            self.key(key_data) catch |ex| {
                @panic(@errorName(ex));
            };
        }

        pub fn modifiers(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
            const self: *Keyboard = @fieldParentPtr("modifiers_event", listener);

            self.modifiers() catch |ex| {
                @panic(@errorName(ex));
            };
        }

        pub fn destroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
            const self: *Keyboard = @fieldParentPtr("destroy_event", listener);

            self.deinit() catch |ex| {
                @panic(@errorName(ex));
            };
        }
    };
};

session: *Session,
cursor: *wlr.Cursor,
cursor_mode: CursorMode,
xcursor_image: ?[*:0]const u8 = null,

//relative_pointer_manager: *wlr.RelativePointerManagerV1,
cursor_shape_manager: *wlr.CursorShapeManagerV1,
xcursor_manager: *wlr.XcursorManager,
seat: *wlr.Seat,
events: InputEvents,

keyboards: wl.list.Head(Keyboard, .link) = undefined,
locked: bool = false,

grab_client: ?*Client = null,
grab_x: i32 = 0,
grab_y: i32 = 0,

pub fn init(self: *Input, session: *Session) !void {
    self.events = .{};

    const cursor = try wlr.Cursor.create();
    cursor.attachOutputLayout(session.output_layout);

    cursor.events.motion.add(&self.events.cursor_motion_event);
    cursor.events.motion_absolute.add(&self.events.cursor_motion_absolute_event);
    cursor.events.button.add(&self.events.cursor_button_event);
    cursor.events.axis.add(&self.events.cursor_axis_event);
    cursor.events.frame.add(&self.events.cursor_frame_event);

    const xcursor_manager = try wlr.XcursorManager.create(null, 24);
    session.backend.events.new_input.add(&self.events.new_input_event);

    const cursor_shape_manager = try wlr.CursorShapeManagerV1.create(session.server, 1);
    cursor_shape_manager.events.request_set_shape.add(&self.events.set_cursor_shape_event);

    const seat = try wlr.Seat.create(session.server, "seat0");
    seat.events.request_set_cursor.add(&self.events.request_set_cursor_event);

    std.log.warn("TODO: virtual keyboards", .{});

    self.* = .{
        .session = session,
        .cursor = cursor,
        .cursor_mode = .normal,
        .xcursor_manager = xcursor_manager,
        .seat = seat,
        .events = self.events,
        .cursor_shape_manager = cursor_shape_manager,
    };

    self.keyboards.init();
}

pub fn xwayland_ready(self: *Input, xwayland: *wlr.Xwayland) void {
    xwayland.setSeat(self.seat);

    self.xcursor_image = "default";
    if (self.xcursor_manager.getXcursor("default", 1)) |xcursor| {
        xwayland.setCursor(
            xcursor.images[0].buffer,
            xcursor.images[0].width * 4,
            xcursor.images[0].width,
            xcursor.images[0].height,
            @as(i32, @intCast(xcursor.*.images[0].*.hotspot_x)),
            @as(i32, @intCast(xcursor.*.images[0].*.hotspot_y)),
        );
    }
}

pub fn cursor_motion(self: *Input, motion: *wlr.Pointer.event.Motion) !void {
    self.cursor.move(motion.device, motion.delta_x, motion.delta_y);
    try self.motionNotify(motion.time_msec);
}

pub fn cursor_motion_absolute(self: *Input, motion: *wlr.Pointer.event.MotionAbsolute) !void {
    self.cursor.warpAbsolute(motion.device, motion.x, motion.y);

    try self.motionNotify(@intCast(motion.time_msec));
}

const MotionError = error{
    TODO,
} || Config.ConfigError || cairo.Error;

pub fn motionNotify(
    self: *Input,
    time: usize,
) MotionError!void {
    const objects = self.session.getObjectsAt(self.cursor.x, self.cursor.y);

    if (self.cursor_mode == .pressed and self.seat.drag == null) {
        std.log.warn("TODO: check if clicking window", .{});
    }

    if (time > 0) {
        //self.relative_pointer_manager.sendRelativeMotion(self.seat, time * 1000, dx, dy, dx_unaccel, dy_unaccel);

        // TODO: constraints

        self.session.idle_notifier.notifyActivity(self.seat);

        if (objects.monitor) |monitor|
            try self.session.focusMonitor(monitor);
    }

    if (self.seat.drag) |drag| {
        if (drag.icon) |icon| {
            const cursor_x: i32 = @intFromFloat(self.cursor.x);
            const cursor_y: i32 = @intFromFloat(self.cursor.y);

            const scene_node: *wlr.SceneNode = @ptrFromInt(icon.data);

            scene_node.setPosition(
                icon.surface.current.dx + cursor_x,
                icon.surface.current.dy + cursor_y,
            );
        }
    }

    const data: Config.LuaVec = .{
        .x = self.cursor.x,
        .y = self.cursor.y,
    };

    if (try self.session.config.sendEvent(Config.LuaVec, .mouse_move, data))
        return;

    if (objects.surface == null and
        self.seat.drag == null and
        self.xcursor_image != null and
        !std.mem.eql(u8, std.mem.span(self.xcursor_image.?), "left_ptr"))
    {
        self.cursor.setXcursor(self.xcursor_manager, self.xcursor_image.?);
    }

    if (objects.client) |focusing|
        try self.pointerFocus(focusing, focusing.getSurface(), objects.surface_x, objects.surface_y, time);
}

pub fn pointerFocus(self: *Input, target_client: *Client, surface: *wlr.Surface, x: f64, y: f64, time: usize) !void {
    const internal_call = time == 0;
    var atime: usize = time;

    if (!internal_call and
        !(target_client.surface == .X11 and !target_client.managed))
        try self.session.focusClient(target_client, false);

    if (internal_call) {
        const now: std.posix.timespec = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch
            @panic("CLOCK_MONOTONIC not supported");

        atime = @bitCast(now.sec * 1000 + @divTrunc(now.nsec, 1000000));
    }

    self.seat.pointerNotifyEnter(surface, x, y);
    self.seat.pointerNotifyMotion(@intCast(atime), x, y);
}

pub fn cursor_button(self: *Input, button: *wlr.Pointer.event.Button) !void {
    self.session.idle_notifier.notifyActivity(self.seat);

    switch (button.state) {
        .pressed => handle_press: {
            self.cursor_mode = .pressed;
            if (self.locked)
                break :handle_press;

            const objects = self.session.getObjectsAt(self.cursor.x, self.cursor.y);

            if (objects.client) |target| {
                if (target.managed)
                    try self.session.focusClient(target, true);

                const keyboard = self.seat.getKeyboard();
                const mods = if (keyboard) |keyb| keyb.getModifiers() else wlr.Keyboard.ModifierMask{};
                if (try self.session.config.mouseBind(.{ .mods = mods, .button = button.button }, .{ .x = self.cursor.x, .y = self.cursor.y }, objects.client)) {
                    self.cursor_mode = .lua;
                    self.grab_client = target;
                    return;
                }
            }
        },
        .released => {
            if (try self.endDrag()) return;
        },
        else => {},
    }

    _ = self.seat.pointerNotifyButton(button.time_msec, button.button, button.state);
}

pub fn endDrag(self: *Input) !bool {
    if (self.cursor_mode == .lua and try self.session.config.sendEvent(i32, .mouse_release, 0)) {
        self.cursor_mode = .normal;

        if (self.xcursor_image) |xcursor_image|
            self.cursor.setXcursor(self.xcursor_manager, xcursor_image);

        self.seat.pointerClearFocus();
        try self.motionNotify(0);

        self.grab_client = null;

        return true;
    } else self.cursor_mode = .normal;

    return false;
}

pub fn cursor_axis(self: *Input, axis: *wlr.Pointer.event.Axis) !void {
    self.session.idle_notifier.notifyActivity(self.seat);

    self.seat.pointerNotifyAxis(axis.time_msec, axis.orientation, axis.delta, axis.delta_discrete, axis.source, axis.relative_direction);
}

pub fn cursor_frame(self: *Input) !void {
    self.seat.pointerNotifyFrame();
}

pub fn set_cursor_shape(self: *Input, event: *wlr.CursorShapeManagerV1.event.RequestSetShape) !void {
    if (self.cursor_mode != .normal and self.cursor_mode != .pressed)
        return;

    if (event.seat_client == self.seat.pointer_state.focused_client) {
        self.xcursor_image = @tagName(event.shape);
        self.cursor.setXcursor(self.xcursor_manager, @tagName(event.shape));
    }
}

pub fn request_set_cursor(self: *Input, event: *wlr.Seat.event.RequestSetCursor) !void {
    if (self.cursor_mode != .normal and self.cursor_mode != .pressed)
        return;

    self.xcursor_image = null;
    if (event.seat_client == self.seat.pointer_state.focused_client) {
        self.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }
}

const xkb_rules: xkb.RuleNames = .{
    .options = null,
    .rules = null,
    .model = null,
    .layout = null,
    .variant = null,
};

pub fn keyrepeat(keyboard: *Keyboard) c_int {
    if (keyboard.keysyms.len == 0 or keyboard.keyboard.repeat_info.rate <= 0)
        return 0;

    keyboard.key_repeat_source.timerUpdate(@divTrunc(1000, keyboard.keyboard.repeat_info.rate)) catch return 0;

    return 0;
}

pub fn new_input(self: *Input, device: *wlr.InputDevice) !void {
    switch (device.type) {
        .keyboard => {
            const wlr_keyboard = device.toKeyboard();

            const keyboard = try allocator.create(Keyboard);
            keyboard.* = .{ .session = self.session, .keyboard = wlr_keyboard };

            const context = xkb.Context.new(.no_flags) orelse return error.XkbInitFailed;
            defer context.unref();

            const keymap = xkb.Keymap.newFromNames(context, &xkb_rules, .no_flags) orelse return error.XkbInitFailed;
            defer keymap.unref();

            _ = keyboard.keyboard.setKeymap(keymap);

            keyboard.keyboard.setRepeatInfo(REPEAT_RATE, REPEAT_DELAY);

            keyboard.keyboard.events.key.add(&keyboard.key_event);
            keyboard.keyboard.events.modifiers.add(&keyboard.modifiers_event);
            keyboard.keyboard.base.events.destroy.add(&keyboard.destroy_event);

            self.seat.setKeyboard(keyboard.keyboard);

            keyboard.key_repeat_source = try self.session.server.getEventLoop().addTimer(*Keyboard, keyrepeat, keyboard);

            self.keyboards.append(keyboard);
        },
        .pointer => {
            // std.log.warn("TODO: libinput", .{});

            self.cursor.attachInputDevice(device);
        },
        else => |device_type| {
            std.log.warn("Unknown device type {}", .{device_type});
        },
    }

    var caps: wl.Seat.Capability = .{
        .pointer = true,
    };
    if (!self.keyboards.empty())
        caps.keyboard = true;

    self.seat.setCapabilities(caps);
}
