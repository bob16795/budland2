const std = @import("std");
const zlua = @import("zlua");
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

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
};

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
pub const allocator = gpa.allocator();

pub var env: std.process.EnvMap = undefined;

const PaletteColor = enum { border, background, foreground };
const Event = enum { startup };

const FontInfo = struct {
    face: [*:0]const u8 = "monospace",
    size: i32 = 12,
};

const BindData = struct {
    mods: wlr.Keyboard.ModifierMask,
    key: xkb.Keysym,
};

title_pad: i32 = 5,
font: FontInfo = .{},
active_colors: std.EnumArray(PaletteColor, [4]f32) = .initFill(.{ 1, 1, 1, 1 }),
inactive_colors: std.EnumArray(PaletteColor, [4]f32) = .initFill(.{ 1, 1, 1, 1 }),
layouts: std.ArrayList(Layout) = .init(allocator),
tags: std.ArrayList([*:0]const u8) = .init(allocator),
binds: std.AutoHashMap(BindData, i32) = .init(allocator),
rules: std.ArrayList(struct { filter: LuaFilter, calls: i32 }) = .init(allocator),
events: std.EnumArray(Event, ?i32) = .initFill(null),
lua: *Lua = undefined,

const LuaFilter = struct {
    title: ?[]const u8,
    appid: ?[]const u8,

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
        const title = lua.toAny(?[]const u8, -1) catch null;
        lua.pop(1);

        _ = lua.getField(index, "appid");
        const appid = lua.toAny(?[]const u8, -1) catch null;
        lua.pop(1);

        return .{
            .title = title,
            .appid = appid,
        };
    }

    pub fn toLua(self: LuaFilter, lua: *Lua) !void {
        lua.newTable();
        if (self.title) |title| {
            lua.pushAny(title);
            lua.setField(-2, "title");
        }

        if (self.appid) |appid| {
            lua.pushAny(appid);
            lua.setField(-2, "appid");
        }
    }
};

const LuaTag = struct {
    id: u8,

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaTag {
        const result = try lua.toUserdata(LuaTag, index);
        return result.*;
    }

    pub fn toLua(self: LuaTag, lua: *Lua) !void {
        const tmp = lua.newUserdata(LuaTag, 0);
        tmp.* = self;

        lua.setMetatableRegistry("Tag");
    }
};

const LuaMonitor = struct {
    child: *Monitor,

    pub fn lua_get_tag(self: *LuaMonitor) !LuaTag {
        return .{ .id = self.child.tag };
    }

    pub fn lua_set_tag(self: *LuaMonitor, tag: *LuaTag) !void {
        try self.child.setTag(tag.id);

        std.log.info("set tag {}", .{tag.id});
    }

    pub fn lua_get_layout(self: *LuaMonitor) !i32 {
        return @intCast(self.child.layout);
    }

    pub fn lua_set_layout(self: *LuaMonitor, layout: i32) !void {
        try self.child.setLayout(layout);

        std.log.info("set layout {}", .{layout});
    }

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaMonitor {
        const result = try lua.toUserdata(LuaMonitor, index);
        return result.*;
    }

    pub fn toLua(self: LuaMonitor, lua: *Lua) !void {
        const tmp = lua.newUserdata(LuaMonitor, 0);
        tmp.* = self;

        lua.setMetatableRegistry("Monitor");
    }
};

const LuaClient = struct {
    child: *Client,

    pub fn lua_set_border(self: *LuaClient, border: i32) !void {
        try self.child.setBorder(border);
    }

    pub fn lua_set_icon(self: *LuaClient, icon: ?[*:0]const u8) !void {
        try self.child.setIcon(icon);
    }

    pub fn lua_set_label(self: *LuaClient, label: ?[*:0]const u8) !void {
        try self.child.setLabel(label);
    }

    pub fn lua_set_tag(self: *LuaClient, tag: *LuaTag) !void {
        try self.child.setTag(tag.id);
    }

    pub fn lua_set_container(self: *LuaClient, container: Layout.Container) !void {
        if (container.stack) |stack| {
            try self.child.setContainer(stack);
            try self.child.setFloating(false);

            std.log.info("set container {}", .{stack});
        }
    }

    pub fn lua_get_floating(self: *LuaClient) bool {
        return self.child.floating;
    }

    pub fn lua_set_floating(self: *LuaClient, value: bool) !void {
        try self.child.setFloating(value);
    }

    pub fn lua_get_stack(self: *LuaClient) ?LuaStack {
        if (self.child.floating) return null;
        return .{ .id = self.child.container };
    }

    pub fn lua_close(self: *LuaClient) void {
        self.child.close();
    }

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaClient {
        const result = try lua.toUserdata(LuaClient, index);
        return result.*;
    }

    pub fn toLua(self: LuaClient, lua: *Lua) !void {
        const tmp = lua.newUserdata(LuaClient, 0);
        tmp.* = self;

        lua.setMetatableRegistry("Client");
    }
};

