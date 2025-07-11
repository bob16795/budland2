const std = @import("std");
const zlua = @import("zlua");
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const c = @import("c.zig");

const Layout = @import("layout.zig");
const Session = @import("session.zig");
const Client = @import("client.zig");
const Monitor = @import("monitor.zig");

const Config = @This();

const Lua = zlua.Lua;

pub const ConfigError = error{
    Unimplemented,
    OutOfMemory,
    LuaSyntax,
    LuaFile,
    LuaRuntime,
    LuaMsgHandler,
    LuaError,
};

pub const allocator_data = if (@import("builtin").mode == .Debug) struct {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
        .stack_trace_frames = 15,
    }) = .{};
    pub const allocator = gpa.allocator();

    pub fn deinit() void {
        if (gpa.deinit() == .ok)
            std.log.debug("no leaks! :)", .{});
    }
} else struct {
    pub const allocator = std.heap.c_allocator;

    pub fn deinit() void {}
};

pub const allocator = allocator_data.allocator;

const PaletteColor = enum { border, background, foreground };
const Event = enum {
    startup,
    add_monitor,
    mouse_move,
    mouse_release,
};

const FontInfo = struct {
    face: [:0]const u8,
    size: i32 = 12,

    pub fn deinit(self: *FontInfo) void {
        allocator.free(self.face);
    }
};

const MouseBindData = struct {
    mods: wlr.Keyboard.ModifierMask,
    button: u32,
};

const BindData = struct {
    mods: wlr.Keyboard.ModifierMask,
    key: xkb.Keysym,
};

font: FontInfo,
title_pad: i32 = 3,
active_colors: std.EnumArray(PaletteColor, [4]f32) = .initFill(.{ 1, 1, 1, 1 }),
inactive_colors: std.EnumArray(PaletteColor, [4]f32) = .initFill(.{ 1, 1, 1, 1 }),
layouts: std.ArrayList(*Layout) = .init(allocator),
tags: std.ArrayList([:0]const u8) = .init(allocator),
binds: std.AutoHashMap(BindData, LuaClosure) = .init(allocator),
mouse_binds: std.AutoHashMap(MouseBindData, LuaClosure) = .init(allocator),

// TODO: better structure?
rules: std.ArrayList(struct { filter: LuaFilter, calls: LuaClosure }) = .init(allocator),

// TODO: Hash Map
events: std.ArrayList(struct { event: Event, calls: LuaClosure }) = .init(allocator),
lua: *Lua = undefined,

const LuaFilter = struct {
    title: ?[]const u8,
    appid: ?[]const u8,

    const LuaMethods = struct {};

    pub fn matches(self: *const LuaFilter, title: []const u8, appid: []const u8) bool {
        if (self.title) |trg_title|
            if (!std.mem.eql(u8, trg_title, title))
                return false;

        if (self.appid) |trg_appid|
            if (!std.mem.eql(u8, trg_appid, appid))
                return false;

        return true;
    }

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaFilter {
        _ = lua.getField(index, "title");
        const lua_title = lua.toAny(?[]const u8, -1) catch null;
        const title = if (lua_title) |new_title| try allocator.dupe(u8, new_title) else null;
        lua.pop(1);

        _ = lua.getField(index, "appid");
        const lua_appid = lua.toAny(?[]const u8, -1) catch null;
        const appid = if (lua_appid) |new_appid| try allocator.dupe(u8, new_appid) else null;
        lua.pop(1);

        return .{
            .title = title,
            .appid = appid,
        };
    }

    pub fn deinit(self: *const LuaFilter) void {
        if (self.title) |title|
            allocator.free(title);

        if (self.appid) |appid|
            allocator.free(appid);
    }
};

const LuaClosure = struct {
    ref: i32,
    upvs: []i32,
    lua: *Lua,

    pub fn deinit(self: LuaClosure) void {
        self.lua.unref(zlua.registry_index, self.ref);
        std.log.info("unref: {}", .{self.ref});
    }

    pub fn toLua(self: LuaClosure, lua: *Lua) void {
        _ = lua.rawGetIndex(zlua.registry_index, self.ref);
    }

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaClosure {
        if (!lua.isFunction(index)) return error.LuaError;

        lua.pushValue(index); // func
        const r = try lua.ref(zlua.registry_index);

        var info: zlua.DebugInfo = undefined;
        lua.pushValue(index); // func
        lua.getInfo(.{ .@">" = true, .u = true }, &info);

        const upvs = try allocator.alloc(i32, info.num_upvalues);
        for (1..info.num_upvalues + 1) |v| {
            _ = try lua.getUpvalue(index, @intCast(v)); // func table upv
            upvs[v - 1] = try lua.ref(zlua.registry_index);
        }

        return .{
            .lua = lua,
            .ref = r,
            .upvs = upvs,
        };
    }
};

