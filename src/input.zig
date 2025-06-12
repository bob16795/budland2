const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");
const xkb = @import("xkbcommon");

const Session = @import("session.zig");
const Client = @import("client.zig");

const Input = @This();

// TODO: config
const REPEAT_RATE = 50;
const REPEAT_DELAY = 300;

const CursorMode = enum {
    normal,
    pressed,
    move,
    resize,
};

const InputEvents = struct {
    cursor_motion_event: wl.Listener(*wlr.Pointer.event.Motion) = .init(Listeners.cursor_motion),
    cursor_motion_absolute_event: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(Listeners.cursor_motion_absolute),
    cursor_button_event: wl.Listener(*wlr.Pointer.event.Button) = .init(Listeners.cursor_button),
    cursor_axis_event: wl.Listener(*wlr.Pointer.event.Axis) = .init(Listeners.cursor_axis),
    cursor_frame_event: wl.Listener(*wlr.Cursor) = .init(Listeners.cursor_frame),

    request_set_cursor_event: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(Listeners.request_set_cursor),

    new_input_event: wl.Listener(*wlr.InputDevice) = .init(Listeners.new_input),
};

const Keyboard = struct {
    input: *Input,

    keyboard: *wlr.Keyboard,
    key_repeat_source: *wl.EventSource = undefined,
    keysyms: []const xkb.Keysym = &.{},
    modifier_mask: wlr.Keyboard.ModifierMask = .{},

    key_event: wl.Listener(*wlr.Keyboard.event.Key) = .init(Listeners.keyboard.key),
    modifiers_event: wl.Listener(*wlr.Keyboard) = .init(Listeners.keyboard.modifiers),

    pub fn key(self: *Keyboard, key_data: *wlr.Keyboard.event.Key) !void {
        const wayland_data = self.input.session.wayland_data.?;

        const keycode = key_data.keycode + 8;

        const keysyms = self.keyboard.xkb_state.?.keyGetSyms(keycode);
        const modifier_mask = self.keyboard.getModifiers();

        wayland_data.idle_notifier.notifyActivity(self.input.seat);

        var handled = false;

        const config = self.input.session.config;

        if (!self.input.locked and
            // wayland_data.input_inhibit_mgr.active_inhibitor == null and
            key_data.state == .pressed)
        {
            for (keysyms) |sym| {
                handled = handled or false;
                if (@intFromEnum(sym) == xkb.Keysym.Escape and
                    modifier_mask.alt and modifier_mask.shift)
                {
                    self.input.session.quit();
                    handled = true;
                }

                for (config.binds.items) |bind| {
                    if (bind.mod == modifier_mask and bind.keysym == sym) {
                        config.apply(bind.operation) catch {};
                        handled = true;
                    }
                }
            }
        }

        if (handled and self.keyboard.repeat_info.delay > 0) {
            self.modifier_mask = modifier_mask;
            self.keysyms = keysyms;
            try self.key_repeat_source.timerUpdate(self.keyboard.repeat_info.delay);
        } else {
            try self.key_repeat_source.timerUpdate(0);
        }

        if (!handled) {
            self.input.seat.setKeyboard(self.keyboard);
            self.input.seat.keyboardNotifyKey(key_data.time_msec, key_data.keycode, key_data.state);
        }
    }

    pub fn modifiers(self: *Keyboard) !void {
        self.input.seat.setKeyboard(self.keyboard);
        self.input.seat.keyboardNotifyModifiers(&self.keyboard.modifiers);
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
    };
};

session: *Session,
cursor: *wlr.Cursor,
cursor_mode: CursorMode,
xcursor_image: [*:0]const u8 = "left_ptr",

relative_pointer_manager: *wlr.RelativePointerManagerV1,
xcursor_manager: *wlr.XcursorManager,
keyboards: std.ArrayList(*Keyboard),
seat: *wlr.Seat,
events: InputEvents,
locked: bool = false,