const LuaStack = struct {
    id: u8,

    pub fn fromLua(lua: *Lua, _: ?std.mem.Allocator, index: i32) !LuaStack {
        const result = try lua.toUserdata(LuaStack, index);
        return result.*;
    }

    pub fn toLua(self: LuaStack, lua: *Lua) !void {
        const tmp = lua.newUserdata(LuaStack, 0);
        tmp.* = self;

        lua.setMetatableRegistry("Stack");
    }
};

pub fn spawnThread(argv: [][]const u8) void {
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .env_map = &env,
    }) catch {};
    allocator.free(argv);
}

pub fn lua_spawn(name: []const u8, args: [][]const u8) !void {
    const new_args = try std.mem.concat(allocator, []const u8, &.{ &.{name}, args });

    const thread = try std.Thread.spawn(
        .{ .allocator = allocator },
        spawnThread,
        .{new_args},
    );
    thread.detach();
}

pub fn lua_set_font(self: *Config, face: []const u8, size: f32) !void {
    self.font = .{
        .face = try allocator.dupeZ(u8, face),
        .size = @intFromFloat(size),
    };

    std.log.info("set font {}", .{self.font});
}

pub fn lua_add_layout(self: *Config, layout: Layout) !void {
    try self.layouts.append(layout);

    std.log.info("create layout {s}", .{layout.name});
}

pub fn lua_new_tag(self: *Config, name: [*:0]const u8) !LuaTag {
    try self.tags.append(name);

    std.log.info("create tag {s}", .{name});

    return .{ .id = @intCast(self.tags.items.len - 1) };
}

pub fn lua_set_color(self: *Config, active: bool, palette_name: []const u8, color_name: []const u8) !void {
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
}

pub fn lua_cycle_focus(self: *Config, dir: i32) !void {
    const session: *Session = @fieldParentPtr("config", self);

    if (dir == 1)
        try session.focusStack(.forward)
    else if (dir == -1)
        try session.focusStack(.backward)
    else
        return error.BadCycleDirection;
}

pub fn lua_active_monitor(self: *Config) ?LuaMonitor {
    const session: *Session = @fieldParentPtr("config", self);

    return .{
        .child = session.selmon orelse return null,
    };
}

pub fn lua_active_client(self: *Config) ?LuaClient {
    const session: *Session = @fieldParentPtr("config", self);

    return .{
        .child = session.focusedClient() orelse return null,
    };
}

pub fn lua_quit(self: *Config) !void {
    const session: *Session = @fieldParentPtr("config", self);

    session.quit();
}

pub fn lua_is_debug() bool {
    return @import("builtin").mode == .Debug;
}

pub fn luaraw_add_hook(lua: *Lua) !i32 {
    const self = lua.toAny(*Config, -3) catch lua.raiseErrorStr("Not a Config", .{});
    const event_name = lua.toAny([]const u8, -2) catch lua.raiseErrorStr("Not a string", .{});

    {
        const event_id = std.meta.stringToEnum(Event, event_name) orelse return error.BadEventName;

        _ = lua.getMetatableRegistry("Events");
        defer lua.pop(1);

        _ = lua.pushValue(-2);
        const calls = try lua.ref(-2);

        if (self.events.get(event_id)) |id|
            lua.unref(-1, id);

        self.events.set(event_id, calls);
    }

    return 0;
}

pub fn luaraw_add_rule(lua: *Lua) !i32 {
    const self = lua.toAny(*Config, -3) catch lua.raiseErrorStr("Not a Config", .{});
    const filter = lua.toAny(LuaFilter, -2) catch lua.raiseErrorStr("Not a lua filter", .{});

    {
        _ = lua.getMetatableRegistry("Rules");
        defer lua.pop(1);

        _ = lua.pushValue(-2);
        const calls = try lua.ref(-2);

        try self.rules.append(.{
            .filter = filter,
            .calls = calls,
        });
    }

    return 0;
}

pub fn luaraw_add_bind(lua: *Lua) !i32 {
    const self = lua.toAny(*Config, -4) catch lua.raiseErrorStr("Not a Config", .{});
    const mod_names = lua.toAny([]const u8, -3) catch lua.raiseErrorStr("Not a string", .{});
    const key_name = lua.toAny([*:0]const u8, -2) catch lua.raiseErrorStr("Not a string", .{});

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
        _ = lua.getMetatableRegistry("Binds");
        defer lua.pop(1);

        _ = lua.pushValue(-2);
        const calls = try lua.ref(-2);

        const key: BindData = .{
            .key = xkb.Keysym.fromName(key_name, .case_insensitive),
            .mods = mods,
        };

        if (self.binds.getPtr(key)) |value| {
            lua.unref(-1, value.*);

            value.* = calls;
            std.log.info("set bind {}", .{key});

            return 0;
        }

        try self.binds.put(key, calls);

        std.log.info("create bind {}", .{key});
    }

    return 0;
}