const LuaRect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaRect {
        const top = lua.getTop();
        defer lua.setTop(top);

        lua.pushValue(index);

        _ = lua.getField(-1, "x");
        const x = lua.toNumber(-1) catch 0;
        lua.pop(1);

        _ = lua.getField(-1, "y");
        const y = lua.toNumber(-1) catch 0;
        lua.pop(1);

        _ = lua.getField(-1, "width");
        const w = lua.toNumber(-1) catch 0;
        lua.pop(1);

        _ = lua.getField(-1, "height");
        const h = lua.toNumber(-1) catch 0;
        lua.pop(1);

        return .{
            .x = x,
            .y = y,
            .width = w,
            .height = h,
        };
    }

    pub fn toLua(self: LuaRect, lua: *Lua) void {
        lua.newTable();
        lua.pushNumber(self.x);
        lua.setField(-2, "x");
        lua.pushNumber(self.y);
        lua.setField(-2, "y");
        lua.pushNumber(self.width);
        lua.setField(-2, "width");
        lua.pushNumber(self.height);
        lua.setField(-2, "height");
    }
};

pub const LuaVec = struct {
    x: f64,
    y: f64,

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaVec {
        const top = lua.getTop();
        defer lua.setTop(top);

        lua.pushValue(index);

        _ = lua.getField(-1, "x");
        const x = lua.toNumber(f64, -1) catch 0;
        lua.pop(1);

        _ = lua.getField(-1, "y");
        const y = lua.toNumber(f64, -1) catch 0;
        lua.pop(1);

        return .{
            .x = x,
            .y = y,
        };
    }

    pub fn toLua(self: LuaVec, lua: *Lua) void {
        lua.newTable();
        lua.pushNumber(self.x);
        lua.setField(-2, "x");
        lua.pushNumber(self.y);
        lua.setField(-2, "y");
    }
};

pub const LuaModule = struct {
    calls: LuaClosure,
    lua: *Lua,

    const LuaMethods = struct {
        pub fn new(text: LuaClosure) LuaModule {
            std.log.info("new module {}", .{text.ref});

            return .{
                .calls = text,
                .lua = text.lua,
            };
        }
    };

    pub fn getText(self: *LuaModule, client: *Client) ![:0]const u8 {
        const lua = self.lua;

        const old_top = lua.getTop();

        try lua.pushAny(self.calls);
        try lua.pushAny(LuaClient{ .child = client });
        lua.protectedCall(.{ .args = 1, .results = 1 }) catch |err| {
            std.log.err("{s} Error: {s}", .{ @errorName(err), self.lua.toString(-1) catch "unknown" });
            self.lua.pop(1);

            return try allocator.dupeZ(u8, "Err");
        };

        const lua_result: []const u8 = lua.toString(-1) catch "";
        const result = try allocator.dupeZ(u8, lua_result);
        lua.pop(1);

        if (old_top != lua.getTop())
            return error.LuaError;

        return result;
    }

    pub fn deinit(self: *LuaModule) void {
        self.calls.deinit();
    }

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaModule {
        const result = try lua.toUserdata(LuaModule, index);
        return result.*;
    }

    pub fn toLua(self: LuaModule, lua: *Lua) !void {
        const tmp = lua.newUserdata(LuaModule, 1);
        tmp.* = self;

        lua.setMetatableRegistry("Module");
    }
};

const LuaTag = struct {
    id: u8,

    const LuaMethods = struct {};

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaTag {
        const result = try lua.toUserdata(LuaTag, index);
        return result.*;
    }

    pub fn toLua(self: LuaTag, lua: *Lua) void {
        const tmp = lua.newUserdata(LuaTag, 0);
        tmp.* = self;

        lua.setMetatableRegistry("Tag");
    }
};

const LuaContainer = struct {
    child: *Layout.Container,

    const LuaMethods = struct {
        pub fn set_stack(parent: *LuaContainer, stack: ?u8) void {
            const self = parent.child;

            self.stack = stack;
        }

        pub fn add_child(parent: *LuaContainer, x_min: f64, y_min: f64, x_max: f64, y_max: f64) !LuaContainer {
            const self = parent.child;

            const container = try allocator.create(Layout.Container);
            container.* = .{
                .stack = null,
                .size = .{
                    .x_min = x_min,
                    .x_max = x_max,
                    .y_min = y_min,
                    .y_max = y_max,
                },
                .children = &.{},
            };

            self.children = try allocator.realloc(self.children, self.children.len + 1);
            self.children[self.children.len - 1] = container;

            std.log.info("child: {}", .{self.children.len - 1});
            return .{ .child = container };
        }
    };

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaContainer {
        const result = try lua.toUserdata(LuaContainer, index);
        return result.*;
    }

    pub fn toLua(self: LuaContainer, lua: *Lua) void {
        const tmp = lua.newUserdata(LuaContainer, 0);
        tmp.* = self;

        lua.setMetatableRegistry("Container");
    }
};