pub fn init(self: *Input, session: *Session) !void {
    const wayland_data = session.wayland_data.?;

    self.events = .{};

    const cursor = try wlr.Cursor.create();
    cursor.attachOutputLayout(wayland_data.output_layout);

    cursor.events.motion.add(&self.events.cursor_motion_event);
    cursor.events.motion_absolute.add(&self.events.cursor_motion_absolute_event);
    cursor.events.button.add(&self.events.cursor_button_event);
    cursor.events.axis.add(&self.events.cursor_axis_event);
    cursor.events.frame.add(&self.events.cursor_frame_event);

    const xcursor_manager = try wlr.XcursorManager.create(null, 24);

    wayland_data.backend.events.new_input.add(&self.events.new_input_event);

    // seat stuff
    const seat = try wlr.Seat.create(wayland_data.server, "seat0");
    seat.events.request_set_cursor.add(&self.events.request_set_cursor_event);

    std.log.warn("TODO: virtual keyboards", .{});

    const relative_pointer_manager = try wlr.RelativePointerManagerV1.create(wayland_data.server);

    self.* = .{
        .session = session,
        .cursor = cursor,
        .cursor_mode = .normal,
        .xcursor_manager = xcursor_manager,
        .keyboards = .init(session.config.allocator),
        .seat = seat,
        .events = self.events,
        .relative_pointer_manager = relative_pointer_manager,
    };
}

pub fn xwayland_ready(self: *Input, xwayland: *wlr.Xwayland) void {
    xwayland.setSeat(self.seat);

    if (self.xcursor_manager.getXcursor("left_ptr", 1)) |xcursor| {
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
    _ = self;
    _ = motion;

    std.log.warn("TODO: cursor motion", .{});
}

pub fn cursor_motion_absolute(self: *Input, motion: *wlr.Pointer.event.MotionAbsolute) !void {
    var layout_x: f64 = 0;
    var layout_y: f64 = 0;
    self.cursor.absoluteToLayoutCoords(motion.device, motion.x, motion.y, &layout_x, &layout_y);
    const dx = layout_x - self.cursor.x;
    const dy = layout_y - self.cursor.y;

    try self.motionNotify(@intCast(motion.time_msec), motion.device, dx, dy, dx, dy);
}

const MotionError = error{};

pub fn motionNotify(
    self: *Input,
    time: usize,
    device: ?*wlr.InputDevice,
    dx_accel: f64,
    dy_accel: f64,
    dx_unaccel: f64,
    dy_unaccel: f64,
) MotionError!void {
    const wayland_data = self.session.wayland_data.?;

    const dx = dx_accel;
    const dy = dy_accel;

    const objects = self.session.getObjectsAt(self.cursor.x, self.cursor.y);

    if (self.cursor_mode == .pressed and self.seat.drag == null) {
        std.log.warn("TODO: check if clicking window", .{});
    }

    if (time > 0) {
        self.relative_pointer_manager.sendRelativeMotion(self.seat, time * 1000, dx, dy, dx_unaccel, dy_unaccel);

        // TODO: constraints
        // var iter = self.pointer_constraints.iterator();

        self.cursor.move(device, dx, dy);

        wayland_data.idle_notifier.notifyActivity(self.seat);

        self.session.selmon = objects.monitor;
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
            // c.wlr_scene_node_set_position(@as(*c.wlr_scene_node, @ptrCast(@alignCast(icon.?.data))), @as(i32, @intFromFloat(cursor.x)) + icon.?.surface.*.sx, @as(i32, @intFromFloat(cursor.y)) + icon.?.surface.*.sy);
        }
    }

    // TODO surface null
    if (objects.surface == null and
        self.seat.drag == null and
        !std.mem.eql(u8, std.mem.span(self.xcursor_image), "left_ptr") and
        !std.mem.eql(u8, std.mem.span(self.xcursor_image), ""))
    {
        self.cursor.setXcursor(self.xcursor_manager, self.xcursor_image);
        // self.xcursor_image = "left_ptr";
        // const xcursor = self.xcursor_manager.getXcursor(self.xcursor_image, 1.0);
        // self.xcursor_manager.load(xcursor, );
        // c.wlr_xcursor_manager_set_cursor_image(cursor_mgr, cursor_image.?.ptr, cursor);
    }

    if (objects.client) |focusing|
        try self.pointerFocus(focusing, objects.surface.?, objects.surface_x, objects.surface_y, time);
}