fn roFunction() !void {
    return error.ReadOnlySet;
}

pub inline fn globalType(lua: *Lua, comptime T: type, name: [:0]const u8) ConfigError!void {
    const info = @typeInfo(T);

    if (info != .@"struct") @compileError("expected struct for pushtype");

    // create my method table
    lua.newTable();

    std.log.info("add type " ++ name, .{});

    inline for (info.@"struct".decls) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, "lua_")) {
            const new_name = decl.name[4..];

            const field_value = @field(T, decl.name);
            const field_type = @TypeOf(field_value);
            const field_info = @typeInfo(field_type);
            switch (field_info) {
                .@"fn" => {
                    std.log.info("add function " ++ new_name, .{});
                    lua.autoPushFunction(field_value);
                    lua.setField(-2, new_name);
                },
                else => {},
            }
        } else if (comptime std.mem.startsWith(u8, decl.name, "luaraw_")) {
            const new_name = decl.name[7..];

            const field_value = @field(T, decl.name);
            const field_type = @TypeOf(field_value);
            const field_info = @typeInfo(field_type);
            switch (field_info) {
                .@"fn" => {
                    std.log.info("add raw function " ++ new_name, .{});
                    lua.pushFunction(zlua.wrap(field_value));
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

    lua.newMetatable(name) catch |err| switch (err) {
        error.LuaError => return error.OutOfMemory,
    };
    lua.pushValue(-2);
    lua.setField(-2, "__index");
    lua.pop(1);

    lua.setGlobal(name);
}

pub fn setupLua(self: *Config) ConfigError!void {
    const home_dir = std.posix.getenv("HOME") orelse "./";

    const path: []const u8 = try std.mem.concat(allocator, u8, &.{
        home_dir,
        "/.config/conpositor/?.lua;",
        home_dir,
        "/.config/conpositor/?;",
        "?;",
        "?.lua",
    });

    std.log.info("LUA_PATH: {s}", .{path});

    self.lua = try Lua.init(allocator);
    const lua = self.lua;

    lua.openLibs();

    _ = lua.getGlobal("package") catch return error.OutOfMemory;

    _ = try lua.pushAny(path);
    lua.setField(-2, "path");
    lua.pop(1);

    try globalType(lua, Config, "Session");
    try globalType(self.lua, Layout.Container, "Container");
    try globalType(self.lua, Layout, "Layout");
    try globalType(self.lua, LuaClient, "Client");
    try globalType(self.lua, LuaMonitor, "Monitor");
    try globalType(self.lua, LuaStack, "Stack");
    try globalType(self.lua, LuaTag, "Tag");
    try globalType(self.lua, LuaFilter, "Filter");

    lua.newMetatable("Binds") catch return error.OutOfMemory;
    lua.pop(1);

    lua.newMetatable("Rules") catch return error.OutOfMemory;
    lua.pop(1);

    lua.newMetatable("Events") catch return error.OutOfMemory;
    lua.pop(1);

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
            _ = lua.getMetatableRegistry("Rules");
            defer lua.pop(1);
            _ = lua.rawGetIndex(-1, rule.calls);

            _ = try lua.pushAny(LuaClient{ .child = client });
            lua.protectedCall(.{ .args = 1, .results = 0 }) catch |err| {
                std.log.err("{s} Error: {s}", .{ @errorName(err), self.lua.toString(-1) catch "unknown" });
                self.lua.pop(1);
            };
        }
    }
}

pub fn keyBind(self: *Config, bind: BindData) !bool {
    const lua = self.lua;

    if (self.binds.get(bind)) |bind_idx| {
        _ = lua.getMetatableRegistry("Binds");
        defer lua.pop(1);

        _ = lua.rawGetIndex(-1, bind_idx);
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

pub fn getLayouts(self: *Config) []Layout {
    return self.layouts.items;
}

pub fn getTags(self: *Config) [][*:0]const u8 {
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

pub fn sendEvent(self: *Config, event_id: Event) !void {
    const lua = self.lua;

    if (self.events.get(event_id)) |event_idx| {
        _ = lua.getMetatableRegistry("Events");
        defer lua.pop(1);

        _ = lua.rawGetIndex(-1, event_idx);
        lua.protectedCall(.{ .args = 0, .results = 0 }) catch |err| {
            std.log.err("{s} Error: {s}", .{ @errorName(err), self.lua.toString(-1) catch "unknown" });
            self.lua.pop(1);
        };
    }
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