const LuaLayout = struct {
    child: *Layout,

    const LuaMethods = struct {
        pub fn root(self: *LuaLayout) LuaContainer {
            return .{
                .child = self.child.container,
            };
        }
    };

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaLayout {
        const result = try lua.toUserdata(LuaLayout, index);
        return result.*;
    }

    pub fn toLua(self: LuaLayout, lua: *Lua) void {
        const tmp = lua.newUserdata(LuaLayout, 0);
        tmp.* = self;

        lua.setMetatableRegistry("Layout");
    }
};

pub const LuaMonitor = struct {
    child: *Monitor,

    const LuaMethods = struct {
        pub fn get_size(self: *LuaMonitor) !LuaRect {
            return .{
                .x = @floatFromInt(self.child.mode.x),
                .y = @floatFromInt(self.child.mode.y),
                .width = @floatFromInt(self.child.mode.width),
                .height = @floatFromInt(self.child.mode.height),
            };
        }

        pub fn get_tag(self: *LuaMonitor) !LuaTag {
            return .{ .id = self.child.tag };
        }

        pub fn set_tag(self: *LuaMonitor, tag: *LuaTag) void {
            self.child.setActiveTag(tag.id);

            std.log.info("set tag {}", .{tag.id});
        }

        pub fn get_layout(self: *LuaMonitor) ?LuaLayout {
            return .{
                .child = self.child.layout orelse return null,
            };
        }

        pub fn set_layout(self: *LuaMonitor, layout: LuaLayout) void {
            std.log.info("set layout {}", .{layout});

            self.child.setLayout(layout.child);
        }

        pub fn set_inner_gaps(self: *LuaMonitor, size: i32) void {
            self.child.setGaps(.inner, size);
        }

        pub fn set_outer_gaps(self: *LuaMonitor, size: i32) void {
            self.child.setGaps(.outer, size);
        }
    };

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaMonitor {
        const result = try lua.toUserdata(LuaMonitor, index);
        return result.*;
    }

    pub fn toLua(self: LuaMonitor, lua: *Lua) void {
        const tmp = lua.newUserdata(LuaMonitor, 0);
        tmp.* = self;

        lua.setMetatableRegistry("Monitor");
    }
};