pub fn pointerFocus(self: *Input, target_client: *Client, surface: *wlr.Surface, x: f64, y: f64, time: usize) !void {
    const internal_call = time == 0;
    var atime: usize = time;

    if (!internal_call and
        !(target_client.surface == .X11 and !target_client.managed))
        try self.session.focus(target_client, false);

    if (internal_call) {
        const now: std.posix.timespec = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch
            @panic("CLOCK_MONOTONIC not supported");

        atime = @bitCast(now.sec * 1000 + @divTrunc(now.nsec, 1000000));
    }

    self.seat.pointerNotifyEnter(surface, x, y);
    self.seat.pointerNotifyMotion(@intCast(atime), x, y);
}

pub fn cursor_button(self: *Input, button: *wlr.Pointer.event.Button) !void {
    const wayland_data = self.session.wayland_data.?;

    wayland_data.idle_notifier.notifyActivity(self.seat);

    switch (button.state) {
        .pressed => {
            const objects = self.session.getObjectsAt(self.cursor.x, self.cursor.y);

            if (objects.client) |target| {
                if (target.managed)
                    try self.session.focus(objects.client, true);
            }
        },
        else => {},
    }

    _ = self.seat.pointerNotifyButton(button.time_msec, button.button, button.state);
}

pub fn cursor_axis(self: *Input, axis: *wlr.Pointer.event.Axis) !void {
    _ = self;
    _ = axis;

    std.log.warn("TODO: cursor axis", .{});
}

pub fn cursor_frame(self: *Input) !void {
    self.seat.pointerNotifyFrame();
}

pub fn request_set_cursor(self: *Input, event: *wlr.Seat.event.RequestSetCursor) !void {
    if (self.cursor_mode != .normal and self.cursor_mode != .pressed)
        return;

    self.xcursor_image = "";
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
    if (keyboard.keysyms.len != 0 and keyboard.keyboard.repeat_info.rate > 0) {
        keyboard.key_repeat_source.timerUpdate(@divTrunc(1000, keyboard.keyboard.repeat_info.rate)) catch return 0;

        // for (keyboard.keysyms) |keysym|
        //     _ = keybinding(kb.mods, keysym);
    }

    return 0;
}

pub fn new_input(self: *Input, device: *wlr.InputDevice) !void {
    switch (device.type) {
        .keyboard => {
            const wayland_data = self.session.wayland_data.?;

            const wlr_keyboard = device.toKeyboard();

            const keyboard = try self.session.config.allocator.create(Keyboard);
            keyboard.* = .{ .input = self, .keyboard = wlr_keyboard };

            const context = xkb.Context.new(.no_flags) orelse return error.XkbInitFailed;
            defer context.unref();
            const keymap = xkb.Keymap.newFromNames(context, &xkb_rules, .no_flags) orelse return error.XkbInitFailed;
            defer keymap.unref();

            _ = keyboard.keyboard.setKeymap(keymap);

            keyboard.keyboard.setRepeatInfo(REPEAT_RATE, REPEAT_DELAY);

            keyboard.keyboard.events.key.add(&keyboard.key_event);
            keyboard.keyboard.events.modifiers.add(&keyboard.modifiers_event);

            self.seat.setKeyboard(keyboard.keyboard);

            keyboard.key_repeat_source = try wayland_data.server.getEventLoop().addTimer(*Keyboard, keyrepeat, keyboard);

            try self.keyboards.append(keyboard);
        },
        .pointer => {
            // const wlr_pointer = device.toPointer();
            // if (device.isLibInput()) {}
            std.log.warn("TODO: cursor lib input", .{});

            self.cursor.attachInputDevice(device);
        },
        else => |device_type| {
            std.log.warn("Unknown device type {}", .{device_type});
        },
    }

    var caps: wl.Seat.Capability = .{
        .pointer = true,
    };
    if (self.keyboards.items.len != 0)
        caps.keyboard = true;

    self.seat.setCapabilities(caps);
}
