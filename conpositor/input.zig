const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const std = @import("std");
const xkb = @import("xkbcommon");
const cairo = @import("cairo");
const c = @import("c.zig");

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

const MotionError = error{
    TODO,
} || Config.ConfigError || cairo.Error;

const xkb_rules: xkb.RuleNames = .{
    .options = null,
    .rules = null,
    .model = null,
    .layout = null,
    .variant = null,
};

const Events = struct {
    cursor_motion_event: wl.Listener(*wlr.Pointer.event.Motion) = .init(Events.cursorMotion),
    cursor_motion_absolute_event: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(Events.cursorMotionAbsolute),
    cursor_button_event: wl.Listener(*wlr.Pointer.event.Button) = .init(Events.cursorButton),
    cursor_axis_event: wl.Listener(*wlr.Pointer.event.Axis) = .init(Events.cursorAxis),
    cursor_frame_event: wl.Listener(*wlr.Cursor) = .init(Events.cursorFrame),

    request_set_cursor_event: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(Events.requestSetCursor),
    set_cursor_shape_event: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) = .init(Events.setCursorShape),
    request_set_primary_selection: wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection) = .init(Events.setPrimarySelection),
    request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(Events.setSelection),

    new_input_event: wl.Listener(*wlr.InputDevice) = .init(Events.newInput),

    fn cursorMotion(listener: *wl.Listener(*wlr.Pointer.event.Motion), motion: *wlr.Pointer.event.Motion) void {
        const events: *Events = @fieldParentPtr("cursor_motion_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.cursorMotion(motion) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    fn cursorMotionAbsolute(listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), motion: *wlr.Pointer.event.MotionAbsolute) void {
        const events: *Events = @fieldParentPtr("cursor_motion_absolute_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.cursorMotionAbsolute(motion) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    fn cursorButton(listener: *wl.Listener(*wlr.Pointer.event.Button), button: *wlr.Pointer.event.Button) void {
        const events: *Events = @fieldParentPtr("cursor_button_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.cursorButton(button) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    fn cursorAxis(listener: *wl.Listener(*wlr.Pointer.event.Axis), axis: *wlr.Pointer.event.Axis) void {
        const events: *Events = @fieldParentPtr("cursor_axis_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.cursorAxis(axis) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const events: *Events = @fieldParentPtr("cursor_frame_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.cursorFrame() catch |ex| {
            @panic(@errorName(ex));
        };
    }

    fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const events: *Events = @fieldParentPtr("new_input_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.newInput(device) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    fn setCursorShape(listener: *wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape), event: *wlr.CursorShapeManagerV1.event.RequestSetShape) void {
        const events: *Events = @fieldParentPtr("set_cursor_shape_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.setCursorShape(event) catch |ex| {
            @panic(@errorName(ex));
        };
    }

    fn setSelection(listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection), event: *wlr.Seat.event.RequestSetSelection) void {
        const events: *Events = @fieldParentPtr("request_set_selection", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.seat.setSelection(event.source, event.serial);
    }

    fn setPrimarySelection(listener: *wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection), event: *wlr.Seat.event.RequestSetPrimarySelection) void {
        const events: *Events = @fieldParentPtr("request_set_primary_selection", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.seat.setPrimarySelection(event.source, event.serial);
    }

    fn requestSetCursor(listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor), event: *wlr.Seat.event.RequestSetCursor) void {
        const events: *Events = @fieldParentPtr("request_set_cursor_event", listener);
        const self: *Input = @fieldParentPtr("events", events);

        self.requestSetCursor(event) catch |ex| {
            @panic(@errorName(ex));
        };
    }
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
    events: Keyboard.Events = .{},
    link: wl.list.Link = undefined,

    const Events = struct {
        key_event: wl.Listener(*wlr.Keyboard.event.Key) = .init(Keyboard.Events.key),
        modifiers_event: wl.Listener(*wlr.Keyboard) = .init(Keyboard.Events.modifiers),
        destroy_event: wl.Listener(*wlr.InputDevice) = .init(Keyboard.Events.destroy),

        fn key(listener: *wl.Listener(*wlr.Keyboard.event.Key), key_data: *wlr.Keyboard.event.Key) void {
            const events: *Keyboard.Events = @fieldParentPtr("key_event", listener);
            const self: *Keyboard = @fieldParentPtr("events", events);

            self.key(key_data) catch |ex| {
                @panic(@errorName(ex));
            };
        }

        fn modifiers(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
            const events: *Keyboard.Events = @fieldParentPtr("modifiers_event", listener);
            const self: *Keyboard = @fieldParentPtr("events", events);

            self.modifiers() catch |ex| {
                @panic(@errorName(ex));
            };
        }

        fn destroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
            const events: *Keyboard.Events = @fieldParentPtr("destroy_event", listener);
            const self: *Keyboard = @fieldParentPtr("events", events);

            self.deinit() catch |ex| {
                @panic(@errorName(ex));
            };
        }
    };

    pub fn init(input: *Input, device: *wlr.InputDevice) !*Keyboard {
        const wlr_keyboard = device.toKeyboard();

        const keyboard = try allocator.create(Keyboard);
        errdefer allocator.destroy(keyboard);

        keyboard.* = .{ .session = input.session, .keyboard = wlr_keyboard };

        const context = xkb.Context.new(.no_flags) orelse return error.XkbInitFailed;
        defer context.unref();

        const keymap = xkb.Keymap.newFromNames(context, &xkb_rules, .no_flags) orelse return error.XkbInitFailed;
        defer keymap.unref();

        _ = keyboard.keyboard.setKeymap(keymap);

        keyboard.keyboard.setRepeatInfo(REPEAT_RATE, REPEAT_DELAY);

        keyboard.keyboard.events.key.add(&keyboard.events.key_event);
        keyboard.keyboard.events.modifiers.add(&keyboard.events.modifiers_event);
        keyboard.keyboard.base.events.destroy.add(&keyboard.events.destroy_event);

        input.seat.setKeyboard(keyboard.keyboard);

        keyboard.key_repeat_source = try input.session.server.getEventLoop().addTimer(*Keyboard, keyRepeat, keyboard);

        return keyboard;
    }

    fn handleKey(session: *Session, xkb_state: *xkb.State, mods: wlr.Keyboard.ModifierMask, keycode: xkb.Keycode, comptime shifted: bool) !bool {
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

    fn key(self: *Keyboard, key_data: *wlr.Keyboard.event.Key) !void {
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

    fn modifiers(self: *Keyboard) !void {
        self.session.input.seat.setKeyboard(self.keyboard);
        self.session.input.seat.keyboardNotifyModifiers(&self.keyboard.modifiers);
    }

    fn deinit(self: *Keyboard) !void {
        self.key_repeat_source.remove();
        self.link.remove();

        self.events.key_event.link.remove();
        self.events.modifiers_event.link.remove();
        self.events.destroy_event.link.remove();

        allocator.destroy(self);
    }
};

session: *Session,
cursor: *wlr.Cursor,
cursor_mode: CursorMode,
xcursor_image: ?[*:0]const u8 = null,

//relative_pointer_manager: *wlr.RelativePointerManagerV1,
cursor_shape_manager: *wlr.CursorShapeManagerV1,
xcursor_manager: *wlr.XcursorManager,
seat: *wlr.Seat,
events: Events,

keyboards: wl.list.Head(Keyboard, .link) = undefined,
locked: bool = false,

grab_client: ?*Client = null,

pub fn init(self: *Input, session: *Session) !void {
    self.events = .{};

    const cursor = try wlr.Cursor.create();
    cursor.attachOutputLayout(session.output_layout);

    cursor.events.motion.add(&self.events.cursor_motion_event);
    cursor.events.motion_absolute.add(&self.events.cursor_motion_absolute_event);
    cursor.events.button.add(&self.events.cursor_button_event);
    cursor.events.axis.add(&self.events.cursor_axis_event);
    cursor.events.frame.add(&self.events.cursor_frame_event);

    const cursor_shape_manager = try wlr.CursorShapeManagerV1.create(session.server, 1);
    cursor_shape_manager.events.request_set_shape.add(&self.events.set_cursor_shape_event);

    const xcursor_manager = try wlr.XcursorManager.create(null, 24);
    session.backend.events.new_input.add(&self.events.new_input_event);

    const seat = try wlr.Seat.create(session.server, "seat0");
    seat.events.request_set_cursor.add(&self.events.request_set_cursor_event);
    seat.events.request_set_primary_selection.add(&self.events.request_set_primary_selection);
    seat.events.request_set_selection.add(&self.events.request_set_selection);

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

pub fn xwaylandReady(self: *Input, xwayland: *wlr.Xwayland) void {
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

pub fn motionNotify(
    self: *Input,
    time: usize,
) MotionError!void {
    const objects = self.session.getObjectsAt(self.cursor.x, self.cursor.y);

    if (self.cursor_mode == .pressed and self.seat.drag == null) {
        std.log.warn("TODO: check if clicking window", .{});
    }

    if (time > 0) {
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

    if (self.cursor_mode == .lua and try self.session.config.sendEvent(Config.LuaVec, .mouse_move, data))
        return;

    if (objects.surface == null and
        self.seat.drag == null and
        self.xcursor_image != null and
        !std.mem.eql(u8, std.mem.span(self.xcursor_image.?), "left_ptr"))
    {
        self.cursor.setXcursor(self.xcursor_manager, self.xcursor_image.?);
    }

    try self.pointerFocus(objects.client, objects.surface, time);
}

pub fn endDrag(self: *Input) !bool {
    if (self.cursor_mode == .lua and try self.session.config.sendEvent(i32, .mouse_release, 0)) {
        self.cursor_mode = .normal;

        if (self.xcursor_image) |xcursor_image|
            self.cursor.setXcursor(self.xcursor_manager, xcursor_image);

        try self.motionNotify(0);

        self.grab_client = null;

        return true;
    }

    self.cursor_mode = .normal;

    return false;
}

fn cursorMotion(self: *Input, motion: *wlr.Pointer.event.Motion) !void {
    self.cursor.move(motion.device, motion.delta_x, motion.delta_y);
    try self.motionNotify(motion.time_msec);
}

fn cursorMotionAbsolute(self: *Input, motion: *wlr.Pointer.event.MotionAbsolute) !void {
    self.cursor.warpAbsolute(motion.device, motion.x, motion.y);

    try self.motionNotify(@intCast(motion.time_msec));
}

fn pointerFocus(self: *Input, target_client: ?*Client, surface: ?*wlr.Surface, time: usize) !void {
    const internal_call = time == 0;
    var atime: usize = time;

    if (!internal_call and
        target_client != null and
        !(target_client.?.surface == .X11 and !target_client.?.managed))
        try self.session.focusClient(target_client.?, false);

    if (surface == null) {
        self.seat.pointerNotifyClearFocus();
        return;
    }

    if (internal_call) {
        const now: std.posix.timespec = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch
            @panic("CLOCK_MONOTONIC not supported");

        atime = @bitCast(now.sec * 1000 + @divTrunc(now.nsec, 1000000));
    }

    if (target_client) |client| {
        const bounds = client.getBounds();
        const inner_bounds = client.getInnerBounds();

        const x = self.cursor.x -
            @as(f64, @floatFromInt(inner_bounds.x)) -
            @as(f64, @floatFromInt(bounds.x));
        const y = self.cursor.y -
            @as(f64, @floatFromInt(inner_bounds.y)) -
            @as(f64, @floatFromInt(bounds.y));

        self.seat.pointerNotifyEnter(surface.?, x, y);
        self.seat.pointerNotifyMotion(@intCast(atime), x, y);
    }
}

fn cursorButton(self: *Input, button: *wlr.Pointer.event.Button) !void {
    self.session.idle_notifier.notifyActivity(self.seat);

    switch (button.state) {
        .pressed => handle_press: {
            self.cursor_mode = .pressed;
            if (self.locked)
                break :handle_press;

            const objects = self.session.getObjectsAt(self.cursor.x, self.cursor.y);

            if (objects.client) |target| {
                if (!target.managed)
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

fn cursorAxis(self: *Input, axis: *wlr.Pointer.event.Axis) !void {
    self.session.idle_notifier.notifyActivity(self.seat);
    self.seat.pointerNotifyAxis(axis.time_msec, axis.orientation, axis.delta, axis.delta_discrete, axis.source, axis.relative_direction);
}

fn cursorFrame(self: *Input) !void {
    self.seat.pointerNotifyFrame();
}

fn setCursorShape(self: *Input, event: *wlr.CursorShapeManagerV1.event.RequestSetShape) !void {
    if (self.cursor_mode != .normal and self.cursor_mode != .pressed)
        return;

    if (event.seat_client == self.seat.pointer_state.focused_client) {
        self.xcursor_image = @tagName(event.shape);
        self.cursor.setXcursor(self.xcursor_manager, @tagName(event.shape));
    }
}

fn requestSetCursor(self: *Input, event: *wlr.Seat.event.RequestSetCursor) !void {
    if (self.cursor_mode != .normal and self.cursor_mode != .pressed)
        return;

    self.xcursor_image = null;
    if (event.seat_client == self.seat.pointer_state.focused_client) {
        self.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }
}

fn keyRepeat(keyboard: *Keyboard) c_int {
    if (keyboard.keysyms.len == 0 or keyboard.keyboard.repeat_info.rate <= 0)
        return 0;

    keyboard.key_repeat_source.timerUpdate(@divTrunc(1000, keyboard.keyboard.repeat_info.rate)) catch return 0;

    return 0;
}

fn newInput(self: *Input, device: *wlr.InputDevice) !void {
    switch (device.type) {
        .keyboard => {
            self.keyboards.append(try .init(self, device));
        },
        .pointer => {
            if (device.isLibinput()) {
                const libinput_device: *c.struct_libinput_device = @ptrCast(device.getLibinputDevice());
                if (c.libinput_device_config_tap_get_finger_count(libinput_device) != 0) {
                    _ = c.libinput_device_config_tap_set_enabled(libinput_device, 1);
                    _ = c.libinput_device_config_tap_set_drag_enabled(libinput_device, 1);
                    _ = c.libinput_device_config_tap_set_drag_lock_enabled(libinput_device, 1);
                    _ = c.libinput_device_config_tap_set_button_map(libinput_device, c.LIBINPUT_CONFIG_TAP_MAP_LRM);
                }

                if (c.libinput_device_config_scroll_has_natural_scroll(libinput_device) != 0)
                    _ = c.libinput_device_config_scroll_set_natural_scroll_enabled(libinput_device, 0);

                if (c.libinput_device_config_dwt_is_available(libinput_device) != 0)
                    _ = c.libinput_device_config_dwt_set_enabled(libinput_device, 0);

                if (c.libinput_device_config_left_handed_is_available(libinput_device) != 0)
                    _ = c.libinput_device_config_left_handed_set(libinput_device, 0);

                if (c.libinput_device_config_middle_emulation_is_available(libinput_device) != 0)
                    _ = c.libinput_device_config_middle_emulation_set_enabled(libinput_device, 1);

                if (c.libinput_device_config_scroll_get_methods(libinput_device) != c.LIBINPUT_CONFIG_SCROLL_NO_SCROLL)
                    _ = c.libinput_device_config_scroll_set_method(libinput_device, c.LIBINPUT_CONFIG_SCROLL_2FG);

                if (c.libinput_device_config_click_get_methods(libinput_device) != c.LIBINPUT_CONFIG_CLICK_METHOD_NONE)
                    _ = c.libinput_device_config_click_set_method(libinput_device, c.LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER);

                if (c.libinput_device_config_send_events_get_modes(libinput_device) != 0)
                    _ = c.libinput_device_config_send_events_set_mode(libinput_device, c.LIBINPUT_CONFIG_SEND_EVENTS_ENABLED);

                if (c.libinput_device_config_accel_is_available(libinput_device) != 0) {
                    _ = c.libinput_device_config_accel_set_profile(libinput_device, c.LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE);
                    _ = c.libinput_device_config_accel_set_speed(libinput_device, 0.5);
                }
            }

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