const LuaClient = struct {
    child: *Client,

    const LuaMethods = struct {
        pub fn get_position(self: *LuaClient) !LuaRect {
            return .{
                .x = @floatFromInt(self.child.floating_bounds.x),
                .y = @floatFromInt(self.child.floating_bounds.y),
                .width = @floatFromInt(self.child.floating_bounds.width),
                .height = @floatFromInt(self.child.floating_bounds.height),
            };
        }

        pub fn set_position(self: *LuaClient, target: LuaRect) void {
            self.child.setFloatingSize(.{
                .x = @intFromFloat(target.x),
                .y = @intFromFloat(target.y),
                .width = @intFromFloat(target.width),
                .height = @intFromFloat(target.height),
            });
        }

        pub fn get_fullscreen(self: *LuaClient) bool {
            return self.child.fullscreen;
        }

        pub fn set_fullscreen(self: *LuaClient, fullscreen: bool) void {
            self.child.setFullscreen(fullscreen);
        }

        pub fn set_border(self: *LuaClient, border: i32) void {
            self.child.setBorder(border);
        }

        pub fn set_icon(self: *LuaClient, icon: ?[:0]const u8) void {
            self.child.setIcon(@ptrCast(icon));
        }

        pub fn set_label(self: *LuaClient, label: ?[:0]const u8) void {
            self.child.setLabel(label);
        }

        pub fn get_label(self: *LuaClient) ?[:0]const u8 {
            return self.child.label;
        }

        pub fn get_appid(self: *LuaClient) ?[:0]const u8 {
            return self.child.getAppId();
        }

        pub fn get_title(self: *LuaClient) ?[:0]const u8 {
            return self.child.getTitle();
        }

        pub fn get_icon(self: *LuaClient) ?[:0]const u8 {
            return self.child.icon;
        }

        pub fn set_tag(self: *LuaClient, tag: *LuaTag) void {
            self.child.setTag(tag.id);
        }

        pub fn set_monitor(self: *LuaClient, monitor: LuaMonitor) void {
            self.child.setMonitor(monitor.child);
        }

        pub fn set_stack(self: *LuaClient, stack: u8) void {
            self.child.setContainer(stack);
            self.child.setFloating(false);

            std.log.info("set container {}", .{stack});
        }

        pub fn set_container(self: *LuaClient, container: *LuaContainer) void {
            if (container.child.stack) |stack| {
                self.child.setContainer(stack);
                self.child.setFloating(false);

                std.log.info("set container {}", .{stack});
            }
        }

        pub fn get_floating(self: *LuaClient) bool {
            return self.child.floating;
        }

        pub fn set_floating(self: *LuaClient, value: bool) void {
            self.child.setFloating(value);
        }

        pub fn get_stack(self: *LuaClient) ?LuaStack {
            if (self.child.floating) return null;
            return .{ .id = self.child.container };
        }

        pub fn close(self: *LuaClient) void {
            self.child.close();
        }

        pub fn raw_set_modules(lua: *Lua) !i32 {
            const old_top = lua.getTop();

            const self: *LuaClient = try lua.toAny(*LuaClient, -2);

            self.child.tab.left_modules.clearRetainingCapacity();
            self.child.tab.center_modules.clearRetainingCapacity();
            self.child.tab.right_modules.clearRetainingCapacity();
            self.child.dirty.title = true;

            _ = lua.getField(-1, "left");
            const left_len = lua.rawLen(-1);

            for (1..left_len + 1) |idx| {
                _ = try lua.pushAny(idx);
                _ = lua.getTable(-2);
                defer lua.pop(1);

                try self.child.tab.left_modules.append(try lua.toAny(LuaModule, -1));
            }

            lua.pop(1);

            _ = lua.getField(-1, "center");
            const center_len = lua.rawLen(-1);

            for (1..center_len + 1) |idx| {
                _ = try lua.pushAny(idx);
                _ = lua.getTable(-2);
                defer lua.pop(1);

                try self.child.tab.center_modules.append(try lua.toAny(LuaModule, -1));
            }

            lua.pop(1);

            _ = lua.getField(-1, "right");
            const right_len = lua.rawLen(-1);

            for (1..right_len + 1) |idx| {
                _ = try lua.pushAny(idx);
                _ = lua.getTable(-2);
                defer lua.pop(1);

                try self.child.tab.right_modules.append(try lua.toAny(LuaModule, -1));
            }

            lua.pop(1);

            if (old_top != lua.getTop() + 0)
                return error.LuaError;

            return 0;
        }
    };

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaClient {
        const result = try lua.toUserdata(LuaClient, index);
        return result.*;
    }

    pub fn toLua(self: LuaClient, lua: *Lua) void {
        const tmp = lua.newUserdata(LuaClient, 0);
        tmp.* = self;

        lua.setMetatableRegistry("Client");
    }
};

const LuaStack = struct {
    id: u8,

    const LuaMethods = struct {};

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaStack {
        const result = try lua.toUserdata(LuaStack, index);
        return result.*;
    }

    pub fn toLua(self: LuaStack, lua: *Lua) void {
        const tmp = lua.newUserdata(LuaStack, 0);
        tmp.* = self;

        lua.setMetatableRegistry("Stack");
    }
};

