const std = @import("std");

const Layout = @import("layout.zig");
const Session = @import("session.zig");
const Lua = @import("zlua").Lua;

const Config = @This();

pub const ConfigError = error{
    Unimplemented,
    LuaSyntax,
    LuaFile,
    LuaRuntime,
    LuaMsgHandler,
};

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
pub const allocator = gpa.allocator();

pub var wayland_display: [*:0]const u8 = "";
pub var xwayland_display: [*:0]const u8 = "";

const PaletteColor = enum { border, background, foreground };
const Event = enum { startup };

const FontInfo = struct {
    face: [*:0]const u8 = "monospace",
    size: i32 = 12,
};

title_pad: i32 = 0,
font: FontInfo = .{},
active_colors: std.EnumArray(PaletteColor, [4]f32) = .initFill(.{ 1, 0, 0, 0 }),
inactive_colors: std.EnumArray(PaletteColor, [4]f32) = .initFill(.{ 0, 0, 0, 0 }),
containers: []Layout.Container = &.{},
layouts: []Layout = &.{},
tags: [][*:0]const u8 = &.{},
lua: *Lua = undefined,

pub fn setupLua(self: *Config) !void {
    self.lua = try Lua.init(allocator);
    // self.lua.define();
}

pub fn getFont(self: *Config) FontInfo {
    return self.font;
}

pub fn getColor(self: *Config, active: bool, palette: PaletteColor) *const [4]f32 {
    if (active)
        return &self.active_colors.get(palette)
    else
        return &self.inactive_colors.get(palette);
}

pub fn getContainers(self: *Config) []Layout.Container {
    return self.containers;
}

pub fn getLayouts(self: *Config) []Layout {
    return self.layouts;
}

pub fn getTags(self: *Config) [][*:0]const u8 {
    return self.tags;
}

pub fn getTitlePad(self: *Config) i32 {
    return self.title_pad;
}

pub fn getTitleHeight(self: *Config) i32 {
    return self.font.size + 2 * self.title_pad;
}

pub fn sourcePath(self: *Config, path: []const u8) !void {
    const cmd = try allocator.dupeZ(u8, path);
    defer allocator.free(cmd);

    try self.lua.doFile(cmd);
}

pub fn run(self: *Config, command: []const u8) !void {
    const cmd = try allocator.dupeZ(u8, command);
    defer allocator.free(cmd);

    try self.lua.doString(cmd);
}

pub fn event(self: *Config, session: *Session, event_id: Event) !void {
    _ = self;
    _ = session;
    _ = event_id;

    // return error.Unimplemented;
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
        else => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err))
            @tagName(scope)
        else
            return,
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
    if (@import("builtin").mode == .Debug) {
        const stderr = std.io.getStdErr().writer();
        nosuspend stderr.print(prefix ++ color ++ format ++ "\x1b[m\n", args) catch return;
    }
}