const LuaMethods = struct {
    pub fn is_debug() bool {
        return @import("builtin").mode == .Debug;
    }

    pub fn quit(self: *Config) !void {
        const session: *Session = @fieldParentPtr("config", self);

        session.quit();
    }

    pub fn active_client(self: *Config) ?LuaClient {
        const session: *Session = @fieldParentPtr("config", self);

        return .{
            .child = session.focusedClient() orelse return null,
        };
    }

    pub fn active_monitor(self: *Config) ?LuaMonitor {
        const session: *Session = @fieldParentPtr("config", self);

        return .{
            .child = session.focusedMonitor orelse return null,
        };
    }

    pub fn cycle_focus(self: *Config, dir: i32) !void {
        const session: *Session = @fieldParentPtr("config", self);

        if (dir == 1)
            try session.focusStack(.forward)
        else if (dir == -1)
            try session.focusStack(.backward)
        else
            return error.BadCycleDirection;
    }

    pub fn spawn(_: *Config, name: [:0]const u8, args: [][*:0]const u8) !void {
        const child_name = try allocator.dupeZ(u8, name);
        const child_args: [:null]?[*:0]const u8 = (try std.mem.concatWithSentinel(allocator, ?[*:0]const u8, &.{ &.{child_name}, args, &.{null} }, null));

        const pid = std.posix.fork() catch {
            return error.Other;
        };

        if (pid == 0) {
            for (child_args) |arg|
                std.log.info("run {?s}", .{arg});

            cleanupChild();

            const pid2 = std.posix.fork() catch c._exit(1);
            if (pid2 == 0) {
                std.posix.execvpeZ(child_name, child_args, std.c.environ) catch c._exit(1);
            }

            c._exit(0);
        }

        // Wait the intermediate child.
        const ret = std.posix.waitpid(pid, 0);
        if (!std.posix.W.IFEXITED(ret.status) or
            (std.posix.W.IFEXITED(ret.status) and std.posix.W.EXITSTATUS(ret.status) != 0))
        {}
    }

    pub fn set_font(self: *Config, face: []const u8, size: f32) !void {
        self.font.deinit();

        self.font = .{
            .face = try allocator.dupeZ(u8, face),
            .size = @intFromFloat(size),
        };

        std.log.info("set font {}", .{self.font});
    }

    pub fn add_layout(self: *Config, name: []const u8) !LuaLayout {
        const container = try allocator.create(Layout.Container);

        container.* = .{
            .stack = null,
            .size = .{ .x_min = 0, .x_max = 1, .y_min = 0, .y_max = 1 },
            .children = &.{},
        };

        const layout = try allocator.create(Layout);

        layout.* = .{
            .name = try allocator.dupeZ(u8, name),
            .container = container,
        };

        try self.layouts.append(layout);

        return .{ .child = layout };
    }

    pub fn new_tag(self: *Config, name: [:0]const u8) !LuaTag {
        const name_dup = try allocator.dupeZ(u8, name);
        try self.tags.append(name_dup);

        std.log.info("create tag {s}", .{name_dup});

        return .{ .id = @intCast(self.tags.items.len - 1) };
    }

    pub fn set_color(self: *Config, active: bool, palette_name: []const u8, color_name: []const u8) !void {
        const session: *Session = @fieldParentPtr("config", self);

        var r: f32 = 1.0;
        var g: f32 = 1.0;
        var b: f32 = 1.0;
        var a: f32 = 1.0;

        std.log.info("color_name: {s}", .{color_name});

        if (color_name.len == 9) {
            if (color_name[0] != '#')
                return error.BadColor;

            const color = try std.fmt.parseInt(u32, color_name[1..], 16);
            r = @as(f32, @floatFromInt((color >> 24) & 0xff)) / 255;
            g = @as(f32, @floatFromInt((color >> 16) & 0xff)) / 255;
            b = @as(f32, @floatFromInt((color >> 8) & 0xff)) / 255;
            a = @as(f32, @floatFromInt((color >> 0) & 0xff)) / 255;
        } else if (color_name.len == 7) {
            if (color_name[0] != '#')
                return error.BadColor;

            const color = try std.fmt.parseInt(u32, color_name[1..], 16);
            r = @as(f32, @floatFromInt((color >> 16) & 0xff)) / 255;
            g = @as(f32, @floatFromInt((color >> 8) & 0xff)) / 255;
            b = @as(f32, @floatFromInt((color >> 0) & 0xff)) / 255;
            a = 1.0;
        } else return error.BadColor;

        const palette = std.meta.stringToEnum(PaletteColor, palette_name) orelse return error.BadLayer;

        std.log.info("rgba for {} {}, {} {} {} {}", .{ active, palette, r, g, b, a });

        if (active)
            self.active_colors.set(palette, .{ r, g, b, a })
        else
            self.inactive_colors.set(palette, .{ r, g, b, a });

        try session.reloadColors();
    }

    pub fn raw_add_bind(lua: *Lua) !i32 {
        const old_top = lua.getTop();

        const self = lua.toAny(*Config, -4) catch lua.raiseErrorStr("Not a Config", .{});
        const mod_names = lua.toString(-3) catch lua.raiseErrorStr("Not a string", .{});
        const key_name = lua.toString(-2) catch lua.raiseErrorStr("Not a string", .{});
        const calls = lua.toAny(LuaClosure, -1) catch lua.raiseErrorStr("Not a closure", .{});
        errdefer calls.deinit();

        var mods: wlr.Keyboard.ModifierMask = .{};

        for (mod_names) |m| {
            switch (std.ascii.toLower(m)) {
                'c' => mods.ctrl = true,
                's' => mods.shift = true,
                'l' => mods.logo = true,
                'a' => mods.alt = true,
                else => {},
            }
        }

        {
            const key: BindData = .{
                .key = xkb.Keysym.fromName(key_name, .case_insensitive),
                .mods = mods,
            };

            if (try self.binds.fetchPut(key, calls)) |value|
                value.value.deinit();

            std.log.info("create bind {}", .{key});
        }

        if (old_top != lua.getTop() + 0)
            return error.LuaError;

        return 0;
    }

    pub fn raw_add_mouse(lua: *Lua) !i32 {
        const old_top = lua.getTop();

        const self = lua.toAny(*Config, -4) catch lua.raiseErrorStr("Not a Config", .{});
        const mod_names = lua.toString(-3) catch lua.raiseErrorStr("Mods not a string", .{});
        const key_name = lua.toString(-2) catch lua.raiseErrorStr("Button not a string", .{});
        const calls = lua.toAny(LuaClosure, -1) catch lua.raiseErrorStr("Not a closure", .{});
        errdefer calls.deinit();

        var mods: wlr.Keyboard.ModifierMask = .{};

        for (mod_names) |m| {
            switch (std.ascii.toLower(m)) {
                'c' => mods.ctrl = true,
                's' => mods.shift = true,
                'l' => mods.logo = true,
                'a' => mods.alt = true,
                else => {},
            }
        }

        const button: u32 = if (std.mem.eql(u8, key_name, "Left"))
            272
        else if (std.mem.eql(u8, key_name, "Right"))
            273
        else
            return error.InvalidMouseButton;

        const key: MouseBindData = .{
            .button = button,
            .mods = mods,
        };

        if (try self.mouse_binds.fetchPut(key, calls)) |value|
            value.value.deinit();

        std.log.info("set mouse bind {}", .{key});

        if (old_top != lua.getTop() + 0)
            return error.LuaError;

        return 0;
    }

    pub fn raw_add_rule(lua: *Lua) !i32 {
        const old_top = lua.getTop();

        const self = lua.toAny(*Config, -3) catch lua.raiseErrorStr("Not a Config", .{});
        const filter = lua.toAny(LuaFilter, -2) catch lua.raiseErrorStr("Not a lua filter", .{});
        const calls = lua.toAny(LuaClosure, -1) catch lua.raiseErrorStr("Not a closure", .{});
        errdefer calls.deinit();

        try self.rules.append(.{
            .filter = filter,
            .calls = calls,
        });

        if (old_top != lua.getTop() + 0)
            return error.LuaError;

        return 0;
    }

    pub fn raw_add_hook(lua: *Lua) !i32 {
        const old_top = lua.getTop();

        const self = lua.toAny(*Config, -3) catch lua.raiseErrorStr("Not a Config", .{});
        const event_name = lua.toString(-2) catch lua.raiseErrorStr("Not a string", .{});
        const calls = lua.toAny(LuaClosure, -1) catch lua.raiseErrorStr("Not a closure", .{});
        errdefer calls.deinit();

        const event_id = std.meta.stringToEnum(Event, event_name) orelse return error.BadEventName;

        try self.events.append(.{
            .event = event_id,
            .calls = calls,
        });

        if (old_top != lua.getTop() + 0)
            return error.LuaError;

        return 0;
    }
};

var original_rlimit: ?std.posix.rlimit = null;

// from river:
// https://github.com/riverwm/river/blob/46f77f30dcce06b7af0ec8dff5ae3e4fbc73176f/river/process.zig
fn cleanupChild() void {
    if (c.setsid() < 0) unreachable;
    if (std.posix.system.sigprocmask(std.posix.SIG.SETMASK, &std.posix.sigemptyset(), null) < 0) unreachable;

    const sig_dfl = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &sig_dfl, null);

    if (original_rlimit) |original| {
        std.posix.setrlimit(.NOFILE, original) catch {
            std.log.err("failed to restore original file descriptor limit for " ++
                "child process, setrlimit failed", .{});
        };
    }
}

fn roFunction() !void {
    return error.ReadOnlySet;
}

inline fn globalType(lua: *Lua, comptime T: type, name: [:0]const u8) ConfigError!void {
    const info = @typeInfo(T.LuaMethods);

    if (info != .@"struct") @compileError("expected struct for pushtype");

    // create my method table
    lua.newTable();

    inline for (info.@"struct".decls) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, "raw_")) {
            const new_name = decl.name[4..];

            const field_value = @field(T.LuaMethods, decl.name);
            const field_type = @TypeOf(field_value);
            const field_info = @typeInfo(field_type);
            switch (field_info) {
                .@"fn" => {
                    lua.pushFunction(zlua.wrap(field_value));
                    lua.setField(-2, new_name);
                },
                else => {},
            }
        } else {
            const new_name = decl.name;

            const field_value = @field(T.LuaMethods, decl.name);
            const field_type = @TypeOf(field_value);
            const field_info = @typeInfo(field_type);
            switch (field_info) {
                .@"fn" => {
                    lua.autoPushFunction(field_value);
                    lua.setField(-2, new_name);
                },
                else => {},
            }
        }
    }

    lua.newTable();
    lua.autoPushFunction(roFunction);
    lua.setField(-2, "__new_index");
    lua.setMetatable(-2);

    try lua.newMetatable(name);
    lua.pushValue(-2);
    lua.setField(-2, "__index");

    if (@hasDecl(T, "fromLua")) {
        const Compare = struct {
            fn eq(a: T, b: T) bool {
                return std.meta.eql(a, b);
            }
        };
        lua.autoPushFunction(Compare.eq);
        lua.setField(-2, "__eq");
    }
    lua.pop(1);

    lua.setGlobal(name);
}

pub fn setupLua(self: *Config) ConfigError!void {
    // also https://github.com/riverwm/river/blob/46f77f30dcce06b7af0ec8dff5ae3e4fbc73176f/river/process.zig
    const sig_ign = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &sig_ign, null);

    // Most unix systems have a default limit of 1024 file descriptors and it
    // seems unlikely for this default to be universally raised due to the
    // broken behavior of select() on fds with value >1024. However, it is
    // unreasonable to use such a low limit for a process such as river which
    // uses many fds in its communication with wayland clients and the kernel.
    //
    // There is however an advantage to having a relatively low limit: it helps
    // to catch any fd leaks. Therefore, don't use some crazy high limit that
    // can never be reached before the system runs out of memory. This can be
    // raised further if anyone reaches it in practice.
    if (std.posix.getrlimit(.NOFILE)) |original| {
        original_rlimit = original;
        const new: std.posix.rlimit = .{
            .cur = @min(4096, original.max),
            .max = original.max,
        };
        if (std.posix.setrlimit(.NOFILE, new)) {
            std.log.info("raised file descriptor limit of the river process to {d}", .{new.cur});
        } else |_| {
            std.log.err("setrlimit failed, using system default file descriptor limit of {d}", .{
                original.cur,
            });
        }
    } else |_| {
        std.log.err("getrlimit failed, using system default file descriptor limit ", .{});
    }

    const home_dir = std.posix.getenv("HOME") orelse "./";
    const libs_dir = std.posix.getenv("CONPOSITOR_LIB_DIR") orelse "/usr/lib";

    const path: []const u8 = try std.mem.concat(allocator, u8, &.{
        home_dir,
        "/.config/conpositor/?.lua;",
        home_dir,
        "/.config/conpositor/?;",
        "?;",
        "?.lua;",
        libs_dir,
        "/?.lua;",
        libs_dir,
        "/?;",
        "/usr/lib/lua/?.lua;",
        "/usr/lib/lua/?;",
    });
    defer allocator.free(path);

    std.log.info("LUA_PATH: {s}", .{path});

    self.lua = try Lua.init(std.heap.c_allocator);
    const lua = self.lua;

    lua.openLibs();

    _ = try lua.getGlobal("package");

    _ = lua.pushString(path);
    lua.setField(-2, "path");
    lua.pop(1);

    try globalType(self.lua, Config, "Session");
    try globalType(self.lua, LuaContainer, "Container");
    try globalType(self.lua, LuaLayout, "Layout");
    try globalType(self.lua, LuaClient, "Client");
    try globalType(self.lua, LuaMonitor, "Monitor");
    try globalType(self.lua, LuaStack, "Stack");
    try globalType(self.lua, LuaTag, "Tag");
    try globalType(self.lua, LuaFilter, "Filter");
    try globalType(self.lua, LuaModule, "Module");

    try lua.pushAny(self);
    lua.setMetatableRegistry("Session");
    lua.setGlobal("session");
}

pub fn applyRules(self: *Config, client: *Client) !void {
    const lua = self.lua;

    const appid = client.getAppId();
    const title = client.getTitle();

    for (self.rules.items) |rule| {
        if (rule.filter.matches(title, appid)) {
            try lua.pushAny(rule.calls);
            try lua.pushAny(LuaClient{ .child = client });
            lua.protectedCall(.{ .args = 1, .results = 0 }) catch |err| {
                std.log.err("{s} Error: {s}", .{ @errorName(err), self.lua.toString(-1) catch "unknown" });
                self.lua.pop(1);
            };
        }
    }
}

pub fn mouseBind(self: *Config, bind: MouseBindData, pos: LuaVec, client: ?*Client) !bool {
    const lua = self.lua;

    const clientArg: ?LuaClient = if (client) |child| .{ .child = child } else null;

    if (self.mouse_binds.get(bind)) |bind_call| {
        try lua.pushAny(bind_call);
        try lua.pushAny(clientArg);
        try lua.pushAny(pos);
        lua.protectedCall(.{ .args = 2, .results = 0 }) catch |err| {
            std.log.err("{s} Error: {s}", .{ @errorName(err), self.lua.toString(-1) catch "unknown" });
            self.lua.pop(1);

            return false;
        };

        return true;
    }

    return false;
}

pub fn keyBind(self: *Config, bind: BindData) !bool {
    const lua = self.lua;

    if (self.binds.get(bind)) |bind_call| {
        try lua.pushAny(bind_call);
        lua.protectedCall(.{ .args = 0, .results = 0 }) catch |err| {
            std.log.err("{s} Error: {s}", .{ @errorName(err), self.lua.toString(-1) catch "unknown" });
            self.lua.pop(1);

            return false;
        };

        return true;
    }

    return false;
}

pub fn getFont(self: *Config) FontInfo {
    return self.font;
}

pub fn getColor(self: *Config, active: bool, palette: PaletteColor) *const [4]f32 {
    if (active)
        return self.active_colors.getPtrConst(palette)
    else
        return self.inactive_colors.getPtrConst(palette);
}

pub fn getLayouts(self: *Config) []*Layout {
    return self.layouts.items;
}

pub fn getTags(self: *Config) [][:0]const u8 {
    return self.tags.items;
}

pub fn getTitlePad(self: *Config) i32 {
    return self.title_pad;
}

pub fn getTitleHeight(self: *Config) i32 {
    return self.font.size + 2 * self.title_pad;
}

pub fn sourcePath(self: *Config, path: []const u8) ConfigError!void {
    const home_dir = std.posix.getenv("HOME") orelse "./";

    const cmd = try std.fmt.allocPrintZ(allocator, "{s}/.config/conpositor/{s}", .{
        home_dir,
        path,
    });
    defer allocator.free(cmd);

    self.lua.doFile(cmd) catch |err| {
        const result = self.lua.toString(-1) catch "unknown lua error";

        std.log.err("{!}: {s}", .{ err, result });

        var idx: i32 = 1;
        while (self.lua.getStack(idx) catch null) |di| : (idx += 1) {
            var tmp = di;

            self.lua.getInfo(.{ .n = true }, &tmp);
            std.log.info("{?s}", .{di.name});
        }
    };
}

pub fn run(self: *Config, command: []const u8) !?[:0]const u8 {
    const cmd = try allocator.dupeZ(u8, command);
    defer allocator.free(cmd);

    self.lua.doString(cmd) catch |err| {
        const result = self.lua.toString(-1) catch "unknown lua error";

        std.log.err("{!}: {s}", .{ err, result });

        var idx: i32 = 1;
        while (self.lua.getStack(idx) catch null) |di| : (idx += 1) {
            var tmp = di;

            self.lua.getInfo(.{ .n = true }, &tmp);
            std.log.info("{?s}", .{di.name});
        }

        return result;
    };

    return null;
}

pub fn sendEvent(self: *Config, comptime T: type, event_id: Event, data: T) ConfigError!bool {
    const lua = self.lua;

    var result = false;
    for (self.events.items) |event| {
        if (event.event != event_id)
            continue;

        _ = try lua.pushAny(event.calls);
        _ = try lua.pushAny(data);
        try lua.protectedCall(.{ .args = 1, .results = 1 });

        result = result or lua.toBoolean(-1);
        self.lua.pop(1);
    }

    return result;
}

pub fn conpositorLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@import("builtin").is_test) {
        return;
    }

    const scope_prefix = "(" ++ switch (scope) {
        std.log.default_log_scope => "conpositor",
        .SandEEE, .Steam => @tagName(scope),
        else => @tagName(scope),
    } ++ "): ";

    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;

    const color = switch (level) {
        .err => "\x1b[1;91m",
        .warn => "\x1b[1;33m",
        .info => "\x1b[1;37m",
        .debug => "\x1b[0;37m",
    };

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    // Print the message to stderr, silently ignoring any errors
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(prefix ++ color ++ format ++ "\x1b[m\n", args) catch return;
}

pub fn deinit(self: *Config) void {
    for (self.layouts.items) |layout|
        layout.deinit();

    for (self.rules.items) |rule|
        rule.filter.deinit();

    for (self.tags.items) |tag|
        allocator.free(tag);

    self.layouts.deinit();
    self.tags.deinit();
    self.binds.deinit();
    self.mouse_binds.deinit();
    self.rules.deinit();
    self.events.deinit();

    self.lua.deinit();
    self.font.deinit();
}
